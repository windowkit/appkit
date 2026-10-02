'use strict';
// The notification response path (windowkit/appkit#26) without an app
// bundle: postNotificationResponse hands a response to node's loop exactly
// as the UNUserNotificationCenter delegate does, so the hand-off, the
// hold-and-replay and the event shape are the real ones while the centre is
// never touched.
//
// What runs here:
//
//   worker-first   a Worker loads the addon and posts a response before the
//                  main thread has required it at all. The event function
//                  the module makes has to be the main thread's
//                  environment's: made in the first loader's instead, every
//                  later response in pump mode crossed to the worker's
//                  thread, where CALEmit delivers nothing, and once that
//                  worker ended it was dropped for good — with the main
//                  thread's listener installed the whole time.
//   shapes         every bad argument a TypeError, before anything is queued
//   settings       the capability readback, and that the posting verbs throw
//                  naming the reason rather than dropping silently (a bare
//                  `node`; skipped in a bundle, where the centre is real)
//   responses      held while there is no listener, replayed in order at the
//                  first pump with one, then one event per response, with
//                  userInfo round-tripped through JSON
//
// Exits 0 when every expectation held.

const { Worker, isMainThread } = require('worker_threads');

// The worker half: first to the module on purpose. Nothing is asserted
// here — what matters is which environment's thread-safe function the
// module's load leaves behind.
if (!isMainThread) {
  const { native } = require('..');
  native.postNotificationResponse({ identifier: 'from-the-worker' });
  return;
}

const fail = (msg, ...rest) => {
  console.error('notifications:', msg, ...rest);
  process.exit(1);
};

// Yield to node's loop: a timer, then an immediate, so a hand-off from
// another thread has landed before the check (a busy pump2 loop never lets
// one through — the response arrives on the loop, not in the pump).
const tick = (ms = 20) => new Promise((r) => setTimeout(() => setImmediate(r), ms));

function pumpUntil(pred, what, ms = 3000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const t = setInterval(() => {
      native.pump2();
      if (pred()) { clearInterval(t); resolve(); }
      else if (Date.now() > deadline) { clearInterval(t); reject(new Error('timed out waiting for ' + what)); }
    }, 8);
  });
}

// The worker runs, and ends, before this thread has the addon loaded.
function workerFirst() {
  return new Promise((resolve, reject) => {
    const w = new Worker(__filename);
    w.on('error', reject);
    w.on('exit', (code) => (code === 0 ? resolve() : reject(new Error('the worker exited ' + code))));
  });
}

let native;

(async () => {
  // 1. the worker gets to the module first, and is gone again
  await workerFirst();
  native = require('..').native;

  // 2. the shapes. Each bad one is a TypeError thrown out of the call, and
  //    nothing is queued for it — checked against the listener below.
  const bad = [
    [undefined, 'no argument'],
    ['from-a-string', 'a string'],
    [{}, 'no identifier'],
    [{ identifier: '' }, 'an empty identifier'],
    [{ identifier: 7 }, 'a numeric identifier'],
    [{ identifier: 'a', actionId: 7 }, 'a numeric actionId'],
    [{ identifier: 'a', categoryId: {} }, 'an object categoryId'],
    [{ identifier: 'a', userText: 7 }, 'a numeric userText'],
    [{ identifier: 'a', dismissed: 'yes' }, 'a string dismissed'],
  ];
  for (const [arg, what] of bad) {
    let err;
    try { native.postNotificationResponse(arg); } catch (e) { err = e; }
    if (!(err instanceof TypeError)) fail(what + ' was not a TypeError', err);
    if (!err.message.startsWith('postNotificationResponse: ')) {
      fail(what + ' did not name the verb', err.message);
    }
  }

  // 3. the capability readback. In a bare node process there is no bundle
  //    identifier, so the centre is unreachable and says why; in a bundle
  //    (the scratch-bundle runs) the centre is real and the throwing half
  //    does not apply.
  const settings = await new Promise((r) => native.notificationSettings(r));
  if (typeof settings.available !== 'boolean') fail('settings.available', settings);
  if (settings.available) {
    if (typeof settings.bundleIdentifier !== 'string' || !settings.bundleIdentifier) {
      fail('an available centre with no bundle identifier', settings);
    }
    for (const k of ['authorizationStatus', 'alert', 'sound', 'badge',
                     'notificationCenter', 'lockScreen', 'criticalAlert',
                     'alertStyle', 'showPreviews']) {
      if (typeof settings[k] !== 'string') fail('settings.' + k, settings);
    }
  } else {
    if (settings.bundleIdentifier !== null) fail('an unavailable centre with a bundle identifier', settings);
    if (typeof settings.reason !== 'string' || !settings.reason) fail('settings.reason', settings);
    // every verb but the readback says so rather than dropping silently
    for (const call of [
      () => native.postNotification({ title: 'x' }, () => {}),
      () => native.removeNotification('x'),
      () => native.deliveredNotifications(() => {}),
    ]) {
      let err;
      try { call(); } catch (e) { err = e; }
      if (!(err instanceof Error)) fail('a verb answered without a centre', err);
      if (!err.message.includes('notifications are unavailable')) {
        fail('a verb did not name the state', err.message);
      }
    }
  }

  // 4. the responses. Two arrive with no listener and wait; the listener
  //    goes in; the first pump hands them over in arrival order.
  const seen = [];
  native.postNotificationResponse({ identifier: 'held-1', actionId: 'reply' });
  native.postNotificationResponse({ identifier: 'held-2', dismissed: true });
  await tick(50);
  native.pump2();
  if (seen.length) fail('a response was delivered with no listener', seen);
  native.setBackendEventCallback((ev) => {
    if (ev.type === 'notification-action' || ev.type === 'notification-dismissed') seen.push(ev);
  });
  native.pump2();
  if (seen.length !== 2) fail('the responses from before the listener should replay', seen);
  if (seen[0].identifier !== 'held-1' || seen[1].identifier !== 'held-2') {
    fail('the held responses replayed out of order', seen);
  }
  if (seen[0].type !== 'notification-action' || seen[0].actionId !== 'reply') fail('held-1', seen[0]);
  if (seen[1].type !== 'notification-dismissed' || seen[1].reason !== 'dismissed') fail('held-2', seen[1]);
  if (seen[0].categoryId !== null) fail('a response with no category should carry null', seen[0]);

  // the worker's own response is not among them: there was no function for
  // it to cross on, and nothing on this thread could have been listening
  if (seen.some((ev) => ev.identifier === 'from-the-worker')) {
    fail("the worker's response arrived after its environment was gone", seen);
  }

  // 5. one event per response with a listener installed, userInfo and
  //    userText carried through
  native.postNotificationResponse({
    identifier: 'live',
    actionId: 'answer',
    categoryId: 'chat',
    userInfo: { room: 'r1', unread: 3, tags: ['a', 'b'] },
    userText: 'on my way',
  });
  await pumpUntil(() => seen.length === 3, 'a response with a listener installed');
  const live = seen[2];
  if (live.type !== 'notification-action') fail('live type', live);
  if (live.identifier !== 'live' || live.actionId !== 'answer') fail('live identity', live);
  if (live.categoryId !== 'chat') fail('live categoryId', live);
  if (live.userText !== 'on my way') fail('live userText', live);
  if (JSON.stringify(live.userInfo) !== JSON.stringify({ room: 'r1', unread: 3, tags: ['a', 'b'] })) {
    fail('userInfo did not round-trip', live.userInfo);
  }
  // a body click is 'default', and that is what an absent actionId means
  native.postNotificationResponse({ identifier: 'body-click' });
  await pumpUntil(() => seen.length === 4, 'a body click');
  if (seen[3].actionId !== 'default') fail('an absent actionId should read as default', seen[3]);

  await tick(100);
  native.pump2();
  if (seen.length !== 4) fail('responses were duplicated', seen.length);
  native.setBackendEventCallback(null);

  console.log('notifications OK:', bad.length, 'bad shapes refused,', seen.length,
              'responses delivered after a worker loaded the module first (centre',
              settings.available ? 'available)' : 'unavailable)');
  process.exit(0);
})().catch((e) => fail(e.stack || e.message));
