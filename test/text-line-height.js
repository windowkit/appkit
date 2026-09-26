'use strict';
// Where a line's glyphs sit in its line box (`createLayout`'s `lineHeight`).
// The model is ntk's, which is CSS's: the box is the line's natural height —
// ascent, descent and the font's line gap — times the multiplier, and
// whatever it has beyond the glyphs' ascent and descent is split evenly above
// and below them, half-leading. A multiplier below one takes the same from
// both sides, so the glyphs overflow a short line evenly, and 0 is a box of no
// height rather than an option left unset. react-x11 draws one tree with this
// engine or with ntk's, and the two have to agree: a paragraph set at 1.5 sat
// at the top of its lines here and in their middle on X11.
//
// Checked: for a face with a line gap and two without one, at multipliers
// from 0 to 3, each line's box is its natural height times the multiplier,
// the natural height counts the line gap, the lines stack box on box, the
// layout is as tall as its boxes, and the baseline splits the leading evenly;
// at the default a face with no line gap sets its baseline where it always
// did; an absent multiplier is 1, and so is a negative or NaN one; and the ink
// moves with the baseline — drawn at 3, a line's glyphs are where the same
// line at 1 put them lowered by the half-leading the multiplier added, and at
// 0 they are raised by half a line. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('text-line-height:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};
const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;

// Arial carries a line gap on macOS, half a pixel at 16px; the system face
// and Menlo carry none
const faces = ['Arial', 'system-ui', 'Menlo'].map((family) => {
  const font = n.matchFont({ families: [family], size: 16 });
  return { family, font, gap: n.fontMetrics(font).leading };
});
ok(faces[0].gap > 0, 'Arial has a line gap to test with', faces[0].gap);

const TEXT = 'Hamburg\nHxg\nlast line';
const layoutOf = (font, extra = {}) =>
  n.createLayout({ spans: [{ text: TEXT, font }], ...extra });

// --- the geometry -------------------------------------------------------------

for (const { family, font, gap } of faces) {
  const natural = layoutOf(font, { lineHeight: 1 }).lines.map((l) => l.height);
  for (const [i, line] of layoutOf(font).lines.entries()) {
    ok(
      near(natural[i], line.ascent + line.descent + gap),
      `${family}: a line's natural height counts the line gap`,
      natural[i],
      line.ascent + line.descent + gap,
    );
    if (gap === 0) {
      ok(
        near(line.baseline, line.y + line.ascent),
        `${family}: with no line gap, the default baseline is where it was`,
      );
    }
  }
  for (const mul of [0, 0.25, 0.8, 1, 1.5, 3]) {
    const layout = layoutOf(font, { lineHeight: mul });
    ok(layout.lines.length === 3, `${family} at ${mul}: three lines`, layout.lines.length);
    let y = 0;
    for (const [i, line] of layout.lines.entries()) {
      ok(
        near(line.height, natural[i] * mul),
        `${family} at ${mul}: the box is the natural height times the multiplier`,
        line.height,
        natural[i] * mul,
      );
      ok(near(line.y, y), `${family} at ${mul}: the lines stack box on box`, line.y, y);
      const above = line.baseline - line.ascent - line.y;
      const below = line.y + line.height - (line.baseline + line.descent);
      ok(
        near(above, below),
        `${family} at ${mul}: the leading is split evenly above and below`,
        above,
        below,
      );
      y += line.height;
    }
    ok(
      near(layout.height, y),
      `${family} at ${mul}: the layout is as tall as its lines`,
      layout.height,
      y,
    );
  }
  const geometry = (extra) => JSON.stringify(layoutOf(font, extra).lines);
  const one = geometry({ lineHeight: 1 });
  ok(geometry({}) === one, `${family}: an absent multiplier is 1`);
  ok(geometry({ lineHeight: undefined }) === one, `${family}: so is an undefined one`);
  ok(
    geometry({ lineHeight: -2 }) === one && geometry({ lineHeight: NaN }) === one,
    `${family}: and so is one that is not a multiplier`,
  );
}

// --- the ink ------------------------------------------------------------------

const W = 80;
const H = 140;
const TOP = 50;

/** The first row a one-line layout's ink reaches, drawn with its top at TOP. */
function inkTop(font, lineHeight) {
  const layout = n.createLayout({ spans: [{ text: 'HH', font }], lineHeight });
  const s = n.createSurface(W, H, 1);
  n.ctxClearRect(s, 0, 0, W, H);
  n.ctxSetFillColor(s, 0, 0, 0, 1);
  n.drawLayout(s, layout.handle, 0, TOP);
  const px = n.ctxGetImageData(s, 0, 0, W, H);
  n.releaseSurface(s);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) if (px[(y * W + x) * 4 + 3] > 127) return y;
  }
  return -1;
}

for (const { family, font } of faces) {
  const natural = n.createLayout({ spans: [{ text: 'HH', font }] }).lines[0].height;
  const atOne = inkTop(font, 1);
  ok(atOne > 0, `${family}: the line draws`, atOne);
  // a pixel either way: the threshold row of an edge that is not on the grid
  const lowered = inkTop(font, 3) - atOne;
  ok(
    Math.abs(lowered - natural) <= 1,
    `${family}: at 3 the glyphs sit a natural line height lower, in the middle of their box`,
    lowered,
    natural,
  );
  const raised = atOne - inkTop(font, 0);
  ok(
    Math.abs(raised - natural / 2) <= 1,
    `${family}: at 0 they sit half a line higher, across the line they have none of`,
    raised,
    natural / 2,
  );
}

if (failed) {
  console.error(`text-line-height: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('text-line-height: ok');
