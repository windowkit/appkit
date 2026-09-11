'use strict';
// Frames from a worker (windowkit/appkit#52): with the main thread parked in
// runMain, the renderer's thread builds and changes a layer tree with the
// same verbs as pump mode. Between txBegin and txCommit they record into the
// thread's frame batch, which applies on the UI thread as one command, in
// one commit; layers are handles answered at the call; an IOSurface a frame
// takes off a layer is handed back by `surface-released`. Exits 0 when every
// expectation held.

const assert = require('assert');
const fs = require('fs');
const { Worker, isMainThread } = require('worker_threads');
const { native } = require('..');

// a worker's console goes through the parked main thread's loop
const say = (s) => fs.writeSync(2, `threaded-frames: ${s}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
  native.connect((batch) => {
    events.push(...batch);
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
  const pv = (layer, key) => new Promise((resolve) => native.presentationValue(layer, key, resolve));
  // the render server shows a commit a moment after it is made
  const settle = async (layer, key, want, what) => {
    let v;
    for (const t = Date.now(); Date.now() - t < 3000; await sleep(10)) {
      v = await pv(layer, key);
      if (want(v)) return v;
    }
    throw new Error(`${what}: presentation value ${JSON.stringify(v)}`);
  };
  const near = (a, b) => Array.isArray(a) && a.length === b.length && a.every((x, i) => Math.abs(x - b[i]) < 1e-3);

  const win = native.createWindow2({ width: 200, height: 150, title: 'frames', x: 100, y: 120, backgroundColor: [1, 1, 1, 1] });
  await until((ev) => ev.type === 'window-created' && ev.handle === win, 'window-created');
  native.showWindow(win, false);
  const root = native.windowRootLayer(win);

  // --- one frame, one command ---------------------------------------------------

  native.txBegin({ disableActions: true });
  const box = native.createLayer();
  assert.strictEqual(typeof box, 'object', 'createLayer answers a handle at the call');
  native.setLayerProps(box, { frame: [10, 10, 60, 40], backgroundColor: [1, 0, 0, 1], cornerRadius: 4 });
  native.addSublayer(root, box);
  await sleep(100);
  assert.strictEqual(await pv(box, 'bounds'), null, 'an open frame applies nothing: the layer is not made yet');
  native.txCommit();
  await settle(box, 'bounds', (v) => near(v, [0, 0, 60, 40]), 'the frame applied');
  assert(near(await pv(box, 'backgroundColor'), [1, 0, 0, 1]), 'the colour');
  assert.strictEqual(await pv(box, 'cornerRadius'), 4, 'the corner radius');

  // a change to a made layer, outside any txBegin: a command of its own
  native.setLayerProps(box, { cornerRadius: 9 });
  await settle(box, 'cornerRadius', (v) => v === 9, 'a change outside a frame');
  say('one frame: ok');

  // --- the other layer kinds ----------------------------------------------------

  native.txBegin({ disableActions: true });
  const shape = native.createShapeLayer();
  native.setShapeProps(shape, { path: [['rect', 0, 0, 20, 20]], fillColor: [0, 0, 1, 1], lineWidth: 3, lineCap: 'round' });
  const grad = native.createGradientLayer();
  native.setGradientProps(grad, { colors: [[1, 0, 0, 1], [0, 0, 1, 1]], startPoint: [0, 0], endPoint: [1, 1] });
  const text = native.createTextLayer();
  native.setTextProps(text, { string: 'hi', fontSize: 18, color: [0, 0, 0, 1] });
  for (const [i, l] of [shape, grad, text].entries()) {
    native.setLayerProps(l, { frame: [80 + i * 30, 10, 24, 24] });
    native.addSublayer(root, l);
  }
  native.txCommit();
  await settle(shape, 'lineWidth', (v) => v === 3, 'the shape layer');
  assert(near(await pv(shape, 'fillColor'), [0, 0, 1, 1]), 'the shape fill');
  assert(near(await pv(grad, 'endPoint'), [1, 1]), 'the gradient');
  assert.strictEqual(await pv(text, 'fontSize'), 18, 'the text layer');
  native.removeFromSuperlayer(text);
  say('layer kinds: ok');

  // --- animations -----------------------------------------------------------------

  assert.strictEqual(native.addAnimation(box, 'opacity', { from: 0, to: 1, duration: 0.2, id: 'fade' }), 0.2, 'the duration, at the call');
  const fade = await until((ev) => ev.type === 'animation-end' && ev.id === 'fade', 'animation-end');
  assert.strictEqual(fade.finished, true, 'ran out');
  // a delay begins in the layer's own time, set as the animation is added,
  // and `from` shows while it waits
  native.addAnimation(box, 'opacity', { from: 0.25, to: 1, duration: 0.3, delay: 0.6, id: 'late' });
  await sleep(200);
  assert(Math.abs((await pv(box, 'opacity')) - 0.25) < 1e-3, 'the delayed animation shows `from` while it waits');
  await until((ev) => ev.type === 'animation-end' && ev.id === 'late', 'the delayed animation-end');
  native.addAnimation(box, 'opacity', { from: 0, to: 1, duration: 5, id: 'cut' });
  native.removeAnimation(box, 'opacity');
  const cut = await until((ev) => ev.type === 'animation-end' && ev.id === 'cut', 'the removed animation-end');
  assert.strictEqual(cut.finished, false, 'removed before it ran out');
  say('animations: ok');

  // --- buffers change hands by event ------------------------------------------------

  const A = native.createSurfaceIOSurface(64, 64, 1);
  const B = native.createSurfaceIOSurface(64, 64, 1);
  const flip = (s) => {
    native.txBegin({ disableActions: true });
    native.setLayerContentsIOSurface(box, s.iosurfaceId);
    native.txCommit();
  };
  flip(A);
  flip(B);
  const released = await until((ev) => ev.type === 'surface-released', 'surface-released');
  assert.strictEqual(released.id, A.iosurfaceId, 'the buffer the second flip replaced');
  let inUse = true;
  for (const t = Date.now(); inUse && Date.now() - t < 3000; await sleep(20)) inUse = native.surfaceIsInUse(A.handle);
  assert.strictEqual(inUse, false, 'the replaced buffer goes off glass');
  assert.strictEqual(events.filter((ev) => ev.type === 'surface-released').length, 1, 'one release per replaced buffer');

  // surfaceToLayer takes the bitmap at the call: what is drawn afterwards
  // does not reach the frame already posted
  const S = native.createSurface(8, 8, 2);
  native.ctxSetFillColor(S, 0, 1, 0, 1);
  native.ctxFillRect(S, 0, 0, 8, 8);
  native.txBegin({ disableActions: true });
  native.surfaceToLayer(S, box);
  native.txCommit();
  native.ctxSetFillColor(S, 1, 0, 1, 1);
  native.ctxFillRect(S, 0, 0, 8, 8);
  await settle(box, 'contentsScale', (v) => v === 2, 'surfaceToLayer');
  const flipsAfter = events.filter((ev) => ev.type === 'surface-released').length;
  await sleep(100);
  assert.strictEqual(flipsAfter, 2, 'B, taken off the layer by the bitmap, is released too');
  say('buffers: ok');

  native.destroyWindow2(win);
}
