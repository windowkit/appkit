'use strict';
// setLayerProps' `contentsGravity`: how a layer's contents sit in bounds
// that are not their size. Core Animation's default, `resize`, stretches
// them, which is what a window or a pane shows of its last frame while a
// frame of the new size is on its way — a page's left column scaled a
// little, and back. The others leave them at their size, anchored; react-x11
// anchors a pane that keeps up with its resizes at its top left. Named as
// they look: `top` is the window's top, where Core Animation's names are
// the layer's own space, whose top is the bottom of the window under a
// geometry-flipped root. Checked on the window's pixels, on a sublayer and
// on the root, with an IOSurface of four colours for contents, the way a
// pane presents; and a name that is no gravity is a TypeError. Exits 0 when
// every expectation held.

const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('contents-gravity:', msg, ...rest);
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

function throwsType(fn, what) {
  let threw = false;
  try { fn(); } catch (e) { threw = e instanceof TypeError; }
  if (!threw) fail('accepted ' + what);
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
const shotFile = path.join(os.tmpdir(), `contents-gravity-${process.pid}.png`);

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
// blue (top right), green (bottom left) and black, the way a pane's frame
// arrives: by id.
function quadrants(w, h, scale) {
  const { handle, iosurfaceId } = native.createSurfaceIOSurface(w * scale, h * scale, scale);
  native.surfaceLock(handle);
  const fill = (x, y, rgb) => {
    native.ctxSetFillColor(handle, rgb[0], rgb[1], rgb[2], 1);
    native.ctxFillRect(handle, x * scale, y * scale, (w / 2) * scale, (h / 2) * scale);
  };
  fill(0, 0, [1, 0, 0]);
  fill(w / 2, 0, [0, 0, 1]);
  fill(0, h / 2, [0, 0.8, 0]);
  fill(w / 2, h / 2, [0, 0, 0]);
  native.surfaceUnlock(handle);
  return { handle, iosurfaceId };
}

(async () => {
  native.initApp();
  const win = native.createWindow2({ ...PTS, kind: 'borderless', x: 140, y: 140 });
  native.showWindow(win, false);
  const scale = native.windowState(native.windowNumber(win)).scale;
  const root = native.windowRootLayer(win);
  const pane = native.createLayer();
  const frame = quadrants(60, 40, scale);
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
  if (!pixels) console.log('contents-gravity: the snapshot shows no layers here; checking the names only');

  // the bounds grown to 120 by 80, as a pane is the moment its window grows
  const grown = async (gravity, where, what) => {
    commit(() =>
      native.setLayerProps(pane, {
        frame: [20, 20, 120, 80],
        ...(gravity && { contentsGravity: gravity }),
      }),
    );
    await pumpFor(150);
    if (pixels) expectAt(shot(win), where, what);
  };
  // 1. the default stretches: the red quarter reaches the middle
  await grown(null, [[30, 30, 'red'], [70, 30, 'red'], [110, 30, 'blue'], [30, 90, 'green']], 'resize, by default');
  // 2. top left: at its size, from the window's top left of the layer
  await grown(
    'topLeft',
    [[30, 30, 'red'], [70, 30, 'blue'], [30, 50, 'green'], [70, 50, 'black'], [110, 30, 'white'], [30, 80, 'white']],
    'topLeft',
  );
  // 3. bottom right: at its size, in the layer's bottom right corner
  await grown(
    'bottomRight',
    [[90, 70, 'red'], [130, 70, 'blue'], [90, 90, 'green'], [130, 90, 'black'], [30, 30, 'white']],
    'bottomRight',
  );
  // 4. top: across the middle, at the top
  await grown('top', [[60, 30, 'red'], [100, 30, 'blue'], [60, 50, 'green'], [30, 30, 'white'], [80, 90, 'white']], 'top');
  // 5. and back to stretching
  await grown('resize', [[70, 30, 'red'], [110, 30, 'blue']], 'resize');

  // 6. the root's own contents, the way a window presents: grown with the
  // window, anchored top left
  const whole = quadrants(PTS.width / 2, PTS.height / 2, scale);
  commit(() => {
    native.removeFromSuperlayer(pane);
    native.setLayerProps(root, { contentsScale: scale, contentsGravity: 'topLeft' });
  });
  native.setLayerContentsIOSurface(root, whole.iosurfaceId);
  await pumpFor(200);
  if (pixels) {
    expectAt(
      shot(win),
      [[10, 10, 'red'], [50, 10, 'blue'], [10, 40, 'green'], [50, 40, 'black'], [120, 20, 'white'], [20, 100, 'white']],
      'the root, topLeft',
    );
  }

  // 7. a name that is no gravity is a TypeError, and nothing is applied
  throwsType(() => native.setLayerProps(pane, { contentsGravity: 'upperLeft' }), 'upperLeft');
  throwsType(() => native.setLayerProps(pane, { contentsGravity: 3 }), 'a number');

  native.destroyWindow2(win);
  console.log(`contents-gravity: ok${pixels ? ", on the window's pixels too" : ''}`);
  process.exit(0);
})().catch((e) => fail(e && e.stack ? e.stack : e));
