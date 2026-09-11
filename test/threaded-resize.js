'use strict';
// The live-resize handshake from a worker (windowkit/appkit#53): with the
// main thread parked in runMain and the renderer on a worker, a window's
// size change waits — bounded — for a frame painted at the new size, and
// that frame lands in the same transaction as the size. The renderer here
// answers every window-resize the way a real one would: a few milliseconds
// of layout, then a frame committed with txCommit({ width, height }).
// Exits 0 when every expectation held.

const assert = require('assert');
const fs = require('fs');
const { Worker, isMainThread } = require('worker_threads');
const { native } = require('..');

// a worker's console goes through the parked main thread's loop
const say = (s) => fs.writeSync(2, `threaded-resize: ${s}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const slack = process.env.CI ? 3 : 1;

if (isMainThread) {
  native.initApp();
  new Worker(__filename).on('error', () => {});
  const code = native.runMain();
  if (code !== 0) say(`FAIL: runMain returned ${code}`);
  process.exit(code === 0 ? 0 : 1);
} else {
  run().then(
    () => native.requestExit(0),
    (e) => {
      say(`FAIL ${e && e.stack ? e.stack : e}`);
      native.requestExit(1);
    },
  );
}

async function run() {
  const events = [];
  let waiters = [];
  let win = null, box = null;
  let layoutMs = 3; // spent on this thread, as layout would be
  let lateMs = 0; // a renderer slower than the budget, off the CPU while late
  const busy = (ms) => {
    for (const t = performance.now(); performance.now() - t < ms; );
  };
  const paint = (w, h) => {
    native.txBegin({ disableActions: true });
    native.setLayerProps(box, { frame: [0, 0, w, h] });
    native.txCommit({ width: w, height: h });
  };
  const liveReads = []; // the published liveResize, read inside each live resize tick
  native.connect((batch) => {
    for (const ev of batch) {
      events.push(ev);
      if (ev.type === 'window-resize' && ev.handle === win && ev.live) liveReads.push(native.getWindowFrame(win).liveResize);
      // the renderer: a frame at every size the window reports
      if (ev.type === 'window-resize' && ev.handle === win && box) {
        if (lateMs) {
          // Late by a timer rather than a busy loop: a spinning thread can
          // keep a small CI VM from scheduling the UI thread whose deadline
          // is being tested (it then wakes when the spin ends, frame in hand)
          setTimeout(() => paint(ev.width, ev.height), lateMs);
        } else {
          busy(layoutMs);
          paint(ev.width, ev.height);
        }
      }
    }
    waiters = waiters.filter((check) => !check());
  });
  const until = (pred, what, ms = 5000) =>
    new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
      const check = () => {
        const hit = events.find(pred);
        if (!hit) return false;
        clearTimeout(timer);
        resolve(hit);
        return true;
      };
      if (!check()) waiters.push(check);
    });
  const q = (xs, p) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(p * xs.length))];
  const acks = (from) => events.slice(from).filter((ev) => ev.type === 'resize-handshake' && ev.handle === win);

  win = native.createWindow2({ width: 300, height: 200, title: 'resize', x: 120, y: 140, backgroundColor: [0.9, 0.9, 0.9, 1] });
  await until((ev) => ev.type === 'window-created' && ev.handle === win, 'window-created');
  native.showWindow(win, false);
  const root = native.windowRootLayer(win);
  native.txBegin({ disableActions: true });
  box = native.createLayer();
  native.setLayerProps(box, { frame: [0, 0, 300, 200], backgroundColor: [0.2, 0.4, 0.8, 1] });
  native.addSublayer(root, box);
  native.txCommit({ width: 300, height: 200 });
  assert.throws(() => native.setResizeHandshake(win, { waitMs: -1 }), TypeError, 'a negative budget');

  // 1. programmatic steps, each met inside the budget
  native.setResizeHandshake(win, { waitMs: 50 });
  let from = events.length;
  for (let i = 1; i <= 20; i++) {
    native.setWindowFrame(win, null, null, 300 + 5 * i, 200 + 3 * i);
    await sleep(20);
  }
  await until(() => acks(from).length >= 20, '20 handshakes');
  let a = acks(from);
  const waited = a.map((ev) => ev.waited);
  say(`programmatic: ${a.filter((ev) => ev.met).length} of ${a.length} met; waited p50 ${q(waited, 0.5).toFixed(2)} ms, max ${Math.max(...waited).toFixed(2)} ms for ${layoutMs} ms of layout`);
  assert(a.every((ev) => ev.met), 'every frame came inside the budget');
  assert(q(waited, 0.5) < (layoutMs + 3) * slack, 'the wait is about the layout time');
  const size = native.getWindowFrame(win);
  const bounds = await new Promise((r) => native.presentationValue(box, 'bounds', r));
  assert.deepStrictEqual(bounds.slice(2), [size.width, size.height], 'the content matches the window');

  // 2. a renderer slower than the budget: the deadline, not a hang
  native.setResizeHandshake(win, { waitMs: 15 });
  lateMs = 60;
  from = events.length;
  native.setWindowFrame(win, null, null, 320, 230);
  await until(() => acks(from).length >= 1, 'the missed handshake');
  a = acks(from)[0];
  say(`missed: met ${a.met}, waited ${a.waited.toFixed(2)} ms of a 15 ms budget for a frame ${lateMs} ms late`);
  assert.strictEqual(a.met, false, 'the frame missed');
  assert(a.waited >= 14 && a.waited < lateMs, 'the wait stopped at the deadline, not at the frame');
  lateMs = 0;
  await sleep(150);

  // 3. off: no wait, no report
  native.setResizeHandshake(win, { waitMs: 0 });
  from = events.length;
  native.setWindowFrame(win, null, null, 310, 210);
  await until((ev) => ev.type === 'window-resize' && ev.handle === win && ev.width === 310, 'the resize with the handshake off');
  await sleep(100);
  assert.strictEqual(acks(from).length, 0, 'no handshake while it is off');

  // 4. a live resize, driven by posted mouse events on the bottom-right
  // corner: AppKit's own tracking loop, the delegate called from inside it
  native.setResizeHandshake(win, { waitMs: 50 });
  const f = native.getWindowFrame(win);
  from = events.length;
  const cx = f.width - 2, cy = f.height - 2;
  native.postMouseEvent(win, 'down', cx, cy);
  for (let i = 1; i <= 30; i++) {
    await sleep(25);
    // top-left stays put while the bottom-right corner is dragged, so a
    // content point is a fixed screen point
    native.postMouseEvent(win, 'drag', cx + 4 * i, cy + 2 * i);
  }
  native.postMouseEvent(win, 'up', cx + 120, cy + 60);
  await sleep(300);
  a = acks(from);
  const live = a.filter((ev) => ev.live);
  say(`live: ${live.filter((ev) => ev.met).length} of ${live.length} live handshakes met (${a.length} in all)` +
    (live.length ? `; waited p50 ${q(live.map((ev) => ev.waited), 0.5).toFixed(2)} ms` : ''));
  assert(live.length > 0, 'the posted drag became a live resize');
  assert(live.every((ev) => ev.met), 'every live frame came inside the budget');

  // #63: the live resize is bracketed by window-live-resize begin / end, the
  // published state says liveResize inside it, and not after
  const after = events.slice(from);
  const phases = after.filter((ev) => ev.type === 'window-live-resize' && ev.handle === win);
  assert.deepStrictEqual(phases.map((ev) => ev.phase), ['begin', 'end'], 'one begin, one end');
  const at = (pred) => after.findIndex(pred);
  const iBegin = at((ev) => ev.type === 'window-live-resize' && ev.phase === 'begin');
  const iEnd = at((ev) => ev.type === 'window-live-resize' && ev.phase === 'end');
  const liveTicks = after.map((ev, i) => [ev, i]).filter(([ev]) => ev.type === 'window-resize' && ev.handle === win && ev.live);
  assert(liveTicks.length && liveTicks.every(([, i]) => i > iBegin && i < iEnd), 'every live tick between begin and end');
  assert(liveReads.length && liveReads.every((v) => v === true), 'published liveResize is true inside the drag');
  assert.strictEqual(native.getWindowFrame(win).liveResize, false, 'and false once it ended');
  say(`live resize bracketed: begin, ${liveTicks.length} live ticks, end`);

  native.destroyWindow2(win);
}
