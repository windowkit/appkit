'use strict';
// System audio from a worker (src/systemaudio.mm, threaded mode): with the
// main thread parked in runMain, the processes are listed both ways, a player
// starting is announced through the channel, and a process with no audio is
// refused by name through it — what CoreAudio reports from its own queues
// crossing as everything else does. No tap is opened: test/system-audio.js
// does that where the grant is there. Exits 0 when every expectation held.

const assert = require('assert');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Worker, isMainThread } = require('worker_threads');
const { native } = require('..');

const say = (s) => fs.writeSync(2, `system-audio-threaded: ${s}\n`);

if (isMainThread) {
  native.initApp();
  if (typeof native.openSystemAudio !== 'function') {
    say('skipped — process taps need macOS 14.2');
    process.exit(0);
  }
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

  const listed = await answer((cb) => native.audioProcesses(cb));
  assert(listed.some((p) => p.pid === process.pid), 'this process, through a callback');
  assert(native.audioProcesses().some((p) => p.pid === process.pid), 'and synchronously, from a worker');

  // a process that never touched CoreAudio has nothing to tap
  const sleeper = spawn('/bin/sleep', ['5'], { stdio: 'ignore' });
  const tap = native.openSystemAudio({ pid: sleeper.pid });
  const refused = await until((e) => e.type === 'system-audio-error' && e.id === tap.id, 'system-audio-error');
  assert.strictEqual(refused.name, 'NotFoundError', 'a process with no audio, through the channel');
  native.closeSystemAudio(tap.id);
  sleeper.kill();

  // a second of mono silence, so nothing is heard
  const file = path.join(os.tmpdir(), `appkit-silence-threaded-${process.pid}.wav`);
  const frames = 48000;
  const b = Buffer.alloc(44 + frames * 2);
  b.write('RIFF', 0);
  b.writeUInt32LE(36 + frames * 2, 4);
  b.write('WAVEfmt ', 8);
  b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20);
  b.writeUInt16LE(1, 22);
  b.writeUInt32LE(48000, 24);
  b.writeUInt32LE(96000, 28);
  b.writeUInt16LE(2, 32);
  b.writeUInt16LE(16, 34);
  b.write('data', 36);
  b.writeUInt32LE(frames * 2, 40);
  fs.writeFileSync(file, b);
  const player = spawn('/usr/bin/afplay', [file], { stdio: 'ignore' });
  await until((e) => e.type === 'audio-processes', 'audio-processes');
  await new Promise((resolve) => player.on('exit', resolve));
  fs.unlinkSync(file);
  say('ok');
}
