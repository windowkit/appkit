'use strict';
// A layer transform as a matrix (sidorares/react-x11#819): setLayerProps'
// `transform` and an animation's values take CSS's `matrix()` and
// `matrix3d()`, and `transformForms()` says so. What a matrix does is read
// back through the presentation layer, and on the window's pixels, where y
// grows down as it does in CSS: a rotation by a positive angle turns
// clockwise, and a positive translation moves down. Exits 0 when every
// expectation held.

const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('layer-transform:', msg, ...rest);
  process.exit(1);
};
const near = (a, b, tol) => typeof a === 'number' && Math.abs(a - b) <= tol;
const nearAll = (a, b, tol = 1e-6) =>
  Array.isArray(a) && a.length === b.length && a.every((v, i) => near(v, b[i], tol));

function pumpFor(ms) {
  return new Promise((resolve) => {
    const until = Date.now() + ms;
    const tick = setInterval(() => {
      native.pump2();
      if (Date.now() > until) {
        clearInterval(tick);
        resolve();
      }
    }, 8);
  });
}

function commit(fn) {
  native.txBegin({ disableActions: true });
  try { fn(); } finally { native.txCommit(); }
  native.pump2();
}

// a frozen animation's value `at` seconds in (test/animation.js's helper)
function sample(layer, keyPath, opts, at) {
  commit(() => native.addAnimation(layer, keyPath, { ...opts, speed: 0, timeOffset: at }, 'sample'));
  const v = native.presentationValue(layer, keyPath);
  commit(() => native.removeAnimation(layer, 'sample'));
  return v;
}

function throwsType(fn, what) {
  let threw = false;
  try { fn(); } catch (e) { threw = e instanceof TypeError; }
  if (!threw) fail('accepted a bad ' + what);
}

// The snapshot is a PNG: its pixels, read with nothing but zlib. 8 or 16
// bits a channel, RGB or RGBA, not interlaced — what CGImageDestination
// writes for a window.
function readPng(file) {
  const buf = fs.readFileSync(file);
  let at = 8;
  let width = 0, height = 0, depth = 0, type = 0;
  const idat = [];
  while (at < buf.length) {
    const len = buf.readUInt32BE(at);
    const kind = buf.toString('latin1', at + 4, at + 8);
    const data = buf.subarray(at + 8, at + 8 + len);
    if (kind === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      depth = data[8];
      type = data[9];
      if (data[12] !== 0) fail('an interlaced snapshot');
    } else if (kind === 'IDAT') {
      idat.push(data);
    }
    at += 12 + len;
  }
  const channels = type === 6 ? 4 : type === 2 ? 3 : 0;
  if (!channels || (depth !== 8 && depth !== 16)) fail(`a PNG of type ${type}, depth ${depth}`);
  const bpp = (channels * depth) / 8;
  const stride = width * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const out = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const row = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[y * stride + x - bpp] : 0;
      const b = y > 0 ? out[(y - 1) * stride + x] : 0;
      const c = x >= bpp && y > 0 ? out[(y - 1) * stride + x - bpp] : 0;
      let v = row[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += b;
      else if (filter === 3) v += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      out[y * stride + x] = v & 255;
    }
  }
  const step = depth / 8;
  return {
    width,
    // [r, g, b] at a pixel; the high byte of a 16-bit channel
    at: (x, y) => {
      const i = y * stride + x * bpp;
      return [out[i], out[i + step], out[i + 2 * step]];
    },
  };
}

const PTS = { width: 160, height: 120 };
const shotFile = path.join(os.tmpdir(), `layer-transform-${process.pid}.png`);

// The window as the window server composites it, sampled in points. The
// colours are matched to the display the window is on, so a sample is a
// kind of colour rather than its exact bytes.
function shot(win) {
  if (!native.snapshotWindow(win, shotFile)) fail('snapshotWindow wrote nothing');
  const png = readPng(shotFile);
  fs.unlinkSync(shotFile);
  const d = png.width / PTS.width;
  return (x, y) => {
    const [r, g, b] = png.at(Math.round(x * d), Math.round(y * d));
    if (r > 180 && g < 120 && b < 120) return 'red';
    if (b > 180 && r < 120 && g < 120) return 'blue';
    if (r > 230 && g > 230 && b > 230) return 'white';
    return `${r},${g},${b}`;
  };
}

function expectAt(px, where, what) {
  for (const [x, y, colour] of where) {
    const got = px(x, y);
    if (got !== colour) fail(`${what}: (${x}, ${y}) is ${got}, expected ${colour}`);
  }
}

// Whether a snapshot shows what the window server composites here at all:
// without the screen-recording grant some machines answer a blank image.
// The pixels are then skipped, and the read-backs still hold the bridge to
// the matrix it was handed.
function seesLayers(px) {
  return px(60, 40) === 'red' && px(100, 40) === 'blue' && px(80, 20) === 'white';
}

(async () => {
  native.initApp();
  const forms = native.transformForms();
  if (!forms.includes('matrix') || !forms.includes('matrix3d')) {
    fail('transformForms() does not offer a matrix', forms);
  }

  const win = native.createWindow2({ ...PTS, kind: 'borderless', x: 120, y: 120 });
  native.showWindow(win, false);
  const root = native.windowRootLayer(win);
  // a card 60×20 at (50, 30): its left half red, its right half blue, so
  // which way it turned shows
  const card = native.createLayer();
  const half = native.createLayer();
  commit(() => {
    native.setLayerProps(root, { backgroundColor: [1, 1, 1, 1] });
    native.addSublayer(root, card);
    native.addSublayer(card, half);
    native.setLayerProps(card, { frame: [50, 30, 60, 20], backgroundColor: [1, 0, 0, 1] });
    native.setLayerProps(half, { frame: [30, 0, 30, 20], backgroundColor: [0, 0, 1, 1] });
  });
  await pumpFor(200);
  const pixels = seesLayers(shot(win));
  if (!pixels) {
    console.log('layer-transform: the snapshot shows no layers here; checking read-backs only');
  }

  // 1. CSS's rotate(90deg), matrix(0, 1, -1, 0, 0, 0), about the anchor at
  // the card's centre (80, 40): clockwise, so the red left half goes up
  commit(() => native.setLayerProps(card, { transform: { matrix: [0, 1, -1, 0, 0, 0] } }));
  await pumpFor(200);
  if (pixels) {
    expectAt(
      shot(win),
      [[80, 20, 'red'], [80, 60, 'blue'], [60, 40, 'white'], [100, 40, 'white']],
      'matrix(0, 1, -1, 0, 0, 0)',
    );
  }
  const turned = native.presentationValue(card, 'transform');
  if (!nearAll(turned, [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])) {
    fail('matrix(0, 1, -1, 0, 0, 0) read back as', turned);
  }

  // 2. a translation is in points, and down is +y: the card at (80, 40)
  commit(() => native.setLayerProps(card, { transform: { matrix: [1, 0, 0, 1, 30, 10] } }));
  await pumpFor(200);
  if (pixels) {
    expectAt(
      shot(win),
      [[90, 50, 'red'], [130, 50, 'blue'], [60, 35, 'white']],
      'matrix(1, 0, 0, 1, 30, 10)',
    );
  }
  const moved = native.presentationValue(card, 'transform');
  if (!near(moved?.[12], 30, 1e-6) || !near(moved?.[13], 10, 1e-6)) {
    fail('matrix(1, 0, 0, 1, 30, 10) read back as', moved);
  }

  // 3. matrix3d: the sixteen numbers presentationValue answers, in and out
  const m3 = [0.6, 0.8, 0, 0, -0.8, 0.6, 0, 0, 0, 0, 1, 0, 5, -3, 0, 1];
  commit(() => native.setLayerProps(card, { transform: { matrix3d: m3 } }));
  const back = native.presentationValue(card, 'transform');
  if (!nearAll(back, m3)) fail('matrix3d read back as', back);

  // 4. a transform is an animation value, from/to and keyframes alike
  commit(() => native.setLayerProps(card, { transform: { matrix: [1, 0, 0, 1, 0, 0] } }));
  const slid = sample(
    card,
    'transform',
    { from: { matrix: [1, 0, 0, 1, 0, 0] }, to: { matrix: [1, 0, 0, 1, 40, 0] }, duration: 1, timing: 'linear' },
    0.25,
  );
  if (!near(slid?.[12], 10, 0.01)) fail('translation a quarter in', slid);
  const grown = sample(
    card,
    'transform',
    { values: [{ matrix: [1, 0, 0, 1, 0, 0] }, { matrix: [3, 0, 0, 3, 0, 0] }], duration: 1 },
    0.5,
  );
  if (!near(grown?.[0], 2, 0.01) || !near(grown?.[5], 2, 0.01)) fail('scale halfway', grown);

  // 5. a matrix of the wrong shape is a TypeError, and nothing is applied
  commit(() => native.setLayerProps(card, { transform: { matrix: [2, 0, 0, 2, 0, 0] } }));
  throwsType(() => native.setLayerProps(card, { transform: { matrix: [1, 2, 3] } }), 'six-number matrix of three');
  throwsType(
    () => native.setLayerProps(card, { transform: { matrix3d: new Array(16).fill(NaN) } }),
    'matrix3d of NaN',
  );
  native.pump2();
  const kept = native.presentationValue(card, 'transform');
  if (!near(kept?.[0], 2, 1e-6)) fail('a refused matrix changed the transform', kept);
  throwsType(
    () => native.addAnimation(card, 'transform', { values: [{ matrix: [1] }, { matrix: [1, 0, 0, 1, 0, 0] }] }, 'bad'),
    'keyframe matrix',
  );
  throwsType(() => native.addAnimation(card, 'transform', { from: { matrix3d: [1] }, to: { matrix: [1, 0, 0, 1, 0, 0] } }, 'bad'), 'from');

  native.destroyWindow2(win);
  console.log(`layer-transform: ok${pixels ? ', on the window\'s pixels too' : ''}`);
  process.exit(0);
})().catch((e) => fail(e && e.stack ? e.stack : e));
