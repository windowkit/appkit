'use strict';
// SF Symbols drawn in a surface (sidorares/react-x11#591): the system's icons
// by name, for a renderer's own content, the way the status item and a menu
// item already take them.
//
// Checked: `symbolSize` answers the symbol's size in points, which grows with
// the point size and the weight, and null for a name the catalogue does not
// know; `ctxDrawSymbol` draws the symbol fitted into its rect, centred, in the
// current fill colour, through the clip and at the global alpha, answers false
// and draws nothing for an unknown name, weighs more at a heavier weight,
// shows less of a variable symbol at a lower value, refuses a name that is not
// a string, and draws the same pixels from a worker as on the main thread.
// Exits 0 when every expectation held.

const { Worker, isMainThread, parentPort } = require('worker_threads');
const { createHash } = require('crypto');
const { native: n } = require('..');

const W = 64;
const H = 64;

/** The symbol drawn red into a fresh surface, after `setup(surface)`. */
function draw(name, options, setup) {
  const s = n.createSurface(W, H, 2);
  n.ctxSetFillColor(s, 1, 0, 0, 1);
  if (setup) setup(s);
  const drawn = n.ctxDrawSymbol(s, name, 8, 8, 48, 48, options);
  return { drawn, px: n.ctxGetImageData(s, 0, 0, W, H) };
}

/** Total alpha, the strongest alpha, and the ink's bounding box. */
function ink(px) {
  let sum = 0;
  let max = 0;
  let x0 = W;
  let y0 = H;
  let x1 = -1;
  let y1 = -1;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const a = px[(y * W + x) * 4 + 3];
      if (!a) continue;
      sum += a;
      max = Math.max(max, a);
      x0 = Math.min(x0, x);
      y0 = Math.min(y0, y);
      x1 = Math.max(x1, x);
      y1 = Math.max(y1, y);
    }
  }
  return { sum, max, box: [x0, y0, x1, y1] };
}

/** One worker-and-main-thread comparison's drawing, hashed. */
function hashed() {
  const s = n.createSurface(96, 96, 2);
  n.ctxSetFillColor(s, 0.2, 0.4, 0.8, 1);
  n.ctxDrawSymbol(s, 'speaker.wave.3.fill', 4, 4, 88, 88, {
    pointSize: 40,
    weight: 600,
  });
  return createHash('sha1')
    .update(n.ctxGetImageData(s, 0, 0, 96, 96))
    .digest('hex');
}

if (!isMainThread) {
  parentPort.postMessage(hashed());
  return;
}

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('symbols:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

// --- measuring --------------------------------------------------------------

const small = n.symbolSize('star.fill', { pointSize: 20 });
const large = n.symbolSize('star.fill', { pointSize: 40 });
ok(small && small.width > 0 && small.height > 0, 'a known symbol has a size', small);
ok(
  large && large.width > small.width * 1.8 && large.height > small.height * 1.8,
  'twice the point size is about twice the size',
  small,
  large,
);
const light = n.symbolSize('star.fill', { pointSize: 40, weight: 100 });
const black = n.symbolSize('star.fill', { pointSize: 40, weight: 900 });
ok(black.width > light.width, 'a heavier weight is wider', light, black);
ok(n.symbolSize('no.such.symbol') === null, 'an unknown name has no size');
ok(n.symbolSize('star.fill').height > 0, 'the options are optional');

// --- drawing ----------------------------------------------------------------

const star = draw('star.fill', { pointSize: 24 });
ok(star.drawn === true, 'a known symbol answers true');
const starInk = ink(star.px);
ok(starInk.max === 255, 'it is drawn opaque', starInk);
const centre = (32 * W + 32) * 4;
ok(
  star.px[centre] === 255 && star.px[centre + 1] === 0 && star.px[centre + 3] === 255,
  'in the fill colour',
  [...star.px.slice(centre, centre + 4)],
);
const [x0, y0, x1, y1] = starInk.box;
ok(x0 >= 8 && y0 >= 8 && x1 < 56 && y1 < 56, 'inside its rect', starInk.box);
ok(
  Math.abs(x0 - (W - 1 - x1)) <= 2 && Math.abs(y0 - (H - 1 - y1)) <= 2,
  'centred in it',
  starInk.box,
);

// over something already drawn: the ink is the symbol's shape, and the
// rest of its rect keeps what was there
const over = draw('star.fill', {}, (s) => {
  n.ctxSetFillColor(s, 1, 1, 1, 1);
  n.ctxFillRect(s, 0, 0, W, H);
  n.ctxSetFillColor(s, 1, 0, 0, 1);
}).px;
const corner = [...over.slice((10 * W + 10) * 4, (10 * W + 10) * 4 + 4)];
ok(
  corner.join() === '255,255,255,255',
  'the background around the shape is left as it was',
  corner,
);
ok(over[centre + 1] === 0, 'and the shape is still the fill colour');

const unknown = draw('no.such.symbol');
ok(unknown.drawn === false, 'an unknown name answers false');
ok(ink(unknown.px).sum === 0, 'and draws nothing');

const blue = n.createSurface(W, H, 2);
n.ctxSetFillColor(blue, 0, 0, 1, 1);
n.ctxDrawSymbol(blue, 'star.fill', 8, 8, 48, 48);
const bluePx = n.ctxGetImageData(blue, 32, 32, 1, 1);
ok(bluePx[2] === 255 && bluePx[0] === 0, 'the colour is the fill colour', [...bluePx]);

const faint = ink(draw('star.fill', {}, (s) => n.ctxSetGlobalAlpha(s, 0.5)).px);
ok(Math.abs(faint.max - 128) <= 1, 'the global alpha applies once', faint.max);

const clipped = draw('star.fill', {}, (s) => {
  n.ctxBeginPath(s);
  n.ctxRect(s, 0, 0, 32, H);
  n.ctxClip(s);
}).px;
let right = 0;
for (let y = 0; y < H; y++) {
  for (let x = 32; x < W; x++) right += clipped[(y * W + x) * 4 + 3];
}
ok(right === 0, 'the clip applies', right);

const thin = ink(draw('circle', { weight: 100 }).px).sum;
const heavy = ink(draw('circle', { weight: 900 }).px).sum;
ok(heavy > thin * 2, 'a heavier weight puts down more ink', thin, heavy);

const quiet = ink(draw('speaker.wave.3.fill', { variableValue: 0 }).px).sum;
const loud = ink(draw('speaker.wave.3.fill', { variableValue: 1 }).px).sum;
ok(quiet < loud, 'a variable symbol shows less at a lower value', quiet, loud);

try {
  n.ctxDrawSymbol(n.createSurface(4, 4, 1), 42, 0, 0, 4, 4);
  fail('a name that is not a string is accepted');
} catch (err) {
  ok(err instanceof TypeError, 'a name that is not a string is a TypeError', err);
}

// --- from a worker ----------------------------------------------------------
//
// A renderer in threaded mode draws from a worker, and a symbol is AppKit's
// NSImage: the same verb there has to draw the same pixels, and not wait on a
// main thread nobody is pumping.

const onMain = hashed();
const worker = new Worker(__filename);
const timer = setTimeout(() => {
  fail('the worker never answered');
  finish();
}, 10000);
worker.on('message', (fromWorker) => {
  clearTimeout(timer);
  ok(fromWorker === onMain, 'a worker draws the same pixels', fromWorker, onMain);
  finish();
});
worker.on('error', (err) => {
  clearTimeout(timer);
  fail('the worker threw', err);
  finish();
});

function finish() {
  if (failed) {
    console.error(`symbols: ${failed} expectation(s) failed`);
    process.exit(1);
  }
  console.log('symbols: ok');
  process.exit(0);
}
