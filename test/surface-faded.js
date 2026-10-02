'use strict';
// ctxDrawSurfaceFaded: ctxDrawSurface under an alpha below 1, drawn from the
// source's pixels scaled by the alpha rather than through CoreGraphics'
// image-at-an-alpha path, which costs some fifteen times the same draw at 1.
//
// Checked: the faded draw comes to the colours the CGImage draw under
// ctxSetGlobalAlpha does, within a unit a premultiplied channel — at an
// offset, from a source sub-rect, under a clip, over a translucent and a
// transparent ground, at alphas across the range — and within three scaled
// up, through the filter; the alpha the destination was set to is what it
// has after; an alpha of 1, a fractional source rect, a rect past the
// source, an IOSurface source and a surface onto itself are drawn as
// ctxDrawSurface draws them; and an alpha of 0 draws nothing. The timing
// line is a report, not an expectation. Exits 0 when every expectation
// held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('surface-faded:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => { if (!cond) fail(msg, ...rest); };

const all = (s, w, h) => Buffer.from(n.ctxGetImageData(s, 0, 0, w, h));

/** A source whose every pixel is a function of where it is, translucent in
 *  places, so a draw one row or column off — or faded twice — differs. */
function source(w, h) {
  const s = n.createSurface(w, h, 1);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      n.ctxSetFillColor(s, x / w, y / h, ((x + y) % 8) / 8, (x * 7 + y * 3) % 5 === 0 ? 0.5 : 1);
      n.ctxFillRect(s, x, y, 1, 1);
    }
  }
  return s;
}

const W = 96;
const H = 64;

/** `src` drawn into a fresh destination over `ground`, at `alpha`: by the
 *  faded verb, or by ctxDrawSurface under ctxSetGlobalAlpha as before. */
function draw(src, rect, alpha, { faded, ground = [0.17, 0.54, 0.24, 1], clip } = {}) {
  const dst = n.createSurface(W, H, 1);
  n.ctxSetFillColor(dst, ...ground);
  n.ctxFillRect(dst, 0, 0, W, H);
  if (clip) {
    n.ctxRect(dst, ...clip);
    n.ctxClip(dst);
  }
  n.ctxSetGlobalAlpha(dst, alpha);
  if (faded) n.ctxDrawSurfaceFaded(dst, src, ...rect, alpha);
  else n.ctxDrawSurface(dst, src, ...rect);
  const pixels = all(dst, W, H);
  n.releaseSurface(dst);
  return pixels;
}

/** The largest difference of one premultiplied channel between two
 *  readbacks. ctxGetImageData answers straight colour, which divides a
 *  pixel's colour by its alpha: a unit of difference at an alpha of 77 reads
 *  back as three, so the colours are multiplied back before comparing. */
function worst(a, b) {
  let most = 0;
  for (let i = 0; i < a.length; i += 4) {
    for (let c = 0; c < 4; c++) {
      const pa = c === 3 ? a[i + 3] : Math.round((a[i + c] * a[i + 3]) / 255);
      const pb = c === 3 ? b[i + 3] : Math.round((b[i + c] * b[i + 3]) / 255);
      most = Math.max(most, Math.abs(pa - pb));
    }
  }
  return most;
}

// --- the faded draw is the draw under the alpha --------------------------------
{
  const src = source(40, 24);
  const cases = [
    ['at the origin', [0, 0, 40, 24, 0, 0, 40, 24], 0.6],
    ['at an offset', [0, 0, 40, 24, 21, 13, 40, 24], 0.6],
    ['from a sub-rect', [5, 3, 20, 11, 30, 30, 20, 11], 0.6],
    ['scaled up', [0, 0, 40, 24, 4, 4, 80, 48], 0.6],
    ['hanging off the edges', [0, 0, 40, 24, W - 12, H - 9, 40, 24], 0.6],
    ['nearly transparent', [0, 0, 40, 24, 10, 10, 40, 24], 0.05],
    ['nearly opaque', [0, 0, 40, 24, 10, 10, 40, 24], 0.97],
  ];
  for (const [name, rect, alpha] of cases) {
    const faded = draw(src, rect, alpha, { faded: true });
    const drawn = draw(src, rect, alpha, { faded: false });
    const most = worst(faded, drawn);
    // resampled, the unit of rounding either draw makes goes through
    // CoreGraphics' medium filter, which sharpens it to as much as three
    const allowed = rect[6] !== rect[2] || rect[7] !== rect[3] ? 3 : 1;
    ok(most <= allowed, `${name}: a channel off by ${most}`);
  }
  const clipped = [0, 0, 40, 24, 10, 10, 40, 24];
  ok(worst(
    draw(src, clipped, 0.6, { faded: true, clip: [20, 15, 18, 9] }),
    draw(src, clipped, 0.6, { faded: false, clip: [20, 15, 18, 9] }),
  ) <= 1, 'under a clip');
  for (const ground of [[0.2, 0.3, 0.9, 0.4], [0, 0, 0, 0]]) {
    const most = worst(
      draw(src, clipped, 0.6, { faded: true, ground }),
      draw(src, clipped, 0.6, { faded: false, ground }),
    );
    ok(most <= 1, `over a ground of alpha ${ground[3]}: a channel off by ${most}`);
  }
  // and it drew something: the ground alone would be one colour
  const faded = draw(src, clipped, 0.6, { faded: true });
  const ground = draw(src, clipped, 0, { faded: false });
  ok(worst(faded, ground) > 40, 'the source landed');
  n.releaseSurface(src);
}

// --- the alpha the destination was set to is the one it keeps -----------------
{
  const src = source(8, 8);
  const dst = n.createSurface(16, 16, 1);
  n.ctxSetGlobalAlpha(dst, 0.5);
  n.ctxDrawSurfaceFaded(dst, src, 0, 0, 8, 8, 0, 0, 8, 8, 0.5);
  n.ctxSetFillColor(dst, 1, 0, 0, 1);
  n.ctxFillRect(dst, 10, 10, 4, 4);
  const [, , , a] = [...n.ctxGetImageData(dst, 11, 11, 1, 1)];
  ok(a === 128, `a fill after it is drawn at the alpha set before it: ${a}`);
  n.releaseSurface(src);
  n.releaseSurface(dst);
}

// --- what is drawn as ctxDrawSurface draws it -----------------------------------
{
  const src = source(40, 24);
  const same = (name, rect, alpha) => {
    const faded = draw(src, rect, alpha, { faded: true });
    const drawn = draw(src, rect, alpha, { faded: false });
    ok(worst(faded, drawn) === 0, `${name}: not the draw it stands in for`);
  };
  same('an alpha of 1', [0, 0, 40, 24, 3, 3, 40, 24], 1);
  same('an alpha of 0', [0, 0, 40, 24, 3, 3, 40, 24], 0);
  same('a fractional source rect', [0.5, 0, 20, 10, 3, 3, 20, 10], 0.6);
  same('a source rect past the source', [30, 10, 20, 20, 3, 3, 20, 20], 0.6);
  n.releaseSurface(src);

  const io = n.createSurfaceIOSurface(16, 16, 1, true);
  n.surfaceLock(io.handle);
  n.ctxSetFillColor(io.handle, 0, 0, 1, 1);
  n.ctxFillRect(io.handle, 0, 0, 16, 16);
  n.surfaceUnlock(io.handle);
  const rect = [0, 0, 16, 16, 5, 5, 16, 16];
  ok(worst(
    draw(io.handle, rect, 0.6, { faded: true }),
    draw(io.handle, rect, 0.6, { faded: false }),
  ) === 0, 'an IOSurface source is drawn through the CGImage');
  n.releaseSurface(io.handle);

  const onto = source(16, 16);
  n.ctxSetGlobalAlpha(onto, 0.6);
  n.ctxDrawSurfaceFaded(onto, onto, 0, 0, 8, 8, 8, 8, 8, 8, 0.6);
  ok(true, 'a surface onto itself is drawn, not refused');
  n.releaseSurface(onto);
}

// --- what it costs, for the record ---------------------------------------------
{
  const w = 556;
  const h = 300;
  const src = n.createSurface(w, h, 2);
  n.ctxSetFillColor(src, 0.96, 0.94, 0.9, 1);
  n.ctxFillRect(src, 0, 0, w, h);
  const dst = n.createSurface(1400, 1000, 2);
  const time = (faded) => {
    n.ctxSetGlobalAlpha(dst, 0.6);
    for (let i = 0; i < 20; i++) {
      if (faded) n.ctxDrawSurfaceFaded(dst, src, 0, 0, w, h, 100, 100, w, h, 0.6);
      else n.ctxDrawSurface(dst, src, 0, 0, w, h, 100, 100, w, h);
    }
    const start = process.hrtime.bigint();
    for (let i = 0; i < 200; i++) {
      if (faded) n.ctxDrawSurfaceFaded(dst, src, 0, 0, w, h, 100, 100, w, h, 0.6);
      else n.ctxDrawSurface(dst, src, 0, 0, w, h, 100, 100, w, h);
    }
    return Number(process.hrtime.bigint() - start) / 1e6 / 200;
  };
  const slow = time(false);
  const fast = time(true);
  console.log(
    `surface-faded: a ${w}x${h} surface at alpha .6, ` +
      `${slow.toFixed(3)}ms drawn under the alpha, ${fast.toFixed(3)}ms faded`,
  );
  n.releaseSurface(src);
  n.releaseSurface(dst);
}

if (failed) {
  console.error(`surface-faded: ${failed} check(s) failed`);
  process.exit(1);
}
console.log('surface-faded OK');
