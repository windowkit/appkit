'use strict';
// The app delegate's three events, driven by real Apple Events sent to this
// process by itself (native.postAppleEvent), so what is exercised is the
// path Launch Services uses: event queue -> NSAppleEventManager -> the app
// delegate -> a backend event. Exits 0 when every expectation held.
//
// Checked: an open-URL that arrives before any callback is installed is
// held and replayed on the first pump with a listener, ahead of what that
// pump drains; a scheme URL arrives as sent; documents arrive as file://
// URLs; a reopen carries hasVisibleWindows; a quit request is routed to JS
// and the process survives it (the OS default would have ended it).

const path = require('path');
const { native } = require('..');

const received = [];
const fail = (msg, ...rest) => {
  console.error('app-lifecycle:', msg, ...rest);
  process.exit(1);
};

// Pump until `pred` holds or `ms` elapse. The pump runs on a timer like a
// renderer's would, so the events come in the way they would there.
function pumpUntil(pred, ms = 3000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const tick = setInterval(() => {
      native.pump2();
      if (pred()) {
        clearInterval(tick);
        resolve();
      } else if (Date.now() > deadline) {
        clearInterval(tick);
        reject(new Error('timed out; received so far: ' + JSON.stringify(received)));
      }
    }, 8);
  });
}
const ofType = (t) => received.filter((e) => e.type === t);
const appEvents = () => received.filter((e) => e.type.startsWith('app-'));

(async () => {
  // 1. before anyone listens: initApp, then a URL through the pump. With
  //    no callback the delegate has to hold it.
  native.initApp();
  native.postAppleEvent('open-url', 'appkit-test://early?x=1');
  const drained = Date.now() + 500;
  while (Date.now() < drained) native.pump2();
  if (received.length !== 0) fail('an event reached JS with no callback installed');

  // 2. a listener appears; the first pump replays the held URL
  native.setBackendEventCallback((ev) => received.push(ev));
  native.pump2();
  if (ofType('app-open-urls').length !== 1 || ofType('app-open-urls')[0].urls.join() !== 'appkit-test://early?x=1') {
    fail('the pre-callback URL was not replayed on the first listening pump', received);
  }

  // 3. live: a scheme URL, as sent
  native.postAppleEvent('open-url', 'appkit-test://live/path?code=abc#frag');
  await pumpUntil(() => ofType('app-open-urls').length === 2);
  if (ofType('app-open-urls')[1].urls.join() !== 'appkit-test://live/path?code=abc#frag') {
    fail('scheme URL altered in transit', ofType('app-open-urls')[1]);
  }

  // 4. documents, as file:// URLs, one event for the whole list
  const docs = [path.join(__dirname, 'app-lifecycle.js'), path.join(__dirname, '..', 'README.md')];
  native.postAppleEvent('open-documents', docs);
  await pumpUntil(() => ofType('app-open-urls').length === 3);
  const urls = ofType('app-open-urls')[2].urls;
  if (urls.length !== 2 || !urls.every((u, i) => u.startsWith('file://') && decodeURIComponent(new URL(u).pathname) === docs[i])) {
    fail('documents did not arrive as their file:// URLs', urls, docs);
  }

  // 5. reopen, with no window of ours on screen, then with one
  native.postAppleEvent('reopen');
  await pumpUntil(() => ofType('app-reopen').length === 1);
  if (ofType('app-reopen')[0].hasVisibleWindows !== false) fail('hasVisibleWindows with no windows', ofType('app-reopen')[0]);
  const win = native.createWindow2({ width: 120, height: 80, title: 'app-lifecycle' });
  native.showWindow(win, false);
  native.pump2();
  native.postAppleEvent('reopen');
  await pumpUntil(() => ofType('app-reopen').length === 2);
  if (ofType('app-reopen')[1].hasVisibleWindows !== true) fail('hasVisibleWindows with a window shown', ofType('app-reopen')[1]);
  native.destroyWindow2(win);

  // 6. quit: routed to JS, and the process is still here afterwards
  native.postAppleEvent('quit');
  await pumpUntil(() => ofType('app-quit-request').length === 1);
  const after = Date.now() + 300;
  while (Date.now() < after) native.pump2();

  // 7. argument checking on the test native itself
  for (const bad of [() => native.postAppleEvent('bogus'), () => native.postAppleEvent('open-url', 7), () => native.postAppleEvent('open-documents', 'x')]) {
    let threw = false;
    try { bad(); } catch (e) { threw = e instanceof TypeError; }
    if (!threw) fail('postAppleEvent accepted a bad argument');
  }

  // the window's own events (occlusion, focus if the app happened to be
  // active) are legitimate; the order of the app events is what is checked
  const kinds = appEvents().map((e) => e.type).join(' ');
  if (kinds !== 'app-open-urls app-open-urls app-open-urls app-reopen app-reopen app-quit-request') fail('unexpected event sequence', kinds);
  console.log('app-lifecycle OK:', kinds);
  process.exit(0);
})().catch((e) => fail(e.message));
