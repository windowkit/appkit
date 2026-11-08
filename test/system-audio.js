'use strict';
// System audio (src/systemaudio.mm), pump mode: CoreAudio's processes listed
// both ways with their applications, a player starting and ending announced,
// a process with no audio refused by name before anything is asked of the
// user, the permission read without a prompt, and the options' shapes.
//
// A tap is opened only where System Audio Recording is allowed already, and
// said to be skipped where it is not: a test never raises a privacy prompt.
// The player is afplay with a file of silence, so nothing is heard.
//
// Exits 0 when every expectation held.

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('system-audio:', msg, ...rest);
  process.exit(1);
};
const skipped = [];

function pumpUntil(pred, ms = 5000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const tick = setInterval(() => {
      native.pump2();
      if (pred()) {
        clearInterval(tick);
        resolve();
      } else if (Date.now() > deadline) {
        clearInterval(tick);
        reject(new Error('timed out'));
      }
    }, 8);
  });
}
const answer = (fn) => new Promise((resolve) => fn(resolve));

/** `seconds` of 16-bit stereo silence at 48 kHz, as a WAV file. */
function silence(seconds) {
  const frames = Math.round(48000 * seconds);
  const data = frames * 4;
  const b = Buffer.alloc(44 + data);
  b.write('RIFF', 0);
  b.writeUInt32LE(36 + data, 4);
  b.write('WAVEfmt ', 8);
  b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20);
  b.writeUInt16LE(2, 22);
  b.writeUInt32LE(48000, 24);
  b.writeUInt32LE(48000 * 4, 28);
  b.writeUInt16LE(4, 32);
  b.writeUInt16LE(16, 34);
  b.write('data', 36);
  b.writeUInt32LE(data, 40);
  const file = path.join(os.tmpdir(), `appkit-silence-${process.pid}.wav`);
  fs.writeFileSync(file, b);
  return file;
}

(async () => {
  native.initApp();
  if (typeof native.openSystemAudio !== 'function') {
    console.log('system-audio: skipped — process taps need macOS 14.2, and the verbs are not exported before it');
    process.exit(0);
  }
  const events = [];
  native.setBackendEventCallback((ev) => events.push(ev));
  const of = (type, id) => events.filter((e) => e.type === type && (id === undefined || e.id === id));

  // --- the processes ------------------------------------------------------------------
  const list = native.audioProcesses();
  if (!Array.isArray(list)) fail('audioProcesses answered', list);
  for (const p of list) {
    if (!(Number.isInteger(p.pid) && p.pid > 0)) fail('a process with no pid', p);
    if (typeof p.bundleId !== 'string' || typeof p.name !== 'string' || typeof p.playing !== 'boolean') {
      fail('a process half described', p);
    }
    if (p.app && (typeof p.app.bundleId !== 'string' || !p.app.bundleId || typeof p.app.regular !== 'boolean')) {
      fail('an application half described', p);
    }
  }
  // asking CoreAudio anything connects this process to it
  if (!list.some((p) => p.pid === process.pid)) fail('this process is not listed, and the listing connected it');
  const later = await answer((cb) => native.audioProcesses(cb));
  if (!Array.isArray(later) || !later.some((p) => p.pid === process.pid)) fail('audioProcesses(cb) answered', later);

  const status = native.authorizationStatus('system-audio-recording');
  if (!['authorized', 'denied', 'notDetermined', 'unknown'].includes(status)) fail('the status is', status);

  // --- a player comes and goes ----------------------------------------------------------
  const file = silence(1.5);
  const player = spawn('/usr/bin/afplay', [file], { stdio: 'ignore' });
  const exited = new Promise((resolve) => player.on('exit', resolve));
  let playing = null;
  await pumpUntil(() => {
    playing = native.audioProcesses().find((p) => p.pid === player.pid) ?? null;
    return playing?.playing === true;
  }).catch(() => fail('afplay never showed as playing', playing));
  if (playing.app) fail('afplay is in no application bundle, and', playing.app);
  await pumpUntil(() => of('audio-processes').length > 0).catch(() => fail('a player started, unannounced'));

  // --- what is not there is refused by name, and nothing prompts ----------------------
  for (const bad of ['nope', { pid: 'x' }, { pid: 0 }, { pid: 1.5 }, { pid: player.pid, bundleId: 'a.b' }]) {
    try {
      native.openSystemAudio(bad);
      fail('openSystemAudio took', bad);
    } catch (e) {
      if (!(e instanceof TypeError)) throw e;
    }
  }
  const quiet = spawn('/bin/sleep', ['5'], { stdio: 'ignore' });
  const none = native.openSystemAudio({ pid: quiet.pid, sampleRate: 16000, channels: 1 });
  if (typeof none.id !== 'number' || none.sampleRate !== 16000 || none.channels !== 1) fail('openSystemAudio answered', none);
  await pumpUntil(() => of('system-audio-error', none.id).length > 0).catch(() =>
    fail('a process with no audio said nothing'),
  );
  if (of('system-audio-error', none.id)[0].name !== 'NotFoundError') {
    fail('a process with no audio is', of('system-audio-error', none.id)[0]);
  }
  native.closeSystemAudio(none.id);
  quiet.kill();

  // --- a tap, where this process may have one -----------------------------------------
  if (status === 'authorized') {
    const all = native.openSystemAudio({ sampleRate: 16000, channels: 1 });
    await pumpUntil(() => of('system-audio-started', all.id).length || of('system-audio-error', all.id).length, 8000).catch(
      () => fail('the tap never started'),
    );
    if (of('system-audio-error', all.id).length) fail('the tap failed', of('system-audio-error', all.id)[0]);
    await pumpUntil(() => of('audio-input', all.id).length >= 5).catch(() => fail('no audio-input from the tap'));
    const chunk = of('audio-input', all.id)[0];
    if (chunk.sampleRate !== 16000 || chunk.frames !== 160 || chunk.channels.length !== 1) fail('a chunk', chunk);
    if (!(chunk.channels[0] instanceof Float32Array) || chunk.channels[0].length !== 160) fail('a channel', chunk);
    native.closeSystemAudio(all.id);
    const one = native.openSystemAudio({ pid: player.pid, sampleRate: 48000, channels: 2 });
    await pumpUntil(() => of('system-audio-started', one.id).length || of('system-audio-error', one.id).length, 8000).catch(
      () => fail("afplay's tap never started"),
    );
    await pumpUntil(() => of('audio-input', one.id).length >= 3).catch(() => fail("no audio-input from afplay's tap"));
    if (of('audio-input', one.id)[0].channels.length !== 2) fail('a stereo chunk', of('audio-input', one.id)[0]);
    await exited;
    await pumpUntil(() => of('system-audio-ended', one.id).length > 0).catch(() => fail('afplay ended, its tap did not'));
    native.closeSystemAudio(one.id);
  } else if (status === 'denied') {
    const no = native.openSystemAudio({});
    await pumpUntil(() => of('system-audio-error', no.id).length > 0).catch(() => fail('a refused tap said nothing'));
    if (of('system-audio-error', no.id)[0].name !== 'NotAllowedError') fail('a refused tap is', of('system-audio-error', no.id)[0]);
    native.closeSystemAudio(no.id);
    skipped.push('a tap: System Audio Recording is denied for this process; only the refusal was checked');
  } else {
    skipped.push(`a tap: System Audio Recording is ${status} for this process (no prompt is raised)`);
  }

  // --- and the player gone, said ------------------------------------------------------
  await exited;
  const before = of('audio-processes').length;
  await pumpUntil(() => !native.audioProcesses().some((p) => p.pid === player.pid && p.playing)).catch(() =>
    fail('afplay still plays, gone'),
  );
  await pumpUntil(() => of('audio-processes').length > before).catch(() => fail('a player ended, unannounced'));
  fs.unlinkSync(file);

  for (const s of skipped) console.log(`system-audio: skipped — ${s}`);
  console.log('system-audio: ok');
  process.exit(0);
})().catch((e) => fail(e?.stack ?? e));
