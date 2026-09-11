// @windowkit/appkit calendars.mm — the user's calendars, the occurrences in
// a date range, and the writes — an event put in, changed, or taken out —
// through EventKit (EKEventStore).
//
// Every account the user added in System Settings › Internet Accounts —
// iCloud, Google, Exchange, CalDAV, a subscribed feed — is served by this one
// framework, the macOS counterpart of Evolution Data Server plus GNOME Online
// Accounts: the desktop did the OAuth, and the app never sees a credential.
//
//   calendars(cb)                                   cb(err, [calendar])
//   eventsBetween({ start, end, calendars? }, cb)   cb(err, [event]) — epoch ms
//   defaultCalendar(cb)                             cb(err, calendar | null)
//   saveEvent(props, opts?, cb)                     cb(err, id)
//   removeEvent(id, opts?, cb)                      cb(err)
//   commitCalendarStore(cb)                         cb(err) — a batch saved with commit: false
//   resetCalendarStore(cb)                          cb(null) — forgets such a batch
//   event: calendar-store-changed {}                EKEventStoreChangedNotification
//
// Mechanism only, policy stays in the renderer: which calendars to show, how
// to render an all-day span, when to re-query, what to put in an event.
//
// Three things EventKit does that a D-Bus (Evolution) rung has to do for
// itself: the predicate answers *occurrences*, so recurrences are already
// expanded and no iCalendar parser is needed here; one notification is posted
// for any change at all, whose documented contract is "re-fetch"; and it
// answers fast enough not to matter as long as the fetch is off the JS
// thread.
//
// Threading. eventsMatchingPredicate: is synchronous and can take a while
// over many calendars, so both reads run on a background queue and answer
// through a thread-safe function — the automation request in permissions.mm
// is the shape. Fetches are documented thread-safe on EKEventStore; the
// store itself is taken on the JS thread (it is a process-wide singleton,
// and reaching for it from two queues at once would be a race), and what the
// framework hands back is copied into the plain C++ shapes below on the
// background queue, so nothing EventKit-owned crosses to JS. The writes take
// a serial queue of their own at the same QoS: off the JS thread like the
// reads, but one after another, so a batch — saves with commit: false, then
// commitCalendarStore — is applied in the order it was asked, and two saves
// never touch the store at once.
//
// All-day events cross as the store reports them: allDay true, startDate at
// local midnight and endDate at the last second of the last day. Normalising
// that to an exclusive end is the renderer's job; the bridge is mechanism,
// and its test pins the convention so the renderer's normalisation has
// something to be checked against. A write takes the same convention.
//
// A store without a grant answers cb(err) naming the status — never [] — so
// "no events" and "not allowed to look" stay distinguishable. The grant
// itself is permissions.mm's ('calendars', windowkit/appkit#39); the store is
// shared with it, and no verb here prompts. Reading needs the full grant; a
// write is content with macOS 14's write-only one, which is why #39 carries
// { access }.
//
// A write. A new EKEvent comes from eventWithEventStore:, an existing one
// from eventWithIdentifier: — the first occurrence of a recurring event, or
// the occurrence at props.occurrenceDate, found through the same predicate
// the reads use — and goes to saveEvent:span:commit:error: /
// removeEvent:span:commit:error:. What the framework refuses crosses as the
// EKErrorDomain code and message (EKErrorCalendarReadOnly, EKErrorNoCalendar,
// EKErrorDatesInverted, …), never as a bare boolean; what it *raises* — a
// recurrence it cannot build, an object from another store — is caught and
// crosses the same way rather than ending the process, since an exception
// escaping a dispatch block is fatal. The recurrence shape is
// EKRecurrenceRule's own vocabulary, what its initialisers take, not an
// RRULE string: a consumer holding iCalendar text parses it on its own side,
// and the bridge carries no grammar. A successful commit is followed by the
// store's own change notification, which is how the reader learns of it —
// and how the consumer's own change and someone else's look the same.
//
// A store holding only the write-only grant can save but not read back:
// eventWithIdentifier: answers nil there, so changing or removing an event
// by id is refused as the EKError it is (EKErrorEventStoreNotAuthorized)
// rather than reported as success.
//
// The change observer is installed when that store is created, so it is in
// place before any listener could be; the event goes out through the same
// backend callback every other event takes, and one that arrives before
// there is a listener is held and replayed at the next pump, as
// notifications.mm does. The framework coalesces changes, and a duplicate is
// harmless to a renderer whose answer to one is to re-query.

#include <napi.h>
#import <Cocoa/Cocoa.h>
#import <EventKit/EventKit.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <utility>
#include <vector>

// backend.mm / threaded.mm: the one backend event path
#include "channel.h"

// permissions.mm: the process's one EKEventStore — created by the first
// EventKit verb and never before, since creating one never prompts — and
// EventKit's authorization word for events, Apple's mapping kept in one
// place.
EKEventStore* CALEventStore();
const char* CALEventsAuthorizationStatus();

// EventKit's own limit on predicateForEventsWithStartDate:endDate:calendars:
// is a four-year span, taken here as 1461 days (four years with one leap
// day). A longer request is refused at the bridge rather than silently
// truncated by the framework; the renderer chunks.
static const double kMaxSpanMs = 1461.0 * 24 * 60 * 60 * 1000;

// Where to look for one occurrence of a recurring event: the predicate's
// widest span, centred on the occurrence's place in the series. A detached
// occurrence lives where it was moved to, not where the series put it, and
// this finds one moved by up to two years either way.
static const double kOccurrenceWindowS = 730.0 * 24 * 60 * 60;

// --- Apple's enums, as words -----------------------------------------------

static const char* CalendarTypeName(EKCalendarType t) {
  switch (t) {
    case EKCalendarTypeCalDAV: return "calDAV";
    case EKCalendarTypeExchange: return "exchange";
    case EKCalendarTypeSubscription: return "subscription";
    case EKCalendarTypeBirthday: return "birthday";
    case EKCalendarTypeLocal:
    default: return "local";
  }
}

static const char* SourceTypeName(EKSourceType t) {
  switch (t) {
    case EKSourceTypeExchange: return "exchange";
    case EKSourceTypeCalDAV: return "calDAV";
    case EKSourceTypeMobileMe: return "mobileMe";
    case EKSourceTypeSubscribed: return "subscribed";
    case EKSourceTypeBirthdays: return "birthdays";
    case EKSourceTypeLocal:
    default: return "local";
  }
}

static const char* EventStatusName(EKEventStatus s) {
  switch (s) {
    case EKEventStatusConfirmed: return "confirmed";
    case EKEventStatusTentative: return "tentative";
    case EKEventStatusCanceled: return "cancelled";
    case EKEventStatusNone:
    default: return "none";
  }
}

static const char* AvailabilityName(EKEventAvailability a) {
  switch (a) {
    case EKEventAvailabilityBusy: return "busy";
    case EKEventAvailabilityFree: return "free";
    case EKEventAvailabilityTentative: return "tentative";
    case EKEventAvailabilityUnavailable: return "unavailable";
    case EKEventAvailabilityNotSupported:
    default: return "notSupported";
  }
}

static const char* ParticipantStatusName(EKParticipantStatus s) {
  switch (s) {
    case EKParticipantStatusPending: return "pending";
    case EKParticipantStatusAccepted: return "accepted";
    case EKParticipantStatusDeclined: return "declined";
    case EKParticipantStatusTentative: return "tentative";
    case EKParticipantStatusDelegated: return "delegated";
    case EKParticipantStatusCompleted: return "completed";
    case EKParticipantStatusInProcess: return "inProcess";
    case EKParticipantStatusUnknown:
    default: return "unknown";
  }
}

static const char* ParticipantRoleName(EKParticipantRole r) {
  switch (r) {
    case EKParticipantRoleRequired: return "required";
    case EKParticipantRoleOptional: return "optional";
    case EKParticipantRoleChair: return "chair";
    case EKParticipantRoleNonParticipant: return "nonParticipant";
    case EKParticipantRoleUnknown:
    default: return "unknown";
  }
}

static const char* ParticipantTypeName(EKParticipantType t) {
  switch (t) {
    case EKParticipantTypePerson: return "person";
    case EKParticipantTypeRoom: return "room";
    case EKParticipantTypeResource: return "resource";
    case EKParticipantTypeGroup: return "group";
    case EKParticipantTypeUnknown:
    default: return "unknown";
  }
}

static const char* FrequencyName(EKRecurrenceFrequency f) {
  switch (f) {
    case EKRecurrenceFrequencyWeekly: return "weekly";
    case EKRecurrenceFrequencyMonthly: return "monthly";
    case EKRecurrenceFrequencyYearly: return "yearly";
    case EKRecurrenceFrequencyDaily:
    default: return "daily";
  }
}

static bool ParseFrequency(const std::string& s, EKRecurrenceFrequency* out) {
  if (s == "daily") *out = EKRecurrenceFrequencyDaily;
  else if (s == "weekly") *out = EKRecurrenceFrequencyWeekly;
  else if (s == "monthly") *out = EKRecurrenceFrequencyMonthly;
  else if (s == "yearly") *out = EKRecurrenceFrequencyYearly;
  else return false;
  return true;
}

// The four a consumer can set; notSupported is what a source answers, not a
// thing to ask for.
static bool ParseAvailability(const std::string& s, EKEventAvailability* out) {
  if (s == "busy") *out = EKEventAvailabilityBusy;
  else if (s == "free") *out = EKEventAvailabilityFree;
  else if (s == "tentative") *out = EKEventAvailabilityTentative;
  else if (s == "unavailable") *out = EKEventAvailabilityUnavailable;
  else return false;
  return true;
}

// EKErrorCode's names, so an error crosses as the word the framework's own
// header uses and not only as its number. nullptr for a code this SDK's
// header does not name.
static const char* EKErrorName(NSInteger code) {
  switch (code) {
#define EK(name) case name: return #name;
    EK(EKErrorEventNotMutable)
    EK(EKErrorNoCalendar)
    EK(EKErrorNoStartDate)
    EK(EKErrorNoEndDate)
    EK(EKErrorDatesInverted)
    EK(EKErrorInternalFailure)
    EK(EKErrorCalendarReadOnly)
    EK(EKErrorDurationGreaterThanRecurrence)
    EK(EKErrorAlarmGreaterThanRecurrence)
    EK(EKErrorStartDateTooFarInFuture)
    EK(EKErrorStartDateCollidesWithOtherOccurrence)
    EK(EKErrorObjectBelongsToDifferentStore)
    EK(EKErrorInvitesCannotBeMoved)
    EK(EKErrorInvalidSpan)
    EK(EKErrorCalendarHasNoSource)
    EK(EKErrorCalendarSourceCannotBeModified)
    EK(EKErrorCalendarIsImmutable)
    EK(EKErrorSourceDoesNotAllowCalendarAddDelete)
    EK(EKErrorRecurringReminderRequiresDueDate)
    EK(EKErrorStructuredLocationsNotSupported)
    EK(EKErrorReminderLocationsNotSupported)
    EK(EKErrorAlarmProximityNotSupported)
    EK(EKErrorCalendarDoesNotAllowEvents)
    EK(EKErrorCalendarDoesNotAllowReminders)
    EK(EKErrorSourceDoesNotAllowReminders)
    EK(EKErrorSourceDoesNotAllowEvents)
    EK(EKErrorPriorityIsInvalid)
    EK(EKErrorInvalidEntityType)
    EK(EKErrorProcedureAlarmsNotMutable)
    EK(EKErrorEventStoreNotAuthorized)
    EK(EKErrorOSNotSupported)
    EK(EKErrorInvalidInviteReplyCalendar)
    EK(EKErrorNotificationsCollectionFlagNotSet)
    EK(EKErrorSourceMismatch)
    EK(EKErrorNotificationCollectionMismatch)
    EK(EKErrorNotificationSavedWithoutCollection)
    EK(EKErrorReminderAlarmContainsEmailOrUrl)
#undef EK
    default: return nullptr;
  }
}

// --- what the framework said, copied out of it ------------------------------

// A field the store may not have: it crosses as null rather than as an empty
// string, so "no location" and "an empty location" stay apart.
using MaybeString = std::optional<std::string>;

static MaybeString Copy(NSString* s) {
  if (!s) return std::nullopt;
  const char* c = s.UTF8String;
  if (!c) return std::nullopt;
  return std::string(c);
}

static MaybeString Copy(NSURL* u) { return Copy(u.absoluteString); }

static std::string CopyRequired(NSString* s) {
  MaybeString m = Copy(s);
  return m ? *m : std::string();
}

// Epoch ms, as the store reports the date.
static double Millis(NSDate* d) { return d.timeIntervalSince1970 * 1000.0; }

// A calendar's colour in sRGB, the space every colour crosses this bridge in
// (the 0.5.1 rule) — EKCalendar keeps a CGColor whose space is whatever the
// account gave it.
static bool CopyColor(CGColorRef c, double out[4]) {
  if (!c) return false;
  CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGColorRef conv = CGColorCreateCopyByMatchingToColorSpace(
      rgb, kCGRenderingIntentDefault, c, NULL);
  CGColorSpaceRelease(rgb);
  CGColorRef src = conv ? conv : c;
  const CGFloat* comps = CGColorGetComponents(src);
  size_t n = CGColorGetNumberOfComponents(src);
  bool ok = true;
  if (n == 4) {
    for (int i = 0; i < 4; i++) out[i] = (double)comps[i];
  } else if (n == 2) {  // greyscale
    out[0] = out[1] = out[2] = (double)comps[0];
    out[3] = (double)comps[1];
  } else {
    ok = false;
  }
  if (conv) CGColorRelease(conv);
  return ok;
}

struct CalInfo {
  std::string id, title;
  bool hasColor = false;
  double color[4] = {0, 0, 0, 0};
  const char* type = "local";
  std::string sourceId, sourceTitle;
  const char* sourceType = "local";
  bool immutable = false, allowsModifications = false, subscribed = false;
};

struct CalParticipant {
  MaybeString name, url;
  const char* status = "unknown";
  const char* role = "unknown";
  const char* type = "unknown";
  bool isCurrentUser = false;
};

// A recurrence rule in EKRecurrenceRule's own vocabulary — what its
// designated initialiser takes — the same shape read and written. The arrays
// are absent rather than empty when the rule has none.
struct DayOfWeek {
  int day = 1;   // 1..7, Sunday = 1 (EKWeekday)
  int week = 0;  // 0: every such day; ±1..: the nth (from the end) in the period
};

struct RuleInfo {
  EKRecurrenceFrequency frequency = EKRecurrenceFrequencyDaily;
  int interval = 1;
  std::optional<double> until;     // epoch ms; or
  std::optional<uint32_t> count;   // occurrences; neither: never ends
  std::optional<std::vector<DayOfWeek>> daysOfWeek;
  std::optional<std::vector<int>> daysOfMonth, monthsOfYear, weeksOfYear,
      daysOfYear, setPositions;
};

// An alarm: relative to the start (seconds, negative before it) or absolute.
struct AlarmInfo {
  bool absolute = false;
  double value = 0;  // seconds from the start, or epoch ms when absolute
};

struct CalEventInfo {
  MaybeString id, itemId, externalId;
  std::string calendar;
  MaybeString title, location, notes, url, timeZone;
  double start = 0, end = 0;
  bool allDay = false;
  const char* status = "none";
  const char* availability = "notSupported";
  bool recurring = false, detached = false;
  std::optional<double> occurrenceDate;
  std::optional<CalParticipant> organizer;
  std::optional<std::vector<CalParticipant>> attendees;
  std::optional<RuleInfo> recurrence;
  std::optional<std::vector<AlarmInfo>> alarms;
};

// One verb's answer, all plain C++: an error, or what the verb answers with.
// Every verb shares it so there is one path from a background queue back to
// JS.
enum class Answer { Calendars, Events, Calendar, Id, Done };

struct CalAnswer {
  std::string error;  // non-empty: cb(err)
  // the framework's own coordinates for the error, when it was its
  bool fromFramework = false;
  double code = 0;
  std::string domain;
  MaybeString reason;  // the EKErrorCode's name, when the header has one
  Answer kind = Answer::Calendars;
  std::vector<CalInfo> calendars;
  std::vector<CalEventInfo> events;
  std::optional<CalInfo> calendar;
  MaybeString id;
};

static void SetFrameworkError(CalAnswer* a, const char* fn, NSError* e) {
  const char* name =
      [e.domain isEqualToString:EKErrorDomain] ? EKErrorName(e.code) : nullptr;
  a->error = std::string(fn) + ": " + CopyRequired(e.localizedDescription);
  if (name) a->error += std::string(" (") + name + ")";
  a->fromFramework = true;
  a->code = (double)e.code;
  a->domain = CopyRequired(e.domain);
  if (name) a->reason = std::string(name);
}

static CalParticipant CopyParticipant(EKParticipant* p) {
  CalParticipant c;
  c.name = Copy(p.name);
  c.url = Copy(p.URL);
  c.status = ParticipantStatusName(p.participantStatus);
  c.role = ParticipantRoleName(p.participantRole);
  c.type = ParticipantTypeName(p.participantType);
  c.isCurrentUser = p.isCurrentUser;
  return c;
}

static CalInfo CopyCalendar(EKCalendar* c) {
  CalInfo i;
  i.id = CopyRequired(c.calendarIdentifier);
  i.title = CopyRequired(c.title);
  i.hasColor = CopyColor(c.CGColor, i.color);
  i.type = CalendarTypeName(c.type);
  EKSource* s = c.source;
  i.sourceId = CopyRequired(s.sourceIdentifier);
  i.sourceTitle = CopyRequired(s.title);
  i.sourceType = SourceTypeName(s.sourceType);
  i.immutable = c.immutable;
  i.allowsModifications = c.allowsContentModifications;
  i.subscribed = c.subscribed;
  return i;
}

// An empty array from the framework means the same as none: absent.
static std::optional<std::vector<int>> CopyInts(NSArray<NSNumber*>* a) {
  if (!a || a.count == 0) return std::nullopt;
  std::vector<int> v;
  v.reserve(a.count);
  for (NSNumber* n in a) v.push_back(n.intValue);
  return v;
}

static RuleInfo CopyRule(EKRecurrenceRule* r) {
  RuleInfo i;
  i.frequency = r.frequency;
  i.interval = (int)r.interval;
  EKRecurrenceEnd* end = r.recurrenceEnd;
  if (end && end.endDate) i.until = Millis(end.endDate);
  else if (end && end.occurrenceCount) i.count = (uint32_t)end.occurrenceCount;
  if (r.daysOfTheWeek.count) {
    std::vector<DayOfWeek> ds;
    for (EKRecurrenceDayOfWeek* d in r.daysOfTheWeek) {
      ds.push_back({(int)d.dayOfTheWeek, (int)d.weekNumber});
    }
    i.daysOfWeek = std::move(ds);
  }
  i.daysOfMonth = CopyInts(r.daysOfTheMonth);
  i.monthsOfYear = CopyInts(r.monthsOfTheYear);
  i.weeksOfYear = CopyInts(r.weeksOfTheYear);
  i.daysOfYear = CopyInts(r.daysOfTheYear);
  i.setPositions = CopyInts(r.setPositions);
  return i;
}

static AlarmInfo CopyAlarm(EKAlarm* a) {
  AlarmInfo i;
  if (a.absoluteDate) {
    i.absolute = true;
    i.value = Millis(a.absoluteDate);
  } else {
    i.value = a.relativeOffset;
  }
  return i;
}

static CalEventInfo CopyEvent(EKEvent* e) {
  CalEventInfo i;
  i.id = Copy(e.eventIdentifier);
  i.itemId = Copy(e.calendarItemIdentifier);
  i.externalId = Copy(e.calendarItemExternalIdentifier);
  i.calendar = CopyRequired(e.calendar.calendarIdentifier);
  i.title = Copy(e.title);
  i.location = Copy(e.location);
  i.notes = Copy(e.notes);
  i.url = Copy(e.URL);
  i.timeZone = Copy(e.timeZone.name);
  i.start = Millis(e.startDate);
  i.end = Millis(e.endDate);
  i.allDay = e.allDay;
  i.status = EventStatusName(e.status);
  i.availability = AvailabilityName(e.availability);
  i.recurring = e.hasRecurrenceRules;
  i.detached = e.isDetached;
  if (e.occurrenceDate) i.occurrenceDate = Millis(e.occurrenceDate);
  if (e.organizer) i.organizer = CopyParticipant(e.organizer);
  if (e.attendees) {
    std::vector<CalParticipant> as;
    as.reserve(e.attendees.count);
    for (EKParticipant* p in e.attendees) as.push_back(CopyParticipant(p));
    i.attendees = std::move(as);
  }
  // the flags are cheap and the arrays are not, so only an item that has
  // them is asked; the first rule is carried — Calendar and every account
  // write exactly one, though the framework allows several
  if (e.hasRecurrenceRules) {
    NSArray<EKRecurrenceRule*>* rules = e.recurrenceRules;
    if (rules.count) i.recurrence = CopyRule(rules[0]);
  }
  if (e.hasAlarms) {
    NSArray<EKAlarm*>* alarms = e.alarms;
    if (alarms) {
      std::vector<AlarmInfo> as;
      as.reserve(alarms.count);
      for (EKAlarm* a in alarms) as.push_back(CopyAlarm(a));
      i.alarms = std::move(as);
    }
  }
  return i;
}

// --- the fetches (background queue) -----------------------------------------

// A read needs the full grant: write-only (macOS 14) may save what it cannot
// read, and the other words are not a grant at all. The status names itself
// in the error, so the renderer can tell a refusal from an empty calendar.
static bool Authorized(const char* fn, CalAnswer* a) {
  const char* st = CALEventsAuthorizationStatus();
  if (strcmp(st, "authorized") == 0) return true;
  a->error = std::string(fn) +
             ": not authorized to read calendars (the 'calendars' "
             "authorization is '" +
             st + "')";
  if (strcmp(st, "writeOnly") == 0) {
    a->error += " — macOS 14's write-only grant saves events but cannot read them";
  }
  return false;
}

static bool WriteOnly() {
  return strcmp(CALEventsAuthorizationStatus(), "writeOnly") == 0;
}

// A write is content with either grant.
static bool Writable(const char* fn, CalAnswer* a) {
  const char* st = CALEventsAuthorizationStatus();
  if (strcmp(st, "authorized") == 0 || strcmp(st, "writeOnly") == 0) return true;
  a->error = std::string(fn) +
             ": not authorized to write calendars (the 'calendars' "
             "authorization is '" +
             st + "')";
  return false;
}

static void FetchCalendars(EKEventStore* store, CalAnswer* a) {
  // so a calendar the user just added in Settings is here; the refresh
  // itself is asynchronous, and what it pulls in arrives as a change event
  [store refreshSourcesIfNecessary];
  for (EKCalendar* c in [store calendarsForEntityType:EKEntityTypeEvent]) {
    a->calendars.push_back(CopyCalendar(c));
  }
}

struct EventsQuery {
  double start = 0, end = 0;
  std::vector<std::string> calendarIds;  // empty: every calendar
};

static void FetchEvents(EKEventStore* store, const EventsQuery& q,
                        CalAnswer* a) {
  NSMutableArray<EKCalendar*>* cals = nil;
  if (!q.calendarIds.empty()) {
    cals = [NSMutableArray arrayWithCapacity:q.calendarIds.size()];
    for (const std::string& id : q.calendarIds) {
      EKCalendar* c = [store
          calendarWithIdentifier:[NSString stringWithUTF8String:id.c_str()]];
      // nil calendars means *every* calendar to the predicate, so an id that
      // names nothing is an error rather than a silently widened query
      if (!c) {
        a->error = "eventsBetween: no calendar with identifier '" + id +
                   "' (it may have been removed; list them again)";
        return;
      }
      [cals addObject:c];
    }
  }
  NSPredicate* p = [store
      predicateForEventsWithStartDate:[NSDate dateWithTimeIntervalSince1970:
                                                  q.start / 1000.0]
                              endDate:[NSDate dateWithTimeIntervalSince1970:
                                                  q.end / 1000.0]
                            calendars:cals];
  NSArray<EKEvent*>* events = [store eventsMatchingPredicate:p];
  events = [events sortedArrayUsingSelector:@selector(compareStartDateWithEvent:)];
  a->events.reserve(events.count);
  for (EKEvent* e in events) a->events.push_back(CopyEvent(e));
}

// --- the answer path --------------------------------------------------------

static Napi::Value StringOrNull(Napi::Env env, const MaybeString& s) {
  if (!s) return env.Null();
  return Napi::String::New(env, *s);
}

static Napi::Object ParticipantJs(Napi::Env env, const CalParticipant& p) {
  Napi::Object o = Napi::Object::New(env);
  o.Set("name", StringOrNull(env, p.name));
  o.Set("url", StringOrNull(env, p.url));
  o.Set("status", p.status);
  o.Set("role", p.role);
  o.Set("type", p.type);
  o.Set("isCurrentUser", p.isCurrentUser);
  return o;
}

static Napi::Object CalendarJs(Napi::Env env, const CalInfo& c) {
  Napi::Object o = Napi::Object::New(env);
  o.Set("id", c.id);
  o.Set("title", c.title);
  if (c.hasColor) {
    Napi::Array col = Napi::Array::New(env, 4);
    for (uint32_t i = 0; i < 4; i++) col.Set(i, c.color[i]);
    o.Set("color", col);
  } else {
    o.Set("color", env.Null());
  }
  o.Set("type", c.type);
  Napi::Object src = Napi::Object::New(env);
  src.Set("id", c.sourceId);
  src.Set("title", c.sourceTitle);
  src.Set("type", c.sourceType);
  o.Set("source", src);
  o.Set("immutable", c.immutable);
  o.Set("allowsModifications", c.allowsModifications);
  o.Set("subscribed", c.subscribed);
  return o;
}

static Napi::Value IntsJs(Napi::Env env,
                          const std::optional<std::vector<int>>& v) {
  if (!v) return env.Null();
  Napi::Array a = Napi::Array::New(env, v->size());
  for (uint32_t i = 0; i < v->size(); i++) a.Set(i, (*v)[i]);
  return a;
}

static Napi::Object RuleJs(Napi::Env env, const RuleInfo& r) {
  Napi::Object o = Napi::Object::New(env);
  o.Set("frequency", FrequencyName(r.frequency));
  o.Set("interval", r.interval);
  o.Set("until", r.until ? Napi::Number::New(env, *r.until)
                         : env.Null().As<Napi::Value>());
  o.Set("count", r.count ? Napi::Number::New(env, *r.count)
                         : env.Null().As<Napi::Value>());
  if (r.daysOfWeek) {
    Napi::Array ds = Napi::Array::New(env, r.daysOfWeek->size());
    for (uint32_t i = 0; i < r.daysOfWeek->size(); i++) {
      Napi::Object d = Napi::Object::New(env);
      d.Set("day", (*r.daysOfWeek)[i].day);
      d.Set("week", (*r.daysOfWeek)[i].week);
      ds.Set(i, d);
    }
    o.Set("daysOfWeek", ds);
  } else {
    o.Set("daysOfWeek", env.Null());
  }
  o.Set("daysOfMonth", IntsJs(env, r.daysOfMonth));
  o.Set("monthsOfYear", IntsJs(env, r.monthsOfYear));
  o.Set("weeksOfYear", IntsJs(env, r.weeksOfYear));
  o.Set("daysOfYear", IntsJs(env, r.daysOfYear));
  o.Set("setPositions", IntsJs(env, r.setPositions));
  return o;
}

static Napi::Object AlarmJs(Napi::Env env, const AlarmInfo& a) {
  Napi::Object o = Napi::Object::New(env);
  o.Set(a.absolute ? "at" : "offset", a.value);
  return o;
}

static Napi::Object EventJs(Napi::Env env, const CalEventInfo& e) {
  Napi::Object o = Napi::Object::New(env);
  o.Set("id", StringOrNull(env, e.id));
  o.Set("itemId", StringOrNull(env, e.itemId));
  o.Set("externalId", StringOrNull(env, e.externalId));
  o.Set("calendar", e.calendar);
  o.Set("title", StringOrNull(env, e.title));
  o.Set("location", StringOrNull(env, e.location));
  o.Set("notes", StringOrNull(env, e.notes));
  o.Set("url", StringOrNull(env, e.url));
  o.Set("start", e.start);
  o.Set("end", e.end);
  o.Set("allDay", e.allDay);
  o.Set("timeZone", StringOrNull(env, e.timeZone));
  o.Set("status", e.status);
  o.Set("availability", e.availability);
  o.Set("recurring", e.recurring);
  o.Set("detached", e.detached);
  o.Set("occurrenceDate", e.occurrenceDate
                              ? Napi::Number::New(env, *e.occurrenceDate)
                              : env.Null().As<Napi::Value>());
  if (e.organizer) o.Set("organizer", ParticipantJs(env, *e.organizer));
  if (e.attendees) {
    Napi::Array as = Napi::Array::New(env, e.attendees->size());
    for (uint32_t i = 0; i < e.attendees->size(); i++) {
      as.Set(i, ParticipantJs(env, (*e.attendees)[i]));
    }
    o.Set("attendees", as);
  }
  if (e.recurrence) o.Set("recurrence", RuleJs(env, *e.recurrence));
  if (e.alarms) {
    Napi::Array as = Napi::Array::New(env, e.alarms->size());
    for (uint32_t i = 0; i < e.alarms->size(); i++) {
      as.Set(i, AlarmJs(env, (*e.alarms)[i]));
    }
    o.Set("alarms", as);
  }
  return o;
}

// An error the framework reported carries its coordinates — code, domain,
// and the EKErrorCode's name as reason — the way a notification error does;
// one the bridge found for itself is the message alone.
static Napi::Value ErrorJs(Napi::Env env, const CalAnswer& a) {
  Napi::Error err = Napi::Error::New(env, a.error);
  if (a.fromFramework) {
    err.Set("code", a.code);
    err.Set("domain", a.domain);
    err.Set("reason", StringOrNull(env, a.reason));
  }
  return err.Value();
}

// cb(err) or cb(null, ...) on the JS thread, from a background queue, then
// the thread-safe function goes — which is what was holding the loop open
// for the length of the fetch or the write.
static void Deliver(Napi::ThreadSafeFunction tsfn, CalAnswer* a) {
  napi_status st = tsfn.BlockingCall(
      a, [](Napi::Env env, Napi::Function cb, CalAnswer* a) {
        if (!a->error.empty()) {
          cb.Call({ErrorJs(env, *a)});
        } else if (a->kind == Answer::Events) {
          Napi::Array out = Napi::Array::New(env, a->events.size());
          for (uint32_t i = 0; i < a->events.size(); i++) {
            out.Set(i, EventJs(env, a->events[i]));
          }
          cb.Call({env.Null(), out});
        } else if (a->kind == Answer::Calendars) {
          Napi::Array out = Napi::Array::New(env, a->calendars.size());
          for (uint32_t i = 0; i < a->calendars.size(); i++) {
            out.Set(i, CalendarJs(env, a->calendars[i]));
          }
          cb.Call({env.Null(), out});
        } else if (a->kind == Answer::Calendar) {
          cb.Call({env.Null(), a->calendar
                                   ? CalendarJs(env, *a->calendar)
                                   : env.Null().As<Napi::Value>()});
        } else if (a->kind == Answer::Id) {
          cb.Call({env.Null(), StringOrNull(env, a->id)});
        } else {
          cb.Call({env.Null()});
        }
        delete a;
      });
  if (st != napi_ok) delete a;
  tsfn.Release();
}

// --- the store's change notification ----------------------------------------

static void CallJsChanged(Napi::Env env, Napi::Function, void*, void*);
using ChangedTsfn = Napi::TypedThreadSafeFunction<void, void, CallJsChanged>;
static ChangedTsfn gChanged;
// One change waiting for a listener. The event carries nothing and the
// framework coalesces, so what is held is that a change happened at all.
static bool gHeldChange = false;

static void EmitOrHoldChange() {
  if (!CALListening()) {
    gHeldChange = true;
    return;
  }
  CALEmit(CALEvent("calendar-store-changed"));
}

// Called at the start of pump2, and as runMain opens the channel
// (backend.mm): a change from before the listener existed goes out ahead of
// that tick's input.
void CALCalendarsReplayHeld() {
  if (!gHeldChange || !CALListening()) return;
  gHeldChange = false;
  EmitOrHoldChange();
}

static void CallJsChanged(Napi::Env env, Napi::Function, void*, void*) {
  if ((napi_env)env == nullptr) return;  // the function is being torn down
  EmitOrHoldChange();
}

// permissions.mm calls this the once, as it creates the process's store: the
// observer is in place from the store's first moment, whichever verb made it.
// EKEventStoreChangedNotification carries no guarantee about its thread, so
// the crossing to node's loop is the same hand-off a notification response
// takes — in pump mode. With threaded mode's channel open the record goes
// straight into it from whichever thread this is.
void CALCalendarsObserveStore(EKEventStore* store) {
  static id observer = nil;
  if (observer) return;
  observer = [NSNotificationCenter.defaultCenter
      addObserverForName:EKEventStoreChangedNotification
                  object:store
                   queue:nil
              usingBlock:^(NSNotification*) {
                if (CALChannelOpen())
                  CALEmit(CALEvent("calendar-store-changed"));
                else
                  gChanged.NonBlockingCall();
              }];
}

// --- the natives ------------------------------------------------------------

static bool ThrowType(Napi::Env env, const std::string& msg) {
  Napi::TypeError::New(env, msg).ThrowAsJavaScriptException();
  return false;
}

// o[k] as finite epoch ms; a Date is the wrapper's job, not the bridge's.
static bool QueryMillis(Napi::Env env, Napi::Object o, const char* k,
                        double* out) {
  Napi::Value v = o.Get(k);
  if (!v.IsNumber() || !std::isfinite(v.As<Napi::Number>().DoubleValue())) {
    return ThrowType(env, std::string("eventsBetween: '") + k +
                              "' must be a time in epoch milliseconds");
  }
  *out = v.As<Napi::Number>().DoubleValue();
  return true;
}

static bool ParseEventsQuery(Napi::Env env, const Napi::CallbackInfo& info,
                             EventsQuery* q) {
  if (info.Length() < 1 || !info[0].IsObject() || info[0].IsFunction()) {
    return ThrowType(env,
                     "eventsBetween: expected ({ start, end, calendars? }, cb)");
  }
  Napi::Object o = info[0].As<Napi::Object>();
  if (!QueryMillis(env, o, "start", &q->start)) return false;
  if (!QueryMillis(env, o, "end", &q->end)) return false;
  if (q->end < q->start) {
    return ThrowType(env, "eventsBetween: 'end' is before 'start'");
  }
  if (q->end - q->start > kMaxSpanMs) {
    return ThrowType(env,
                     "eventsBetween: the predicate is limited to a four-year "
                     "span (1461 days); ask for the range in chunks");
  }
  Napi::Value cals = o.Get("calendars");
  if (cals.IsUndefined() || cals.IsNull()) return true;
  if (!cals.IsArray()) {
    return ThrowType(env,
                     "eventsBetween: 'calendars' must be an array of calendar "
                     "ids");
  }
  Napi::Array a = cals.As<Napi::Array>();
  if (a.Length() == 0) {
    // an empty list would reach the predicate as nil, i.e. every calendar
    return ThrowType(env,
                     "eventsBetween: 'calendars' must name at least one "
                     "calendar; leave it out for all of them");
  }
  for (uint32_t i = 0; i < a.Length(); i++) {
    Napi::Value v = a.Get(i);
    if (!v.IsString()) {
      return ThrowType(env,
                       "eventsBetween: 'calendars' must be an array of "
                       "calendar ids (strings)");
    }
    q->calendarIds.push_back(v.As<Napi::String>().Utf8Value());
  }
  return true;
}

// calendars(cb) — cb(err, [calendar]): every EKCalendar that holds events,
// across every source. Never prompts.
static Napi::Value Calendars(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsFunction()) {
    ThrowType(env, "calendars: expected a callback (cb)");
    return env.Undefined();
  }
  @autoreleasepool {
    EKEventStore* store = CALEventStore();  // JS thread: it is a singleton
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env, info[0].As<Napi::Function>(), "appkit:calendars", 0, 1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
        CalAnswer* a = new CalAnswer;
        if (Authorized("calendars", a)) FetchCalendars(store, a);
        Deliver(tsfn, a);
      }
    });
  }
  return env.Undefined();
}

// eventsBetween({ start, end, calendars? }, cb) — cb(err, [event]): the
// occurrences the predicate answers, recurrences expanded by the framework,
// sorted by start. Never prompts.
static Napi::Value EventsBetween(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  EventsQuery q;
  if (!ParseEventsQuery(env, info, &q)) return env.Undefined();
  if (info.Length() < 2 || !info[1].IsFunction()) {
    ThrowType(env, "eventsBetween: expected ({ start, end, calendars? }, cb)");
    return env.Undefined();
  }
  @autoreleasepool {
    EKEventStore* store = CALEventStore();
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env, info[1].As<Napi::Function>(), "appkit:eventsBetween", 0, 1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
        CalAnswer* a = new CalAnswer;
        a->kind = Answer::Events;
        if (Authorized("eventsBetween", a)) FetchEvents(store, q, a);
        Deliver(tsfn, a);
      }
    });
  }
  return env.Undefined();
}


// --- the writes: what to save, parsed on the JS thread ----------------------

// One field of a save: absent (unchanged, or the default for a new event),
// null (cleared), or a value. undefined counts as absent, so a wrapper that
// spreads { start: toMs(undefined) } says nothing about start.
template <typename T>
struct Field {
  bool given = false, null = false;
  T value{};
  bool set() const { return given && !null; }
};

struct EventProps {
  std::optional<std::string> id;         // absent: create
  std::optional<double> occurrenceDate;  // with id: which occurrence
  std::optional<std::string> calendar;   // create: the default when absent
  Field<std::string> title, location, notes, url, timeZone;
  std::optional<double> start, end;      // both required to create
  std::optional<bool> allDay;
  std::optional<EKEventAvailability> availability;
  Field<RuleInfo> recurrence;
  Field<std::vector<AlarmInfo>> alarms;  // null or []: none
};

struct WriteOpts {
  EKSpan span = EKSpanThisEvent;
  bool commit = true;
  std::optional<double> occurrenceDate;  // removeEvent: which occurrence
};

// o[k], or empty when absent or undefined.
static Napi::Value Given(Napi::Object o, const char* k) {
  Napi::Value v = o.Get(k);
  return v.IsUndefined() ? Napi::Value() : v;
}

static bool ParseMillis(Napi::Env env, Napi::Value v, const std::string& what,
                        double* out) {
  if (!v.IsNumber() || !std::isfinite(v.As<Napi::Number>().DoubleValue())) {
    return ThrowType(env, what + " must be a time in epoch milliseconds");
  }
  *out = v.As<Napi::Number>().DoubleValue();
  return true;
}

// An integer in [lo, hi], never zero: the framework's arrays count from one,
// negatives from the end.
static bool ParseInt(Napi::Env env, Napi::Value v, const std::string& what,
                     int lo, int hi, int* out) {
  double d = v.IsNumber() ? v.As<Napi::Number>().DoubleValue() : NAN;
  if (!(d == std::floor(d)) || d < lo || d > hi || d == 0) {
    return ThrowType(env, what + " must be an integer from " +
                              std::to_string(lo) + " to " +
                              std::to_string(hi) + (lo < 0 ? ", never zero" : ""));
  }
  *out = (int)d;
  return true;
}

static bool ParseInts(Napi::Env env, Napi::Object rule, const char* k, int lo,
                      int hi, std::optional<std::vector<int>>* out) {
  Napi::Value v = Given(rule, k);
  if (v.IsEmpty() || v.IsNull()) return true;
  std::string what = std::string("saveEvent: recurrence.") + k;
  if (!v.IsArray()) return ThrowType(env, what + " must be an array of integers");
  Napi::Array a = v.As<Napi::Array>();
  std::vector<int> ints;
  for (uint32_t i = 0; i < a.Length(); i++) {
    int n;
    if (!ParseInt(env, a.Get(i), what, lo, hi, &n)) return false;
    ints.push_back(n);
  }
  if (!ints.empty()) *out = std::move(ints);  // []: none, as nil is
  return true;
}

static bool ParseRule(Napi::Env env, Napi::Value v, RuleInfo* r) {
  if (!v.IsObject() || v.IsArray() || v.IsFunction()) {
    return ThrowType(env,
                     "saveEvent: 'recurrence' must be { frequency, interval?, "
                     "until? | count?, daysOfWeek?, daysOfMonth?, "
                     "monthsOfYear?, weeksOfYear?, daysOfYear?, "
                     "setPositions? } or null");
  }
  Napi::Object o = v.As<Napi::Object>();
  Napi::Value f = Given(o, "frequency");
  if (f.IsEmpty() || !f.IsString() ||
      !ParseFrequency(f.As<Napi::String>().Utf8Value(), &r->frequency)) {
    return ThrowType(env,
                     "saveEvent: recurrence.frequency must be 'daily', "
                     "'weekly', 'monthly' or 'yearly'");
  }
  Napi::Value iv = Given(o, "interval");
  if (!iv.IsEmpty() && !iv.IsNull()) {
    if (!ParseInt(env, iv, "saveEvent: recurrence.interval", 1, INT32_MAX,
                  &r->interval)) {
      return false;
    }
  }
  Napi::Value until = Given(o, "until"), count = Given(o, "count");
  bool hasUntil = !until.IsEmpty() && !until.IsNull();
  bool hasCount = !count.IsEmpty() && !count.IsNull();
  if (hasUntil && hasCount) {
    return ThrowType(env,
                     "saveEvent: a recurrence ends at 'until' or after "
                     "'count' occurrences, not both");
  }
  if (hasUntil) {
    double ms;
    if (!ParseMillis(env, until, "saveEvent: recurrence.until", &ms)) return false;
    r->until = ms;
  }
  if (hasCount) {
    int n;
    if (!ParseInt(env, count, "saveEvent: recurrence.count", 1, INT32_MAX, &n)) {
      return false;
    }
    r->count = (uint32_t)n;
  }
  Napi::Value days = Given(o, "daysOfWeek");
  if (!days.IsEmpty() && !days.IsNull()) {
    if (!days.IsArray()) {
      return ThrowType(env,
                       "saveEvent: recurrence.daysOfWeek must be an array of "
                       "{ day: 1..7 (Sunday = 1), week? }");
    }
    // the framework raises for a week number its frequency has no place
    // for: none on a daily or weekly rule, ±1..5 in a month, ±1..53 in a year
    int maxWeek = r->frequency == EKRecurrenceFrequencyMonthly ? 5
                  : r->frequency == EKRecurrenceFrequencyYearly ? 53
                                                                : 0;
    Napi::Array a = days.As<Napi::Array>();
    std::vector<DayOfWeek> ds;
    for (uint32_t i = 0; i < a.Length(); i++) {
      Napi::Value e = a.Get(i);
      if (!e.IsObject() || e.IsArray() || e.IsFunction()) {
        return ThrowType(env,
                         "saveEvent: recurrence.daysOfWeek must be an array "
                         "of { day: 1..7 (Sunday = 1), week? }");
      }
      Napi::Object d = e.As<Napi::Object>();
      DayOfWeek dw;
      Napi::Value day = Given(d, "day");
      if (day.IsEmpty() ||
          !ParseInt(env, day, "saveEvent: recurrence.daysOfWeek[].day", 1, 7,
                    &dw.day)) {
        if (day.IsEmpty()) {
          ThrowType(env, "saveEvent: recurrence.daysOfWeek[].day must be an "
                         "integer from 1 to 7 (Sunday = 1)");
        }
        return false;
      }
      Napi::Value week = Given(d, "week");
      if (!week.IsEmpty() && !week.IsNull()) {
        double w = week.IsNumber() ? week.As<Napi::Number>().DoubleValue() : NAN;
        if (!(w == std::floor(w)) || std::fabs(w) > maxWeek) {
          if (maxWeek == 0) {
            return ThrowType(env,
                             "saveEvent: recurrence.daysOfWeek[].week has no "
                             "meaning on a daily or weekly rule (the "
                             "framework raises for one); leave it out");
          }
          return ThrowType(env, "saveEvent: recurrence.daysOfWeek[].week must "
                                "be an integer from -" +
                                    std::to_string(maxWeek) + " to " +
                                    std::to_string(maxWeek) + " for a " +
                                    FrequencyName(r->frequency) + " rule");
        }
        dw.week = (int)w;
      }
      ds.push_back(dw);
    }
    if (!ds.empty()) r->daysOfWeek = std::move(ds);
  }
  return ParseInts(env, o, "daysOfMonth", -31, 31, &r->daysOfMonth) &&
         ParseInts(env, o, "monthsOfYear", 1, 12, &r->monthsOfYear) &&
         ParseInts(env, o, "weeksOfYear", -53, 53, &r->weeksOfYear) &&
         ParseInts(env, o, "daysOfYear", -366, 366, &r->daysOfYear) &&
         ParseInts(env, o, "setPositions", -366, 366, &r->setPositions);
}

static bool ParseAlarms(Napi::Env env, Napi::Value v,
                        std::vector<AlarmInfo>* out) {
  const char* shape =
      "saveEvent: 'alarms' must be an array of { offset: seconds from the "
      "start } or { at: epoch ms }, or null";
  if (!v.IsArray()) return ThrowType(env, shape);
  Napi::Array a = v.As<Napi::Array>();
  for (uint32_t i = 0; i < a.Length(); i++) {
    Napi::Value e = a.Get(i);
    if (!e.IsObject() || e.IsArray() || e.IsFunction()) return ThrowType(env, shape);
    Napi::Object o = e.As<Napi::Object>();
    Napi::Value offset = Given(o, "offset"), at = Given(o, "at");
    bool hasOffset = !offset.IsEmpty() && !offset.IsNull();
    bool hasAt = !at.IsEmpty() && !at.IsNull();
    if (hasOffset == hasAt) return ThrowType(env, shape);
    AlarmInfo al;
    if (hasAt) {
      al.absolute = true;
      if (!ParseMillis(env, at, "saveEvent: alarms[].at", &al.value)) return false;
    } else if (!offset.IsNumber() ||
               !std::isfinite(offset.As<Napi::Number>().DoubleValue())) {
      return ThrowType(env,
                       "saveEvent: alarms[].offset must be a number of seconds "
                       "from the start (negative before it)");
    } else {
      al.value = offset.As<Napi::Number>().DoubleValue();
    }
    out->push_back(al);
  }
  return true;
}

// An absolute URL, as the string says it: macOS 14's URLWithString: would
// percent-encode a space itself and accept a bare word as a relative
// reference, neither of which is what an event's URL is.
static NSURL* ParseURL(const std::string& s) {
  NSString* str = [NSString stringWithUTF8String:s.c_str()];
  NSURL* u = nil;
  if (@available(macOS 14.0, *)) {
    u = [NSURL URLWithString:str encodingInvalidCharacters:NO];
  } else {
    u = [NSURL URLWithString:str];
  }
  return u && u.scheme.length ? u : nil;
}

static bool ParseStringField(Napi::Env env, Napi::Object o, const char* k,
                             Field<std::string>* f) {
  Napi::Value v = Given(o, k);
  if (v.IsEmpty()) return true;
  f->given = true;
  if (v.IsNull()) {
    f->null = true;
    return true;
  }
  if (!v.IsString()) {
    return ThrowType(env, std::string("saveEvent: '") + k +
                              "' must be a string or null");
  }
  f->value = v.As<Napi::String>().Utf8Value();
  return true;
}

static bool ParseEventProps(Napi::Env env, Napi::Value v, EventProps* p) {
  if (!v.IsObject() || v.IsFunction() || v.IsArray()) {
    return ThrowType(env, "saveEvent: expected (props, opts?, cb)");
  }
  Napi::Object o = v.As<Napi::Object>();
  Napi::Value id = Given(o, "id");
  if (!id.IsEmpty()) {
    if (!id.IsString() || id.As<Napi::String>().Utf8Value().empty()) {
      return ThrowType(env,
                       "saveEvent: 'id' must be the identifier of an existing "
                       "event (a string); leave it out to create one");
    }
    p->id = id.As<Napi::String>().Utf8Value();
  }
  Napi::Value occ = Given(o, "occurrenceDate");
  if (!occ.IsEmpty() && !occ.IsNull()) {
    double ms;
    if (!ParseMillis(env, occ, "saveEvent: 'occurrenceDate'", &ms)) return false;
    if (!p->id) {
      return ThrowType(env,
                       "saveEvent: 'occurrenceDate' picks an occurrence of an "
                       "existing event; pass its 'id' as well");
    }
    p->occurrenceDate = ms;
  }
  Napi::Value cal = Given(o, "calendar");
  if (!cal.IsEmpty()) {
    if (!cal.IsString() || cal.As<Napi::String>().Utf8Value().empty()) {
      return ThrowType(env,
                       "saveEvent: 'calendar' must be a calendar id (string); "
                       "leave it out for the default calendar");
    }
    p->calendar = cal.As<Napi::String>().Utf8Value();
  }
  if (!ParseStringField(env, o, "title", &p->title) ||
      !ParseStringField(env, o, "location", &p->location) ||
      !ParseStringField(env, o, "notes", &p->notes) ||
      !ParseStringField(env, o, "url", &p->url) ||
      !ParseStringField(env, o, "timeZone", &p->timeZone)) {
    return false;
  }
  @autoreleasepool {
    // validated here, where a refusal can be a TypeError; made again on
    // the write queue from the string
    if (p->url.set() && !ParseURL(p->url.value)) {
      return ThrowType(env,
                       "saveEvent: 'url' is not an absolute URL "
                       "('https://example.com/…')");
    }
    if (p->timeZone.set() &&
        ![NSTimeZone timeZoneWithName:[NSString stringWithUTF8String:
                                                     p->timeZone.value.c_str()]]) {
      return ThrowType(env,
                       "saveEvent: 'timeZone' is not a time zone identifier "
                       "('Europe/London'); null makes the event floating");
    }
  }
  for (const char* k : {"start", "end"}) {
    Napi::Value t = Given(o, k);
    if (t.IsEmpty()) continue;
    double ms;
    if (!ParseMillis(env, t, std::string("saveEvent: '") + k + "'", &ms)) return false;
    (strcmp(k, "start") == 0 ? p->start : p->end) = ms;
  }
  if (!p->id && (!p->start || !p->end)) {
    return ThrowType(env,
                     "saveEvent: 'start' and 'end' (epoch ms) are required to "
                     "create an event");
  }
  Napi::Value allDay = Given(o, "allDay");
  if (!allDay.IsEmpty()) {
    if (!allDay.IsBoolean()) return ThrowType(env, "saveEvent: 'allDay' must be a boolean");
    p->allDay = allDay.As<Napi::Boolean>().Value();
  }
  Napi::Value av = Given(o, "availability");
  if (!av.IsEmpty()) {
    EKEventAvailability a;
    if (!av.IsString() || !ParseAvailability(av.As<Napi::String>().Utf8Value(), &a)) {
      return ThrowType(env,
                       "saveEvent: 'availability' must be 'busy', 'free', "
                       "'tentative' or 'unavailable'");
    }
    p->availability = a;
  }
  Napi::Value rec = Given(o, "recurrence");
  if (!rec.IsEmpty()) {
    p->recurrence.given = true;
    if (rec.IsNull()) p->recurrence.null = true;
    else if (!ParseRule(env, rec, &p->recurrence.value)) return false;
  }
  Napi::Value alarms = Given(o, "alarms");
  if (!alarms.IsEmpty()) {
    p->alarms.given = true;
    if (alarms.IsNull()) p->alarms.null = true;
    else if (!ParseAlarms(env, alarms, &p->alarms.value)) return false;
    if (p->alarms.value.empty()) p->alarms.null = true;
  }
  return true;
}

static bool ParseWriteOpts(Napi::Env env, const char* fn, Napi::Value v,
                           bool forRemove, WriteOpts* o) {
  if (v.IsEmpty() || v.IsUndefined() || v.IsNull()) return true;
  std::string shape = std::string(fn) + ": options must be { span?: 'this' | "
                                        "'future', commit?: boolean" +
                      (forRemove ? ", occurrenceDate? }" : " }");
  if (!v.IsObject() || v.IsFunction() || v.IsArray()) return ThrowType(env, shape);
  Napi::Object opts = v.As<Napi::Object>();
  Napi::Value span = Given(opts, "span");
  if (!span.IsEmpty() && !span.IsNull()) {
    std::string s = span.IsString() ? span.As<Napi::String>().Utf8Value() : "";
    if (s == "this") o->span = EKSpanThisEvent;
    else if (s == "future") o->span = EKSpanFutureEvents;
    else return ThrowType(env, std::string(fn) + ": span must be 'this' (the default) or 'future'");
  }
  Napi::Value commit = Given(opts, "commit");
  if (!commit.IsEmpty() && !commit.IsNull()) {
    if (!commit.IsBoolean()) return ThrowType(env, std::string(fn) + ": commit must be a boolean");
    o->commit = commit.As<Napi::Boolean>().Value();
  }
  Napi::Value occ = Given(opts, "occurrenceDate");
  if (!occ.IsEmpty() && !occ.IsNull()) {
    if (!forRemove) return ThrowType(env, shape + " — 'occurrenceDate' goes in the props, with the 'id'");
    double ms;
    if (!ParseMillis(env, occ, std::string(fn) + ": occurrenceDate", &ms)) return false;
    o->occurrenceDate = ms;
  }
  return true;
}

// --- the writes (the write queue) --------------------------------------------

// Serial, at the reads' QoS: writes go one after another, in the order they
// were asked, which is what makes a batch (commit: false, …, commit) mean
// something.
static dispatch_queue_t WriteQueue() {
  static dispatch_queue_t q = dispatch_queue_create(
      "dev.windowkit.appkit.calendars.write",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                              QOS_CLASS_USER_INITIATED, 0));
  return q;
}

static NSString* NS(const std::string& s) {
  return [NSString stringWithUTF8String:s.c_str()];
}

static NSDate* DateMs(double ms) {
  return [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
}

static NSArray<NSNumber*>* Numbers(const std::optional<std::vector<int>>& v) {
  if (!v) return nil;
  NSMutableArray<NSNumber*>* a = [NSMutableArray arrayWithCapacity:v->size()];
  for (int n : *v) [a addObject:@(n)];
  return a;
}

static EKRecurrenceRule* MakeRule(const RuleInfo& r) {
  NSMutableArray<EKRecurrenceDayOfWeek*>* days = nil;
  if (r.daysOfWeek) {
    days = [NSMutableArray arrayWithCapacity:r.daysOfWeek->size()];
    for (const DayOfWeek& d : *r.daysOfWeek) {
      [days addObject:[EKRecurrenceDayOfWeek dayOfWeek:(EKWeekday)d.day
                                           weekNumber:d.week]];
    }
  }
  EKRecurrenceEnd* end = nil;
  if (r.until) end = [EKRecurrenceEnd recurrenceEndWithEndDate:DateMs(*r.until)];
  else if (r.count) end = [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:*r.count];
  return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:r.frequency
                                                      interval:r.interval
                                                 daysOfTheWeek:days
                                                daysOfTheMonth:Numbers(r.daysOfMonth)
                                               monthsOfTheYear:Numbers(r.monthsOfYear)
                                                weeksOfTheYear:Numbers(r.weeksOfYear)
                                                 daysOfTheYear:Numbers(r.daysOfYear)
                                                  setPositions:Numbers(r.setPositions)
                                                           end:end];
}

static EKAlarm* MakeAlarm(const AlarmInfo& a) {
  return a.absolute ? [EKAlarm alarmWithAbsoluteDate:DateMs(a.value)]
                    : [EKAlarm alarmWithRelativeOffset:a.value];
}

// Anything the framework raises rather than reports comes back as text, so
// it can cross as an error instead of ending the process.
static NSString* Guarded(void (^body)(void)) {
  @try {
    body();
    return nil;
  } @catch (NSException* ex) {
    return [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason];
  }
}

// The occurrence of `id` whose place in the series is `occMs`, through the
// reads' predicate over the widest window it takes, on the event's own
// calendar. nil when no occurrence sits there.
static EKEvent* FindOccurrence(EKEventStore* store, EKEvent* first,
                               const std::string& id, double occMs) {
  NSDate* at = DateMs(occMs);
  NSArray<EKCalendar*>* cals = first.calendar ? @[ first.calendar ] : nil;
  NSPredicate* p = [store
      predicateForEventsWithStartDate:[at dateByAddingTimeInterval:-kOccurrenceWindowS]
                              endDate:[at dateByAddingTimeInterval:kOccurrenceWindowS]
                            calendars:cals];
  NSString* wanted = NS(id);
  for (EKEvent* e in [store eventsMatchingPredicate:p]) {
    if (![e.eventIdentifier isEqualToString:wanted] || !e.occurrenceDate) continue;
    if (std::fabs(Millis(e.occurrenceDate) - occMs) < 1.0) return e;
  }
  return nil;
}

// The event a write names: by id, then by occurrence when one is named. Sets
// the answer's error and returns nil when there is no such event — under the
// write-only grant that is the framework refusing to read it back, and it
// crosses as the EKError it is.
static EKEvent* ResolveEvent(EKEventStore* store, const char* fn,
                             const std::string& id,
                             const std::optional<double>& occ, CalAnswer* a) {
  EKEvent* e = [store eventWithIdentifier:NS(id)];
  if (!e) {
    if (WriteOnly()) {
      a->error = std::string(fn) + ": no event with identifier '" + id +
                 "' — macOS 14's write-only grant saves events but cannot "
                 "read one back to change or remove it "
                 "(EKErrorEventStoreNotAuthorized)";
      a->fromFramework = true;
      a->code = (double)EKErrorEventStoreNotAuthorized;
      a->domain = CopyRequired(EKErrorDomain);
      a->reason = std::string("EKErrorEventStoreNotAuthorized");
    } else {
      a->error = std::string(fn) + ": no event with identifier '" + id +
                 "' (it may have been removed; query again)";
    }
    return nil;
  }
  if (!occ) return e;
  EKEvent* o = FindOccurrence(store, e, id, *occ);
  if (!o) {
    a->error = std::string(fn) + ": no occurrence of '" + id + "' at " +
               std::to_string((long long)*occ) +
               " (pass the occurrenceDate eventsBetween reported for it)";
  }
  return o;
}

static bool ResolveCalendar(EKEventStore* store, const std::string& id,
                            EKCalendar** out, CalAnswer* a) {
  *out = [store calendarWithIdentifier:NS(id)];
  if (*out) return true;
  a->error = "saveEvent: no calendar with identifier '" + id + "'" +
             (WriteOnly() ? " — under macOS 14's write-only grant the "
                            "calendars may not be readable; leave it out for "
                            "the default calendar"
                          : " (it may have been removed; list them again)");
  return false;
}

static void DoDefaultCalendar(EKEventStore* store, CalAnswer* a) {
  EKCalendar* c = store.defaultCalendarForNewEvents;
  if (c) a->calendar = CopyCalendar(c);
}

static void DoSave(EKEventStore* store, const EventProps& p,
                   const WriteOpts& o, CalAnswer* a) {
  NSString* raised = Guarded(^{
    EKEvent* e = nil;
    if (p.id) {
      e = ResolveEvent(store, "saveEvent", *p.id, p.occurrenceDate, a);
      if (!e) return;
    } else {
      e = [EKEvent eventWithEventStore:store];
      // nil here is the framework's to refuse (EKErrorNoCalendar)
      if (!p.calendar) e.calendar = store.defaultCalendarForNewEvents;
    }
    if (p.calendar) {
      EKCalendar* c;
      if (!ResolveCalendar(store, *p.calendar, &c, a)) return;
      e.calendar = c;
    }
    if (p.title.given) e.title = p.title.null ? nil : NS(p.title.value);
    if (p.location.given) e.location = p.location.null ? nil : NS(p.location.value);
    if (p.notes.given) e.notes = p.notes.null ? nil : NS(p.notes.value);
    if (p.url.given) e.URL = p.url.null ? nil : ParseURL(p.url.value);
    if (p.timeZone.given) {
      e.timeZone = p.timeZone.null ? nil : [NSTimeZone timeZoneWithName:NS(p.timeZone.value)];
    }
    if (p.allDay) e.allDay = *p.allDay;
    if (p.start) e.startDate = DateMs(*p.start);
    if (p.end) e.endDate = DateMs(*p.end);
    if (p.availability) e.availability = *p.availability;
    if (p.recurrence.given) {
      e.recurrenceRules = p.recurrence.null ? nil : @[ MakeRule(p.recurrence.value) ];
    }
    if (p.alarms.given) {
      NSMutableArray<EKAlarm*>* alarms = nil;
      if (!p.alarms.null) {
        alarms = [NSMutableArray arrayWithCapacity:p.alarms.value.size()];
        for (const AlarmInfo& al : p.alarms.value) [alarms addObject:MakeAlarm(al)];
      }
      e.alarms = alarms;
    }
    // NO with no error is "nothing was dirty", which is not a failure
    NSError* err = nil;
    BOOL ok = [store saveEvent:e span:o.span commit:o.commit error:&err];
    if (!ok && err) {
      SetFrameworkError(a, "saveEvent", err);
      return;
    }
    a->id = Copy(e.eventIdentifier);
  });
  if (raised) a->error = "saveEvent: EventKit raised " + CopyRequired(raised);
}

static void DoRemove(EKEventStore* store, const std::string& id,
                     const WriteOpts& o, CalAnswer* a) {
  NSString* raised = Guarded(^{
    EKEvent* e = ResolveEvent(store, "removeEvent", id, o.occurrenceDate, a);
    if (!e) return;
    NSError* err = nil;
    BOOL ok = [store removeEvent:e span:o.span commit:o.commit error:&err];
    if (!ok && err) SetFrameworkError(a, "removeEvent", err);
  });
  if (raised) a->error = "removeEvent: EventKit raised " + CopyRequired(raised);
}

static void DoCommit(EKEventStore* store, CalAnswer* a) {
  NSString* raised = Guarded(^{
    NSError* err = nil;
    if (![store commit:&err] && err) SetFrameworkError(a, "commitCalendarStore", err);
  });
  if (raised) a->error = "commitCalendarStore: EventKit raised " + CopyRequired(raised);
}

// --- the write natives ------------------------------------------------------

// The callback of a (…, opts?, cb) call: at 1 when there are no options.
static bool CallbackAt(Napi::Env env, const Napi::CallbackInfo& info,
                       size_t first, const char* shape, size_t* at) {
  *at = info.Length() > first && info[first].IsFunction() ? first : first + 1;
  if (info.Length() <= *at || !info[*at].IsFunction()) return ThrowType(env, shape);
  return true;
}

// defaultCalendar(cb) — cb(err, calendar | null): defaultCalendarForNewEvents,
// where a save with no calendar goes. Either grant; never prompts.
static Napi::Value DefaultCalendar(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsFunction()) {
    ThrowType(env, "defaultCalendar: expected a callback (cb)");
    return env.Undefined();
  }
  @autoreleasepool {
    EKEventStore* store = CALEventStore();
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env, info[0].As<Napi::Function>(), "appkit:defaultCalendar", 0, 1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
        CalAnswer* a = new CalAnswer;
        a->kind = Answer::Calendar;
        if (Writable("defaultCalendar", a)) DoDefaultCalendar(store, a);
        Deliver(tsfn, a);
      }
    });
  }
  return env.Undefined();
}

// saveEvent(props, opts?, cb) — cb(err, id): a new event when props has no
// id, a change to the one it names otherwise (the occurrence at
// props.occurrenceDate of a recurring one). opts.span says how far a change
// to a recurring event reaches; opts.commit false leaves it for
// commitCalendarStore. Either grant; never prompts.
static Napi::Value SaveEvent(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* shape = "saveEvent: expected (props, opts?, cb)";
  size_t cbAt;
  if (info.Length() < 1 || !CallbackAt(env, info, 1, shape, &cbAt)) {
    if (info.Length() < 1) ThrowType(env, shape);
    return env.Undefined();
  }
  EventProps props;
  WriteOpts opts;
  if (!ParseEventProps(env, info[0], &props)) return env.Undefined();
  if (cbAt == 2 && !ParseWriteOpts(env, "saveEvent", info[1], false, &opts)) {
    return env.Undefined();
  }
  @autoreleasepool {
    EKEventStore* store = CALEventStore();
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env, info[cbAt].As<Napi::Function>(), "appkit:saveEvent", 0, 1);
    dispatch_async(WriteQueue(), ^{
      @autoreleasepool {
        CalAnswer* a = new CalAnswer;
        a->kind = Answer::Id;
        if (Writable("saveEvent", a)) DoSave(store, props, opts, a);
        Deliver(tsfn, a);
      }
    });
  }
  return env.Undefined();
}

// removeEvent(id, opts?, cb) — cb(err): the event, or with opts.span
// 'future' this and every later occurrence, or with opts.occurrenceDate the
// one occurrence (and what follows it). Either grant; never prompts.
static Napi::Value RemoveEvent(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* shape = "removeEvent: expected (id, opts?, cb)";
  size_t cbAt;
  if (info.Length() < 1 || !CallbackAt(env, info, 1, shape, &cbAt)) {
    if (info.Length() < 1) ThrowType(env, shape);
    return env.Undefined();
  }
  if (!info[0].IsString() || info[0].As<Napi::String>().Utf8Value().empty()) {
    ThrowType(env, "removeEvent: 'id' must be the identifier of an event (a string)");
    return env.Undefined();
  }
  std::string id = info[0].As<Napi::String>().Utf8Value();
  WriteOpts opts;
  if (cbAt == 2 && !ParseWriteOpts(env, "removeEvent", info[1], true, &opts)) {
    return env.Undefined();
  }
  @autoreleasepool {
    EKEventStore* store = CALEventStore();
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env, info[cbAt].As<Napi::Function>(), "appkit:removeEvent", 0, 1);
    dispatch_async(WriteQueue(), ^{
      @autoreleasepool {
        CalAnswer* a = new CalAnswer;
        a->kind = Answer::Done;
        if (Writable("removeEvent", a)) DoRemove(store, id, opts, a);
        Deliver(tsfn, a);
      }
    });
  }
  return env.Undefined();
}

// commitCalendarStore(cb) — cb(err): commits what saves and removes with
// commit: false left pending, in the order they were asked.
static Napi::Value CommitCalendarStore(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsFunction()) {
    ThrowType(env, "commitCalendarStore: expected a callback (cb)");
    return env.Undefined();
  }
  @autoreleasepool {
    EKEventStore* store = CALEventStore();
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env, info[0].As<Napi::Function>(), "appkit:commitCalendarStore", 0, 1);
    dispatch_async(WriteQueue(), ^{
      @autoreleasepool {
        CalAnswer* a = new CalAnswer;
        a->kind = Answer::Done;
        if (Writable("commitCalendarStore", a)) DoCommit(store, a);
        Deliver(tsfn, a);
      }
    });
  }
  return env.Undefined();
}

// resetCalendarStore(cb) — cb(null): forgets a pending batch, [EKEventStore
// reset]; the store is back to the database's state. Needs no grant.
static Napi::Value ResetCalendarStore(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsFunction()) {
    ThrowType(env, "resetCalendarStore: expected a callback (cb)");
    return env.Undefined();
  }
  @autoreleasepool {
    EKEventStore* store = CALEventStore();
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env, info[0].As<Napi::Function>(), "appkit:resetCalendarStore", 0, 1);
    dispatch_async(WriteQueue(), ^{
      @autoreleasepool {
        CalAnswer* a = new CalAnswer;
        a->kind = Answer::Done;
        [store reset];
        Deliver(tsfn, a);
      }
    });
  }
  return env.Undefined();
}

// --- test seam ---------------------------------------------------------------

// postCalendarStoreChanged() — the notification EventKit posts when anything
// in the store changed, posted from here through the same centre, so the
// observer path can be exercised without touching the user's calendars.
// Test-only, like postAccessibilityDisplayChange; it creates the store (and
// with it the observer) if no verb has yet, which never prompts.
static Napi::Value PostCalendarStoreChanged(const Napi::CallbackInfo& info) {
  @autoreleasepool {
    [NSNotificationCenter.defaultCenter
        postNotificationName:EKEventStoreChangedNotification
                      object:CALEventStore()];
  }
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// registration (called from addon.mm's Init)
// ---------------------------------------------------------------------------

void InitCalendars(Napi::Env env, Napi::Object exports) {
  gChanged = ChangedTsfn::New(env, "appkit:calendars-changed", 0, 1);
  gChanged.Unref(env);  // a change never holds the loop open by itself
  exports.Set("calendars", Napi::Function::New(env, Calendars));
  exports.Set("eventsBetween", Napi::Function::New(env, EventsBetween));
  exports.Set("defaultCalendar", Napi::Function::New(env, DefaultCalendar));
  exports.Set("saveEvent", Napi::Function::New(env, SaveEvent));
  exports.Set("removeEvent", Napi::Function::New(env, RemoveEvent));
  exports.Set("commitCalendarStore",
              Napi::Function::New(env, CommitCalendarStore));
  exports.Set("resetCalendarStore",
              Napi::Function::New(env, ResetCalendarStore));
  exports.Set("postCalendarStoreChanged",
              Napi::Function::New(env, PostCalendarStoreChanged));
}
