'use strict';
// A window the pointer passes through: createWindow2's `ignoresMouseEvents`,
// the setter of the same name, and `windowNumberAtPoint`, the window
// server's own answer to which window a mouse-down at a point reaches. What
// a drag preview needs (sidorares/react-x11#488): a popup following the
// pointer is the window found under it for the whole gesture, registered for
// dragged types or not, so the drag has no destination and the window
// beneath never hears of it. Exits 0 when every expectation held.
//
// Checked: a popup over a window is what the hit finds, registered for a
// dragged type or not; with ignoresMouseEvents it is looked past and the
// window beneath is found — set at creation, and flipped through the setter
// both ways; the frame report says which; a bad point is a TypeError. The
// walk hands `belowWindowNumber` back to look beneath the windows of other
// applications (a lock screen, a floating panel), so it holds on a desktop
// with anything over ours.

const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('ignores-mouse-events:', msg, ...rest);
  process.exit(1);
};

// Pump until `pred` holds or `ms` elapse. The window server applies a
// change on its own clock; the checks wait for it rather than assume it.
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
        reject(new Error('timed out'));
      }
    }, 8);
  });
}

(async () => {
  native.initApp();

  // a titled window, and over its middle a popup — the preview's shape: a
  // borderless non-activating panel at the pop-up-menu level
  const base = native.createWindow2({ width: 400, height: 300, x: 200, y: 200, title: 'ignores-mouse-events' });
  const popup = native.createWindow2({ kind: 'popup', width: 200, height: 100, x: 300, y: 250 });
  const baseNo = native.windowNumber(base);
  const popupNo = native.windowNumber(popup);
  const ours = new Map([[baseNo, 'base'], [popupNo, 'popup']]);
  native.showWindow(base, false);
  native.showWindow(popup, false);

  // the topmost of OUR windows at a global top-left point; another
  // application's window above them is walked beneath with belowWindowNumber
  const oursAt = (x, y) => {
    let hit = native.windowNumberAtPoint(x, y);
    for (let i = 0; hit && !ours.has(hit) && i < 64; i++) hit = native.windowNumberAtPoint(x, y, hit);
    return ours.has(hit) ? hit : 0;
  };
  const name = (n) => ours.get(n) || String(n);
  const inPopup = [350, 300];
  const beside = [250, 220];

  // the window server has them once the point beside the popup finds the base
  await pumpUntil(() => oursAt(...beside) === baseNo).catch(() => fail('the windows never reached the screen', oursAt(...beside)));

  // 1. the popup is what a hit over it finds — registered for a dragged
  //    type or not, which is the belief this exists to pin down
  if (oursAt(...inPopup) !== popupNo) fail('the popup is not what the hit finds', name(oursAt(...inPopup)));
  if (native.getWindowFrame(popup).ignoresMouseEvents !== false) fail('the frame report should say the popup takes the pointer');
  native.registerDropTypes(popup, ['public.utf8-plain-text']);
  native.pump2();
  if (oursAt(...inPopup) !== popupNo) fail('registered for a dragged type, the popup is not what the hit finds', name(oursAt(...inPopup)));
  native.registerDropTypes(popup, []);
  native.pump2();
  if (oursAt(...inPopup) !== popupNo) fail('an unregistered popup is looked past, which the property would not be needed for', name(oursAt(...inPopup)));

  // 2. the setter: the hit passes through to the base, and comes back
  native.setWindowIgnoresMouseEvents(popup, true);
  if (native.getWindowFrame(popup).ignoresMouseEvents !== true) fail('the frame report does not say ignoresMouseEvents');
  await pumpUntil(() => oursAt(...inPopup) === baseNo).catch(() => fail('ignoresMouseEvents did not pass the hit through', name(oursAt(...inPopup))));
  if (native.getWindowFrame(popup).visible !== true) fail('the popup went off screen with the flag');
  native.setWindowIgnoresMouseEvents(popup, false);
  if (native.getWindowFrame(popup).ignoresMouseEvents !== false) fail('the frame report does not say the flag was cleared');
  await pumpUntil(() => oursAt(...inPopup) === popupNo).catch(() => fail('clearing ignoresMouseEvents did not bring the popup back', name(oursAt(...inPopup))));

  // 3. at creation: a preview made with the option, in the popup's place
  native.hideWindow(popup);
  await pumpUntil(() => oursAt(...inPopup) === baseNo).catch(() => fail('the hidden popup is still found', name(oursAt(...inPopup))));
  const preview = native.createWindow2({ kind: 'popup', width: 200, height: 100, x: 300, y: 250, ignoresMouseEvents: true });
  ours.set(native.windowNumber(preview), 'preview');
  if (native.getWindowFrame(preview).ignoresMouseEvents !== true) fail('the option was not applied');
  native.showWindow(preview, false);
  await pumpUntil(() => native.getWindowFrame(preview).visible === true).catch(() => fail('the preview never showed'));
  native.pump2();
  if (oursAt(...inPopup) !== baseNo) fail('a preview created with the option is what the hit finds', name(oursAt(...inPopup)));
  if (oursAt(...beside) !== baseNo) fail('beside the preview, the base is not found', name(oursAt(...beside)));

  // 4. a bad point is a TypeError, not a hit
  for (const bad of [() => native.windowNumberAtPoint(), () => native.windowNumberAtPoint('1', 2), () => native.windowNumberAtPoint(1, null)]) {
    let err;
    try { bad(); } catch (e) { err = e; }
    if (!(err instanceof TypeError)) fail('expected a TypeError, got', err);
  }

  native.destroyWindow2(preview);
  native.destroyWindow2(popup);
  native.destroyWindow2(base);
  console.log('ignores-mouse-events: ok');
  process.exit(0);
})().catch((e) => fail(e && e.stack ? e.stack : e));
