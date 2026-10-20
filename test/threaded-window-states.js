'use strict';
// window-states.js from a worker: with the main thread parked in runMain,
// setWindowFullScreen runs on the UI thread, the transition comes back as
// window-fullscreen events naming the handle, and the published copy the
// worker reads says the target from the begin. Its own file because a trip
// through a full-screen Space leaves the app between Spaces for a while,
// which the pop-up menus later in threaded-verbs.js do not survive. Exits 0
// when every expectation held.

const assert = require('assert');
const fs = require('fs');
const { Worker, isMainThread } = require('worker_threads');
const { native } = require('..');

const say = (s) => fs.writeSync(2, `threaded-window-states: ${s}\n`);

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
  const until = (pred, what, ms = 6000) =>
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

  const win = native.createWindow2({ width: 300, height: 200, title: 'states from a worker', x: 120, y: 140 });
  native.showWindow(win, true);
  native.activateApp();
  await until((ev) => ev.type === 'window-occlusion' && ev.handle === win, 'shown');
  const before = native.getWindowFrame(win);
  assert.deepStrictEqual(
    [before.fullscreen, before.zoomed, before.miniaturized],
    [false, false, false],
    'the published window states',
  );

  native.setWindowMiniaturized(win, true);
  await until((ev) => ev.type === 'window-miniaturize' && ev.miniaturized && ev.handle === win, 'miniaturized');
  assert.strictEqual(native.getWindowFrame(win).miniaturized, true, 'published miniaturized');
  native.setWindowMiniaturized(win, false);
  await until((ev) => ev.type === 'window-miniaturize' && !ev.miniaturized && ev.handle === win, 'restored');
  assert.strictEqual(native.getWindowFrame(win).miniaturized, false, 'published restored');

  native.setWindowFullScreen(win, true);
  const entering = await until(
    (ev) => ev.type === 'window-fullscreen' && ev.phase === 'begin' && ev.handle === win,
    'window-fullscreen begin',
  );
  assert.strictEqual(entering.fullscreen, true, 'the begin says where it is going');
  assert.strictEqual(native.getWindowFrame(win).fullscreen, true, 'published from the begin');
  await until((ev) => ev.type === 'window-fullscreen' && ev.phase === 'end' && ev.fullscreen, 'entered');

  native.setWindowFullScreen(win, false);
  await until((ev) => ev.type === 'window-fullscreen' && ev.phase === 'end' && !ev.fullscreen, 'exited');
  assert.strictEqual(native.getWindowFrame(win).fullscreen, false, 'published after the exit');

  native.destroyWindow2(win);
  say('ok');
}
