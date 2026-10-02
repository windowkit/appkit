'use strict';
// An IOSurface on a layer is matched to the display the way a CGImage and a
// layer colour are: every IOSurface this bridge makes names sRGB as its
// colour space (kIOSurfaceColorSpace), and setLayerContentsIOSurface names
// one that names none. Unnamed, Core Animation shows a surface's numbers as
// the display's own, so on any display whose profile is not sRGB the
// presentation surface and a layer beside it disagreed — on a MacBook's
// wide-gamut panel #ff0000 in the surface was (255, 0, 0) in the panel's
// space, and on a layer (234, 51, 35).
//
// Checked, on a real window read back through snapshotWindow: the same
// colours drawn into an IOSurface-backed surface and shown through
// setLayerContentsIOSurface, drawn into a plain surface and shown through
// surfaceToLayer (a CGImage, which carries its space), and set as layers'
// backgroundColor (CGColors), come out as the same numbers. On a display
// whose profile is sRGB that holds whether a surface names a space or not,
// and the test says it could not tell; a capture with nothing composited in
// it — a locked or sleeping display — fails rather than passing unlooked.
// Exits 0 when every expectation held.

const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('surface-colorspace:', msg, ...rest);
  process.exit(1);
};

// Pump until `pred` holds or `ms` elapse.
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

// The snapshot as { width, height, rgb(x, y) }: an 8- or 16-bit RGB or RGBA
// PNG, not interlaced, which is what ImageIO writes for a window. The raw
// numbers, whatever profile the file carries — the display's, so two
// regions of one capture compare as the display was asked to show them.
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

// what CSS calls these, and so what the bridge's sRGB says they are
const COLOURS = [
  [255, 0, 0], [0, 255, 0], [0, 0, 255], [59, 130, 246], [128, 128, 128], [219, 231, 244],
];
const W = 300; // points
const ROW = 30;
const SWATCH = 40;
const swatchX = (i) => 10 + i * 48;

(async () => {
  native.initApp();
  const win = native.createWindow2({ width: W, height: 120, x: 200, y: 200, title: 'surface-colorspace' });
  native.showWindow(win, false);
  await pumpUntil(() => native.getWindowFrame(win)?.visible === true).catch(() => fail('the window never showed'));
  const scale = native.getWindowFrame(win).scale;
  const root = native.windowRootLayer(win);
  native.setLayerProps(root, { backgroundColor: [1, 1, 1, 1] });

  // one row of the swatches into a surface, in device pixels
  const paint = (s) => {
    native.ctxSetFillColor(s, 1, 1, 1, 1);
    native.ctxFillRect(s, 0, 0, W * scale, ROW * scale);
    COLOURS.forEach(([r, g, b], i) => {
      native.ctxSetFillColor(s, r / 255, g / 255, b / 255, 1);
      native.ctxFillRect(s, swatchX(i) * scale, 0, SWATCH * scale, ROW * scale);
    });
  };
  const row = (y) => {
    const layer = native.createLayer();
    native.setLayerProps(layer, { frame: [0, y, W, ROW] });
    native.addSublayer(root, layer);
    return layer;
  };

  // 1. an IOSurface, presented the way a window's swapchain is
  const io = native.createSurfaceIOSurface(W * scale, ROW * scale, scale);
  native.surfaceLock(io.handle);
  paint(io.handle);
  native.surfaceUnlock(io.handle);
  native.setLayerContentsIOSurface(row(10), io.iosurfaceId);
  // 2. a plain surface, handed over as a CGImage
  const plain = native.createSurface(W * scale, ROW * scale, scale);
  paint(plain);
  native.surfaceToLayer(plain, row(45));
  // 3. a layer colour per swatch
  COLOURS.forEach(([r, g, b], i) => {
    const layer = native.createLayer();
    native.setLayerProps(layer, { frame: [swatchX(i), 80, SWATCH, ROW], backgroundColor: [r / 255, g / 255, b / 255, 1] });
    native.addSublayer(root, layer);
  });
  native.pump2();
  await pumpFor(400);

  const shot = path.join(os.tmpdir(), `appkit-surface-colorspace-${process.pid}.png`);
  if (!native.snapshotWindow(win, shot)) fail('snapshotWindow wrote nothing');
  const png = readPng(shot);
  fs.unlinkSync(shot);
  const k = png.width / W; // the capture's pixels per point
  const top = png.height - Math.round(120 * k); // below the title bar
  const at = (x, y) => png.rgb(Math.round(x * k), top + Math.round(y * k));
  const near = (a, b) => a.every((v, i) => Math.abs(v - b[i]) <= 1);
  const hex = (c) => `#${c.map((v) => v.toString(16).padStart(2, '0')).join('')}`;
  const read = (y) => COLOURS.map((_, i) => at(swatchX(i) + SWATCH / 2, y + ROW / 2));
  const surface = read(10);
  const image = read(45);
  const colour = read(80);

  // A window the WindowServer is not compositing — the session locked, the
  // display asleep — captures as one flat colour, black or white, where
  // every row would agree and the checks below would pass without having
  // looked at anything. Six different colours were drawn.
  if (new Set(image.map(String)).size !== COLOURS.length) {
    fail('the capture is blank: the window was not composited, as on a locked or sleeping display', image);
  }

  let matched = false; // whether the display moved any colour off its sRGB numbers
  COLOURS.forEach((css, i) => {
    if (!near(image[i], colour[i])) fail(`${hex(css)}: a CGImage and a layer colour disagree`, image[i], colour[i]);
    if (!near(surface[i], image[i])) fail(`${hex(css)}: the IOSurface shows`, surface[i], 'where a CGImage of the same pixels shows', image[i]);
    if (!near(image[i], css)) matched = true;
  });
  native.releaseSurface(io.handle);
  native.releaseSurface(plain);
  native.destroyWindow2(win);
  console.log(
    matched
      ? 'surface-colorspace: ok'
      : "surface-colorspace: ok (the display's profile is sRGB, so an unnamed surface would have matched too)",
  );
  process.exit(0);
})().catch((e) => fail(e && e.stack ? e.stack : e));
