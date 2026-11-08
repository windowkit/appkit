'use strict';
// Media capture from a worker (src/capture.mm, threaded mode): with the main
// thread parked in runMain, the same verbs answer the same way, and what
// AVFoundation and CoreAudio report from their own queues comes through the
// channel — a camera that is not there, the devices listed through a
// callback, an output's queue played out, a camera's layer as a handle, and
// a display's stream started, its layer a handle too.
// Exits 0 when every expectation held.

const assert = require('assert');
const fs = require('fs');
const { Worker, isMainThread } = require('worker_threads');
const { native } = require('..');

const say = (s) => fs.writeSync(2, `capture-threaded: ${s}\n`);
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
  const answer = (fn) => new Promise((resolve) => fn(resolve));

  const devices = await answer((cb) => native.captureDevices(cb));
  assert(Array.isArray(devices), 'captureDevices(cb) from a worker');
  assert.deepStrictEqual(
    native.captureDevices().map((d) => d.id).sort(),
    devices.map((d) => d.id).sort(),
    'and the same synchronously',
  );

  const cam = native.openCamera('no-such-camera', {});
  const refused = await until((e) => e.type === 'camera-error' && e.id === cam.id, 'camera-error');
  assert.strictEqual(refused.name, 'NotFoundError', 'a missing camera, through the channel');
  native.closeCamera(cam.id);

  const camera = devices.find((d) => d.kind === 'camera');
  if (camera && native.authorizationStatus('camera') === 'authorized') {
    const c = native.openCamera(camera.id, { width: 640, height: 480 });
    assert.strictEqual(typeof c.layer, 'object', 'the layer is a handle at the call');
    await until((e) => (e.type === 'camera-started' || e.type === 'camera-error') && e.id === c.id, 'the camera');
    native.cameraFrames(c.id, true);
    const f = await until((e) => e.type === 'camera-frame' && e.id === c.id, 'a frame');
    assert(Buffer.isBuffer(f.planes[0]), 'planes cross as Buffers');
    native.closeCamera(c.id);
  }

  if (devices.some((d) => d.kind === 'speaker' && d.isDefault)) {
    const out = native.openAudioOutput({ sampleRate: 24000, channels: 2 });
    const silence = new Float32Array(2400);
    assert.strictEqual(native.audioOutputWrite(out.id, [silence, silence]), 2400, 'queued from a worker');
    const deadline = Date.now() + 3000;
    while (native.audioOutputState(out.id).queued > 0 && Date.now() < deadline) await sleep(20);
    const state = native.audioOutputState(out.id);
    assert.strictEqual(state.queued, 0, 'the queue played out');
    assert(state.currentTime >= 0.099, `0.1s played: ${JSON.stringify(state)}`);
    native.closeAudioOutput(out.id);
  }

  const displays = await answer((cb) => native.screenCaptureDisplays(cb));
  assert(displays.length > 0, 'displays through a callback');
  assert.throws(() => native.screenCaptureDisplays(), TypeError, 'and not synchronously off the main thread');

  // a display's stream (src/displaystream.mm): a window that is not there
  // refused through the channel, and the main display streamed where Screen
  // Recording is allowed — its layer a handle at the call, its frames
  // crossing as Buffers
  const missing = native.openDisplayStream({ window: 0x7ffffff0 });
  assert.strictEqual(typeof missing.layer, 'object', 'a stream’s layer is a handle at the call');
  if (native.authorizationStatus('screen-recording') === 'authorized') {
    const gone = await until((e) => e.type === 'display-error' && e.id === missing.id, 'display-error');
    assert.strictEqual(gone.name, 'NotFoundError', 'a missing window, through the channel');
    const s = native.openDisplayStream({ width: 320, frameRate: 10 });
    const started = await until(
      (e) => (e.type === 'display-started' || e.type === 'display-error') && e.id === s.id,
      'the display',
    );
    assert.strictEqual(started.type, 'display-started', JSON.stringify(started));
    assert.strictEqual(started.width, 320, 'at the width asked');
    native.displayStreamFrames(s.id, true);
    // the main display changes by itself only sometimes; a frame is asked for
    // where one comes, and the stream closes either way
    const f = await until((e) => e.type === 'display-frame' && e.id === s.id, 'a display frame', 3000).catch(
      () => null,
    );
    if (f) assert(Buffer.isBuffer(f.planes[0]) && f.format === 'BGRA', 'display planes cross as Buffers');
    native.closeDisplayStream(s.id);
  }
  native.closeDisplayStream(missing.id);
  say('ok');
}
