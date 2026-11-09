'use strict';
// A window made larger and smaller a step at a time, as a live resize does,
// reports no mouseenter and no mouseleave: the pointer did not cross into
// the view or out of it. Each step changed the view's geometry, and the
// view made its tracking area again at each one, which AppKit answered with
// an exit and an enter: an application heard the pointer leave and come
// back some sixty times a second while a window's edge was dragged, and a
// page in it ran its mouse handlers for each. Exits 0 when none came.

const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('resize-no-crossing:', msg, ...rest);
  process.exit(1);
};

native.initApp();
const events = [];
native.setBackendEventCallback((ev) => events.push(ev));
const win = native.createWindow2({ width: 300, height: 200, title: 'resize-no-crossing', x: 120, y: 140 });
native.showWindow(win, false);
const settle = (ms) => {
  for (const deadline = Date.now() + ms; Date.now() < deadline; ) native.pump2();
};
settle(300);

const crossings = () => events.filter((ev) => ev.type === 'mouseenter' || ev.type === 'mouseleave');
const before = crossings().length;
let resizes = 0;
for (let i = 1; i <= 30; i++) {
  const grow = i <= 15 ? i : 30 - i;
  native.setWindowFrame(win, null, null, 300 + 8 * grow, 200 + 4 * grow);
  settle(16);
}
settle(200);
resizes = events.filter((ev) => ev.type === 'window-resize').length;
if (!resizes) fail('no window-resize came, so nothing was checked');
const during = crossings().slice(before);
if (during.length) fail(`${during.length} crossings over ${resizes} resizes`, during.slice(0, 4).map((ev) => ev.type));
native.destroyWindow2(win);
console.log(`resize-no-crossing OK: ${resizes} resizes, no crossing`);
process.exit(0);
