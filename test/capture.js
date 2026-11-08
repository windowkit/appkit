'use strict';
// Media capture (src/capture.mm), pump mode: the devices listed in both
// forms and nothing announced that did not change, a camera and a
// microphone that are not there refused by name before anything is asked of
// the user, the audio output played through its queue on the device's
// clock, a window's picture through ScreenCaptureKit and one kept out of it
// by setWindowSharing.
//
// What needs a grant this process may not have is run where the grant is
// there and said to be skipped where it is not: a test never raises a
// privacy prompt. A camera and a microphone that are allowed are opened and
// read from; Screen Recording decides the screenshots.
//
// Exits 0 when every expectation held.

const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('capture:', msg, ...rest);
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
const pumpFor = (ms) => pumpUntil(() => false, ms).catch(() => {});
const answer = (fn) => new Promise((resolve) => fn(resolve));

(async () => {
  native.initApp();
  const events = [];
  native.setBackendEventCallback((ev) => events.push(ev));
  const of = (type, id) => events.filter((e) => e.type === type && (id === undefined || e.id === id));

  // --- devices --------------------------------------------------------------------
  const devices = native.captureDevices();
  if (!Array.isArray(devices)) fail('captureDevices answered', devices);
  for (const d of devices) {
    if (typeof d.id !== 'string' || !d.id) fail('a device with no id', d);
    if (!['camera', 'microphone', 'speaker'].includes(d.kind)) fail('a device of no kind', d);
    if (typeof d.name !== 'string' || typeof d.isDefault !== 'boolean') fail('a device half described', d);
    if (d.kind === 'camera') {
      if (!Array.isArray(d.formats) || !d.formats.length) fail('a camera with no formats', d);
      for (const f of d.formats) {
        if (!(f.width > 0 && f.height > 0 && f.maxFrameRate >= f.minFrameRate)) fail('a format', f);
      }
    }
    if (/^CADefaultDeviceAggregate|^VPAUAggregateAudioDevice/.test(d.id)) fail('a private aggregate listed', d);
  }
  for (const kind of ['camera', 'microphone', 'speaker']) {
    const defaults = devices.filter((d) => d.kind === kind && d.isDefault).length;
    if (defaults > 1) fail(`${defaults} default ${kind}s`);
  }
  const later = await answer((cb) => native.captureDevices(cb));
  if (JSON.stringify(later.map((d) => d.id).sort()) !== JSON.stringify(devices.map((d) => d.id).sort())) {
    fail('captureDevices(cb) listed other devices', later, devices);
  }
  const speaker = devices.find((d) => d.kind === 'speaker' && d.isDefault);

  // --- what is not there is refused by name, and nothing prompts -------------------
  const cam = native.openCamera('no-such-camera', { width: 640, height: 480 });
  if (typeof cam.id !== 'number') fail('openCamera answered no id', cam);
  await pumpUntil(() => of('camera-error', cam.id).length > 0).catch(() => fail('a missing camera said nothing'));
  if (of('camera-error', cam.id)[0].name !== 'NotFoundError') fail('a missing camera is', of('camera-error', cam.id)[0]);
  native.closeCamera(cam.id);
  const mic = native.openMicrophone('no-such-microphone', { sampleRate: 16000, channels: 1 });
  if (mic.sampleRate !== 16000 || mic.channels !== 1) fail('openMicrophone answered', mic);
  await pumpUntil(() => of('microphone-error', mic.id).length > 0).catch(() =>
    fail('a missing microphone said nothing'),
  );
  if (of('microphone-error', mic.id)[0].name !== 'NotFoundError') {
    fail('a missing microphone is', of('microphone-error', mic.id)[0]);
  }
  native.closeMicrophone(mic.id);

  // --- the audio output ---------------------------------------------------------------
  if (speaker) {
    const out = native.openAudioOutput({ sampleRate: 48000, channels: 1 });
    if (out.sampleRate !== 48000 || out.channels !== 1) fail('openAudioOutput answered', out);
    // 0.2s of near-silence, so a person at the machine hears nothing
    const quiet = new Float32Array(9600);
    for (let i = 0; i < quiet.length; i++) quiet[i] = 0.001 * Math.sin((2 * Math.PI * 440 * i) / 48000);
    const queued = native.audioOutputWrite(out.id, [quiet]);
    if (queued !== 9600) fail('a write of 9600 frames queued', queued);
    try {
      native.audioOutputWrite(out.id, [new Float64Array(4)]);
      fail('a Float64Array was taken');
    } catch (e) {
      if (!(e instanceof TypeError)) throw e;
    }
    await pumpUntil(() => native.audioOutputState(out.id).queued === 0, 3000).catch(() =>
      fail('the queue never played out', native.audioOutputState(out.id)),
    );
    const state = native.audioOutputState(out.id);
    if (!(state.currentTime >= 0.19)) fail('0.2s played, and the clock says', state);
    if (!(state.latency >= 0)) fail('a latency', state);
    native.closeAudioOutput(out.id);
    await pumpFor(100);
    if (native.audioOutputState(out.id).currentTime !== 0) fail('a closed output still has a clock');
  } else {
    skipped.push('the audio output: no default speaker');
  }

  // --- devices announced only when they change -----------------------------------------
  // opening an output makes CoreAudio an aggregate device of this process's
  // own, which is no device of anybody's
  if (of('capture-devices').length) fail('capture-devices with nothing plugged in', of('capture-devices'));

  // --- the screen -------------------------------------------------------------------------
  const displays = await answer((cb) => native.screenCaptureDisplays(cb));
  if (!displays.length || !(displays[0].width > 0 && displays[0].scale >= 1)) fail('displays', displays);
  try {
    native.setWindowSharing({}, 'everyone');
    fail('a sharing mode that is not one was taken');
  } catch (e) {
    if (!(e instanceof TypeError)) throw e;
  }
  if (native.authorizationStatus('screen-recording') === 'authorized') {
    const win = native.createWindow2({ width: 160, height: 100, x: 260, y: 260, title: 'capture' });
    native.showWindow(win, false);
    await pumpUntil(() => native.getWindowFrame(win)?.visible === true).catch(() => fail('the window never showed'));
    native.setLayerProps(native.windowRootLayer(win), { backgroundColor: [0.9, 0.1, 0.2, 1] });
    await pumpFor(300);
    const number = native.windowNumber(win);
    const shot = await answer((cb) => native.captureScreenshot({ window: number }, cb));
    if (shot.error) fail('a screenshot of our own window', shot);
    if (shot.data.length !== shot.width * shot.height * 4) fail('a screenshot of the wrong length', shot.width, shot.height);
    const mid = ((shot.height >> 1) * shot.width + (shot.width >> 1)) * 4;
    const px = [...shot.data.subarray(mid, mid + 4)];
    if (!(px[0] > 200 && px[1] < 60 && px[2] < 80 && px[3] === 255)) fail('the window is red, and its middle is', px);
    const part = await answer((cb) =>
      native.captureScreenshot({ display: displays[0].id, rect: { x: 0, y: 0, width: 40, height: 20 } }, cb),
    );
    if (part.error || part.width !== Math.round(40 * part.scale)) fail('a part of the display', part);
    native.setWindowSharing(win, 'none');
    await pumpFor(300);
    const hidden = await answer((cb) => native.captureScreenshot({ window: number }, cb));
    // macOS 15 answers the window with nothing in it: every pixel clear
    if (!hidden.error) {
      const h = [...hidden.data.subarray(mid, mid + 4)];
      if (h[3] !== 0 && h[0] > 200 && h[1] < 60) fail('a window shared with nobody was captured', h);
    }
    const gone = await answer((cb) => native.captureScreenshot({ window: 0x7ffffff0 }, cb));
    if (gone.name !== 'NotFoundError') fail('a window that is not there', gone);
    native.destroyWindow2(win);
  } else {
    skipped.push('screenshots: Screen Recording is not allowed for this process');
  }

  // --- a camera and a microphone, where this process may have them ----------------------
  if (native.authorizationStatus('camera') === 'authorized' && devices.some((d) => d.kind === 'camera')) {
    const c = native.openCamera(null, { width: 640, height: 480, frameRate: 30 });
    if (c.format !== 'NV12' || !(c.width > 0)) fail('openCamera answered', c);
    await pumpUntil(() => of('camera-started', c.id).length || of('camera-error', c.id).length, 8000).catch(() =>
      fail('the camera never started'),
    );
    if (of('camera-error', c.id).length) fail('the camera failed', of('camera-error', c.id)[0]);
    const surface = native.createSurface(c.width, c.height, 1);
    let copied = null;
    await pumpUntil(() => (copied = native.cameraCopyFrame(c.id, surface)) !== null).catch(() =>
      fail('cameraCopyFrame never had a frame'),
    );
    if (copied.written !== true || copied.width !== c.width) fail('the copy says', copied);
    if (of('camera-frame', c.id).length) fail('frames crossed before anyone asked');
    native.cameraFrames(c.id, true);
    await pumpUntil(() => of('camera-frame', c.id).length >= 3).catch(() => fail('no frames on request'));
    const f = of('camera-frame', c.id)[0];
    if (f.planes.length !== 2 || f.planes[0].length < f.width * f.height || f.strides[0] < f.width) {
      fail('an NV12 frame', { ...f, planes: f.planes.map((p) => p.length) });
    }
    native.cameraFrames(c.id, false);
    native.closeCamera(c.id);
  } else {
    skipped.push('the camera: not allowed for this process (no prompt is raised)');
  }
  if (native.authorizationStatus('microphone') === 'authorized' && devices.some((d) => d.kind === 'microphone')) {
    const m = native.openMicrophone(null, { sampleRate: 16000, channels: 1, echoCancellation: true });
    await pumpUntil(() => of('microphone-started', m.id).length || of('microphone-error', m.id).length, 8000).catch(
      () => fail('the microphone never started'),
    );
    if (of('microphone-error', m.id).length) fail('the microphone failed', of('microphone-error', m.id)[0]);
    await pumpUntil(() => of('audio-input', m.id).length >= 5).catch(() => fail('no audio-input'));
    const chunk = of('audio-input', m.id)[0];
    if (chunk.sampleRate !== 16000 || chunk.frames !== 160 || chunk.channels.length !== 1) fail('a chunk', chunk);
    if (!(chunk.channels[0] instanceof Float32Array) || chunk.channels[0].length !== 160) fail('a channel', chunk);
    native.closeMicrophone(m.id);
  } else {
    skipped.push('the microphone: not allowed for this process (no prompt is raised)');
  }

  console.log(`capture: ok${skipped.length ? ` (skipped: ${skipped.join('; ')})` : ''}`);
  process.exit(0);
})().catch((e) => fail(e && e.stack ? e.stack : e));
