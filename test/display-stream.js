'use strict';
// A display or a window as a stream (src/displaystream.mm), pump mode: a
// window of ours listed among the windows to share, streamed — started at
// the size asked with its aspect kept, its frames handed over on request and
// copied into a surface, its rate and size changed without stopping, muted
// while the window is minimized — and ended when the window goes; a window
// that is not there refused by name.
//
// Screen Recording decides all of it: where this process has the grant it
// runs, and where it has not it is said to be skipped. A test never raises a
// privacy prompt, and a refusal without one is checked by name instead.
//
// Exits 0 when every expectation held.

const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('display-stream:', msg, ...rest);
  process.exit(1);
};

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
const pumpFor = (ms) => pumpUntil(() => false, ms).catch(() => {});
const answer = (fn) => new Promise((resolve) => fn(resolve));

(async () => {
  native.initApp();
  const events = [];
  native.setBackendEventCallback((ev) => events.push(ev));
  const of = (type, id) => events.filter((e) => e.type === type && (id === undefined || e.id === id));
  const waitFor = (type, id, what, ms) =>
    pumpUntil(() => of(type, id).length > 0, ms).catch(() => fail(`no ${type} for ${what}`, events.slice(-5)));

  for (const verb of [
    'screenCaptureWindows',
    'openDisplayStream',
    'displayStreamFrames',
    'displayStreamCopyFrame',
    'displayStreamConfigure',
    'closeDisplayStream',
  ]) {
    if (typeof native[verb] !== 'function') fail(`no ${verb}`);
  }
  try {
    native.displayStreamFrames('one', true);
    fail('an id that is not one was taken');
  } catch (e) {
    if (!(e instanceof TypeError)) throw e;
  }

  if (native.authorizationStatus('screen-recording') !== 'authorized') {
    // asked without the grant, the stream says so by name — and nothing
    // here may raise the prompt that would answer it, so it is not opened
    console.log('display-stream: ok (skipped: Screen Recording is not allowed for this process)');
    process.exit(0);
  }

  const win = native.createWindow2({ width: 200, height: 100, x: 300, y: 300, title: 'display stream' });
  native.showWindow(win, false);
  await pumpUntil(() => native.getWindowFrame(win)?.visible === true).catch(() => fail('the window never showed'));
  native.setLayerProps(native.windowRootLayer(win), { backgroundColor: [0.9, 0.1, 0.2, 1] });
  await pumpFor(300);
  const number = native.windowNumber(win);

  // listed, with its title and this process as its owner
  const windows = await answer((cb) => native.screenCaptureWindows(cb));
  if (!Array.isArray(windows)) fail('screenCaptureWindows answered', windows);
  const ours = windows.find((w) => w.id === number);
  if (!ours) fail('our window is not listed', windows.map((w) => w.id));
  if (ours.title !== 'display stream' || ours.app.pid !== process.pid) fail('our window, listed as', ours);
  if (!(ours.width >= 200 && ours.height >= 100)) fail('our window, sized as', ours);

  // streamed at a width asked: the height follows the window's aspect, and
  // both are even
  const s = native.openDisplayStream({ window: number, width: 100, frameRate: 30, cursor: false });
  if (typeof s.id !== 'number' || !s.layer) fail('openDisplayStream answered', s);
  await waitFor('display-started', s.id, 'our window');
  const started = of('display-started', s.id)[0];
  if (started.width !== 100 || started.height % 2 !== 0 || started.frameRate !== 30) {
    fail('started as', started);
  }
  if (Math.abs(started.width / started.height - ours.width / ours.height) > 0.05) {
    fail('the aspect is not the window’s', started, ours);
  }

  // frames, once asked: BGRA, the window's red in the middle. A still window
  // sends none, so it is repainted to make one.
  native.displayStreamFrames(s.id, true);
  native.setLayerProps(native.windowRootLayer(win), { backgroundColor: [0.9, 0.1, 0.25, 1] });
  await waitFor('display-frame', s.id, 'a repaint', 3000);
  const f = of('display-frame', s.id).at(-1);
  if (f.format !== 'BGRA' || f.width !== started.width || f.planes.length !== 1) fail('a frame', f);
  const mid = (f.height >> 1) * f.strides[0] + (f.width >> 1) * 4;
  const [b, g, r] = f.planes[0].subarray(mid, mid + 3);
  if (!(r > 190 && g < 70 && b < 90)) fail('the middle of the window is', [r, g, b]);
  native.displayStreamFrames(s.id, false);

  // copied into a surface: the newest frame once, then nothing newer
  const surface = native.createSurface(f.width, f.height, 1);
  native.setLayerProps(native.windowRootLayer(win), { backgroundColor: [0.9, 0.1, 0.2, 1] });
  let copied = null;
  await pumpUntil(() => (copied = native.displayStreamCopyFrame(s.id, surface)) !== null, 3000).catch(() =>
    fail('no frame to copy'),
  );
  if (!copied.written || copied.width !== f.width) fail('copied', copied);
  const px = [...native.ctxGetImageData(surface, f.width >> 1, f.height >> 1, 1, 1)];
  if (!(px[0] > 190 && px[1] < 70)) fail('the copy’s middle is', px);
  if (native.displayStreamCopyFrame(s.id, surface) !== null) fail('a frame copied twice');

  // another size and rate, the stream running on
  native.displayStreamConfigure(s.id, { width: 60, frameRate: 10 });
  await waitFor('display-configured', s.id, 'the new size');
  const conf = of('display-configured', s.id)[0];
  if (conf.error || conf.width !== 60 || conf.frameRate !== 10) fail('configured as', conf);
  native.displayStreamFrames(s.id, true);
  const before = of('display-frame', s.id).length;
  native.setLayerProps(native.windowRootLayer(win), { backgroundColor: [0.1, 0.2, 0.9, 1] });
  await pumpUntil(() => of('display-frame', s.id).length > before, 3000).catch(() => fail('no frame after configure'));
  const g2 = of('display-frame', s.id).at(-1);
  if (g2.width !== 60) fail('a frame after configure is', g2.width, 'wide');

  // minimized, the stream is muted; back, it is not, and frames come again
  native.setWindowMiniaturized(win, true);
  await pumpUntil(() => of('display-muted', s.id).some((e) => e.muted), 5000).catch(() =>
    fail('no mute for a minimized window', events.slice(-4)),
  );
  if (of('display-ended', s.id).length) fail('a minimized window ended its stream');
  native.setWindowMiniaturized(win, false);
  await pumpFor(600);
  native.setLayerProps(native.windowRootLayer(win), { backgroundColor: [0.9, 0.1, 0.2, 1] });
  await pumpUntil(() => of('display-muted', s.id).at(-1)?.muted === false, 5000).catch(() =>
    fail('no unmute for a window restored', events.slice(-4)),
  );

  // the window goes: the stream ends, of its own accord — said as a mute
  // first, since ScreenCaptureKit suspends it as it would a minimized one
  native.destroyWindow2(win);
  await waitFor('display-ended', s.id, 'a closed window', 5000);
  native.closeDisplayStream(s.id);
  native.closeDisplayStream(s.id); // twice is nothing

  // a window that is not there, by name
  const gone = native.openDisplayStream({ window: 0x7ffffff0 });
  await waitFor('display-error', gone.id, 'a window that is not there');
  if (of('display-error', gone.id)[0].name !== 'NotFoundError') fail('a missing window', of('display-error', gone.id));

  // closed before it started: nothing after
  const early = native.openDisplayStream({});
  native.closeDisplayStream(early.id);
  await pumpFor(800);
  if (of('display-started', early.id).length || of('display-frame', early.id).length) {
    fail('a stream closed at once said', events.filter((e) => e.id === early.id));
  }

  console.log('display-stream: ok');
  process.exit(0);
})().catch((e) => fail(e.stack || e));
