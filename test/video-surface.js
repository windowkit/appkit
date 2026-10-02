'use strict';
// Video surfaces on screen (src/video.mm): a frame written into an NV12 or
// BGRA surface and shown through setLayerContentsIOSurface, beside the same
// frame converted by writeVideoSurface into a plain surface and shown as a
// CGImage — the two presentations a renderer moves a video between, as a
// layer when nothing is drawn over it and drawn into its bitmap when
// something is. Read back through snapshotWindow (the window server's
// composite; CALayer.render(in:) draws no YCbCr surface at all), the two
// have to show the same colours, for both ranges, for I420 interleaved on
// the way in, and for each colour space; and the colour space has to matter,
// since a surface whose tags Core Animation ignored would pass the first
// check while showing every BT.601 frame as BT.709.
//
// Also: the verbs refuse what they cannot do with a message that says what
// was wanted, and a surface is in use only while something shows it.
// Exits 0 when every expectation held.

const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('video-surface:', msg, ...rest);
  process.exit(1);
};

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
const pumpFor = (ms) => pumpUntil(() => false, ms).catch(() => {});

// test/surface-colorspace.js's reader: 8- or 16-bit RGB(A), not interlaced
function readPng(file) {
  const buf = fs.readFileSync(file);
  let width = 0, height = 0, depth = 0, type = 0;
  const idat = [];
  for (let o = 8; o < buf.length; ) {
    const len = buf.readUInt32BE(o);
    const kind = buf.toString('latin1', o + 4, o + 8);
    const data = buf.subarray(o + 8, o + 8 + len);
    if (kind === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      depth = data[8];
      type = data[9];
      if (data[12] !== 0) throw new Error('interlaced PNG');
    } else if (kind === 'IDAT') idat.push(data);
    o += 12 + len;
  }
  const channels = { 2: 3, 6: 4 }[type];
  if (!channels || (depth !== 8 && depth !== 16)) throw new Error(`PNG type ${type}/${depth}`);
  const bpp = (channels * depth) / 8;
  const stride = width * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const px = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const out = px.subarray(y * stride, (y + 1) * stride);
    const up = y ? px.subarray((y - 1) * stride, y * stride) : null;
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? out[i - bpp] : 0;
      const b = up ? up[i] : 0;
      const c = up && i >= bpp ? up[i - bpp] : 0;
      let v = line[i];
      if (filter === 1) v += a;
      else if (filter === 2) v += b;
      else if (filter === 3) v += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      out[i] = v & 0xff;
    }
  }
  const rgb = (x, y) => {
    const i = y * stride + x * bpp;
    const at = (k) => (depth === 8 ? px[i + k] : px[i + 2 * k]);
    return [at(0), at(1), at(2)];
  };
  return { width, height, rgb };
}

const expectThrow = (fn, phrase) => {
  try {
    fn();
  } catch (e) {
    if (!String(e.message).includes(phrase)) fail(`threw "${e.message}", expected it to say "${phrase}"`);
    return;
  }
  fail(`did not throw (expected "${phrase}")`);
};

// one solid-colour frame, in each layout the verbs take
const W = 64, H = 48;
const cw = W / 2, ch = H / 2;
const nv12 = ([y, cb, cr]) => {
  const uv = Buffer.alloc(cw * 2 * ch);
  for (let i = 0; i < uv.length; i += 2) {
    uv[i] = cb;
    uv[i + 1] = cr;
  }
  return [Buffer.alloc(W * H, y), uv];
};
const i420 = ([y, cb, cr]) => [Buffer.alloc(W * H, y), Buffer.alloc(cw * ch, cb), Buffer.alloc(cw * ch, cr)];
const bgra = ([r, g, b]) => {
  const p = Buffer.alloc(W * H * 4);
  for (let i = 0; i < p.length; i += 4) {
    p[i] = b;
    p[i + 1] = g;
    p[i + 2] = r;
    p[i + 3] = 0; // a decoder's undefined fourth byte: the verbs make it opaque
  }
  return [p];
};

// [label, surface options, frame format, planes, write options]
const ORANGE = [150, 60, 190]; // Y, Cb, Cr: an orange in video range
const ORANGE_FULL = [160, 50, 200];
// A dark grey is where the two ways to linearise BT.709 part furthest: Core
// Animation shows a surface tagged 709 throughout with the exact curve, and
// converts 601 — like VideoToolbox and Core Image convert everything — with
// a 1.961 gamma. Y'=50 is sRGB 55 on the one and 44 on the other.
const DARK = [50, 128, 128];
const CASES = [
  ['NV12 bt709 video', {}, 'NV12', nv12(ORANGE), {}],
  ['I420 bt709 video', {}, 'I420', i420(ORANGE), {}],
  ['NV12 bt601 video', { colorSpace: 'bt601' }, 'NV12', nv12(ORANGE), { colorSpace: 'bt601' }],
  ['NV12 bt709 full', { range: 'full' }, 'NV12', nv12(ORANGE_FULL), { range: 'full' }],
  ['BGRA', { format: 'BGRA' }, 'BGRA', bgra([40, 160, 220]), {}],
  ['I420 into BGRA', { format: 'BGRA' }, 'I420', i420(ORANGE), {}],
  ['NV12 bt709 dark grey', {}, 'NV12', nv12(DARK), {}],
  ['NV12 bt601 dark grey', { colorSpace: 'bt601' }, 'NV12', nv12(DARK), { colorSpace: 'bt601' }],
  // in sRGB's gamut: a 2020 colour outside it shows on a wide-gamut panel
  // from a layer, and is clipped in an sRGB bitmap
  ['NV12 bt2020', { colorSpace: 'bt2020' }, 'NV12', nv12([120, 118, 136]), { colorSpace: 'bt2020' }],
];
const TILE = 40; // points
const ROWS = 2;
const WIN_W = 10 + CASES.length * (TILE + 8);
const WIN_H = 10 + ROWS * (TILE + 8);

(async () => {
  // --- refusals ---------------------------------------------------------------
  expectThrow(() => native.createVideoSurface(0, 10), 'whole numbers of pixels');
  expectThrow(() => native.createVideoSurface(10, 10, { format: 'I420' }), "'NV12' or 'BGRA'");
  expectThrow(() => native.createVideoSurface(10, 10, { colorSpace: 'srgb' }), "'bt709', 'bt601'");
  expectThrow(() => native.createVideoSurface(10, 10, { range: 'limited' }), "'video' or 'full'");
  const probe = native.createVideoSurface(W, H);
  expectThrow(() => native.writeVideoSurface(probe.handle, 'YUY2', []), "'NV12', 'I420' or 'BGRA'");
  expectThrow(() => native.writeVideoSurface(probe.handle, 'NV12', [Buffer.alloc(W * H)]), 'array of 2 planes');
  expectThrow(() => native.writeVideoSurface(probe.handle, 'BGRA', bgra([0, 0, 0])), 'not BGRA');
  expectThrow(
    () => native.writeVideoSurface(probe.handle, 'I420', [Buffer.alloc(W * H), Buffer.alloc(10), Buffer.alloc(cw * ch)]),
    `plane 1 of a ${W}x${H} I420 frame needs ${cw * ch} bytes, and has 10`,
  );
  expectThrow(
    () => native.writeVideoSurface(probe.handle, 'NV12', nv12(ORANGE), { strides: [W - 1] }),
    'stride of plane 0 must be a whole number of at least',
  );
  // a stride wider than the row: the planes are read row by row from it
  {
    const [y, uv] = nv12(ORANGE);
    const wide = Buffer.alloc((W + 16) * H, 0);
    for (let r = 0; r < H; r++) y.copy(wide, r * (W + 16), r * W, (r + 1) * W);
    native.writeVideoSurface(probe.handle, 'NV12', [wide, uv], { strides: [W + 16] });
  }
  expectThrow(() => native.writeVideoSurface({}, 'NV12', nv12(ORANGE)), 'expected a surface handle');
  if (native.videoSurfaceIsInUse(probe.handle)) fail('a surface nothing shows is in use');
  native.releaseVideoSurface(probe.handle);
  native.releaseVideoSurface(probe.handle); // idempotent
  expectThrow(() => native.writeVideoSurface(probe.handle, 'NV12', nv12(ORANGE)), 'video surface was released');

  // --- on screen ----------------------------------------------------------------
  native.initApp();
  const win = native.createWindow2({ width: WIN_W, height: WIN_H, x: 200, y: 200, title: 'video-surface' });
  native.showWindow(win, false);
  await pumpUntil(() => native.getWindowFrame(win)?.visible === true).catch(() => fail('the window never showed'));
  const scale = native.getWindowFrame(win).scale;
  const root = native.windowRootLayer(win);
  native.setLayerProps(root, { backgroundColor: [1, 1, 1, 1] });
  const tile = (i, row) => {
    const layer = native.createLayer();
    native.setLayerProps(layer, { frame: [10 + i * (TILE + 8), 10 + row * (TILE + 8), TILE, TILE] });
    native.addSublayer(root, layer);
    return layer;
  };

  const shown = [];
  CASES.forEach(([, surfaceOpts, format, planes, writeOpts], i) => {
    // lifted: the surface itself is the layer's contents
    const v = native.createVideoSurface(W, H, surfaceOpts);
    native.writeVideoSurface(v.handle, format, planes, writeOpts);
    native.setLayerContentsIOSurface(tile(i, 0), v.iosurfaceId);
    // drawn: converted into a bitmap, shown the way a window's bitmap is
    const s = native.createSurface(W, H, 1);
    native.writeVideoSurface(s, format, planes, writeOpts);
    native.surfaceToLayer(s, tile(i, 1));
    shown.push({ v, s });
  });
  native.pump2();
  await pumpFor(400);

  if (!shown.some(({ v }) => native.videoSurfaceIsInUse(v.handle))) {
    fail('no surface a layer shows is in use: videoSurfaceIsInUse cannot tell a ring which to write');
  }

  const shot = path.join(os.tmpdir(), `appkit-video-surface-${process.pid}.png`);
  if (!native.snapshotWindow(win, shot)) fail('snapshotWindow wrote nothing');
  const png = readPng(shot);
  if (process.env.KEEP_SHOT) fs.copyFileSync(shot, process.env.KEEP_SHOT);
  fs.unlinkSync(shot);
  const k = png.width / WIN_W;
  const top = png.height - Math.round(WIN_H * k);
  const at = (i, row) =>
    png.rgb(Math.round((10 + i * (TILE + 8) + TILE / 2) * k), top + Math.round((10 + row * (TILE + 8) + TILE / 2) * k));
  const lifted = CASES.map((_, i) => at(i, 0));
  const drawn = CASES.map((_, i) => at(i, 1));
  const white = [255, 255, 255];
  const near = (a, b, d = 2) => a.every((v, i) => Math.abs(v - b[i]) <= d);

  CASES.forEach(([label], i) => {
    if (near(lifted[i], white, 1)) fail(`${label}: the surface on a layer showed nothing`, lifted[i]);
    if (!near(lifted[i], drawn[i])) {
      fail(`${label}: on a layer it shows`, lifted[i], 'and drawn into a bitmap', drawn[i]);
    }
  });
  if (!near(lifted[0], lifted[1], 1)) fail('I420 interleaved into NV12 shows', lifted[1], 'where NV12 shows', lifted[0]);
  if (near(lifted[0], lifted[2], 2)) {
    fail('a BT.601 surface shows', lifted[2], 'the same as a BT.709 one', lifted[0], '— its colour tags were not read');
  }
  if (!near(lifted[4], drawn[4], 1)) fail('a BGRA frame on a layer and in a bitmap differ', lifted[4], drawn[4]);
  if (near(lifted[6], lifted[7], 4)) {
    fail('a dark grey shows', lifted[6], 'tagged BT.709 and', lifted[7], 'tagged BT.601: the curve each is shown with is no longer the one this bridge converts by');
  }

  for (const { v, s } of shown) {
    native.releaseVideoSurface(v.handle);
    native.releaseSurface(s);
  }
  native.destroyWindow2(win);
  console.log('video-surface: ok', JSON.stringify({ lifted, drawn }));
  process.exit(0);
})().catch((e) => fail(e && e.stack ? e.stack : e));
