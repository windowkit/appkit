'use strict';
// Full screen, zoom and the Dock (windowkit/appkit#15's remainder), in pump
// mode: setWindowFullScreen takes a window into a Space of its own and back,
// bracketed by window-fullscreen { fullscreen, phase: 'begin' | 'end' }, and
// the published state says the target from the begin on — the moment a
// renderer hides its chrome. A second ask during the transition is applied
// when it ends. setWindowZoomed and setWindowMiniaturized are read back the
// same way. Exits 0 when every expectation held.

const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('window-states:', msg, ...rest);
  process.exit(1);
};

native.initApp();
const events = [];
native.setBackendEventCallback((ev) => events.push(ev));
const win = native.createWindow2({ width: 320, height: 220, title: 'window-states', x: 140, y: 160 });
native.showWindow(win, true);
native.activateApp();

const pumpUntil = (pred, what, ms = 6000) => {
  for (const deadline = Date.now() + ms; Date.now() < deadline; ) {
    native.pump2();
    const hit = events.find(pred);
    if (hit) return hit;
  }
  fail(`timed out waiting for ${what}`, events.map((ev) => ev.type));
};
const settle = (ms) => {
  for (const deadline = Date.now() + ms; Date.now() < deadline; ) native.pump2();
};
settle(300);

const before = native.getWindowFrame(win);
for (const k of ['fullscreen', 'zoomed', 'miniaturized']) {
  if (before[k] !== false) fail(`${k} before anything`, before);
}

// --- full screen, and an exit asked for mid-animation ---------------------
events.length = 0;
let beginRead = null;
native.setBackendEventCallback((ev) => {
  events.push(ev);
  if (ev.type === 'window-fullscreen' && ev.phase === 'begin' && ev.fullscreen)
    beginRead = native.getWindowFrame(win).fullscreen;
});
native.setWindowFullScreen(win, true);
pumpUntil((ev) => ev.type === 'window-fullscreen' && ev.phase === 'begin', 'the enter begin');
if (beginRead !== true) fail('the published state did not say full screen at the begin', beginRead);
native.setWindowFullScreen(win, true); // a no-op: already on its way
pumpUntil((ev) => ev.type === 'window-fullscreen' && ev.phase === 'end' && ev.fullscreen, 'the enter end');
const full = native.getWindowFrame(win);
if (!full.fullscreen || full.zoomed) fail('after entering', full);
if (full.width <= before.width) fail('the window did not grow', before, full);

events.length = 0;
const exitReads = [];
native.setBackendEventCallback((ev) => {
  events.push(ev);
  const f = native.getWindowFrame(win);
  if (!f.fullscreen) exitReads.push(f.zoomed);
});
native.setWindowFullScreen(win, false);
pumpUntil((ev) => ev.type === 'window-fullscreen' && ev.phase === 'begin', 'the exit begin');
native.setWindowFullScreen(win, true); // during the transition, which AppKit would drop
pumpUntil((ev) => ev.type === 'window-fullscreen' && ev.phase === 'end' && ev.fullscreen, 'the re-entry');
if (exitReads.some((z) => z)) fail('zoomed said on the way out of full screen', exitReads);
let fs = events.filter((ev) => ev.type === 'window-fullscreen');
if (fs.map((ev) => `${ev.phase}:${ev.fullscreen}`).join() !== 'begin:false,end:false,begin:true,end:true')
  fail('the ask made during the exit was not applied at its end', fs);
if (fs.some((ev) => ev.windowNumber !== native.windowNumber(win))) fail('for another window', fs);

// an ask that the transition already satisfies starts nothing
events.length = 0;
native.setWindowFullScreen(win, false);
pumpUntil((ev) => ev.type === 'window-fullscreen' && ev.phase === 'begin', 'the second exit begin');
native.setWindowFullScreen(win, true);
native.setWindowFullScreen(win, false);
pumpUntil((ev) => ev.type === 'window-fullscreen' && ev.phase === 'end', 'the second exit end');
settle(1500);
fs = events.filter((ev) => ev.type === 'window-fullscreen');
if (fs.map((ev) => `${ev.phase}:${ev.fullscreen}`).join() !== 'begin:false,end:false')
  fail('expected one exit and nothing after the last ask', fs);
if (native.getWindowFrame(win).fullscreen) fail('still full screen');

// --- zoom -------------------------------------------------------------------
native.setWindowZoomed(win, true);
settle(800);
if (!native.getWindowFrame(win).zoomed) fail('not zoomed', native.getWindowFrame(win));
native.setWindowZoomed(win, false);
settle(800);
if (native.getWindowFrame(win).zoomed) fail('still zoomed', native.getWindowFrame(win));

// --- the Dock ---------------------------------------------------------------
events.length = 0;
native.setWindowMiniaturized(win, true);
pumpUntil((ev) => ev.type === 'window-miniaturize' && ev.miniaturized, 'miniaturize');
if (!native.getWindowFrame(win).miniaturized) fail('published state not miniaturized');
native.setWindowMiniaturized(win, false);
pumpUntil((ev) => ev.type === 'window-miniaturize' && !ev.miniaturized, 'deminiaturize');
if (native.getWindowFrame(win).miniaturized) fail('published state still miniaturized');

native.destroyWindow2(win);
console.log('window-states OK: full screen in and out, a mid-transition ask, zoom, the Dock');
process.exit(0);
