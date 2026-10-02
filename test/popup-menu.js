'use strict';
// A pop-up menu over a control (popUpMenu), in pump mode: the menu is
// tracked inside the call, so the answer comes before the call returns —
// the item chosen, or null for a menu dismissed. Keys posted before the call
// are read by the tracking as a person's would be, which is how this drives
// it: Down and Return choose the item after the current one, Escape
// dismisses, and a disabled item is passed over. Exits 0 when every
// expectation held. The worker's half is in threaded-verbs.js.

const assert = require('assert');
const { native } = require('..');

native.initApp();
const win = native.createWindow2({ width: 360, height: 240, title: 'popup-menu', x: 300, y: 200 });
native.showWindow(win, true);
for (const t = Date.now(); Date.now() - t < 300; ) native.pump2();

const key = (code, chars) => {
  native.postKeyEvent(win, true, code, chars);
  native.postKeyEvent(win, false, code, chars);
};
const DOWN = [125, ''];
const RETURN = [36, '\r'];
const ESCAPE = [53, '\x1b'];
const items = [
  { id: 10, title: 'alpha' },
  { id: 11, title: 'beta' },
  { id: 12, title: 'gamma' },
];
const frame = [40, 60, 200, 24];

/** Open a pop-up with `keys` already queued; what it answered, and when. */
function popUp(spec, keys) {
  for (const k of keys) key(...k);
  let answer = 'never';
  const handle = native.popUpMenu(win, { items, frame, ...spec }, (v) => (answer = v));
  return { handle, answer };
}

let r = popUp({ selected: 10 }, [DOWN, RETURN]);
assert.strictEqual(r.answer, 11, 'Down, Return: the item after the current one, answered before the call returned');
assert.strictEqual(typeof r.handle, 'object', 'a menu handle');
assert.strictEqual(native.popUpMenuInfo(r.handle), null, 'answered: no open pop-up behind the handle');
assert.strictEqual(native.cancelPopUpMenu(r.handle), false, 'and nothing to cancel');

r = popUp({ selected: 11 }, [ESCAPE]);
assert.strictEqual(r.answer, null, 'Escape: a dismissal answers null');

r = popUp(
  {
    items: [
      { id: 1, title: 'one' },
      { id: 2, title: 'two', enabled: false },
      { separator: true },
      { id: 3, title: 'three' },
    ],
    selected: 1,
  },
  [DOWN, RETURN],
);
assert.strictEqual(r.answer, 3, 'a disabled item and a separator are passed over');

r = popUp({}, [RETURN]);
assert.notStrictEqual(r.answer, 'never', 'with nothing selected it still opens and answers');

assert.throws(() => native.popUpMenu(win, { items, frame }), TypeError, 'a callback is required');
assert.throws(() => native.popUpMenu({}, { items, frame }, () => {}), TypeError, 'and a window handle');
assert.throws(() => native.cancelPopUpMenu(null), TypeError, 'cancelPopUpMenu takes a menu handle');

native.destroyWindow2(win);
console.log('popup-menu: ok');
process.exit(0);
