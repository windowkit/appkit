'use strict';
// Text at a display's scale: a font made at `size` pixels with `scale`
// answers, in pixels, what the font of `size / scale` points answers in
// points, times the scale — for every query, and every glyph drawn.
//
// A font made at the pixel size alone is a font of that many points to
// CoreText, which reads a face's size-dependent data at its point size: the
// optical size and tracking San Francisco is set at, the tracking Apple
// Color Emoji's `trak` table adds below 29pt. So on a 2x display a 13px
// label was set at 26pt — 8% narrower than AppKit sets it — and a 19px
// emoji was 1em wide where it is 23pt at 19pt. Faces with no such data
// (Helvetica, Menlo) measured the same either way, which is why the gap
// hid.
//
// Checked, at scale 2 against the point-size font: metrics, advances and
// glyph ids; a fallback face and a copy at another size, with other
// variations or features, which keep the scale; fontShapeText's runs; a
// layout's width, lines, runs, wrapping, alignment, letter spacing, carets
// and hit testing; and drawLayout, ctxDrawGlyphs and drawLayoutGradient,
// pixel for pixel against the point-size font drawn under a scaled CTM —
// Apple Color Emoji's bitmaps included, which CoreText draws at the font's
// point size whatever its matrix — and layoutCoverage against drawLayout.
// That the faces checked do differ at the two point sizes is checked too,
// so none of it passes by measuring nothing. Exits 0 when every
// expectation held.
//
// Two answers are not the point-size face's to the last digit, and are held
// to what they are instead. An emoji's advance: CoreText rounds a bitmap
// glyph's advance to a whole pixel of the font it is set in, which is a
// whole point at the point size and half of one at 2x, so a run is up to a
// pixel short of twice its width there (45 against 46 at 19pt) and whatever
// follows it on the line moves with it. And the system face's name: NSFont
// calls the point-size face by its alias, .AppleSystemUIFont, and any copy
// of it — at a scale, or CTFontCreateUIFontForLanguage's own — by the
// PostScript name CoreText answers for both, .SFNS-Regular.

const { readFileSync } = require('fs');
const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('text-scale:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

const S = 2;
const EPS = 1e-3;
const near = (a, b, eps = EPS) => Math.abs(a - b) <= eps;

/** `b` is `a` at the scale: numbers in `px` times S, the rest equal. */
function scaled(a, b, px, label, eps = EPS) {
  for (const key of Object.keys(a)) {
    const x = a[key];
    const y = b[key];
    if (typeof x === 'number') {
      const want = px.includes(key) ? x * S : x;
      ok(near(y, want, eps), `${label}: ${key}`, y, want);
    } else if (key === 'postScriptName' && x === '.AppleSystemUIFont') {
      ok(y === '.SFNS-Regular', `${label}: the system face`, y);
    } else if (typeof x === 'string' || typeof x === 'boolean') {
      ok(x === y, `${label}: ${key}`, y, x);
    }
  }
}

/** How far a measure after `text`'s emoji may be from the point-size one:
 *  a pixel an emoji, the rounding of a bitmap glyph's advance. */
const slack = (text) => ([...text].filter((c) => c === EMOJI).length ? 1.001 : EPS);

const METRICS = ['ascent', 'descent', 'leading', 'capHeight', 'xHeight', 'size'];
const LINE = ['x', 'y', 'width', 'height', 'baseline', 'ascent', 'descent'];
const RUN = ['x', 'width'];

/** A face at `px` points, and at `px` × S pixels with the scale. */
const pair = (families, px, extra = {}) => [
  n.matchFont({ families, size: px, ...extra }),
  n.matchFont({ families, size: px * S, scale: S, ...extra }),
];

const EMOJI = '\u{1F605}';
const TEXTS = [
  'The quick brown fox jumps',
  `Hamburg ${EMOJI} ffi 12`,
  'abc שלום def',
];

// --- the faces checked have size-dependent data ------------------------------
{
  const [, sf] = pair(['system-ui'], 13);
  const sf26 = n.matchFont({ families: ['system-ui'], size: 26 });
  const w = (font, text) => n.createLayout({ spans: [{ text, font }] }).width;
  ok(!near(w(sf, TEXTS[0]), w(sf26, TEXTS[0]), 1), 'SF at 13pt is not SF at 26pt',
    w(sf, TEXTS[0]), w(sf26, TEXTS[0]));
  const [, hv] = pair(['Helvetica'], 19);
  const hv38 = n.matchFont({ families: ['Helvetica'], size: 38 });
  ok(!near(w(hv, EMOJI), w(hv38, EMOJI), 1), 'an emoji at 19pt is not an emoji at 38pt',
    w(hv, EMOJI), w(hv38, EMOJI));
  ok(near(w(hv, 'Helvetica'), w(hv38, 'Helvetica')), 'and Helvetica is Helvetica at either');
}

// --- a face ----------------------------------------------------------------------
for (const [families, px] of [[['system-ui'], 13], [['Helvetica'], 19], [['Menlo'], 11]]) {
  const label = `${families[0]} ${px}`;
  const [a, b] = pair(families, px);
  scaled(n.fontMetrics(a), n.fontMetrics(b), METRICS, `${label} metrics`);
  const glyphs = new Uint16Array(['H', 'a', '0'].map((c) => n.fontGlyphForCodepoint(a, c)));
  ok(['H', 'a', '0'].every((c, i) => n.fontGlyphForCodepoint(b, c) === glyphs[i]), `${label}: the same glyphs`);
  const adv = n.fontGlyphAdvances(a, glyphs);
  const advB = n.fontGlyphAdvances(b, glyphs);
  adv.forEach((x, i) => ok(near(advB[i], x * S), `${label}: advance ${i}`, advB[i], x * S));

  // a copy keeps the scale
  scaled(n.fontMetrics(n.fontWithSize(a, px + 3)), n.fontMetrics(n.fontWithSize(b, (px + 3) * S)),
    METRICS, `${label} fontWithSize`);
  scaled(n.fontMetrics(n.fontApplyVariations(a, { wght: 700 })),
    n.fontMetrics(n.fontApplyVariations(b, { wght: 700 })), METRICS, `${label} variations`);
  const tnum = (f) => n.fontApplyFeatures(f, { tnum: true });
  const w = (font, text) => n.createLayout({ spans: [{ text, font }] }).width;
  ok(near(w(tnum(b), '1111'), w(tnum(a), '1111') * S), `${label}: features keep the scale`,
    w(tnum(b), '1111'), w(tnum(a), '1111') * S);

  // a fallback face is at the scale too
  const fa = n.fontFallbackFor(a, EMOJI);
  const fb = n.fontFallbackFor(b, EMOJI);
  ok(fa && fb, `${label}: an emoji has a fallback face`);
  if (fa && fb) scaled(n.fontMetrics(fa), n.fontMetrics(fb), METRICS, `${label} fallback`);
}

// --- the other ways to a face -------------------------------------------------
{
  const ps = n.fontByPostScriptName('Helvetica-Bold', 17);
  const psB = n.fontByPostScriptName('Helvetica-Bold', 17 * S, S);
  ok(ps && psB, 'fontByPostScriptName finds the face at a scale');
  if (ps && psB) scaled(n.fontMetrics(ps), n.fontMetrics(psB), METRICS, 'fontByPostScriptName');

  const file = ['/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/Supplemental/Arial.ttf']
    .find((f) => { try { readFileSync(f); return true; } catch { return false; } });
  const face = n.fontFromData(readFileSync(file));
  const cg = n.cgFontWithSize(face.cg, 15);
  const cgB = n.cgFontWithSize(face.cg, 15 * S, S);
  scaled(n.fontMetrics(cg), n.fontMetrics(cgB), METRICS, 'cgFontWithSize');
  const w = (font) => n.createLayout({ spans: [{ text: TEXTS[0], font }] }).width;
  ok(near(w(cgB), w(cg) * S), 'a face from data lays out at the scale', w(cgB), w(cg) * S);
}

// --- fontShapeText ---------------------------------------------------------------
for (const text of TEXTS) {
  const [a, b] = pair(['system-ui'], 15);
  for (const spacing of [0, 1.5]) {
    const sa = n.fontShapeText(a, text, { letterSpacing: spacing });
    const sb = n.fontShapeText(b, text, { letterSpacing: spacing * S });
    const label = `fontShapeText ${JSON.stringify(text)} spaced ${spacing}`;
    const eps = slack(text);
    ok(near(sb.width, sa.width * S, eps), `${label}: width`, sb.width, sa.width * S);
    ok(sa.runs.length === sb.runs.length, `${label}: runs`, sa.runs.length, sb.runs.length);
    sa.runs.forEach((ra, i) => {
      const rb = sb.runs[i];
      if (!rb) return;
      ok(ra.glyphs.join() === rb.glyphs.join(), `${label}: run ${i} glyphs`);
      ra.positions.forEach((p, k) => ok(near(rb.positions[k], p * S, eps), `${label}: run ${i} position ${k}`, rb.positions[k], p * S));
      ra.advances.forEach((p, k) => ok(near(rb.advances[k], p * S, eps), `${label}: run ${i} advance ${k}`, rb.advances[k], p * S));
      if (ra.font && rb.font) scaled(n.fontMetrics(ra.font), n.fontMetrics(rb.font), METRICS, `${label}: run ${i} face`);
    });
  }
}

// --- a layout ---------------------------------------------------------------------
const layoutPair = (spans, opts = {}) => {
  const fonts = spans.map((s) => pair(s.families, s.px));
  const make = (k, mul) =>
    n.createLayout({
      ...opts,
      ...(opts.maxWidth ? { maxWidth: opts.maxWidth * mul } : {}),
      spans: spans.map((s, i) => ({
        text: s.text,
        font: fonts[i][k],
        ...(s.letterSpacing ? { letterSpacing: s.letterSpacing * mul } : {}),
      })),
    });
  return [make(0, 1), make(1, S)];
};

const PARAGRAPH = `Pack my box with five dozen liquor jugs ${EMOJI} and then some more`;
const LAYOUTS = [
  ['one span', [{ families: ['system-ui'], px: 13, text: TEXTS[0] }]],
  ['an emoji', [{ families: ['Helvetica'], px: 19, text: `think. ${EMOJI}` }]],
  ['two faces', [
    { families: ['Helvetica'], px: 16, text: 'Helvetica ' },
    { families: ['system-ui'], px: 13, text: `then SF ${EMOJI} ` },
    { families: ['Menlo'], px: 12, text: 'and Menlo' },
  ]],
  ['right to left', [{ families: ['system-ui'], px: 14, text: TEXTS[2] }]],
  ['spaced', [{ families: ['system-ui'], px: 14, text: TEXTS[0], letterSpacing: 2 }]],
  ['wrapped', [{ families: ['system-ui'], px: 14, text: PARAGRAPH }], { maxWidth: 150 }],
  ['centred', [{ families: ['system-ui'], px: 14, text: PARAGRAPH }], { maxWidth: 150, align: 0.5 }],
  ['flush right', [{ families: ['system-ui'], px: 14, text: PARAGRAPH }], { maxWidth: 150, align: 1 }],
  ['set loose', [{ families: ['system-ui'], px: 14, text: PARAGRAPH }], { maxWidth: 150, lineHeight: 1.5 }],
  ['elided', [{ families: ['system-ui'], px: 14, text: PARAGRAPH }], { maxWidth: 150, maxLines: 2, ellipsis: true }],
];

for (const [label, spans, opts] of LAYOUTS) {
  const [la, lb] = layoutPair(spans, opts);
  const text = spans.map((s) => s.text).join('');
  const eps = slack(text);
  ok(near(lb.width, la.width * S, eps), `${label}: width`, lb.width, la.width * S);
  ok(near(lb.height, la.height * S), `${label}: height`, lb.height, la.height * S);
  ok(la.lines.length === lb.lines.length, `${label}: lines`, lb.lines.length, la.lines.length);
  la.lines.forEach((line, i) => {
    const other = lb.lines[i];
    if (!other) return;
    scaled(line, other, LINE, `${label} line ${i}`, eps);
    ok(line.runs.length === other.runs.length, `${label} line ${i}: runs`);
    line.runs.forEach((run, k) => other.runs[k] && scaled(run, other.runs[k], RUN, `${label} line ${i} run ${k}`, eps));
  });
  // carets and hit testing
  for (let index = 0; index <= text.length; index += 3) {
    const ca = n.layoutCaret(la.handle, index);
    const cb = n.layoutCaret(lb.handle, index);
    scaled(ca, cb, ['x', 'y', 'height'], `${label} caret ${index}`, eps);
    const ia = n.layoutIndexAt(la.handle, ca.x + 1, ca.y + ca.height / 2);
    const ib = n.layoutIndexAt(lb.handle, (ca.x + 1) * S, (ca.y + ca.height / 2) * S);
    ok(ia === ib, `${label}: the index at caret ${index}`, ib, ia);
  }
}

// --- drawn -------------------------------------------------------------------------
// The scaled face drawn at the scale, against the point-size face drawn under
// a CTM scaled by it: the way AppKit draws to a Retina backing store.

const W = 560;
const H = 120;
const pixels = (s) => n.ctxGetImageData(s, 0, 0, W, H);

/** How far apart two RGBA buffers are: the largest channel difference, and
 *  how many pixels differ by more than `tol`. */
function apart(p, q, tol = 8) {
  let worst = 0;
  let count = 0;
  for (let i = 0; i < p.length; i += 4) {
    let d = 0;
    for (let c = 0; c < 4; c++) d = Math.max(d, Math.abs(p[i + c] - q[i + c]));
    worst = Math.max(worst, d);
    if (d > tol) count++;
  }
  return { worst, count };
}
/** A raster's ink and the centre of it, a pixel's ink at the pixel's
 *  centre. */
function centre(w, h, at) {
  let sum = 0;
  let sx = 0;
  let sy = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const v = at(x, y);
      sum += v;
      sx += v * (x + 0.5);
      sy += v * (y + 0.5);
    }
  }
  return { sum, x: sx / sum, y: sy / sum };
}
const inked = (p) => {
  let sum = 0;
  for (let i = 3; i < p.length; i += 4) sum += p[i];
  return sum;
};

function compare(label, draw) {
  const a = n.createSurface(W, H, S);
  n.ctxScale(a, S, S);
  n.ctxSetFillColor(a, 0.1, 0.2, 0.6, 1);
  draw(a, 0, 1);
  const b = n.createSurface(W, H, S);
  n.ctxSetFillColor(b, 0.1, 0.2, 0.6, 1);
  draw(b, 1, S);
  const pa = pixels(a);
  const pb = pixels(b);
  ok(inked(pa) > 255 * 200, `${label}: drew something`, inked(pa) / 255);
  const d = apart(pa, pb);
  ok(d.count <= 4, `${label}: the same pixels`, d);
  n.releaseSurface?.(a);
  n.releaseSurface?.(b);
}

// an emoji last on its line, where the rounding of its advance moves nothing
const DRAWN = [
  LAYOUTS[0],
  LAYOUTS[1],
  ['two faces', [
    { families: ['Helvetica'], px: 16, text: 'Helvetica ' },
    { families: ['system-ui'], px: 13, text: 'then SF ' },
    { families: ['Menlo'], px: 12, text: 'and Menlo ' },
    { families: ['Helvetica'], px: 16, text: EMOJI },
  ]],
];
for (const [label, spans] of DRAWN) {
  const fonts = spans.map((s) => pair(s.families, s.px));
  const layout = (k) =>
    n.createLayout({ spans: spans.map((s, i) => ({ text: s.text, font: fonts[i][k] })) });
  const layouts = [layout(0), layout(1)];
  compare(`drawLayout, ${label}`, (s, k, mul) => n.drawLayout(s, layouts[k].handle, 6 * mul, 10 * mul));
  compare(`drawLayoutGradient, ${label}`, (s, k, mul) =>
    n.drawLayoutGradient(s, layouts[k].handle, 6 * mul, 10 * mul, 0, 0, W * mul, 0,
      [0, 0, 0, 1, 1, 1, 0.2, 0.2, 1, 1]));

  // layoutCoverage: the scaled layout's raster is the point-size one at the
  // scale — its box, its ink and where the ink is, the outlines' own
  // coverage being exact geometry — and a bitmap glyph in it is where
  // drawLayout draws it
  const PAD = 3;
  const ca = n.layoutCoverage(layouts[0].handle, PAD);
  const cb = n.layoutCoverage(layouts[1].handle, PAD * S);
  ok(Math.abs(cb.width - ca.width * S) <= 2 && Math.abs(cb.height - ca.height * S) <= 2,
    `layoutCoverage, ${label}: its box`, `${cb.width}x${cb.height}`, `${ca.width}x${ca.height}`);
  const inA = centre(ca.width, ca.height, (x, y) => ca.data[y * ca.width + x]);
  const inB = centre(cb.width, cb.height, (x, y) => cb.data[y * cb.width + x]);
  ok(Math.abs(inB.sum / (inA.sum * S * S) - 1) < 0.03, `layoutCoverage, ${label}: its ink`, inB.sum, inA.sum * S * S);
  // an emoji's ink is a bitmap of another strike at each size: a pixel
  const off = spans.some((s) => s.text.includes(EMOJI)) ? 1 : 0.25;
  ok(Math.abs(inB.x - inA.x * S) < off && Math.abs(inB.y - inA.y * S) < off,
    `layoutCoverage, ${label}: where it is`, inB, inA);
}
{
  const [, b] = pair(['Helvetica'], 19);
  const layout = n.createLayout({ spans: [{ text: EMOJI, font: b }] });
  const c = n.layoutCoverage(layout.handle, 4);
  const drawn = n.createSurface(c.width, c.height, S);
  n.drawLayout(drawn, layout.handle, 4, 4);
  const px = n.ctxGetImageData(drawn, 0, 0, c.width, c.height);
  const covered = centre(c.width, c.height, (x, y) => c.data[y * c.width + x]);
  const onSurface = centre(c.width, c.height, (x, y) => px[(y * c.width + x) * 4 + 3]);
  ok(covered.sum > 255 * 400, 'layoutCoverage: an emoji is covered', covered.sum / 255);
  ok(Math.abs(covered.sum / onSurface.sum - 1) < 0.02 && Math.abs(covered.x - onSurface.x) < 0.1 &&
      Math.abs(covered.y - onSurface.y) < 0.1, 'layoutCoverage: an emoji where drawLayout draws it',
    covered, onSurface);
  n.releaseSurface?.(drawn);
}

// ctxDrawGlyphs: a run's glyphs at origins of the caller's, in pixels
for (const text of [TEXTS[0], `ab cd ${EMOJI}`]) {
  const [a, b] = pair(['system-ui'], 15);
  const shaped = [n.fontShapeText(a, text), n.fontShapeText(b, text)];
  compare(`ctxDrawGlyphs ${JSON.stringify(text)}`, (s, k, mul) => {
    const fonts = [a, b];
    n.ctxDrawGlyphs(s, shaped[k].runs.map((run) => {
      const positions = new Float64Array(run.positions.length);
      for (let i = 0; i < positions.length; i += 2) {
        positions[i] = 6 * mul + run.positions[i];
        positions[i + 1] = 40 * mul - run.positions[i + 1];
      }
      return { font: run.font ?? fonts[k], glyphs: run.glyphs, positions };
    }));
  });
}

if (failed) {
  console.error(`text-scale: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('text-scale: ok');
