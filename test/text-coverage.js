'use strict';
// A layout's coverage without a surface (sidorares/react-x11#673): how much
// of each pixel its glyphs cover, one byte a pixel, for text drawn where a
// surface is not, such as a GL surface's label atlas or a signed distance
// field.
//
// Checked: the raster is the layout's box in whole pixels with the pad round
// it, the origin at (pad, pad), and a fractional pad rounds up; the ink is the
// outlines' own, the same as the glyph outlines filled as a path
// (drawLayoutGradient's clip, in a flat opaque ink) to a percent of its weight,
// a tenth of a pixel of its place and a few levels an edge pixel, which
// CoreText's glyph rasterizer is not, and in the place drawLayout draws it to
// under a pixel; a line nudged by a twentieth of a pixel moves its ink with it
// and is not held on a grid; a span's colour plays no part, a translucent one
// covering what an opaque one does; a colour glyph comes out as its
// silhouette; two glyphs on top of each other cover a pixel once; every line
// is covered; an empty layout covers nothing; anything that is not a layout
// answers null; and a worker gets the same bytes as the main thread. Exits 0
// when every expectation held.

const { Worker, isMainThread, parentPort } = require('worker_threads');
const { createHash } = require('crypto');
const { native: n } = require('..');

const PAD = 4;
const font = (size, families = ['system-ui']) => n.matchFont({ families, size });
const layoutOf = (text, size = 32, extra = {}) =>
  n.createLayout({ spans: [{ text, font: font(size), ...extra }] });

/** One worker-and-main-thread comparison's coverage, hashed. */
function hashed() {
  const coverage = n.layoutCoverage(layoutOf('Hamburg 12 ffi', 22).handle, 3);
  return `${coverage.width}x${coverage.height} ${createHash('sha1').update(coverage.data).digest('hex')}`;
}

if (!isMainThread) {
  parentPort.postMessage(hashed());
  return;
}

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('text-coverage:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

/** Total ink and its centre, over a width × height raster read by `at`. */
function ink(width, height, at) {
  let sum = 0;
  let sx = 0;
  let sy = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const a = at(x, y);
      sum += a;
      sx += a * x;
      sy += a * y;
    }
  }
  return { sum, x: sum ? sx / sum : NaN, y: sum ? sy / sum : NaN };
}

const inkOf = ({ width, height, data }) => ink(width, height, (x, y) => data[y * width + x]);

/**
 * The same layout drawn at (pad, pad) onto a transparent surface the size of
 * its coverage, as its alpha, one byte a pixel: through the glyph outlines
 * filled as a path (`outlines`), or through drawLayout, as the screen gets it
 * (`drawn`).
 */
function drawnAlpha(layout, { width, height }, how, pad = PAD) {
  const s = n.createSurface(width, height, 1);
  n.ctxSetFillColor(s, 1, 1, 1, 1);
  if (how === 'outlines') {
    n.drawLayoutGradient(s, layout.handle, pad, pad, 0, 0, width, 0, [0, 1, 1, 1, 1, 1, 1, 1, 1, 1]);
  } else {
    n.drawLayout(s, layout.handle, pad, pad);
  }
  const px = n.ctxGetImageData(s, 0, 0, width, height);
  const alpha = new Uint8Array(width * height);
  for (let i = 0; i < alpha.length; i++) alpha[i] = px[i * 4 + 3];
  return { width, height, data: alpha };
}

const drawnInk = (layout, coverage, how, pad) => inkOf(drawnAlpha(layout, coverage, how, pad));

const fixed = (v) => v.toFixed(2);

// --- the raster -------------------------------------------------------------

const layout = layoutOf('Hamburg 12');
const coverage = n.layoutCoverage(layout.handle, PAD);
ok(coverage, 'no coverage for a layout');
ok(
  coverage.width === Math.ceil(layout.width) + PAD * 2,
  'the layout box with the pad round it',
  coverage.width,
  layout.width,
);
ok(coverage.height === Math.ceil(layout.height) + PAD * 2, 'and as tall', coverage.height, layout.height);
ok(coverage.data instanceof Uint8Array, 'one byte a pixel', coverage.data);
ok(coverage.data.length === coverage.width * coverage.height, 'row-major, width × height', coverage.data.length);

let full = 0;
let grey = 0;
for (const a of coverage.data) {
  if (a === 255) full++;
  else if (a > 0) grey++;
}
console.log(`coverage  : ${coverage.width}x${coverage.height}, ${full} whole, ${grey} grey`);
ok(full > 50, 'no pixel is wholly covered: this is not coverage', full);
ok(grey > 50, 'no grey pixel: the glyphs are aliased', grey);
for (let x = 0; x < coverage.width; x++) {
  if (coverage.data[x] !== 0) {
    fail('ink in the top pad row, at', x);
    break;
  }
}
for (let y = 0; y < coverage.height; y++) {
  if (coverage.data[y * coverage.width] !== 0) {
    fail('ink in the left pad column, at', y);
    break;
  }
}

const plain = n.layoutCoverage(layout.handle);
ok(
  plain.width === Math.ceil(layout.width) && plain.height === Math.ceil(layout.height),
  'no pad unless asked',
  plain.width,
  plain.height,
);
const moved = inkOf(coverage);
const unmoved = inkOf(plain);
ok(
  Math.abs(moved.x - PAD - unmoved.x) < 0.01 && Math.abs(moved.y - PAD - unmoved.y) < 0.01,
  'the pad moves the ink by the pad: the origin is at (pad, pad)',
  moved,
  unmoved,
);
ok(n.layoutCoverage(layout.handle, 2.2).width === coverage.width - 2, 'a fractional pad rounds up');
ok(n.layoutCoverage(layout.handle, -3).width === plain.width, 'a negative pad is none');
ok(n.layoutCoverage(layout.handle, NaN).width === plain.width, 'and so is NaN');

// --- the outlines' own ink, where drawing puts it ---------------------------

const outlines = drawnInk(layout, coverage, 'outlines');
console.log(
  `coverage  : ink ${moved.sum} centred at ${fixed(moved.x)},${fixed(moved.y)}; ` +
    `outlines ${outlines.sum} at ${fixed(outlines.x)},${fixed(outlines.y)}`,
);
ok(
  Math.abs(moved.sum / outlines.sum - 1) < 0.02,
  'not the ink of the outlines filled as a path: smoothed, or gamma applied',
  moved.sum,
  outlines.sum,
);
ok(
  Math.abs(moved.x - outlines.x) < 0.1 && Math.abs(moved.y - outlines.y) < 0.1,
  'not where the outlines are',
  moved,
  outlines,
);
const drawn = drawnInk(layout, coverage, 'drawn');
console.log(`drawLayout: ink ${drawn.sum} centred at ${fixed(drawn.x)},${fixed(drawn.y)}`);
ok(
  Math.abs(moved.x - drawn.x) < 0.75 && Math.abs(moved.y - drawn.y) < 0.75,
  'not where drawLayout puts the ink',
  moved,
  drawn,
);

// Edge by edge. CoreText's glyph rasterizer, even with font smoothing off, is
// not the outlines' coverage: it shrinks a small glyph's counters, and over
// Menlo at 14px its edge pixels are 5-10 levels off the outlines' on average,
// where the outlines' own coverage is about 2 (CoreGraphics' path fill and the
// accumulation differ by that much).
const small = n.createLayout({ spans: [{ text: 'Hamburg abg 12', font: font(14, ['Menlo']) }] });
const smallCoverage = n.layoutCoverage(small.handle, PAD);
const smallOutlines = drawnAlpha(small, smallCoverage, 'outlines');
let edges = 0;
let off = 0;
for (let i = 0; i < smallOutlines.data.length; i++) {
  const a = smallOutlines.data[i];
  if (a > 0 && a < 255) edges++;
  off += Math.abs(smallCoverage.data[i] - a);
}
console.log(`coverage  : Menlo 14, ${fixed(off / edges)} levels off the outlines an edge pixel`);
ok(edges > 100, 'precondition: the outlines have edges', edges);
ok(off / edges < 3.5, "the edges are not the outlines': a glyph cache's, or smoothed", off / edges);

// A line nudged by a twentieth of a pixel at a time, right-aligned in a
// growing width: its ink follows the outlines' at every step, where a glyph
// cache's subpixel grid would hold it and then jump.
const stem = font(18);
let worst = 0;
for (let k = 0; k <= 20; k++) {
  const nudged = n.createLayout({ spans: [{ text: 'l', font: stem }], maxWidth: 40 + k * 0.05, align: 1 });
  const c = n.layoutCoverage(nudged.handle, 40);
  worst = Math.max(worst, Math.abs(inkOf(c).x - drawnInk(nudged, c, 'outlines', 40).x));
}
ok(worst < 0.03, 'a line nudged by a fraction of a pixel is held on a grid', worst);

// --- ink is the caller's ----------------------------------------------------

const same = (a, b) => a.width === b.width && a.height === b.height && Buffer.compare(a.data, b.data) === 0;
ok(
  same(n.layoutCoverage(layoutOf('Hamburg 12', 32, { color: [1, 0, 0, 0.25] }).handle, PAD), coverage),
  "a translucent span's coverage is not an opaque one's",
);
ok(
  same(n.layoutCoverage(layoutOf('Hamburg 12', 32, { color: [0, 0, 1, 1] }).handle, PAD), coverage),
  "a coloured span's coverage is not an uncoloured one's",
);
// Apple Color Emoji is bitmaps with no outlines: its glyph comes out as the
// image's silhouette, between the two letters it sits between.
const emoji = layoutOf('a\u{1F600}b', 24);
const withEmoji = inkOf(n.layoutCoverage(emoji.handle));
const without = inkOf(n.layoutCoverage(layoutOf('ab', 24).handle));
ok(withEmoji.sum > without.sum * 2, 'a colour glyph covers nothing', withEmoji.sum, without.sum);

// --- overlaps, lines, and nothing -------------------------------------------

// Two glyphs on top of each other, the second spaced back by the first's
// advance: where one covers a pixel wholly, the two cover it wholly too, once
// and not twice.
const ell = font(64);
const [advance] = n.fontGlyphAdvances(ell, [n.fontGlyphForCodepoint(ell, 'l'.codePointAt(0))]);
const one = n.layoutCoverage(n.createLayout({ spans: [{ text: 'l', font: ell }] }).handle, PAD);
const stacked = n.layoutCoverage(
  n.createLayout({
    spans: [
      { text: 'l', font: ell, letterSpacing: -advance },
      { text: 'l', font: ell },
    ],
  }).handle,
  PAD,
);
ok(stacked.width === one.width && stacked.height === one.height, "precondition: one glyph's box", stacked, one);
let whole = 0;
let twice = 0;
for (let i = 0; i < one.data.length; i++) {
  if (one.data[i] !== 255) continue;
  whole++;
  if (stacked.data[i] !== 255) twice++;
}
ok(whole > 100, 'precondition: a stem wholly covers pixels', whole);
ok(twice === 0, 'a pixel two glyphs cover is not covered once', twice);


const twoLines = layoutOf('one\ntwo', 20);
ok(twoLines.lines.length === 2, 'precondition: two lines', twoLines.lines.length);
const both = n.layoutCoverage(twoLines.handle);
const rows = (y0, y1) => {
  let s = 0;
  for (let y = y0; y < y1; y++) for (let x = 0; x < both.width; x++) s += both.data[y * both.width + x];
  return s;
};
const middle = Math.round(twoLines.lines[1].y);
ok(
  rows(0, middle) > 0 && rows(middle, both.height) > 0,
  'a line with no ink',
  rows(0, middle),
  rows(middle, both.height),
);

const empty = n.createLayout({ spans: [] });
ok(n.layoutCoverage(empty.handle) === null, 'an empty layout with no pad has no raster to answer');
const padded = n.layoutCoverage(empty.handle, 2);
ok(
  padded && padded.width === 4 && padded.height === 4 && padded.data.every((a) => a === 0),
  'an empty layout with a pad covers nothing',
  padded,
);
for (const notALayout of [undefined, null, 42, {}, 'layout']) {
  ok(n.layoutCoverage(notALayout, 2) === null, 'something that is not a layout has coverage', notALayout);
}

// --- from a worker ----------------------------------------------------------

const mainHash = hashed();
const worker = new Worker(__filename);
const timeout = setTimeout(() => {
  fail('the worker did not answer');
  finish();
}, 10000);
worker.on('message', (answer) => {
  ok(answer === mainHash, 'a worker gets other bytes than the main thread', answer, mainHash);
  finish();
});
worker.on('error', (err) => {
  fail('the worker threw', err);
  finish();
});

function finish() {
  clearTimeout(timeout);
  worker.terminate();
  if (failed) {
    console.error(`text-coverage: ${failed} expectation(s) failed`);
    process.exit(1);
  }
  console.log('text-coverage: ok');
  process.exit(0);
}
