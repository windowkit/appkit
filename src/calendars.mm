// @windowkit/appkit calendars.mm — the user's calendars and the occurrences
// in a date range, through EventKit (EKEventStore).
//
// Every account the user added in System Settings › Internet Accounts —
// iCloud, Google, Exchange, CalDAV, a subscribed feed — is served by this one
// framework, the macOS counterpart of Evolution Data Server plus GNOME Online
// Accounts: the desktop did the OAuth, and the app never sees a credential.
//
//   calendars(cb)                              cb(err, [calendar])
//   eventsBetween({ start, end, calendars? }, cb)   cb(err, [event]) — epoch ms
//   event: calendar-store-changed {}           EKEventStoreChangedNotification
//
// Mechanism only, policy stays in the renderer: which calendars to show, how
// to render an all-day span, when to re-query.
//
// Three things EventKit does that a D-Bus (Evolution) rung has to do for
// itself: the predicate answers *occurrences*, so recurrences are already
// expanded and no iCalendar parser is needed here; one notification is posted
// for any change at all, whose documented contract is "re-fetch"; and it
// answers fast enough not to matter as long as the fetch is off the JS
// thread.
//
// Threading. eventsMatchingPredicate: is synchronous and can take a while
// over many calendars, so both verbs run on a background queue and answer
// through a thread-safe function — the automation request in permissions.mm
// is the shape. Fetches are documented thread-safe on EKEventStore; the
// store itself is taken on the JS thread (it is a process-wide singleton,
// and reaching for it from two queues at once would be a race), and what the
// framework hands back is copied into the plain C++ shapes below on the
// background queue, so nothing EventKit-owned crosses to JS.
//
// All-day events cross as the store reports them: allDay true, startDate at
// local midnight and endDate at the last second of the last day. Normalising
// that to an exclusive end is the renderer's job; the bridge is mechanism,
// and its test pins the convention so the renderer's normalisation has
// something to be checked against.
//
// A store without a grant answers cb(err) naming the status — never [] — so
// "no events" and "not allowed to look" stay distinguishable. The grant
// itself is permissions.mm's ('calendars', windowkit/appkit#39); the store is
// shared with it, and neither verb here prompts.
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
#include <cstring>
#include <optional>
#include <string>
#include <utility>
#include <vector>

// backend.mm: the one backend event callback
bool CALHasBackendCb();
void CALEmitBackendEvent(Napi::Env env, Napi::Object ev);

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
};

// One fetch's answer, all plain C++: an error, or the copies. Both verbs
// share it so there is one path from the background queue back to JS.
struct CalAnswer {
  std::string error;  // non-empty: cb(err)
  bool isEvents = false;
  std::vector<CalInfo> calendars;
  std::vector<CalEventInfo> events;
};

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
  return o;
}

// cb(err) or cb(null, [...]) on the JS thread, from the background queue,
// then the thread-safe function goes — which is what was holding the loop
// open for the length of the fetch.
static void Deliver(Napi::ThreadSafeFunction tsfn, CalAnswer* a) {
  napi_status st = tsfn.BlockingCall(
      a, [](Napi::Env env, Napi::Function cb, CalAnswer* a) {
        if (!a->error.empty()) {
          cb.Call({Napi::Error::New(env, a->error).Value()});
        } else if (a->isEvents) {
          Napi::Array out = Napi::Array::New(env, a->events.size());
          for (uint32_t i = 0; i < a->events.size(); i++) {
            out.Set(i, EventJs(env, a->events[i]));
          }
          cb.Call({env.Null(), out});
        } else {
          Napi::Array out = Napi::Array::New(env, a->calendars.size());
          for (uint32_t i = 0; i < a->calendars.size(); i++) {
            out.Set(i, CalendarJs(env, a->calendars[i]));
          }
          cb.Call({env.Null(), out});
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

static void EmitOrHoldChange(Napi::Env env) {
  if (!CALHasBackendCb()) {
    gHeldChange = true;
    return;
  }
  Napi::HandleScope scope(env);
  Napi::Object ev = Napi::Object::New(env);
  ev.Set("type", "calendar-store-changed");
  CALEmitBackendEvent(env, ev);
}

// Called at the start of pump2 (backend.mm): a change from before the
// listener existed goes out ahead of that tick's input.
void CALCalendarsReplayHeld(Napi::Env env) {
  if (!gHeldChange || !CALHasBackendCb()) return;
  gHeldChange = false;
  EmitOrHoldChange(env);
}

static void CallJsChanged(Napi::Env env, Napi::Function, void*, void*) {
  if ((napi_env)env == nullptr) return;  // the function is being torn down
  EmitOrHoldChange(env);
}

// permissions.mm calls this the once, as it creates the process's store: the
// observer is in place from the store's first moment, whichever verb made it.
// EKEventStoreChangedNotification carries no guarantee about its thread, so
// the crossing to node's loop is the same hand-off a notification response
// takes.
void CALCalendarsObserveStore(EKEventStore* store) {
  static id observer = nil;
  if (observer) return;
  observer = [NSNotificationCenter.defaultCenter
      addObserverForName:EKEventStoreChangedNotification
                  object:store
                   queue:nil
              usingBlock:^(NSNotification*) { gChanged.NonBlockingCall(); }];
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
        a->isEvents = true;
        if (Authorized("eventsBetween", a)) FetchEvents(store, q, a);
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
  exports.Set("postCalendarStoreChanged",
              Napi::Function::New(env, PostCalendarStoreChanged));
}
