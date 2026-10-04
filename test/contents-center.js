'use strict';
// setLayerProps' `contentsRect` and `contentsCenter`: the part of a layer's
// contents it shows, and the part that stretches when they are scaled to
// bounds not their size, the rest keeping its size. A frame whose bounds
// outgrew it — a pane's, the moment its window grows, before a frame of the
// new size is drawn — can then be shown at its size with its last column and
// row carried over the rest, where gravity either stretches the whole frame
// or anchors it and leaves a strip of whatever is under it. Both are unit
// rects named as they look, y down from the window's top. Checked on the
// window's pixels with an IOSurface for contents, the way a pane presents:
// a frame grown, cropped, grown one way and cropped the other, and back to
// stretching; a value that is no unit rect is a TypeError naming its key.
// Exits 0 when every expectation held.

const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('contents-center:', msg, ...rest);
  process.exit(1);
};

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

function throwsType(fn, key, what) {
  let err = null;
  try { fn(); } catch (e) { err = e; }
  if (!(err instanceof TypeError)) fail('accepted ' + what);
  if (!err.message.startsWith(key + ':')) fail(`${what}: the error names no key: ${err.message}`);
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
const shotFile = path.join(os.tmpdir(), `contents-center-${process.pid}.png`);

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
    if (r > 180 && g > 180 && b < 140) return 'yellow';
    if (g > 180 && b > 180 && r < 120) return 'cyan';
    if (r > 180 && g < 120 && b < 120) return 'red';
    if (b > 180 && r < 120 && g < 120) return 'blue';
    if (g > 150 && r < 120 && b < 120) return 'green';
    if (r < 60 && g < 60 && b < 60) return 'black';
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

// An IOSurface `w` by `h` points at the window's scale, its quadrants red,
// blue (top right), green (bottom left) and black, its last column of
// pixels yellow and its last row cyan: the edges a grown frame carries over.
function frameOf(w, h, scale) {
  const W = w * scale, H = h * scale;
  const { handle, iosurfaceId } = native.createSurfaceIOSurface(W, H, scale);
  native.surfaceLock(handle);
  const fill = (x, y, fw, fh, rgb) => {
    native.ctxSetFillColor(handle, rgb[0], rgb[1], rgb[2], 1);
    native.ctxFillRect(handle, x, y, fw, fh);
  };
  fill(0, 0, W / 2, H / 2, [1, 0, 0]);
  fill(W / 2, 0, W / 2, H / 2, [0, 0, 1]);
  fill(0, H / 2, W / 2, H / 2, [0, 0.8, 0]);
  fill(W / 2, H / 2, W / 2, H / 2, [0, 0, 0]);
  fill(W - 1, 0, 1, H, [1, 1, 0]);
  fill(0, H - 1, W, 1, [0, 1, 1]);
  native.surfaceUnlock(handle);
  return { handle, iosurfaceId, W, H };
}

(async () => {
  native.initApp();
  const win = native.createWindow2({ ...PTS, kind: 'borderless', x: 140, y: 140 });
  native.showWindow(win, false);
  const scale = native.windowState(native.windowNumber(win)).scale;
  const root = native.windowRootLayer(win);
  const pane = native.createLayer();
  const frame = frameOf(60, 40, scale);
  const { W, H } = frame;
  commit(() => {
    native.setLayerProps(root, { backgroundColor: [1, 1, 1, 1] });
    native.addSublayer(root, pane);
    native.setLayerProps(pane, { frame: [20, 20, 60, 40], contentsScale: scale });
  });
  native.setLayerContentsIOSurface(pane, frame.iosurfaceId);
  await pumpFor(200);
  const first = shot(win);
  const pixels =
    first(30, 30) === 'red' && first(70, 30) === 'blue' && first(30, 50) === 'green';
  if (!pixels) console.log('contents-center: the snapshot shows no layers here; checking the values only');

  const props = async (p, where, what) => {
    commit(() => native.setLayerProps(pane, p));
    await pumpFor(150);
    if (pixels) expectAt(shot(win), where, what);
  };
  // The middle of the last pixel, a hundredth of one wide: a centre a whole
  // pixel wide stretches what the filter makes between it and the pixel
  // before it, a blend of the two, and one of no width is no centre at all.
  const lastColumn = (w) => [(w - 0.5) / w, 0, 0.01 / w, 1];

  // 1. grown to 120 by 80 with the last pixel the centre: the frame at its
  // size, its last column carried right, its last row down, and the corner
  // pixel into the corner
  await props(
    {
      frame: [20, 20, 120, 80],
      contentsCenter: [(W - 0.5) / W, (H - 0.5) / H, 0.01 / W, 0.01 / H],
    },
    [
      [30, 30, 'red'], [70, 30, 'blue'], [30, 50, 'green'], [70, 50, 'black'],
      [110, 30, 'yellow'], [110, 50, 'yellow'], [135, 30, 'yellow'],
      [30, 90, 'cyan'], [70, 90, 'cyan'],
      [110, 90, 'cyan'],
      [145, 30, 'white'], [30, 105, 'white'],
    ],
    'grown, the last pixel stretched',
  );
  // 2. narrowed to 40 by 30, the part that fits shown at its size
  await props(
    { frame: [20, 20, 40, 30], contentsCenter: null, contentsRect: [0, 0, 40 / 60, 30 / 40] },
    [[30, 30, 'red'], [55, 30, 'blue'], [30, 45, 'green'], [55, 45, 'black'], [70, 30, 'white'], [30, 55, 'white']],
    'cropped',
  );
  // 3. wider and shorter: cropped to 30 high, its last column carried
  // right. The centre is in the shown part's own square.
  await props(
    { frame: [20, 20, 120, 30], contentsRect: [0, 0, 1, 30 / 40], contentsCenter: lastColumn(W) },
    [
      [30, 30, 'red'], [70, 30, 'blue'], [30, 45, 'green'], [70, 45, 'black'],
      [110, 30, 'yellow'], [110, 45, 'yellow'],
      [30, 55, 'white'],
    ],
    'cropped one way, grown the other',
  );
  // 4. the bottom half: y down from the window's top, as it looks
  await props(
    { frame: [20, 20, 60, 20], contentsRect: [0, 0.5, 1, 0.5], contentsCenter: null },
    [[30, 30, 'green'], [70, 30, 'black'], [30, 45, 'white']],
    'the bottom half',
  );
  // 5. both back to the whole, and a grown frame is stretched again
  await props(
    { frame: [20, 20, 120, 80], contentsRect: null, contentsCenter: null },
    [[30, 30, 'red'], [70, 30, 'red'], [110, 30, 'blue'], [30, 90, 'green']],
    'the whole, stretched',
  );

  // 6. what Core Animation holds: a rect that reads the same either way up
  commit(() => native.setLayerProps(pane, { contentsCenter: [0.25, 0.25, 0.5, 0.5] }));
  const held = native.presentationValue(pane, 'contentsCenter');
  if (!Array.isArray(held) || held.join() !== [0.25, 0.25, 0.5, 0.5].join()) {
    fail('contentsCenter as held', held);
  }

  // 7. a value that is no unit rect is a TypeError naming its key, and
  // nothing is applied
  throwsType(() => native.setLayerProps(pane, { contentsRect: [0, 0, 1] }), 'contentsRect', 'three numbers');
  throwsType(() => native.setLayerProps(pane, { contentsCenter: [0, 0, NaN, 1] }), 'contentsCenter', 'NaN');
  throwsType(() => native.setLayerProps(pane, { contentsRect: 'whole' }), 'contentsRect', 'a string');
  throwsType(
    () => native.setLayerProps(pane, { frame: [0, 0, 10, 10], contentsCenter: [0, 0, 1, '1'] }),
    'contentsCenter',
    'a string in the rect',
  );
  native.pump2();
  const bounds = native.presentationValue(pane, 'bounds');
  if (bounds && bounds[2] === 10) fail('a rejected set applied its frame');

  native.destroyWindow2(win);
  console.log(`contents-center: ok${pixels ? ", on the window's pixels too" : ''}`);
  process.exit(0);
})().catch((e) => fail(e && e.stack ? e.stack : e));
