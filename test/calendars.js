'use strict';
// The EventKit calendar reads (windowkit/appkit#40): the user's calendars,
// the occurrences in a date range, and the store's change notification as a
// backend event. What runs depends on the grant this process holds, and the
// last line says which half ran:
//
//   always      the argument shapes (every bad one a TypeError before
//               anything is fetched, with no callback ever called), the
//               four-year limit on the predicate and its exact boundary,
//               that no answer arrives inside the call, and the change
//               event — held while there is no listener (coalesced, since
//               the event carries nothing), replayed at the first pump with
//               one, then one event per change
//   ungranted   both verbs answer cb(err) naming the status, never []
//   granted     the shapes the README documents, occurrences sorted by
//               start, the all-day convention (local midnight to the last
//               second of the last day), the calendars filter, and an id
//               that names no calendar as an error rather than a widened
//               query
//
// Exits 0 when every expectation held.

const { native, calendars, permissions } = require('..');

const fail = (msg, ...rest) => {
  console.error('calendars:', msg, ...rest);
  process.exit(1);
};

// Yield to node's loop: a timer, then an immediate, so a hand-off from
// another thread has landed before the check (a busy pump2 loop never lets
// one through — the notification arrives on the loop, not in the pump).
const tick = (ms = 20) => new Promise((r) => setTimeout(() => setImmediate(r), ms));

function pumpUntil(pred, what, ms = 3000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const t = setInterval(() => {
      native.pump2();
      if (pred()) { clearInterval(t); resolve(); }
      else if (Date.now() > deadline) { clearInterval(t); reject(new Error('timed out waiting for ' + what)); }
    }, 8);
  });
}

const DAY = 24 * 60 * 60 * 1000;
const SPAN = 1461 * DAY;  // the predicate's four years, one leap day in
const CAL_WORDS = new Set(['local', 'calDAV', 'exchange', 'subscription', 'birthday']);
const SOURCE_WORDS = new Set(['local', 'exchange', 'calDAV', 'mobileMe', 'subscribed', 'birthdays']);
const STATUS_WORDS = new Set(['none', 'confirmed', 'tentative', 'cancelled']);
const AVAIL_WORDS = new Set(['notSupported', 'busy', 'free', 'tentative', 'unavailable']);
const PART_STATUS = new Set(['unknown', 'pending', 'accepted', 'declined', 'tentative', 'delegated', 'completed', 'inProcess']);
const PART_ROLE = new Set(['unknown', 'required', 'optional', 'chair', 'nonParticipant']);
const PART_TYPE = new Set(['unknown', 'person', 'room', 'resource', 'group']);

const isString = (v) => typeof v === 'string';
const orNull = (v, is) => v === null || is(v);

function checkCalendar(c) {
  if (!isString(c.id) || !c.id) fail('calendar id', c);
  if (!isString(c.title)) fail('calendar title', c);
  if (c.color !== null && !(Array.isArray(c.color) && c.color.length === 4 && c.color.every((n) => typeof n === 'number'))) fail('calendar colour', c);
  if (!CAL_WORDS.has(c.type)) fail('calendar type', c);
  if (!c.source || !isString(c.source.id) || !isString(c.source.title) || !SOURCE_WORDS.has(c.source.type)) fail('calendar source', c);
  for (const f of ['immutable', 'allowsModifications', 'subscribed']) {
    if (typeof c[f] !== 'boolean') fail('calendar ' + f, c);
  }
}

function checkParticipant(p, where) {
  if (!orNull(p.name, isString) || !orNull(p.url, isString)) fail(where + ' name/url', p);
  if (!PART_STATUS.has(p.status) || !PART_ROLE.has(p.role) || !PART_TYPE.has(p.type)) fail(where + ' status/role/type', p);
  if (typeof p.isCurrentUser !== 'boolean') fail(where + ' isCurrentUser', p);
}

function checkEvent(e, byId) {
  for (const f of ['id', 'itemId', 'externalId', 'title', 'location', 'notes', 'url', 'timeZone']) {
    if (!orNull(e[f], isString)) fail('event ' + f, e);
  }
  if (!byId.has(e.calendar)) fail('event names a calendar that was not listed', e.calendar);
  if (!(typeof e.start === 'number' && typeof e.end === 'number') || e.end < e.start) fail('event start/end', e);
  if (!STATUS_WORDS.has(e.status) || !AVAIL_WORDS.has(e.availability)) fail('event status/availability', e);
  for (const f of ['allDay', 'recurring', 'detached']) {
    if (typeof e[f] !== 'boolean') fail('event ' + f, e);
  }
  if (!orNull(e.occurrenceDate, (v) => typeof v === 'number')) fail('event occurrenceDate', e);
  if ('organizer' in e) checkParticipant(e.organizer, 'organizer');
  if ('attendees' in e) {
    if (!Array.isArray(e.attendees)) fail('event attendees', e);
    for (const a of e.attendees) checkParticipant(a, 'attendee');
  }
}

(async () => {
  const status = permissions.status('calendars');
  native.initApp();

  // 1. bad shapes: a TypeError before anything is fetched, and no callback
  //    called — a query that cannot be run must not look like an empty answer
  let called = 0;
  const cb = () => { called++; };
  const bad = [
    ['a list without a callback', () => native.calendars(), /expected a callback/],
    ['a callback that is not one', () => native.calendars(7), /expected a callback/],
    ['a query that is not one', () => native.eventsBetween(cb), /\{ start, end/],
    ['a query without a callback', () => native.eventsBetween({ start: 0, end: 1 }), /\{ start, end/],
    ['a start that is not a time', () => native.eventsBetween({ start: 'now', end: 1 }, cb), /'start' must be a time/],
    ['a start that is not finite', () => native.eventsBetween({ start: NaN, end: 1 }, cb), /'start' must be a time/],
    ['an end that is not finite', () => native.eventsBetween({ start: 0, end: Infinity }, cb), /'end' must be a time/],
    ['an end before the start', () => native.eventsBetween({ start: 10, end: 9 }, cb), /'end' is before 'start'/],
    ['a span the predicate cannot take', () => native.eventsBetween({ start: 0, end: SPAN + 1 }, cb), /four-year span/],
    ['a calendars filter that is not a list', () => native.eventsBetween({ start: 0, end: 1, calendars: 'x' }, cb), /array of calendar ids/],
    ['a calendar id that is not a string', () => native.eventsBetween({ start: 0, end: 1, calendars: [1] }, cb), /strings/],
    ['an empty calendars filter', () => native.eventsBetween({ start: 0, end: 1, calendars: [] }, cb), /at least one calendar/],
  ];
  for (const [what, fn, re] of bad) {
    let err;
    try { fn(); } catch (e) { err = e; }
    if (!(err instanceof TypeError)) fail(what + ': expected a TypeError, got', err);
    if (!re.test(err.message)) fail(what + ': message', err.message);
  }
  if (called) fail('a refused call reached its callback');

  // 2. the boundary itself is allowed, and no answer arrives inside the call.
  //    The span sits far enough out to hold nothing, so a granted run is not
  //    a four-year fetch.
  const far = Date.now() + 10 * 365 * DAY;
  let sync = true;
  let answered = 0;
  native.eventsBetween({ start: far, end: far + SPAN }, () => { if (sync) fail('the callback ran inside the call'); answered++; });
  native.calendars(() => { if (sync) fail('the callback ran inside the call'); answered++; });
  sync = false;
  await pumpUntil(() => answered === 2, 'the two answers');

  // 3. the grant decides what can be checked past here
  if (status === 'authorized') {
    const list = await calendars.list();
    if (!Array.isArray(list)) fail('the calendar list is not an array', list);
    list.forEach(checkCalendar);
    const byId = new Map(list.map((c) => [c.id, c]));
    if (byId.size !== list.length) fail('two calendars share an id');

    const from = Date.now() - 30 * DAY;
    const events = await calendars.eventsBetween({ start: new Date(from), end: new Date(from + 90 * DAY) });
    if (!Array.isArray(events)) fail('the event list is not an array', events);
    events.forEach((e) => checkEvent(e, byId));
    for (let i = 1; i < events.length; i++) {
      if (events[i].start < events[i - 1].start) fail('the occurrences are not sorted by start', events[i - 1], events[i]);
    }
    // the all-day convention, as the store reports it: local midnight to the
    // last second of the last day (the renderer normalises, the bridge does not)
    const allDay = events.filter((e) => e.allDay);
    for (const e of allDay) {
      const s = new Date(e.start);
      const t = new Date(e.end);
      if (s.getHours() || s.getMinutes() || s.getSeconds()) fail('an all-day event does not start at local midnight', e);
      if (t.getHours() !== 23 || t.getMinutes() !== 59 || t.getSeconds() !== 59) fail('an all-day event does not end at the last second of a day', e);
    }
    // the filter: only that calendar's occurrences, and the same ones the
    // unfiltered query gave for it
    if (list.length) {
      const one = list.find((c) => events.some((e) => e.calendar === c.id)) || list[0];
      const mine = await calendars.eventsBetween({ start: from, end: from + 90 * DAY, calendars: [one.id] });
      if (mine.some((e) => e.calendar !== one.id)) fail('the calendars filter let another calendar through', one.id);
      if (mine.length !== events.filter((e) => e.calendar === one.id).length) fail('the filtered query and the unfiltered one disagree', one.title);
    }
    // an id that names no calendar is an error, not a query over all of them
    const err = await calendars.eventsBetween({ start: from, end: from + DAY, calendars: ['not-a-calendar'] }).then(() => null, (e) => e);
    if (!err || !/no calendar with identifier 'not-a-calendar'/.test(err.message)) fail('an unknown calendar id', err);
    console.log('calendars: granted —', list.length, 'calendars,', events.length, 'occurrences in 120 days,', allDay.length, 'of them all-day');
  } else {
    // without the grant both verbs answer an error naming the status: "no
    // events" and "not allowed to look" must not read the same
    for (const [what, p] of [['list', calendars.list()], ['eventsBetween', calendars.eventsBetween({ start: far, end: far + DAY })]]) {
      const err = await p.then((v) => v, (e) => e);
      if (!(err instanceof Error)) fail(what + ' answered a value without a grant', err);
      if (!err.message.includes(status)) fail(what + ' did not name the status', err.message);
    }
    console.log('calendars: not granted (' + status + ') — both verbs answered an error naming it');
  }

  // 4. the store's change notification as a backend event. Posted from here
  //    through the same centre EventKit posts on, so the observer, the
  //    hand-off and the replay are the real ones.
  const seen = [];
  native.postCalendarStoreChanged();
  native.postCalendarStoreChanged();
  await tick(50);
  native.pump2();
  if (seen.length) fail('a change was delivered with no listener', seen);
  native.setBackendEventCallback((ev) => { if (ev.type === 'calendar-store-changed') seen.push(ev); });
  native.pump2();
  if (seen.length !== 1) fail('the changes from before the listener should replay as one', seen);
  if (Object.keys(seen[0]).length !== 1) fail('the event carries more than its type', seen[0]);
  native.postCalendarStoreChanged();
  await pumpUntil(() => seen.length === 2, 'a change with a listener installed');
  native.postCalendarStoreChanged();
  native.postCalendarStoreChanged();
  await pumpUntil(() => seen.length === 4, 'two more changes');
  await tick(100);
  if (seen.length !== 4) fail('changes were duplicated', seen.length);
  native.setBackendEventCallback(null);

  console.log('calendars OK:', bad.length, 'bad shapes refused,', seen.length, 'change events');
  process.exit(0);
})().catch((e) => fail(e.stack || e.message));
