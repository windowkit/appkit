'use strict';
// window-live-resize in pump mode (windowkit/appkit#63): a live resize
// driven by mouse events posted on a window's bottom-right corner — AppKit's
// own tracking loop, run inside pump2() — is bracketed by begin and end
// events around its live window-resize ticks, and getWindowFrame says
// liveResize inside it and not after. (threaded-resize.js checks the same
// from a worker.) Exits 0 when every expectation held.

const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('live-resize:', msg, ...rest);
  process.exit(1);
};

native.initApp();
const events = [];
const liveReads = [];
let win = null;
native.setBackendEventCallback((ev) => {
  events.push(ev);
  if (ev.type === 'window-resize' && ev.live) liveReads.push(native.getWindowFrame(win).liveResize);
});
win = native.createWindow2({ width: 300, height: 200, title: 'live-resize', x: 120, y: 140 });
native.showWindow(win, false);
native.pump2(); // one dequeue first: an event posted before the app's first is dropped

const f = native.getWindowFrame(win);
if (f.liveResize !== false) fail('liveResize before any resize', f);
// the top-left stays put while the bottom-right corner is dragged, so a
// content point is a fixed screen point
const cx = f.width - 2, cy = f.height - 2;
native.postMouseEvent(win, 'down', cx, cy);
for (let i = 1; i <= 12; i++) native.postMouseEvent(win, 'drag', cx + 5 * i, cy + 3 * i);
native.postMouseEvent(win, 'up', cx + 60, cy + 36);
for (const deadline = Date.now() + 3000; Date.now() < deadline; ) {
  native.pump2();
  if (events.some((ev) => ev.type === 'window-live-resize' && ev.phase === 'end')) break;
}

const phases = events.filter((ev) => ev.type === 'window-live-resize');
if (phases.map((ev) => ev.phase).join() !== 'begin,end') fail('expected one begin and one end', phases);
if (phases.some((ev) => ev.windowNumber !== native.windowNumber(win))) fail('for another window', phases);
const iBegin = events.indexOf(phases[0]), iEnd = events.indexOf(phases[1]);
const ticks = events.map((ev, i) => [ev, i]).filter(([ev]) => ev.type === 'window-resize' && ev.live);
if (!ticks.length) fail('no live window-resize ticks', events.map((ev) => ev.type));
if (!ticks.every(([, i]) => i > iBegin && i < iEnd)) fail('a live tick outside begin / end');
if (!liveReads.every((v) => v === true)) fail('getWindowFrame did not say liveResize inside the drag', liveReads);
if (native.getWindowFrame(win).liveResize !== false) fail('liveResize after the end');
native.destroyWindow2(win);
console.log(`live-resize OK: begin, ${ticks.length} live ticks, end`);
process.exit(0);
