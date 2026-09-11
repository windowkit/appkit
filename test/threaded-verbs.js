'use strict';
// The AppKit verbs from a worker (windowkit/appkit#51): with the main thread
// parked in runMain, the renderer's thread calls the same verbs it calls in
// pump mode, and each takes the shape #51 gives it — a handle answered at
// the call and bound when the UI thread makes the object, a command for
// what returns nothing, the published copy for what reads state back, a
// callback for what has to ask AppKit. Exits 0 when every expectation held.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Worker, isMainThread } = require('worker_threads');
const { native } = require('..');

// a worker's console goes through the parked main thread's loop
const say = (s) => fs.writeSync(2, `threaded-verbs: ${s}\n`);
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

  // --- windows ----------------------------------------------------------------

  // a handle at the call; the window follows, announced with the same handle
  const win = native.createWindow2({ width: 260, height: 180, title: 'from a worker', x: 90, y: 110 });
  assert.strictEqual(typeof win, 'object', 'createWindow2 answers a handle at the call');
  assert.strictEqual(native.windowNumber(win), null, 'windowNumber before the window is made');
  assert.strictEqual(native.getWindowFrame(win), null, 'getWindowFrame before the window is made');
  const created = await until((ev) => ev.type === 'window-created', 'window-created');
  assert.strictEqual(created.handle, win, 'window-created names the handle JS holds');
  assert(created.windowNumber > 0, 'window-created carries the number');
  assert.strictEqual(native.windowNumber(win), created.windowNumber, 'windowNumber once made');

  const frame = native.getWindowFrame(win);
  assert.deepStrictEqual([frame.x, frame.y, frame.width, frame.height], [90, 110, 260, 180], 'the published frame');
  assert.strictEqual(native.windowIsVisible(win), false, 'not yet shown');
  assert(native.windowRootLayer(win), 'windowRootLayer answers the layer handle');

  native.showWindow(win, false);
  await until((ev) => ev.type === 'window-occlusion' && ev.handle === win, 'an occlusion event naming the handle');
  for (let t = Date.now(); !native.windowIsVisible(win) && Date.now() - t < 2000; ) await sleep(10);
  assert.strictEqual(native.windowIsVisible(win), true, 'visible after showWindow');

  // commands apply in order; the resize comes back as an event naming the handle
  native.setWindowTitle(win, 'renamed');
  native.setWindowMinMax(win, { minWidth: 100, minHeight: 80 });
  native.setWindowFrame(win, 120, 130, 300, 200);
  const resized = await until((ev) => ev.type === 'window-resize' && ev.handle === win, 'window-resize');
  assert.deepStrictEqual([resized.width, resized.height], [300, 200], 'the new size');
  const moved = native.getWindowFrame(win);
  assert.deepStrictEqual([moved.x, moved.y, moved.width, moved.height], [120, 130, 300, 200], 'the published frame follows');

  // input posted into the window carries the handle too
  native.postMouseEvent(win, 'down', 20, 20);
  native.postMouseEvent(win, 'up', 20, 20);
  const up = await until((ev) => ev.type === 'mouseup', 'the posted click');
  assert.strictEqual(up.handle, win, 'input events name the handle');

  // reads that ask AppKit answer through a callback
  const shot = path.join(os.tmpdir(), `appkit-threaded-verbs-${process.pid}.png`);
  const ok = await answer((cb) => native.snapshotWindow(win, shot, cb));
  assert.strictEqual(ok, true, 'snapshotWindow through a callback');
  assert(fs.statSync(shot).size > 0, 'the snapshot was written');
  fs.unlinkSync(shot);
  const hit = await answer((cb) => native.windowNumberAtPoint(moved.x + 10, moved.y + 10, cb));
  assert.strictEqual(typeof hit, 'number', 'windowNumberAtPoint through a callback');
  assert.throws(() => native.windowNumberAtPoint(1, 1), TypeError, 'a read off the main thread without a callback');
  assert.throws(() => native.createWindow(100, 100), /pump mode/, 'the first-generation API is pump mode only');

  native.destroyWindow2(win);
  native.destroyWindow2(win); // counted once
  for (let t = Date.now(); native.windowIsVisible(win) !== null && Date.now() - t < 2000; ) await sleep(10);
  assert.strictEqual(native.getWindowFrame(win), null, 'the published copy is gone with the window');
  say('windows: ok');

  // --- menus, the Dock, the app ---------------------------------------------

  const count = (type) => events.filter((ev) => ev.type === type).length;
  native.setMainMenu([
    { title: 'App', items: [{ title: 'About', id: 1 }] },
    { title: 'File', items: [{ title: 'Open…', id: 21, key: 'o' }, { separator: true }, { title: 'Close', id: 22 }] },
  ]);
  const bar = await answer((cb) => native.mainMenuInfo(cb));
  assert.deepStrictEqual(bar.items.map((m) => m.title), ['App', 'File'], 'mainMenuInfo through a callback');
  assert.deepStrictEqual(bar.items[1].submenu.items.map((i) => i.id), [21, 0, 22], 'the File menu');
  const menuActivations = count('menu-activate');
  assert.strictEqual(await answer((cb) => native.activateMenuItem([1, 2], cb)), true, 'activateMenuItem');
  const activated = await until((ev) => ev.type === 'menu-activate' && count('menu-activate') > menuActivations, 'menu-activate');
  assert.deepStrictEqual([activated.id, activated.menu], [22, 'main'], 'the main menu activation');

  native.setDockMenu([{ title: 'New window', id: 7 }]);
  const dock = await answer((cb) => native.dockMenuInfo(cb));
  assert.deepStrictEqual(dock.items.map((i) => i.title), ['New window'], 'dockMenuInfo');
  assert.strictEqual(await answer((cb) => native.activateDockMenuItem([0], cb)), true, 'activateDockMenuItem');
  await until((ev) => ev.type === 'menu-activate' && ev.menu === 'dock' && ev.id === 7, 'the Dock activation');
  native.setDockMenu(null);
  assert.strictEqual(await answer((cb) => native.dockMenuInfo(cb)), null, 'the Dock menu cleared');

  native.setDockBadge(7);
  for (let t = Date.now(); native.appInfo().dockBadge !== '7' && Date.now() - t < 2000; ) await sleep(10);
  assert.strictEqual(native.appInfo().dockBadge, '7', 'appInfo from the published copy follows setDockBadge');
  native.setDockBadge(null);
  assert.strictEqual(native.appInfo().activationPolicy, native.activationPolicy(), 'appInfo.activationPolicy');
  const attention = native.requestUserAttention('informational');
  assert(attention >= 2 ** 40, 'a worker gets a bridge id for the request');
  native.cancelUserAttention(attention);
  native.setCursor('text');
  native.setCursor('arrow');
  say('menus, Dock, app: ok');

  // --- the pasteboard ---------------------------------------------------------

  const saved = await answer((cb) => native.pasteboardReadText(cb));
  const before = native.pasteboardChangeCount();
  const text = `threaded-verbs ${process.pid}`;
  native.pasteboardWriteText(text);
  assert.strictEqual(await answer((cb) => native.pasteboardReadText(cb)), text, 'written, then read back through a callback');
  assert(native.pasteboardChangeCount() > before, 'the published change count follows a write');
  if (saved === null) native.pasteboardClear();
  else native.pasteboardWriteText(saved);
  say('pasteboard: ok');

  // --- a status item ------------------------------------------------------------

  const item = native.createStatusItem({ title: 'T', tooltip: 'from a worker' });
  assert.strictEqual(typeof item, 'object', 'createStatusItem answers a handle at the call');
  let si = await answer((cb) => native.statusItemInfo(item, cb));
  assert.deepStrictEqual([si.title, si.tooltip, si.menu], ['T', 'from a worker', null], 'statusItemInfo');
  native.setStatusItem(item, { title: 'U' });
  si = await answer((cb) => native.statusItemInfo(item, cb));
  assert.strictEqual(si.title, 'U', 'setStatusItem');
  const clicks = count('status-item-click');
  assert.strictEqual(await answer((cb) => native.clickStatusItem(item, 'left', cb)), true, 'clickStatusItem');
  const click = await until((ev) => ev.type === 'status-item-click' && count('status-item-click') > clicks, 'status-item-click');
  assert.strictEqual(click.statusItem, item, 'the click names the handle JS holds');
  native.setStatusItemMenu(item, [{ title: 'Quit', id: 9 }]);
  si = await answer((cb) => native.statusItemInfo(item, cb));
  assert.deepStrictEqual(si.menu.items.map((i) => i.title), ['Quit'], 'the status menu');
  assert.strictEqual(await answer((cb) => native.activateStatusItemMenuItem(item, [0], cb)), true, 'activateStatusItemMenuItem');
  await until((ev) => ev.type === 'menu-activate' && ev.menu === 'status' && ev.id === 9, 'the status menu activation');
  native.removeStatusItem(item);
  native.removeStatusItem(item); // once
  assert.strictEqual(await answer((cb) => native.statusItemInfo(item, cb)), null, 'gone after removeStatusItem');
  say('status item: ok');

  // --- panels -----------------------------------------------------------------

  const w2 = native.createWindow2({ width: 320, height: 240, title: 'drops', x: 140, y: 160 });
  await until((ev) => ev.type === 'window-created' && ev.handle === w2, 'the second window');
  native.showWindow(w2, false);
  const cancelled = (open, spec) =>
    new Promise((resolve, reject) => {
      const kind = spec.window ? 'sheet' : 'app-modal panel';
      const timer = setTimeout(() => reject(new Error(`the ${kind} never answered`)), 5000);
      const done = (v) => {
        clearTimeout(timer);
        resolve(v);
      };
      const panel = open ? native.openPanel(spec, done) : native.savePanel(spec, done);
      assert.strictEqual(typeof panel, 'object', 'a panel handle at the call');
      setTimeout(() => native.cancelPanel(panel), 300);
    });
  assert.strictEqual(await cancelled(false, { window: w2, nameFieldStringValue: 'x.txt' }), null, 'a sheet cancelled from the worker');
  // pump mode cannot reach an app-modal panel (runModal holds the thread
  // that would call cancelPanel); a worker's command drains inside it
  assert.strictEqual(await cancelled(true, { title: 'threaded-verbs' }), null, 'an app-modal panel cancelled from the worker');
  say('panels: ok');

  // --- drag and drop, test posts -------------------------------------------------

  const T = 'public.utf8-plain-text';
  native.registerDropTypes(w2, [T]);
  const drag = (phase, opts) => answer((cb) => native.postDragEvent(w2, phase, opts, cb));
  assert.strictEqual(await drag('enter', { x: 30, y: 30, items: [{ [T]: 'dropped text' }] }), 'none', 'refused until the renderer answers');
  const enter = await until((ev) => ev.type === 'drag-enter' && ev.handle === w2, 'drag-enter');
  assert(enter.types.includes(T), 'drag-enter carries the types');
  native.setDropResponse(w2, { accept: true });
  assert.strictEqual(await drag('over', { x: 40, y: 40 }), 'copy', 'the standing answer set from the worker');
  assert.strictEqual(await drag('drop', { x: 40, y: 40 }), true, 'the drop is taken');
  const perform = await until((ev) => ev.type === 'drag-perform' && ev.handle === w2, 'drag-perform');
  assert.strictEqual(perform.items.length, 1, 'the drop carries its items');
  assert.strictEqual(perform.items[0].strings[T], 'dropped text', 'and their text, read in');
  assert.strictEqual(await answer((cb) => native.dragItemString(0, T, cb)), 'dropped text', 'dragItemString through a callback');

  const endedBefore = count('drag-session-ended');
  assert.strictEqual(native.beginDrag(w2, { items: [{ 'dyn.appkit-threaded-verbs': 'x' }] }), undefined, 'beginDrag answers through events');
  const ended = await until((ev) => ev.type === 'drag-session-ended' && count('drag-session-ended') > endedBefore, 'no press: a session that ended');
  assert.strictEqual(ended.dropped, false, 'with nothing dropped');
  assert.throws(() => native.beginDrag(w2, { items: [{ [T]: null }], provide: () => 'x' }), TypeError, '`provide` from a worker');

  native.postAppleEvent('open-url', 'appkit-test://from-a-worker');
  const opened = await until((ev) => ev.type === 'app-open-urls', 'app-open-urls');
  assert.deepStrictEqual(opened.urls, ['appkit-test://from-a-worker'], 'postAppleEvent as a command');
  assert.throws(() => native.pump2(), /main thread/, 'pump2 is the main thread\'s');
  native.destroyWindow2(w2);
  say('drag and drop, posts: ok');
}
