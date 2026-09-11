'use strict';
// Threaded mode's core (windowkit/appkit#50): the process main thread parked
// in [NSApp run] by runMain(), the renderer's JS on a Worker, commands in
// through the main run loop's common modes, events out in batches. Exits 0
// when every expectation held.
//
// Checked from the worker, against what the main thread saw before it
// handed itself to AppKit:
//   - input posted before anyone connected is dispatched by [NSApp run]
//     through the event monitor and waits for the connection, in order, its
//     twenty moves folded (consecutive ones only: the window's first
//     occlusion change lands after the first move, so they cross as two);
//   - the published state answers what a pump-mode renderer reads live
//     (windowState, listScreens, accessibilityDisplayOptions,
//     pasteboardChangeCount, activationPolicy), with the main thread's values;
//   - a command's round trip (pingUI -> ui-pong) and a microtask queued
//     inside a delivery;
//   - what arrives while the worker is busy comes as one batch;
//   - commands apply inside a menu's tracking and inside runModal, the
//     worker's own 5 ms timer keeps firing through both, and a command
//     queued behind the one that starts the loop does not wait for its end;
//   - a producer on the main queue (the accessibility observer, its
//     notification posted by a command, since AppKit's own observer of it
//     rebuilds the menu bar) reaches the worker; a SIGHUP arrives as an
//     event and the process lives on;
//   - requestExit ends the run with its code.
// And in child processes, the ways a run ends without requestExit: the
// connected worker returning with nothing on screen, calling process.exit,
// throwing (runMain -> null each time); a SIGTERM with nobody connected
// (runMain -> 143).

const assert = require('assert');
const { spawnSync } = require('child_process');
const fs = require('fs');
const { Worker, isMainThread, workerData } = require('worker_threads');
const { native } = require('..');

// A worker's console writes go through the main thread's event loop, which
// is parked in [NSApp run]; write straight to the descriptor instead.
const say = (s) => fs.writeSync(2, `threaded: ${s}\n`);
const mode = (isMainThread ? process.argv[2] : workerData.mode) || 'full';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// CI runners are shared VMs; the acceptance numbers are for a quiet machine
const slack = process.env.CI ? 5 : 1;

if (isMainThread) main();
else worker();

// --- the process main thread ------------------------------------------------

function main() {
  if (native.threaded()) fail('threaded() before runMain');
  if (mode === 'full') runChildren();
  native.initApp();
  const expect = { mode };
  if (mode === 'full' || mode === 'exit' || mode === 'throw') {
    const win = native.createWindow2({ width: 240, height: 160, title: 'threaded', x: 80, y: 120 });
    native.showWindow(win, false);
    native.pump2(); // one dequeue first: an event posted before the app's first is dropped
    if (mode === 'full') {
      // pump mode, before the switch: a command on the main thread runs inline
      const got = [];
      native.setBackendEventCallback((ev) => got.push(ev));
      native.pingUI(7);
      native.setBackendEventCallback(null);
      if (got.length !== 1 || got[0].type !== 'ui-pong' || got[0].tag !== 7 || got[0].drained !== false) {
        fail('pingUI in pump mode did not answer inline', got);
      }
      Object.assign(expect, {
        windowNumber: native.windowNumber(win),
        frame: native.getWindowFrame(win),
        screens: native.listScreens(),
        a11y: native.accessibilityDisplayOptions(),
        pasteboard: native.pasteboardChangeCount(),
        policy: native.appInfo().activationPolicy,
      });
      for (let i = 0; i < 20; i++) native.postMouseEvent(win, 'move', 10 + i, 20);
      native.postMouseEvent(win, 'down', 40, 30);
      native.postMouseEvent(win, 'up', 40, 30);
    }
  }
  const w = new Worker(__filename, { workerData: expect });
  w.on('error', () => {}); // the 'throw' child's; runMain's answer is what is checked
  const code = native.runMain();
  if (native.threaded()) fail('threaded() still true after runMain returned');
  const want = { full: 0, idle: null, exit: null, throw: null, signal: 143 }[mode];
  if (code !== want) fail(`${mode}: runMain returned ${code}, expected ${want}`);
  if (mode !== 'full') say(`${mode}: runMain returned ${code}`);
  process.exit(0);
}

function runChildren() {
  for (const m of ['idle', 'exit', 'throw', 'signal']) {
    const r = spawnSync(process.execPath, [__filename, m], { encoding: 'utf8', timeout: 20000 });
    process.stderr.write(r.stderr || '');
    if (r.status !== 0) fail(`child '${m}' ended with status ${r.status}, signal ${r.signal}`);
  }
}

function fail(msg, ...rest) {
  say(`FAIL ${msg}${rest.length ? ' ' + JSON.stringify(rest) : ''}`);
  process.exit(1);
}

// --- the renderer's thread --------------------------------------------------

function worker() {
  if (mode === 'idle') {
    // nothing on screen: the channel lets the loop go, the worker ends
    native.connect(() => {});
  } else if (mode === 'exit') {
    native.connect(() => {});
    setTimeout(() => process.exit(3), 50);
  } else if (mode === 'throw') {
    native.connect(() => {});
    setTimeout(() => {
      throw new Error('thrown on purpose');
    }, 50);
  } else if (mode === 'signal') {
    // never connects: nobody to hand the signal to
    setTimeout(() => process.kill(process.pid, 'SIGTERM'), 50);
  } else {
    full().then(
      () => native.requestExit(0),
      (e) => {
        say(`FAIL ${e && e.stack ? e.stack : e}`);
        native.requestExit(1);
      },
    );
  }
}

async function full() {
  const expect = workerData;
  const events = []; // { ev, at }
  const batches = [];
  const micro = [];
  let waiters = [];
  native.connect((batch) => {
    const at = performance.now();
    batches.push(batch);
    queueMicrotask(() => micro.push(performance.now() - at));
    for (const ev of batch) events.push({ ev, at });
    waiters = waiters.filter((check) => !check());
  });
  const until = (pred, what, ms = 5000) =>
    new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
      const check = () => {
        if (!pred()) return false;
        clearTimeout(timer);
        resolve();
        return true;
      };
      if (!check()) waiters.push(check);
    });
  const find = (pred) => events.find(({ ev }) => pred(ev));
  const pong = (tag) => find((ev) => ev.type === 'ui-pong' && ev.tag === tag);
  const indexOf = (pred) => events.findIndex(({ ev }) => pred(ev));
  const q = (xs, p) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(p * xs.length))];
  const ms = (x) => x.toFixed(2);

  // 1. the switch
  for (let t = Date.now(); !native.threaded() && Date.now() - t < 2000; ) await sleep(5);
  assert(native.threaded(), 'threaded() never turned true');

  // 2. input from before the connection, in order, the moves folded
  await until(() => find((ev) => ev.type === 'mouseup'), 'the input posted before runMain');
  const mouse = events.map(({ ev }) => ev).filter((ev) => ['mousemove', 'mousedown', 'mouseup'].includes(ev.type));
  const moves = mouse.filter((ev) => ev.type === 'mousemove');
  const runs = mouse.map((ev) => ev.type).filter((t, i, a) => t !== a[i - 1]);
  assert.deepStrictEqual(runs, ['mousemove', 'mousedown', 'mouseup'], 'input order');
  assert(moves.length < 20, `20 moves crossed as ${moves.length}: nothing folded`);
  assert.strictEqual(moves[moves.length - 1].x, 29, 'the folded move is not the latest');
  assert(mouse.every((ev) => ev.windowNumber === expect.windowNumber), 'input for another window');
  say(`20 moves queued before connect crossed as ${moves.length}`);

  // 3. published state, read without a hop
  const st = native.windowState(expect.windowNumber);
  assert(st, 'windowState: no state for the window');
  for (const k of ['x', 'y', 'width', 'height', 'scale']) {
    assert.strictEqual(st[k], expect.frame[k], `windowState.${k}`);
  }
  for (const k of ['visible', 'occluded', 'key', 'ignoresMouseEvents']) assert.strictEqual(typeof st[k], 'boolean', k);
  assert.strictEqual(native.windowState(0x7fffffff), null, 'windowState of no window');
  assert.deepStrictEqual(native.listScreens(), expect.screens, 'listScreens from the published copy');
  assert.deepStrictEqual(native.accessibilityDisplayOptions(), expect.a11y, 'accessibilityDisplayOptions from the copy');
  assert.strictEqual(native.pasteboardChangeCount(), expect.pasteboard, 'pasteboardChangeCount from the copy');
  assert.strictEqual(native.activationPolicy(), expect.policy, 'activationPolicy');

  // 4. a command's round trip, and a microtask inside a delivery
  const rtt = [];
  for (let i = 0; i < 60; i++) {
    const tag = 1000 + i;
    const t0 = performance.now();
    native.pingUI(tag);
    await until(() => pong(tag), `pong ${tag}`);
    const { ev, at } = pong(tag);
    rtt.push(at - t0);
    assert.strictEqual(ev.mode, 'kCFRunLoopDefaultMode', 'idle pong mode');
    assert.strictEqual(ev.drained, true, 'a worker command came inline');
    await sleep(3);
  }
  say(`round trip, command + event: p50 ${ms(q(rtt, 0.5))} ms, p95 ${ms(q(rtt, 0.95))} ms`);
  assert(q(rtt, 0.95) < 2 * slack, `round trip p95 ${ms(q(rtt, 0.95))} ms`);
  say(`microtask queued inside a delivery ran after ${ms(q(micro, 0.5))} ms p50`);
  assert(q(micro, 0.5) < 1 * slack, 'microtasks inside a delivery wait');

  // 5. a busy worker gets what it missed as one batch
  const before = batches.length;
  for (let i = 0; i < 10; i++) native.pingUI(2000 + i);
  for (const t = performance.now(); performance.now() - t < 60; );
  await until(() => pong(2009), 'the pongs of a busy worker');
  const busyTags = (b) => b.filter((ev) => ev.type === 'ui-pong' && ev.tag >= 2000 && ev.tag < 2010).length;
  const busyBatch = batches.slice(before).find((b) => busyTags(b) > 0);
  assert.strictEqual(busyTags(busyBatch), 10, 'the pongs came in more than one batch');

  // 6. the nested loops that freeze pump mode
  let nextTag = 5000;
  for (const [kind, runLoopMode] of [
    ['menu', 'NSEventTrackingRunLoopMode'],
    ['modal', 'NSModalPanelRunLoopMode'],
  ]) {
    const began = events.length;
    const ofRun = (type) => events.slice(began).find(({ ev }) => ev.type === type && ev.kind === kind);
    native.postModalLoop(kind, 700);
    const behind = nextTag++;
    native.pingUI(behind); // queued behind the command that starts the loop
    await until(() => ofRun('modal-loop-begin'), `${kind} to begin`);
    let last = performance.now();
    const gaps = [];
    const timer = setInterval(() => {
      const t = performance.now();
      gaps.push(t - last);
      last = t;
    }, 5);
    const tags = [];
    const pinger = setInterval(() => {
      const tag = nextTag++;
      tags.push(tag);
      native.pingUI(tag);
    }, 10);
    await until(() => ofRun('modal-loop-end'), `${kind} to end`);
    clearInterval(pinger);
    clearInterval(timer);
    await until(() => tags.every((t) => pong(t)), `the pongs sent during the ${kind}`);
    const inside = tags.filter((t) => pong(t).ev.mode === runLoopMode).length;
    const worst = Math.max(...gaps);
    say(`${kind}: ${inside} of ${tags.length} commands applied in ${runLoopMode}; the worker's 5 ms timer's worst gap ${ms(worst)} ms`);
    assert(inside >= 10, `${kind}: only ${inside} commands applied inside the loop`);
    assert(worst < 20 * slack, `${kind}: the worker's timer stalled for ${ms(worst)} ms`);
    const endAt = indexOf((ev) => ev.type === 'modal-loop-end' && ev.kind === kind);
    assert(indexOf((ev) => ev.type === 'ui-pong' && ev.tag === behind) < endAt, `${kind}: a queued command waited for the loop to end`);
  }

  // 7. a producer on the main queue: the accessibility observer
  native.postAccessibilityDisplayChange();
  await until(() => find((ev) => ev.type === 'accessibility-display-changed'), 'accessibility-display-changed');
  const { type, ...a11y } = find((ev) => ev.type === 'accessibility-display-changed').ev;
  assert.deepStrictEqual(a11y, expect.a11y, 'accessibility-display-changed fields');

  // 8. a signal is an event, and the process lives on
  process.kill(process.pid, 'SIGHUP');
  await until(() => find((ev) => ev.type === 'signal'), 'the SIGHUP event');
  assert.strictEqual(find((ev) => ev.type === 'signal').ev.signal, 'SIGHUP');
  native.pingUI(9999);
  await until(() => pong(9999), 'a pong after the signal');

  say(`ok: ${events.length} events in ${batches.length} batches`);
}
