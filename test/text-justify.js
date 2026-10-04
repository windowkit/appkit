'use strict';
// createLayout's `justify`: lines set to fill `maxWidth`, what each leaves
// of it shared equally among its word separators — the spaces and no-break
// spaces before the white space it ends on — after the typesetter has
// broken them, so a kept typesetter is broken and spaced again at another
// width and nothing is shaped. Bits: 1 for every line that goes on to
// another, 2 for the paragraph's last and each a forced break ends.
//
// Checked: the lines are where they are unjustified, each but the last as
// wide as the width; each space is that line's share wider and nothing else
// is, nor the space a line ends on; a no-break space is a separator, and a
// line with none keeps its alignment; `2` and `3` set the lines theirs; a
// right-to-left line fills from the right; a line an ellipsis ends is set
// as it is; carets and hit tests agree with the spacing; a kept typesetter
// justifies; and drawn, a justified line's glyphs before its first space are
// the unjustified line's, pixel for pixel, its last word ending at the
// width. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('text-justify:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};
const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;

const font = n.matchFont({ families: ['Helvetica'], size: 16 });
const WIDTH = 200;
const WORDS = 'the quick brown fox jumps over the lazy dog and back again ';
const layoutOf = (text, extra = {}) =>
  n.createLayout({ spans: [{ text, font }], maxWidth: WIDTH, ...extra });
const caret = (layout, i) => n.layoutCaret(layout.handle, i);

// --- lines --------------------------------------------------------------------------

{
  const text = WORDS.repeat(3);
  const plain = layoutOf(text);
  const justified = layoutOf(text, { justify: 1 });
  ok(plain.lines.length > 2, 'a paragraph of several lines', plain.lines.length);
  ok(
    JSON.stringify(justified.lines.map((l) => [l.start, l.end])) ===
      JSON.stringify(plain.lines.map((l) => [l.start, l.end])),
    'broken where it was'
  );
  for (const line of justified.lines.slice(0, -1)) {
    ok(near(line.width, WIDTH), 'a line as wide as the width', line.width);
    ok(near(line.x, 0), 'from its start', line.x);
    const right = Math.max(...line.runs.map((r) => r.x + r.width));
    // the runs reach the width, and the space the line ends on past it
    ok(right >= WIDTH - 1e-6, 'its runs reach the width', right);
  }
  ok(near(justified.lines.at(-1).width, plain.lines.at(-1).width), 'the last as it was');
  ok(near(justified.width, WIDTH), 'the layout as wide as the width', justified.width);

  // each space inside the first line one share further on, nothing else
  const line = plain.lines[0];
  const spaces = [];
  for (let i = line.start; i < line.end; i++) if (text[i] === ' ') spaces.push(i);
  const inside = spaces.filter((i) => i < line.end - 1);
  const share = (WIDTH - line.width) / inside.length;
  ok(share > 0, 'room to share', share);
  let k = 0;
  for (let i = line.start; i < line.end; i++) {
    if (text[i - 1] === ' ' && i - 1 < line.end - 1) k++;
    const a = caret(plain, i).x;
    const b = caret(justified, i).x;
    ok(near(b, a + k * share, 1e-4), `caret ${i}`, b, a, k);
    // and the point there finds the index again
    const hit = n.layoutIndexAt(justified.handle, b + 0.01, 1);
    ok(hit === i, `hit ${i}`, hit);
  }
  // a point inside a widened space lands at one of its edges
  const s0 = inside[0];
  const mid = (caret(justified, s0).x + caret(justified, s0 + 1).x) / 2;
  const at = n.layoutIndexAt(justified.handle, mid - 0.5, 1);
  ok(at === s0 || at === s0 + 1, 'inside a space', at);
}

// --- what is a separator, and which lines ----------------------------------------

{
  const text = 'aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll';
  const plain = layoutOf(text);
  const justified = layoutOf(text, { justify: 1 });
  const nb = text.indexOf(' ');
  const before = caret(plain, nb + 1).x - caret(plain, nb).x;
  const after = caret(justified, nb + 1).x - caret(justified, nb).x;
  ok(after > before + 0.5, 'a no-break space is widened', before, after);

  // a word cut to fit, a line at a time: no separator, centred as ever
  const cut = n.createLayout({
    spans: [{ text: 'Supercalifragilisticexpialidociouslylongword and more', font }],
    maxWidth: 100,
    align: 0.5,
    justify: 1
  });
  const first = cut.lines[0];
  ok(first.width < 99, 'a piece of the word', first.width);
  ok(near(first.x, (100 - first.width) / 2, 1e-3), 'centred', first.x, first.width);

  const ended = `${WORDS.repeat(2)}\n${WORDS.repeat(2)}`;
  const lines = layoutOf(ended).lines;
  const stop = lines.findIndex((l) => ended[l.end - 1] === '\n');
  ok(stop > 0 && stop < lines.length - 1, 'a line a forced break ends', stop);
  const full = (justify) => layoutOf(ended, { justify }).lines.map((l) => near(l.width, WIDTH));
  const rest = full(1);
  ok(!rest[stop] && !rest.at(-1), '1: not the line a break ends, nor the last');
  ok(rest.every((f, i) => f || i === stop || i === rest.length - 1), '1: the others');
  const last = full(2);
  ok(last[stop] && last.at(-1), '2: the line a break ends, and the last');
  ok(last.every((f, i) => !f || i === stop || i === last.length - 1), '2: no other');
  ok(full(3).every(Boolean), '3: every line');
  const separated = layoutOf(`${WORDS.slice(0, 30)} ${WORDS}`, { justify: 1 });
  ok(near(separated.lines[0].width, WIDTH), 'a line separator is no forced break');
}

// --- right to left, an ellipsis, a kept typesetter --------------------------------

{
  const text = 'שלום עולם זה טקסט בעברית '.repeat(4);
  const rtl = layoutOf(text, { rtl: true, align: 1, justify: 1 });
  ok(rtl.lines.length > 1, 'a right-to-left paragraph of lines', rtl.lines.length);
  for (const line of rtl.lines.slice(0, -1)) {
    ok(near(line.width, WIDTH), 'as wide as the width', line.width);
    const left = Math.min(...line.runs.map((r) => line.x + r.x));
    const right = Math.max(...line.runs.map((r) => line.x + r.x + r.width));
    ok(right <= WIDTH + 1e-3 && right >= WIDTH - 1e-3, 'to the right edge', right);
    ok(left <= 1e-3, 'from the left edge, or the space it ends on past it', left);
  }

  const cut = layoutOf(WORDS.repeat(3), { justify: 1, maxLines: 2, ellipsis: true });
  ok(near(cut.lines[0].width, WIDTH), 'a line before the cut is justified');
  const uncut = layoutOf(WORDS.repeat(3), { maxLines: 2, ellipsis: true });
  ok(near(cut.lines[1].width, uncut.lines[1].width), 'the one the ellipsis ends is set as it is', cut.lines[1].width);

  const kept = layoutOf(WORDS.repeat(3), { keep: true });
  const again = n.createLayout({ typesetter: kept.typesetter, maxWidth: 160, justify: 1 });
  ok(again.lines.length > 2 && near(again.lines[0].width, 160), 'a kept typesetter, justified at another width');
  n.releaseTypesetter(kept.typesetter);
}

// --- at a display's scale ------------------------------------------------------------

{
  // a font made at its pixel size under a matrix of the scale: separators
  // found and widened in pixels, as its runs are measured
  const scaled = n.fontByPostScriptName('Helvetica', 32, 2);
  const text = WORDS.repeat(3);
  const lay = (justify) =>
    n.createLayout({ spans: [{ text, font: scaled }], maxWidth: 2 * WIDTH, justify });
  const plain = lay(0);
  const justified = lay(1);
  ok(
    JSON.stringify(justified.lines.map((l) => [l.start, l.end])) ===
      JSON.stringify(plain.lines.map((l) => [l.start, l.end])),
    'at 2x, broken where it was'
  );
  for (const line of justified.lines.slice(0, -1)) {
    ok(near(line.width, 2 * WIDTH), 'at 2x, as wide as the width', line.width);
    const right = Math.max(...line.runs.map((r) => r.x + r.width));
    ok(right >= 2 * WIDTH - 1e-6, 'at 2x, its runs reach the width', right);
  }
  const e = justified.lines[0].end;
  ok(near(n.layoutCaret(justified.handle, e - 1).x, 2 * WIDTH, 1e-3), 'at 2x, the last word ends at the width');
}

// --- drawn ---------------------------------------------------------------------------

{
  const W = 240;
  const H = 30;
  const draw = (layout) => {
    const s = n.createSurface(W, H, 1);
    n.ctxClearRect(s, 0, 0, W, H);
    n.ctxSetFillColor(s, 0, 0, 0, 1);
    n.drawLayout(s, layout.handle, 10, 2);
    const out = Buffer.from(n.ctxGetImageData(s, 0, 0, W, H));
    n.releaseSurface(s);
    return out;
  };
  const text = WORDS.repeat(2);
  const plain = layoutOf(text);
  const justified = layoutOf(text, { justify: 1 });
  const a = draw(plain);
  const b = draw(justified);
  // the first word, before the first space moves anything, the same pixels
  const firstSpace = caret(plain, text.indexOf(' ')).x;
  const upTo = Math.floor(10 + firstSpace);
  let same = true;
  for (let y = 0; y < H && same; y++) {
    for (let x = 0; x < upTo; x++) {
      const i = (y * W + x) * 4;
      if (a[i + 3] !== b[i + 3]) {
        same = false;
        break;
      }
    }
  }
  ok(same, 'the first word drawn as the unjustified line draws it');
  const inkRight = (px) => {
    let right = -1;
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) if (px[(y * W + x) * 4 + 3] > 128) right = Math.max(right, x);
    }
    return right;
  };
  ok(inkRight(a) < 10 + WIDTH - 6, 'unjustified, short of the width', inkRight(a));
  const r = inkRight(b);
  ok(r >= 10 + WIDTH - 3 && r <= 10 + WIDTH, 'justified, its last word at the width', r);
}

if (failed) {
  console.error(`text-justify: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('text-justify: ok');
