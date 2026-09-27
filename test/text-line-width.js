'use strict';
// A line's width leaves out the white space it ends on (`createLayout`'s
// `width`, and each line's). The space hangs past the line, as ntk measures
// it and as CSS has it; CoreText counts it in, so a paragraph ending in a
// space measured a space wider here than on X11, a box sized to it grew by
// one, and every wrapped line counted the space it broke at.
//
// Checked: text measures the same with one trailing space, several, a tab,
// a line break or none, and a no-break space it ends on is measured, as CSS
// measures it;
// each line of a wrapped paragraph is as wide as its words laid out alone; a
// line of nothing but spaces is 0 wide; a word too wide for the line breaks
// between its clusters, and runs on whole where not even one fits; flush right still sets each line's
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
for (const text of ['ab ', 'ab   ', 'ab\t', 'ab\n', 'ab \n']) {
  const spaced = layoutOf(text);
  ok(near(spaced.width, bare.width), 'a trailing space is not measured', JSON.stringify(text), spaced.width, bare.width);
  ok(near(spaced.lines[0].width, bare.lines[0].width), 'nor in its line', JSON.stringify(text));
}
const blank = layoutOf('   ');
ok(near(blank.lines[0].width, 0) && near(blank.width, 0), 'a line of spaces is 0 wide', blank.width);

// --- a no-break space -------------------------------------------------------------
// is not white space a line hangs: CSS measures it wherever it stands, and
// CTLineGetTrailingWhitespaceWidth counted it in with the spaces.

const nbsp = layoutOf('\u00a0ab').width - bare.width;
ok(nbsp > 1, 'the face has a no-break space', nbsp);
ok(near(layoutOf('ab\u00a0').width, bare.width + nbsp, 0.01), 'a trailing no-break space is measured', layoutOf('ab\u00a0').width, bare.width + nbsp);
ok(near(layoutOf('ab\u00a0 ').width, bare.width + nbsp, 0.01), 'and a space after it still hangs', layoutOf('ab\u00a0 ').width);

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

// --- a word too wide for its line -------------------------------------------------
// breaks between its clusters where some of it fits, as ntk breaks it. Where not
// even its first cluster fits, CoreText gave the line that one cluster anyway,
// and at a width of 1 — how a layout is asked for its longest word — a word came
// out a letter a line. It runs on to the next place a line may break instead, as
// ntk lets it and as CSS has it.

const glued = layoutOf('ab\u00a0cd', { maxWidth: 1 });
ok(glued.lines.length === 1, 'a word with no break in it is one line', glued.lines.length);
ok(near(glued.width, layoutOf('ab\u00a0cd').width), 'as wide as it is');
const each = layoutOf('ab cdef', { maxWidth: 1 });
ok(each.lines.length === 2, 'a line a word', each.lines.length);
ok(near(each.width, layoutOf('cdef').width), 'and the paragraph as its longest word', each.width);
const split = layoutOf('abcdefghijklmnop', { maxWidth: 40 });
ok(split.lines.length > 1, 'a word part of which fits still breaks inside it', split.lines.length);
for (const line of split.lines) {
  ok(line.width <= 40 + 1e-6, 'each piece fits', line.width);
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
