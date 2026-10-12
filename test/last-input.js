'use strict';
// lastInputMs (react-x11#951's bridge follow-up): the session's idle time,
// read the way a screen saver reads it. A test cannot make or withhold the
// user's input, so what is checked is what holds whatever they do. Exits 0
// when every expectation held.
//
// Checked: before initApp it answers a finite, non-negative number; between
// two reads it either grew by the time between them or was reset by input
// since; it is never longer than IOHIDSystem's HIDIdleTime read just before,
// since any hardware input resets both; and from a worker, with the main
// thread parked in runMain, it answers synchronously on the worker's thread.

const { execFileSync } = require('child_process');
const fs = require('fs');
const { Worker, isMainThread } = require('worker_threads');
const { native } = require('..');

const say = (s) => fs.writeSync(2, `last-input: ${s}\n`);
const fail = (msg) => {
  say(`FAIL ${msg}`);
  process.exit(1);
};
const TOL = 50;

const isIdleTime = (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0;

const blockFor = (ms) => {
  const until = Date.now() + ms;
  while (Date.now() < until);
};

function hidIdleMs() {
  const out = execFileSync('/usr/sbin/ioreg', ['-c', 'IOHIDSystem', '-r', '-d', '1', '-k', 'HIDIdleTime'], {
    encoding: 'utf8',
  });
  const m = /"HIDIdleTime"\s*=\s*(\d+)/.exec(out);
  return m ? Number(m[1]) / 1e6 : null;
}

if (isMainThread) {
  // 1. before initApp, synchronously
  const first = native.lastInputMs();
  if (!isIdleTime(first)) fail(`lastInputMs() before initApp: ${first}`);

  // 2. a clock: it grew by the time between the reads, or input reset it
  const t0 = Date.now();
  const a = native.lastInputMs();
  blockFor(300);
  const b = native.lastInputMs();
  const elapsed = Date.now() - t0;
  const grew = Math.abs(b - a - elapsed) <= TOL;
  const reset = b <= elapsed + TOL;
  if (!grew && !reset) fail(`two reads ${elapsed} ms apart: ${a} then ${b}`);

  // 3. never longer than the HID idle time read before it
  const h0 = Date.now();
  const hid = hidIdleMs();
  const c = native.lastInputMs();
  if (hid == null) say('no HIDIdleTime from ioreg; skipped the comparison');
  else if (c > hid + (Date.now() - h0) + TOL) fail(`lastInputMs ${c} > HIDIdleTime ${hid}`);

  // 4. from a worker, the main thread parked
  native.initApp();
  new Worker(__filename).on('error', (e) => fail(e && e.stack ? e.stack : e));
  const code = native.runMain();
  if (code !== 0) fail(`runMain returned ${code}`);
  say('ok');
  process.exit(0);
} else {
  native.connect(() => {});
  const v = native.lastInputMs();
  if (!isIdleTime(v)) {
    say(`FAIL lastInputMs() from a worker: ${v}`);
    native.requestExit(1);
  } else {
    native.requestExit(0);
  }
}
