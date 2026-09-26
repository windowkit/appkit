'use strict';
// A line's width leaves out the white space it ends on (`createLayout`'s
// `width`, and each line's). The space hangs past the line, as ntk measures
// it and as CSS has it; CoreText counts it in, so a paragraph ending in a
// space measured a space wider here than on X11, a box sized to it grew by
// one, and every wrapped line counted the space it broke at.
//
// Checked: text measures the same with one trailing space, several, a tab,
// or none;
// each line of a wrapped paragraph is as wide as its words laid out alone; a
// line of nothing but spaces is 0 wide; flush right still sets each line's
// ink against the edge; and nothing drawn changes. Exits 0 when every
// expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('text-line-width:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};
const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;

const font = n.matchFont({ families: ['Arial'], size: 20 });
const layoutOf = (text, extra = {}) =>
  n.createLayout({ spans: [{ text, font }], ...extra });

// --- trailing space ------------------------------------------------------------

const bare = layoutOf('ab');
for (const text of ['ab ', 'ab   ', 'ab\t']) {
  const spaced = layoutOf(text);
  ok(near(spaced.width, bare.width), 'a trailing space is not measured', JSON.stringify(text), spaced.width, bare.width);
  ok(near(spaced.lines[0].width, bare.lines[0].width), 'nor in its line', JSON.stringify(text));
}
const blank = layoutOf('   ');
ok(near(blank.lines[0].width, 0) && near(blank.width, 0), 'a line of spaces is 0 wide', blank.width);

// --- wrapped ---------------------------------------------------------------------

const text = 'alpha beta gamma delta epsilon';
const wrapped = layoutOf(text, { maxWidth: 120 });
ok(wrapped.lines.length >= 3, 'the paragraph wraps', wrapped.lines.length);
let widest = 0;
for (const line of wrapped.lines) {
  const words = text.slice(line.start, line.end).trimEnd();
  const alone = layoutOf(words).width;
  ok(near(line.width, alone, 1e-3), 'a wrapped line is as wide as its words', JSON.stringify(words), line.width, alone);
  widest = Math.max(widest, line.width);
}
ok(near(wrapped.width, widest), 'and the paragraph as its widest line');

const right = layoutOf(text, { maxWidth: 120, align: 1 });
for (const line of right.lines) {
  ok(Math.abs(line.x + line.width - 120) < 0.5, 'flush right sets the ink against the edge', line.x, line.width);
}

// --- drawn -------------------------------------------------------------------------

const pixels = (layout) => {
  const s = n.createSurface(80, 40, 1);
  n.ctxClearRect(s, 0, 0, 80, 40);
  n.ctxSetFillColor(s, 0, 0, 0, 1);
  n.drawLayout(s, layout.handle, 2, 4);
  const out = Buffer.from(n.ctxGetImageData(s, 0, 0, 80, 40));
  n.releaseSurface(s);
  return out;
};
ok(pixels(layoutOf('ab ')).equals(pixels(bare)), 'a trailing space draws nothing');

if (failed) {
  console.error(`text-line-width: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('text-line-width: ok');
