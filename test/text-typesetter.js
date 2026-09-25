'use strict';
// A paragraph's typesetter, kept (`createLayout`'s `keep`, `typesetter` and
// `packed`, and `releaseTypesetter`): most of a layout is the text becoming
// glyphs, and a layout of the same paragraph at another width breaks the
// same glyphs into other lines.
//
// Checked: a layout made from a kept typesetter is the layout the spans
// would have made — every line and run, at several widths, flush settings,
// line heights and an elided last line, over fonts, colours, letter spacing,
// an emoji and a hard break — and draws the same pixels; right-to-left text
// stays right to left; the packed geometry is the unpacked geometry, number
// for number; `keep` returns nothing extra when it is off; an empty
// paragraph keeps a typesetter that lays out no lines; a released
// typesetter is refused, and releasing it again is not an error.
// Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('text-typesetter:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

const body = n.matchFont({ families: ['system-ui'], size: 15 });
const bold = n.matchFont({ families: ['system-ui'], size: 15, weight: 700 });
const mono = n.matchFont({ families: ['Menlo', 'monospace'], size: 13 });
const spans = [
  { text: 'A paragraph whose words are set in ', font: body },
  { text: 'three faces', font: bold, color: [0.8, 0.1, 0.1, 1] },
  { text: ', with ', font: body },
  { text: 'spaced code()', font: mono, letterSpacing: 1.5 },
  { text: ' and an emoji 😀 before a hard break.\nThen a second line of it, ', font: body },
  { text: 'long enough to wrap at every width below.', font: body },
];

const geometry = (layout) =>
  JSON.stringify({ width: layout.width, height: layout.height, lines: layout.lines });

// --- the same layout, at every option ---------------------------------------

const kept = n.createLayout({ spans, maxWidth: 420, keep: true });
ok(kept.typesetter !== undefined, 'keep returns the typesetter');
ok(
  geometry(kept) === geometry(n.createLayout({ spans, maxWidth: 420 })),
  'keeping it changes nothing about the layout it came with',
);
ok(
  n.createLayout({ spans, maxWidth: 420 }).typesetter === undefined,
  'no typesetter unless it is asked for',
);

const options = [];
for (const maxWidth of [undefined, 600, 300, 180, 97.5]) {
  for (const align of [0, 0.5, 1]) options.push({ maxWidth, align });
}
options.push({ maxWidth: 240, lineHeight: 1.5 });
options.push({ maxWidth: 240, maxLines: 2, ellipsis: true });
options.push({ maxWidth: 240, maxLines: 3 });
for (const opts of options) {
  const fresh = n.createLayout({ spans, ...opts });
  const again = n.createLayout({ typesetter: kept.typesetter, ...opts });
  ok(
    geometry(again) === geometry(fresh),
    'a layout from the kept typesetter is the fresh one',
    JSON.stringify(opts),
  );
}

// …and draws what the fresh one draws: the fonts and colours are the
// typesetter's, not the call's
const pixels = (layout, w, h) => {
  const s = n.createSurface(w, h, 1);
  n.ctxClearRect(s, 0, 0, w, h);
  n.ctxSetFillColor(s, 0, 0, 0, 1);
  n.drawLayout(s, layout.handle, 0, 0);
  return Buffer.from(n.ctxGetImageData(s, 0, 0, w, h));
};
{
  const fresh = n.createLayout({ spans, maxWidth: 260 });
  const again = n.createLayout({ typesetter: kept.typesetter, maxWidth: 260 });
  const w = Math.ceil(fresh.width) + 2;
  const h = Math.ceil(fresh.height) + 2;
  ok(pixels(fresh, w, h).equals(pixels(again, w, h)), 'the same pixels');
}

// --- right to left ----------------------------------------------------------

{
  const rtlSpans = [{ text: 'שלום עולם, זו פסקה שנשברת לכמה שורות', font: body }];
  const keptRtl = n.createLayout({ spans: rtlSpans, rtl: true, keep: true });
  for (const maxWidth of [400, 120]) {
    const fresh = n.createLayout({ spans: rtlSpans, rtl: true, maxWidth, align: 1 });
    const again = n.createLayout({ typesetter: keptRtl.typesetter, maxWidth, align: 1 });
    ok(geometry(again) === geometry(fresh), 'right to left, at', maxWidth);
    ok(again.lines.every((l) => l.runs.every((r) => r.rtl)), 'and its runs say so');
  }
}

// --- packed -------------------------------------------------------------------

for (const opts of [{ maxWidth: 200 }, { maxWidth: 200, maxLines: 2, ellipsis: true }, {}]) {
  const plain = n.createLayout({ spans, ...opts });
  const packed = n.createLayout({ typesetter: kept.typesetter, packed: true, ...opts });
  ok(packed.lines === undefined, 'packed has no line objects');
  ok(packed.lineData instanceof Float64Array && packed.runData instanceof Float64Array, 'but two arrays');
  const lines = [];
  for (let i = 0, r = 0; i < packed.lineData.length; i += 10) {
    const d = packed.lineData;
    const runs = [];
    for (let k = 0; k < d[i + 9]; k++, r += 5) {
      const q = packed.runData;
      runs.push({ x: q[r], width: q[r + 1], start: q[r + 2], end: q[r + 3], rtl: q[r + 4] === 1 });
    }
    lines.push({
      x: d[i], y: d[i + 1], width: d[i + 2], height: d[i + 3], baseline: d[i + 4],
      ascent: d[i + 5], descent: d[i + 6], start: d[i + 7], end: d[i + 8], runs,
    });
  }
  ok(
    JSON.stringify(lines) === JSON.stringify(plain.lines),
    'the packed geometry is the line objects, number for number',
    JSON.stringify(opts),
  );
  ok(packed.width === plain.width && packed.height === plain.height, 'and the size');
}

// --- empty, and released ----------------------------------------------------

{
  const empty = n.createLayout({ spans: [{ text: '', font: body }], keep: true });
  ok(empty.typesetter !== undefined, 'an empty paragraph keeps one too');
  const again = n.createLayout({ typesetter: empty.typesetter, maxWidth: 100 });
  ok(again.lines.length === 0 && again.height === 0, 'which lays out nothing');
}

n.releaseTypesetter(kept.typesetter);
try {
  n.createLayout({ typesetter: kept.typesetter, maxWidth: 200 });
  fail('a released typesetter is laid out');
} catch (err) {
  ok(/released/.test(err.message), 'a released typesetter is refused', err.message);
}
n.releaseTypesetter(kept.typesetter);
try {
  n.releaseTypesetter({});
  fail('a non-typesetter is released');
} catch (err) {
  ok(err instanceof TypeError, 'releasing a non-typesetter is a TypeError', err);
}

if (failed) {
  console.error(`text-typesetter: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('text-typesetter: ok');
