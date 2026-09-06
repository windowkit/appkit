'use strict';
// The accessibility display options (windowkit/appkit#31): the query, and the
// change delivered as a backend event through the same notification centre
// the system posts on — posted from here, since a test cannot flip the
// user's settings, so what is exercised is the observer and the hand-off,
// with whatever the settings are. Exits 0 when every expectation held.
//
// Checked: the query answers five booleans; with no callback a change is
// dropped, not held; with one, each posted change arrives as one event
// carrying the same five fields, with the same values the query gives.

const { native } = require('..');

const received = [];
const fail = (msg, ...rest) => {
  console.error('accessibility-display:', msg, ...rest);
  process.exit(1);
};
const FIELDS = ['reduceMotion', 'reduceTransparency', 'increaseContrast', 'differentiateWithoutColor', 'invertColors'];

function pumpUntil(pred, ms = 3000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const tick = setInterval(() => {
      native.pump2();
      if (pred()) {
        clearInterval(tick);
        resolve();
      } else if (Date.now() > deadline) {
        clearInterval(tick);
        reject(new Error('timed out; received so far: ' + JSON.stringify(received)));
      }
    }, 8);
  });
}
const changes = () => received.filter((e) => e.type === 'accessibility-display-changed');

(async () => {
  native.initApp();

  // 1. the query: five booleans, and the same answer twice
  const opts = native.accessibilityDisplayOptions();
  for (const f of FIELDS) if (typeof opts[f] !== 'boolean') fail('query field ' + f, opts);
  if (Object.keys(opts).length !== FIELDS.length) fail('query has extra fields', opts);
  if (JSON.stringify(native.accessibilityDisplayOptions()) !== JSON.stringify(opts)) fail('query is not stable');

  // 2. nobody listening: the change is dropped, and the process is fine
  native.postAccessibilityDisplayChange();
  const drained = Date.now() + 300;
  while (Date.now() < drained) native.pump2();

  // 3. a listener: nothing replayed from before it, one event per change,
  //    carrying the query's fields and values
  native.setBackendEventCallback((ev) => received.push(ev));
  const settled = Date.now() + 200;
  while (Date.now() < settled) native.pump2();
  if (changes().length !== 0) fail('a change from before the callback was replayed', changes());
  native.postAccessibilityDisplayChange();
  await pumpUntil(() => changes().length === 1);
  const ev = changes()[0];
  for (const f of FIELDS) if (ev[f] !== opts[f]) fail('event field ' + f + ' differs from the query', ev, opts);
  if (Object.keys(ev).length !== FIELDS.length + 1) fail('event has extra fields', ev);
  native.postAccessibilityDisplayChange();
  native.postAccessibilityDisplayChange();
  await pumpUntil(() => changes().length === 3);
  const after = Date.now() + 200;
  while (Date.now() < after) native.pump2();
  if (changes().length !== 3) fail('changes were duplicated', changes().length);

  console.log('accessibility-display OK:', JSON.stringify(opts));
  process.exit(0);
})().catch((e) => fail(e.message));
