'use strict';
// ctxSetImageSmoothing: how an image drawn scaled or turned is resampled —
// the 2D canvas's imageSmoothingEnabled and imageSmoothingQuality.
//
// Checked: 'none' draws a source scaled up as its pixels, and every other
// quality draws the colours between them; a context starts at 'medium';
// ctxSave and ctxRestore scope the setting; and a draw at 1:1 on whole
// pixels is the same at every quality. The timing line is a report, not an
// expectation: a surface drawn a tile at a time through a matrix, each tile
// under its own clip, as a box in perspective is drawn, at 'medium' and at
// 'low'. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('image-smoothing:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

const all = (s, w, h) => Buffer.from(n.ctxGetImageData(s, 0, 0, w, h));

/** Four pixels, black and white in a check. */
function check() {
  const s = n.createSurface(2, 2, 1);
  n.ctxSetFillColor(s, 1, 1, 1, 1);
  n.ctxFillRect(s, 0, 0, 2, 2);
  n.ctxSetFillColor(s, 0, 0, 0, 1);
  n.ctxFillRect(s, 0, 0, 1, 1);
  n.ctxFillRect(s, 1, 1, 1, 1);
  return s;
}

/** The check drawn eight times its size, at `quality` where one is given,
 *  through `around` where it is: the destination's pixels. */
function scaled(quality, around) {
  const src = check();
  const dst = n.createSurface(16, 16, 1);
  if (around) around(dst);
  if (quality) n.ctxSetImageSmoothing(dst, quality);
  n.ctxDrawSurface(dst, src, 0, 0, 2, 2, 0, 0, 16, 16);
  const pixels = all(dst, 16, 16);
  n.releaseSurface(dst);
  n.releaseSurface(src);
  return pixels;
}

/** How many pixels are neither black nor white. */
function between(pixels) {
  let count = 0;
  for (let i = 0; i < pixels.length; i += 4) {
    const v = pixels[i];
    if (v !== 0 && v !== 255) count++;
  }
  return count;
}

// --- a quality is how the pixels between are drawn ------------------------------
{
  ok(between(scaled('none')) === 0, "'none' draws the source's own pixels");
  for (const q of ['low', 'medium', 'high']) {
    ok(between(scaled(q)) > 0, `'${q}' draws the colours between them`);
  }
  ok(
    Buffer.compare(scaled(null), scaled('medium')) === 0,
    "a context starts at 'medium'",
  );
}

// --- the graphics state holds it -------------------------------------------------
{
  const restored = scaled(null, (dst) => {
    n.ctxSave(dst);
    n.ctxSetImageSmoothing(dst, 'none');
    n.ctxRestore(dst);
  });
  ok(
    Buffer.compare(restored, scaled('medium')) === 0,
    'ctxRestore puts back the quality ctxSave kept',
  );
  const kept = scaled(null, (dst) => {
    n.ctxSetImageSmoothing(dst, 'none');
    n.ctxSave(dst);
    n.ctxRestore(dst);
  });
  ok(between(kept) === 0, 'and one set before the save stays');
}

// --- a draw at 1:1 resamples nothing ---------------------------------------------
{
  const src = n.createSurface(24, 16, 1);
  for (let y = 0; y < 16; y++) {
    for (let x = 0; x < 24; x++) {
      n.ctxSetFillColor(src, x / 24, y / 16, ((x + y) % 4) / 4, 1);
      n.ctxFillRect(src, x, y, 1, 1);
    }
  }
  const at = (q) => {
    const dst = n.createSurface(40, 30, 1);
    if (q) n.ctxSetImageSmoothing(dst, q);
    n.ctxDrawSurface(dst, src, 0, 0, 24, 16, 7, 5, 24, 16);
    const pixels = all(dst, 40, 30);
    n.releaseSurface(dst);
    return pixels;
  };
  const medium = at(null);
  for (const q of ['none', 'low', 'high']) {
    ok(Buffer.compare(at(q), medium) === 0, `a 1:1 draw at '${q}' is the same`);
  }
  n.releaseSurface(src);
}

// --- what it costs a surface drawn a tile at a time -------------------------------
{
  // a panel turned about its upright in a perspective, as `<Html>` draws
  // one: tiles of 40px, each under its clip and the matrix of the plane
  // over it, foreshortened a little more the further right it is
  const W = 1400;
  const H = 1120;
  const T = 40;
  const src = n.createSurface(W, H, 1);
  n.ctxSetFillColor(src, 0.2, 0.3, 0.4, 1);
  n.ctxFillRect(src, 0, 0, W, H);
  n.ctxSetFillColor(src, 1, 0.8, 0, 1);
  for (let i = 0; i < 60; i++) n.ctxFillRect(src, (i * 37) % W, (i * 53) % H, 30, 18);
  const dst = n.createSurface(W + 200, H + 200, 1);
  const tiles = [];
  for (let y = 0; y < H; y += T) {
    for (let x = 0; x < W * 0.8; x += T) {
      const k = 0.8 - (x / W) * 0.2;
      const sk = (y / H - 0.5) * 0.15;
      tiles.push({
        x: Math.round(50 + x * 0.8),
        y: 50 + y,
        m: [k, sk * 0.3, 0, 1, 50 + x * (1 - k), 50 - sk * 30],
      });
    }
  }
  const draw = (q) => {
    const start = process.hrtime.bigint();
    for (const t of tiles) {
      n.ctxSave(dst);
      n.ctxSetImageSmoothing(dst, q);
      n.ctxBeginPath(dst);
      n.ctxRect(dst, t.x, t.y, T, T);
      n.ctxClip(dst);
      n.ctxTransform(dst, ...t.m);
      n.ctxDrawSurface(dst, src, 0, 0, W, H, 0, 0, W, H);
      n.ctxRestore(dst);
    }
    return Number(process.hrtime.bigint() - start) / 1e6;
  };
  draw('low'); // warm
  const medium = draw('medium');
  const low = draw('low');
  console.log(
    `image-smoothing: ${tiles.length} tiles of a ${W}x${H} surface, ` +
      `${medium.toFixed(1)}ms at 'medium', ${low.toFixed(1)}ms at 'low'`,
  );
  n.releaseSurface(dst);
  n.releaseSurface(src);
}

if (failed) {
  console.error(`image-smoothing: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('image-smoothing: ok');
