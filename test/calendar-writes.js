'use strict';
// The EventKit calendar writes (windowkit/appkit#41): an event put in,
// changed and taken out through the shared store — the span for a recurring
// one and the occurrence it reaches, the default calendar, a batch. What
// runs depends on the grant this process holds, and the last line says which
// half ran:
//
//   always      the argument shapes (every bad one a TypeError before
//               anything is saved, with no callback ever called), that no
//               answer arrives inside the call, and that reset answers
//               without a grant
//   ungranted   every verb answers cb(err) naming the status — never an id —
//               and the wrapper's Dates reach the bridge as epoch ms
//   granted     against the user's own default calendar (or the first that
//               allows modifications): create and read back, change with a
//               field left alone and one cleared, the recurrence and the
//               alarms round-tripped, a span of 'this' detaching one
//               occurrence and 'future' splitting the series, removal by
//               span, a batch reset and one committed, the store's change
//               event after a commit, and the framework's refusals crossing
//               as EKErrors — inverted dates, a read-only calendar, an id
//               that names nothing, an occurrence that is not one. Every
//               event it makes carries a title that says what it is, and all
//               of them are removed again before it exits, whatever happened.
//
// Exits 0 when every expectation held.

const { native, calendars, permissions } = require('..');

// Throws rather than exits, so the granted branch's cleanup still runs.
const fail = (msg, ...rest) => {
  console.error('calendar-writes:', msg, ...rest);
  throw new Error('calendar-writes: failed');
};

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

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const PREFIX = 'appkit calendar-writes check';
const isString = (v) => typeof v === 'string';
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const rejection = (p) => p.then((v) => ({ value: v }), (e) => ({ error: e }));

// The k-th local day after `ms`, at the same wall-clock time — what a daily
// rule means across a DST change, where epoch arithmetic would be an hour off.
const daysAfter = (ms, k) => { const d = new Date(ms); d.setDate(d.getDate() + k); return d.getTime(); };

(async () => {
  const status = permissions.status('calendars');
  native.initApp();

  // 1. bad shapes: a TypeError before anything is saved, no callback called
  let called = 0;
  const cb = () => { called++; };
  const ok = { start: 0, end: 1 };
  const bad = [
    ['a save without arguments', () => native.saveEvent(), /expected \(props, opts\?, cb\)/],
    ['a save without a callback', () => native.saveEvent(ok), /expected \(props, opts\?, cb\)/],
    ['props that are not an object', () => native.saveEvent('x', cb), /expected \(props, opts\?, cb\)/],
    ['a create without dates', () => native.saveEvent({ title: 'no dates' }, cb), /'start' and 'end' .* required to create/],
    ['a start that is not a time', () => native.saveEvent({ start: 'now', end: 1 }, cb), /'start' must be a time/],
    ['an end that is not finite', () => native.saveEvent({ start: 0, end: NaN }, cb), /'end' must be a time/],
    ['a title that is not a string', () => native.saveEvent({ ...ok, title: 5 }, cb), /'title' must be a string or null/],
    ['an id that is not a string', () => native.saveEvent({ id: 7, title: 'x' }, cb), /'id' must be the identifier/],
    ['an empty id', () => native.saveEvent({ id: '', title: 'x' }, cb), /'id' must be the identifier/],
    ['an occurrence without an id', () => native.saveEvent({ ...ok, occurrenceDate: 5 }, cb), /pass its 'id' as well/],
    ['an occurrence that is not a time', () => native.saveEvent({ id: 'x', occurrenceDate: 'then' }, cb), /'occurrenceDate' must be a time/],
    ['a calendar that is null', () => native.saveEvent({ ...ok, calendar: null }, cb), /'calendar' must be a calendar id/],
    ['a url that is not one', () => native.saveEvent({ ...ok, url: 'not a url' }, cb), /'url' is not an absolute URL/],
    ['a url without a scheme', () => native.saveEvent({ ...ok, url: 'example.com/x' }, cb), /'url' is not an absolute URL/],
    ['a time zone that is not one', () => native.saveEvent({ ...ok, timeZone: 'Mars/Olympus' }, cb), /'timeZone' is not a time zone identifier/],
    ['an allDay that is not a boolean', () => native.saveEvent({ ...ok, allDay: 'yes' }, cb), /'allDay' must be a boolean/],
    ['an availability one cannot ask for', () => native.saveEvent({ ...ok, availability: 'notSupported' }, cb), /'availability' must be/],
    ['a recurrence as RRULE text', () => native.saveEvent({ ...ok, recurrence: 'FREQ=DAILY' }, cb), /'recurrence' must be \{ frequency/],
    ['a recurrence without a frequency', () => native.saveEvent({ ...ok, recurrence: {} }, cb), /recurrence\.frequency must be/],
    ['a frequency that is not one', () => native.saveEvent({ ...ok, recurrence: { frequency: 'hourly' } }, cb), /recurrence\.frequency must be/],
    ['an interval of zero', () => native.saveEvent({ ...ok, recurrence: { frequency: 'daily', interval: 0 } }, cb), /recurrence\.interval must be an integer from 1/],
    ['both until and count', () => native.saveEvent({ ...ok, recurrence: { frequency: 'daily', until: 5, count: 2 } }, cb), /not both/],
    ['a count of zero', () => native.saveEvent({ ...ok, recurrence: { frequency: 'daily', count: 0 } }, cb), /recurrence\.count must be an integer from 1/],
    ['days of the week as numbers', () => native.saveEvent({ ...ok, recurrence: { frequency: 'weekly', daysOfWeek: [2] } }, cb), /daysOfWeek must be an array of \{ day/],
    ['an eighth day', () => native.saveEvent({ ...ok, recurrence: { frequency: 'weekly', daysOfWeek: [{ day: 8 }] } }, cb), /daysOfWeek\[\]\.day must be an integer from 1 to 7/],
    ['a week number on a weekly rule', () => native.saveEvent({ ...ok, recurrence: { frequency: 'weekly', daysOfWeek: [{ day: 2, week: 1 }] } }, cb), /no meaning on a daily or weekly rule/],
    ['a sixth week of the month', () => native.saveEvent({ ...ok, recurrence: { frequency: 'monthly', daysOfWeek: [{ day: 2, week: 6 }] } }, cb), /from -5 to 5 for a monthly rule/],
    ['a 32nd of the month', () => native.saveEvent({ ...ok, recurrence: { frequency: 'monthly', daysOfMonth: [32] } }, cb), /daysOfMonth must be an integer from -31 to 31/],
    ['a zeroth of the month', () => native.saveEvent({ ...ok, recurrence: { frequency: 'monthly', daysOfMonth: [0] } }, cb), /daysOfMonth must be an integer from -31 to 31/],
    ['a 13th month', () => native.saveEvent({ ...ok, recurrence: { frequency: 'yearly', monthsOfYear: [13] } }, cb), /monthsOfYear must be an integer from 1 to 12/],
    ['alarms that are not a list', () => native.saveEvent({ ...ok, alarms: { offset: 1 } }, cb), /'alarms' must be an array/],
    ['an alarm with no trigger', () => native.saveEvent({ ...ok, alarms: [{}] }, cb), /'alarms' must be an array/],
    ['an alarm with two triggers', () => native.saveEvent({ ...ok, alarms: [{ offset: 1, at: 2 }] }, cb), /'alarms' must be an array/],
    ['an offset that is not a number', () => native.saveEvent({ ...ok, alarms: [{ offset: 'soon' }] }, cb), /alarms\[\]\.offset must be a number of seconds/],
    ['a span that is not one', () => native.saveEvent(ok, { span: 'all' }, cb), /span must be 'this'/],
    ['a commit that is not a boolean', () => native.saveEvent(ok, { commit: 'no' }, cb), /commit must be a boolean/],
    ['an occurrence in the save options', () => native.saveEvent(ok, { occurrenceDate: 5 }, cb), /'occurrenceDate' goes in the props/],
    ['options that are not an object', () => native.saveEvent(ok, 'opts', cb), /options must be/],
    ['a remove without arguments', () => native.removeEvent(), /expected \(id, opts\?, cb\)/],
    ['a remove without a callback', () => native.removeEvent('x'), /expected \(id, opts\?, cb\)/],
    ['a remove of a number', () => native.removeEvent(7, cb), /'id' must be the identifier/],
    ['a remove of nothing', () => native.removeEvent('', cb), /'id' must be the identifier/],
    ['a remove with a span that is not one', () => native.removeEvent('x', { span: 'never' }, cb), /span must be 'this'/],
    ['a remove of an occurrence that is not a time', () => native.removeEvent('x', { occurrenceDate: 'then' }, cb), /occurrenceDate must be a time/],
    ['the default calendar without a callback', () => native.defaultCalendar(), /expected a callback/],
    ['a commit without a callback', () => native.commitCalendarStore(), /expected a callback/],
    ['a reset with a callback that is not one', () => native.resetCalendarStore(5), /expected a callback/],
  ];
  for (const [what, fn, re] of bad) {
    let err;
    try { fn(); } catch (e) { err = e; }
    if (!(err instanceof TypeError)) fail(what + ': expected a TypeError, got', err);
    if (!re.test(err.message)) fail(what + ': message', err.message);
  }
  if (called) fail('a refused call reached its callback');

  // 2. no answer arrives inside the call; reset needs no grant. A throw
  //    inside a native callback would be swallowed, so what went wrong is
  //    noted there and raised here.
  let sync = true;
  let answered = 0;
  let wrong = null;
  native.defaultCalendar(() => { if (sync) wrong = 'defaultCalendar answered inside the call'; answered++; });
  native.resetCalendarStore((err) => {
    if (sync) wrong = 'reset answered inside the call';
    if (err !== null && err !== undefined) wrong = 'reset answered an error: ' + err;
    answered++;
  });
  sync = false;
  await pumpUntil(() => answered === 2, 'the two answers');
  if (wrong) fail(wrong);

  if (status !== 'authorized' && status !== 'writeOnly') {
    // 3a. without a grant every verb answers an error naming the status — never
    //     an id — and a Date reaches the bridge as epoch ms (the refusal is the
    //     grant's, not the shape's)
    const verbs = [
      ['defaultCalendar', rejection(calendars.defaultCalendar())],
      ['saveEvent', rejection(calendars.saveEvent({ title: PREFIX, start: new Date(), end: new Date(Date.now() + HOUR), recurrence: { frequency: 'daily', until: new Date() }, alarms: [{ at: new Date() }] }))],
      ['removeEvent', rejection(calendars.removeEvent('x', { occurrenceDate: new Date() }))],
      ['commit', rejection(calendars.commit())],
    ];
    for (const [what, p] of verbs) {
      const r = await p;
      if (!(r.error instanceof Error)) fail(what + ' answered a value without a grant', r.value);
      if (!r.error.message.includes(status)) fail(what + ' did not name the status', r.error.message);
    }
    console.log('calendar-writes: not granted (' + status + ') — every verb answered an error naming it;', bad.length, 'bad shapes refused');
    process.exit(0);
  }

  // 3b. the granted half, against a real calendar. Everything it makes is
  //     titled PREFIX and removed at the end.
  let changes = 0;
  native.setBackendEventCallback((ev) => { if (ev.type === 'calendar-store-changed') changes++; });
  const list = status === 'authorized' ? await calendars.list() : [];
  const def = await calendars.defaultCalendar();
  if (def !== null && !(def && isString(def.id) && isString(def.title) && typeof def.allowsModifications === 'boolean')) fail('defaultCalendar shape', def);
  const cal = def && def.allowsModifications ? def : list.find((c) => c.allowsModifications);
  if (!cal) {
    console.log('calendar-writes: granted (' + status + '), but no calendar allows modifications — nothing to write into;', bad.length, 'bad shapes refused');
    process.exit(0);
  }
  const fetch = (from, to) => calendars.eventsBetween({ start: from, end: to, calendars: [cal.id] });
  const mine = (events) => events.filter((e) => isString(e.title) && e.title.startsWith(PREFIX));
  const only = (events, id) => {
    const m = events.filter((e) => e.id === id);
    if (m.length !== 1) fail('expected one occurrence of ' + id + ', found ' + m.length, events.map((e) => [e.id, e.title, e.occurrenceDate]));
    return m[0];
  };
  const sweep = async () => {
    // remove, by series, everything with the prefix in the working window
    for (let round = 0; round < 3; round++) {
      const left = mine(await fetch(base - 2 * DAY, base + 20 * DAY));
      if (!left.length) return [];
      for (const id of new Set(left.map((e) => e.id))) {
        await calendars.removeEvent(id, { span: 'future' }).catch(() => {});
      }
    }
    return mine(await fetch(base - 2 * DAY, base + 20 * DAY));
  };

  // the working window: six weeks out, mid-morning local time
  const at = new Date(); at.setDate(at.getDate() + 45); at.setHours(9, 0, 0, 0);
  const base = at.getTime();
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const facts = [];
  let failed = null;
  try {
    // create, with a Date for start and ms for end, and read back every field
    const id = await calendars.saveEvent({
      calendar: cal.id, title: PREFIX + ' 1', start: new Date(base), end: base + HOUR, location: 'Nowhere in particular',
      notes: 'made by test/calendar-writes.js; safe to delete', url: 'https://github.com/windowkit/appkit/issues/41',
      timeZone: tz, availability: 'free', alarms: [{ offset: -600 }],
    });
    if (!isString(id) || !id) fail('saveEvent did not answer an id', id);
    await pumpUntil(() => changes >= 1, 'the change event after a commit');
    let e = only(await fetch(base - DAY, base + DAY), id);
    if (e.calendar !== cal.id) fail('created in the wrong calendar', e.calendar, cal.id);
    if (e.title !== PREFIX + ' 1' || e.location !== 'Nowhere in particular' || e.notes !== 'made by test/calendar-writes.js; safe to delete') fail('created text fields', e);
    if (e.url !== 'https://github.com/windowkit/appkit/issues/41') fail('created url', e.url);
    if (e.start !== base || e.end !== base + HOUR || e.allDay) fail('created dates', e.start - base, e.end - base - HOUR, e.allDay);
    if (e.timeZone !== tz) fail('created timeZone', e.timeZone, tz);
    if (e.availability !== 'free') fail('created availability', e.availability);
    if (!same(e.alarms, [{ offset: -600 }])) fail('created alarms', e.alarms);
    if (e.recurring || 'recurrence' in e) fail('a plain event reads as recurring', e);
    facts.push('created and read back');

    // change: a field given changes, one absent stays, null clears
    const id2 = await calendars.saveEvent({ id, title: PREFIX + ' 2', start: base + HOUR, end: base + 2 * HOUR, location: null, notes: 'changed', alarms: null });
    if (id2 !== id) facts.push('a change answered a new id');
    e = only(await fetch(base - DAY, base + DAY), id2);
    if (e.title !== PREFIX + ' 2' || e.notes !== 'changed') fail('changed fields', e);
    if (e.location !== null) fail('a null did not clear the location', e.location);
    if (e.url !== 'https://github.com/windowkit/appkit/issues/41') fail('an absent field did not stay', e.url);
    if (e.start !== base + HOUR || e.end !== base + 2 * HOUR) fail('moved dates', e);
    if ('alarms' in e) fail('a null did not clear the alarms', e.alarms);
    facts.push('changed in place');

    // all-day, in the store's own convention (local midnight to the last
    // second of the day) reads back as written; an exclusive end — the next
    // midnight — is recorded as the store makes of it, not asserted
    const day0 = new Date(base); day0.setHours(0, 0, 0, 0);
    const idA = await calendars.saveEvent({ calendar: cal.id, title: PREFIX + ' all-day', start: day0.getTime(), end: daysAfter(day0.getTime(), 1) - 1000, allDay: true });
    let ad = only(await fetch(base - DAY, base + 2 * DAY), idA);
    if (!ad.allDay || ad.start !== day0.getTime() || ad.end !== daysAfter(day0.getTime(), 1) - 1000) fail('all-day in the store convention', ad.allDay, ad.start - day0.getTime(), ad.end - daysAfter(day0.getTime(), 1));
    await calendars.saveEvent({ id: idA, end: daysAfter(day0.getTime(), 1) });
    ad = only(await fetch(base - DAY, base + 3 * DAY), idA);
    facts.push('an all-day end at the next midnight reads back as ' + Math.round((ad.end - ad.start) / HOUR) + ' hours');
    await calendars.removeEvent(idA);

    // a recurrence, read back in its own shape, five occurrences a day apart
    const rule = { frequency: 'daily', interval: 1, until: null, count: 5, daysOfWeek: null, daysOfMonth: null, monthsOfYear: null, weeksOfYear: null, daysOfYear: null, setPositions: null };
    await calendars.saveEvent({ id: id2, recurrence: { frequency: 'daily', count: 5 } });
    let occ = mine(await fetch(base - DAY, base + 8 * DAY)).sort((a, b) => a.occurrenceDate - b.occurrenceDate);
    if (occ.length !== 5) fail('expected five occurrences', occ.map((o) => [o.id, o.title, o.occurrenceDate]));
    for (let k = 0; k < 5; k++) {
      const o = occ[k];
      if (o.id !== id2 || !o.recurring || o.detached) fail('occurrence ' + k, o);
      if (!same(o.recurrence, rule)) fail('the rule did not round-trip', o.recurrence, rule);
      if (o.occurrenceDate !== daysAfter(base + HOUR, k) || o.start !== o.occurrenceDate) fail('occurrence ' + k + ' is not on its day', o.occurrenceDate - daysAfter(base + HOUR, k));
    }
    facts.push('recurrence round-tripped');

    // span 'this' at the third occurrence: that one detaches, the rest stay
    await calendars.saveEvent({ id: id2, occurrenceDate: occ[2].occurrenceDate, title: PREFIX + ' 3', start: occ[2].start + HOUR, end: occ[2].end + HOUR }, { span: 'this' });
    occ = mine(await fetch(base - DAY, base + 8 * DAY)).sort((a, b) => a.occurrenceDate - b.occurrenceDate);
    if (occ.length !== 5) fail('a detached occurrence changed the count', occ.length);
    const slot = daysAfter(base + HOUR, 2);  // where the series had put the third
    if (occ[2].title !== PREFIX + ' 3' || !occ[2].detached || occ[2].start !== slot + HOUR) fail('the third occurrence did not detach and move', occ[2]);
    for (const k of [0, 1, 3, 4]) if (occ[k].title !== PREFIX + ' 2' || occ[k].detached) fail('span this touched occurrence ' + k, occ[k]);
    facts.push(occ[2].id === id2 ? 'a detached occurrence keeps the series id' : 'a detached occurrence gets its own id');
    facts.push('a moved, detached occurrence reports occurrenceDate as ' + (occ[2].occurrenceDate === slot ? 'its original slot' : occ[2].occurrenceDate === occ[2].start ? 'its new start' : 'neither (' + occ[2].occurrenceDate + ')'));

    // span 'future' at the fourth: it and the fifth change, the rest stay
    await calendars.saveEvent({ id: id2, occurrenceDate: occ[3].occurrenceDate, title: PREFIX + ' 4' }, { span: 'future' });
    occ = mine(await fetch(base - DAY, base + 8 * DAY)).sort((a, b) => a.occurrenceDate - b.occurrenceDate);
    if (occ.length !== 5) fail('span future changed the count', occ.map((o) => [o.id, o.title]));
    for (const k of [3, 4]) if (occ[k].title !== PREFIX + ' 4') fail('span future missed occurrence ' + k, occ[k]);
    for (const k of [0, 1]) if (occ[k].title !== PREFIX + ' 2') fail('span future reached back to occurrence ' + k, occ[k]);
    if (occ[2].title !== PREFIX + ' 3') fail('span future touched the detached occurrence', occ[2]);
    facts.push(occ[3].id === id2 ? 'span future keeps the series id' : 'span future splits the series into a new id');

    // remove with span 'future' from the second: the first stays, the second goes
    await calendars.removeEvent(id2, { span: 'future', occurrenceDate: occ[1].occurrenceDate });
    occ = mine(await fetch(base - DAY, base + 8 * DAY)).sort((a, b) => a.occurrenceDate - b.occurrenceDate);
    if (!occ.some((o) => o.id === id2 && o.occurrenceDate === daysAfter(base + HOUR, 0))) fail('removing future from the second took the first', occ);
    if (occ.some((o) => o.occurrenceDate === daysAfter(base + HOUR, 1))) fail('removing future from the second left it', occ);
    facts.push('after removing future from the second, ' + occ.length + ' occurrence(s) remain');

    // remove every series that is left, by id, from its first occurrence
    for (const sid of new Set(occ.map((o) => o.id))) await calendars.removeEvent(sid, { span: 'future' });
    if (mine(await fetch(base - DAY, base + 8 * DAY)).length) fail('removing by id left occurrences behind');

    // a batch: saved with commit false, reset forgets it; saved again, commit keeps it
    const before = changes;
    const idB = await calendars.saveEvent({ calendar: cal.id, title: PREFIX + ' batch', start: base, end: base + HOUR }, { commit: false });
    facts.push('an uncommitted save answers ' + (isString(idB) ? 'an id' : String(idB)));
    await calendars.reset();
    if (mine(await fetch(base - DAY, base + DAY)).length) fail('a reset batch reached the store');
    await calendars.saveEvent({ calendar: cal.id, title: PREFIX + ' batch', start: base, end: base + HOUR }, { commit: false });
    await calendars.commit();
    await pumpUntil(() => changes > before, 'the change event after commit()');
    const batched = mine(await fetch(base - DAY, base + DAY));
    if (batched.length !== 1 || batched[0].title !== PREFIX + ' batch') fail('a committed batch did not reach the store', batched);
    await calendars.removeEvent(batched[0].id);
    if (mine(await fetch(base - DAY, base + DAY)).length) fail('the batched event was not removed');
    facts.push('batch reset and committed');

    // the framework's refusals cross as EKErrors, with their coordinates
    let r = await rejection(calendars.saveEvent({ calendar: cal.id, title: PREFIX + ' inverted', start: base + HOUR, end: base }));
    if (r.error) {
      if (r.error.domain !== 'EKErrorDomain' || typeof r.error.code !== 'number') fail('inverted dates: not an EKError', r.error);
      facts.push('inverted dates: ' + r.error.reason);
    } else {
      facts.push('inverted dates were accepted');
    }
    const ro = list.find((c) => !c.allowsModifications);
    if (ro) {
      r = await rejection(calendars.saveEvent({ calendar: ro.id, title: PREFIX + ' read-only', start: base, end: base + HOUR }));
      if (!r.error) fail('a read-only calendar took an event', ro.title);
      if (r.error.domain !== 'EKErrorDomain') fail('read-only calendar: not an EKError', r.error);
      facts.push('read-only calendar: ' + r.error.reason);
    }
    r = await rejection(calendars.saveEvent({ id: 'not-an-event', title: 'x' }));
    if (!r.error || !/no event with identifier 'not-an-event'/.test(r.error.message)) fail('an unknown id on save', r);
    r = await rejection(calendars.removeEvent('not-an-event'));
    if (!r.error || !/no event with identifier 'not-an-event'/.test(r.error.message)) fail('an unknown id on remove', r);
    r = await rejection(calendars.saveEvent({ calendar: 'not-a-calendar', start: base, end: base + HOUR }));
    if (!r.error || !/no calendar with identifier 'not-a-calendar'/.test(r.error.message)) fail('an unknown calendar', r);
    const idP = await calendars.saveEvent({ calendar: cal.id, title: PREFIX + ' plain', start: base, end: base + HOUR });
    r = await rejection(calendars.saveEvent({ id: idP, occurrenceDate: base + 12345, title: 'x' }));
    if (!r.error || !/no occurrence of/.test(r.error.message)) fail('an occurrence that is not one', r);
    await calendars.removeEvent(idP);
    facts.push('refusals named');
  } catch (err) {
    failed = err;
  } finally {
    native.setBackendEventCallback(null);
    const left = await sweep().catch((e) => [{ title: 'sweep failed: ' + e.message }]);
    if (left.length) {
      console.error('calendar-writes: could not remove what it made — please delete from', cal.title + ':', left.map((e) => e.title));
      process.exit(1);
    }
  }
  if (failed) { console.error(failed.stack || failed.message); process.exit(1); }
  console.log('calendar-writes: granted (' + status + ') in "' + cal.title + '" —', facts.join('; ') + ';', changes, 'change events;', bad.length, 'bad shapes refused');
  process.exit(0);
})().catch((e) => { console.error(e.stack || e.message); process.exit(1); });
