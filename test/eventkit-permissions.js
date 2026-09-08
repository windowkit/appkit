'use strict';
// The EventKit privacy authorizations (windowkit/appkit#39): 'calendars' and
// 'reminders' in permissions.mm's shape, with the fifth status word macOS 14
// added ('writeOnly', the save-only grant) and the { access } option that
// names the calendars grant to ask for. Only the reading half runs here — a
// request raises the system prompt, which no test can answer — so what is
// exercised is the status (never a prompt; one of the five words; the same
// word whichever level is named, since the level only matters to a request),
// the argument shapes (every bad one a TypeError before anything is asked,
// with no callback ever called and the loop not held), the wrapper's
// rejection, and the Settings anchor's validation. Exits 0 when every
// expectation held.

const { native, permissions } = require('..');

const fail = (msg, ...rest) => {
  console.error('eventkit-permissions:', msg, ...rest);
  process.exit(1);
};
const WORDS = new Set(['authorized', 'denied', 'restricted', 'notDetermined', 'writeOnly']);

(async () => {
  // 1. the status: one of the five words, stable, the same word with or
  //    without a level, through the wrapper too
  const seen = {};
  for (const kind of ['calendars', 'reminders']) {
    const s = native.authorizationStatus(kind);
    if (!WORDS.has(s)) fail(kind + ' status', s);
    if (native.authorizationStatus(kind) !== s) fail(kind + ' status is not stable');
    for (const opts of [{}, { access: 'full' }, { access: undefined }, { access: null }]) {
      if (native.authorizationStatus(kind, opts) !== s) fail(kind + ' with', opts);
    }
    if (permissions.status(kind) !== s) fail(kind + ' through the wrapper');
    seen[kind] = s;
  }
  if (native.authorizationStatus('calendars', { access: 'write-only' }) !== seen.calendars) fail('calendars with access write-only');
  // the older kinds never answer the fifth word
  for (const kind of ['camera', 'microphone', 'location']) {
    if (native.authorizationStatus(kind) === 'writeOnly') fail(kind + ' answered writeOnly');
  }

  // 2. bad shapes: a TypeError before anything is asked — no prompt, no
  //    callback, and nothing left holding the loop
  let called = 0;
  const cb = () => { called++; };
  const bad = [
    ['reminders have no write-only grant', () => native.authorizationStatus('reminders', { access: 'write-only' }), /no write-only grant/],
    ['nor can one be requested', () => native.requestAuthorization('reminders', { access: 'write-only' }, cb), /no write-only grant/],
    ['an unknown level', () => native.authorizationStatus('calendars', { access: 'read-only' }), /'full' or 'write-only'/],
    ['a level that is not a string', () => native.requestAuthorization('calendars', { access: 1 }, cb), /'full' or 'write-only'/],
    ['a request without a callback', () => native.requestAuthorization('calendars', { access: 'write-only' }), /callback/],
    ['a kind that is not one', () => native.authorizationStatus('calendar'), /unknown kind 'calendar'/],
    ['a Settings anchor that is not one', () => native.openPrivacySettings('calendar'), /unknown kind 'calendar'/],
  ];
  for (const [what, fn, re] of bad) {
    let err;
    try { fn(); } catch (e) { err = e; }
    if (!(err instanceof TypeError)) fail(what + ': expected a TypeError, got', err);
    if (!re.test(err.message)) fail(what + ': message', err.message);
  }
  // the wrapper turns the same TypeError into a rejection
  const rejected = await permissions.request('reminders', { access: 'write-only' }).then(() => null, (e) => e);
  if (!(rejected instanceof TypeError)) fail('the wrapper did not reject a bad shape', rejected);
  if (called) fail('a refused request called its callback');

  // 3. nothing above held the loop: an unreferenced timer only fires if
  //    something else keeps the process alive
  setTimeout(() => fail('still running 3 s later: a refused request held the loop open'), 3000).unref();
  process.on('exit', (code) => {
    if (code === 0 && called) fail('a refused request called its callback late');
  });
  console.log('eventkit-permissions OK:', JSON.stringify(seen), 'and', bad.length, 'bad shapes refused');
})();
