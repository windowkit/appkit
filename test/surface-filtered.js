'use strict';
// ctxDrawSurfaceFiltered: ctxDrawSurface through a CSS filter list, run by
// vImage — colour matrices over straight colour, each clamped before the
// next, an alpha, and a Gaussian blur of premultiplied colour with nothing
// past the source rect, as react-x11's src/backend/filter.js runs them in
// JavaScript.
//
// Checked against the same filter run on the CPU here: grayscale, invert,
// sepia, a hue turn, two matrices whose first runs out of range (the clamp
// between them), an alpha, over translucent and transparent pixels, from a
// source sub-rect, scaled, and under the destination's clip; a blur's
// centre, its reach past the rect and a transparent edge; an empty rect
// answers false and draws nothing. The timing lines are a report, not an
// expectation. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('surface-filtered:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => { if (!cond) fail(msg, ...rest); };

if (typeof n.ctxDrawSurfaceFiltered !== 'function') {
  console.error('surface-filtered: no ctxDrawSurfaceFiltered');
  process.exit(1);
}

const all = (s, w, h) => Buffer.from(n.ctxGetImageData(s, 0, 0, w, h));

/** A source whose every pixel is a function of where it is, translucent and
 *  transparent in places. */
function source(w, h) {
  const s = n.createSurface(w, h, 1);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const a = (x * 7 + y * 3) % 11 === 0 ? 0 : (x + y) % 3 === 0 ? 0.5 : 1;
      if (!a) continue;
      n.ctxSetFillColor(s, x / w, y / h, ((x + y) % 8) / 8, a);
      n.ctxFillRect(s, x, y, 1, 1);
    }
  }
  return s;
}

const unit = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
/** react-x11's filterPixels: straight RGBA 0–255 through the matrices. */
function cpuColour(px, filter) {
  const out = Buffer.from(px);
  for (let i = 0; i < out.length; i += 4) {
    const a = out[i + 3];
    if (!a) continue;
    let r = out[i] / 255;
    let g = out[i + 1] / 255;
    let b = out[i + 2] / 255;
    for (const m of filter.matrices) {
      const r1 = m[0] * r + m[1] * g + m[2] * b + m[3];
      const g1 = m[4] * r + m[5] * g + m[6] * b + m[7];
      const b1 = m[8] * r + m[9] * g + m[10] * b + m[11];
      r = unit(r1);
      g = unit(g1);
      b = unit(b1);
    }
    out[i] = Math.round(r * 255);
    out[i + 1] = Math.round(g * 255);
    out[i + 2] = Math.round(b * 255);
    out[i + 3] = Math.round(a * filter.alpha);
  }
  return out;
}

/** The largest difference of one premultiplied channel between two
 *  readbacks (straight colour divides by alpha, which magnifies a unit). */
function worst(a, b, skip = () => false) {
  let most = 0;
  let at = -1;
  for (let i = 0; i < a.length; i += 4) {
    if (skip(i / 4)) continue;
    for (let c = 0; c < 4; c++) {
      const pa = c === 3 ? a[i + 3] : Math.round((a[i + c] * a[i + 3]) / 255);
      const pb = c === 3 ? b[i + 3] : Math.round((b[i + c] * b[i + 3]) / 255);
      const d = Math.abs(pa - pb);
      if (d > most) { most = d; at = i / 4; }
    }
  }
  return { most, at };
}

const row = (r, g, b) => [...r, ...g, ...b];
const GRAYSCALE = row([0.2126, 0.7152, 0.0722, 0], [0.2126, 0.7152, 0.0722, 0], [0.2126, 0.7152, 0.0722, 0]);
const INVERT = row([-1, 0, 0, 1], [0, -1, 0, 1], [0, 0, -1, 1]);
const SEPIA = row([0.393, 0.769, 0.189, 0], [0.349, 0.686, 0.168, 0], [0.272, 0.534, 0.131, 0]);
const BRIGHT = row([2.5, 0, 0, 0], [0, 2.5, 0, 0], [0, 0, 2.5, 0]);
const HALF = row([0.5, 0, 0, 0], [0, 0.5, 0, 0], [0, 0, 0.5, 0]);
const t = (Math.PI * 60) / 180;
const [c, s] = [Math.cos(t), Math.sin(t)];
const HUE = row(
  [0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0],
  [0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.14, 0.072 - c * 0.072 - s * 0.283, 0],
  [0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0],
);

// --- colour functions: the filtered draw is the CPU's ----------------------
{
  const W = 48;
  const H = 32;
  const src = source(W, H);
  const before = all(src, W, H);
  const cases = {
    grayscale: { matrices: [GRAYSCALE], alpha: 1, blur: 0 },
    invert: { matrices: [INVERT], alpha: 1, blur: 0 },
    sepia: { matrices: [SEPIA], alpha: 1, blur: 0 },
    'hue-rotate': { matrices: [HUE], alpha: 1, blur: 0 },
    'clamped between': { matrices: [BRIGHT, HALF], alpha: 1, blur: 0 },
    'opacity alone': { matrices: [], alpha: 0.4, blur: 0 },
    'invert at an alpha': { matrices: [INVERT], alpha: 0.6, blur: 0 },
  };
  for (const [name, filter] of Object.entries(cases)) {
    const dst = n.createSurface(W, H, 1);
    const drew = n.ctxDrawSurfaceFiltered(dst, src, 0, 0, W, H, 0, 0, W, H, filter);
    ok(drew === true, `${name}: answered ${drew}`);
    const got = all(dst, W, H);
    const want = cpuColour(before, filter);
    const { most, at } = worst(got, want);
    ok(most <= 2, `${name}: ${most} apart at pixel ${at}`, [...got.subarray(at * 4, at * 4 + 4)], [...want.subarray(at * 4, at * 4 + 4)]);
    n.releaseSurface(dst);
  }
  // a sub-rect, drawn at an offset and twice the size: each source pixel a
  // block of four
  {
    const dst = n.createSurface(W, H, 1);
    n.ctxDrawSurfaceFiltered(dst, src, 4, 6, 8, 5, 10, 3, 16, 10, { matrices: [INVERT], alpha: 1, blur: 0 });
    const got = all(dst, W, H);
    const want = cpuColour(before, { matrices: [INVERT], alpha: 1 });
    let most = 0;
    for (let y = 0; y < 10; y += 2) {
      for (let x = 0; x < 16; x += 2) {
        const g = (y + 3) * W + (x + 10);
        const w = (6 + y / 2) * W + (4 + x / 2);
        // a block's top-left pixel: the source pixel itself, whatever the
        // resampling makes of the ones between
        const a = got.subarray(g * 4, g * 4 + 4);
        const b = want.subarray(w * 4, w * 4 + 4);
        if (!a[3] && !b[3]) continue;
        most = Math.max(most, worst(a, b).most);
      }
    }
    ok(most <= 60, `a sub-rect scaled lands where it should: ${most} apart`);
    ok(got[3] === 0, 'and draws nothing outside its rect');
    n.releaseSurface(dst);
  }
  // under the destination's clip
  {
    const dst = n.createSurface(W, H, 1);
    n.ctxRect(dst, 0, 0, W / 2, H);
    n.ctxClip(dst);
    n.ctxDrawSurfaceFiltered(dst, src, 0, 0, W, H, 0, 0, W, H, { matrices: [GRAYSCALE], alpha: 1, blur: 0 });
    const got = all(dst, W, H);
    let past = 0;
    for (let y = 0; y < H; y++) for (let x = W / 2; x < W; x++) past = Math.max(past, got[(y * W + x) * 4 + 3]);
    ok(past === 0, `the clip holds: ${past}`);
    n.releaseSurface(dst);
  }
  // nothing to draw
  {
    const dst = n.createSurface(W, H, 1);
    ok(n.ctxDrawSurfaceFiltered(dst, src, 0, 0, 0, 0, 0, 0, W, H, { matrices: [], alpha: 1, blur: 0 }) === false, 'an empty rect answers false');
    n.releaseSurface(dst);
  }
  n.releaseSurface(src);
}

// --- blur: a Gaussian of premultiplied colour, nothing past the rect -------
{
  const W = 80;
  const H = 80;
  // an opaque white square in the middle of nothing
  const src = n.createSurface(W, H, 1);
  n.ctxSetFillColor(src, 1, 1, 1, 1);
  n.ctxFillRect(src, 20, 20, 40, 40);
  const sigma = 4;
  const dst = n.createSurface(W + 40, H + 40, 1);
  n.ctxDrawSurfaceFiltered(dst, src, 0, 0, W, H, 20, 20, W, H, { matrices: [], alpha: 1, blur: sigma });
  const got = all(dst, W + 40, H + 40);
  const alphaAt = (x, y) => got[((y + 20) * (W + 40) + (x + 20)) * 4 + 3];
  // the edge of a square under a Gaussian: half at the edge, erf beyond
  const erf = (x) => {
    const t = 1 / (1 + 0.3275911 * Math.abs(x));
    const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-x * x);
    return x >= 0 ? y : -y;
  };
  const edge = (d) => 0.5 * (1 + erf(d / (sigma * Math.SQRT2)));
  let most = 0;
  for (const d of [-8, -4, -2, 0, 2, 4, 8]) {
    // across the left edge, at the square's middle row; the edge between
    // pixels 19 and 20 is at 20
    const x = 20 + d;
    const want = 255 * edge(x + 0.5 - 20);
    most = Math.max(most, Math.abs(alphaAt(x, 40) - want));
  }
  ok(most <= 12, `the blurred edge is a Gaussian's: ${most.toFixed(1)} apart`);
  ok(alphaAt(40, 40) >= 250, `its middle stays opaque: ${alphaAt(40, 40)}`);
  // and past the rect: a square at the source's own edge fades into
  // nothing, drawn out as far as its reach
  const edgy = n.createSurface(W, H, 1);
  n.ctxSetFillColor(edgy, 1, 0, 0, 1);
  n.ctxFillRect(edgy, 0, 0, W, H);
  const wide = n.createSurface(W + 40, H + 40, 1);
  n.ctxDrawSurfaceFiltered(wide, edgy, 0, 0, W, H, 20, 20, W, H, { matrices: [], alpha: 1, blur: sigma });
  const w2 = all(wide, W + 40, H + 40);
  const a2 = (x, y) => w2[(y * (W + 40) + x) * 4 + 3];
  ok(a2(20 + W / 2, 20 - 4) > 0 && a2(20 + W / 2, 20 - 4) < 128, `the blur reaches past the rect: ${a2(20 + W / 2, 16)}`);
  ok(a2(20 + W / 2, 20) < 200, `fading into nothing at the rect's edge: ${a2(20 + W / 2, 20)}`);
  ok(w2[((20 + 40) * (W + 40) + 60) * 4] >= 250, 'red stays red where it is opaque');
  for (const s of [src, dst, edgy, wide]) n.releaseSurface(s);
}

// --- what it costs ------------------------------------------------------------
{
  const W = 1281;
  const H = 961;
  const src = source(W, H);
  const dst = n.createSurface(W + 40, H + 40, 1);
  for (const [name, filter] of [
    ['grayscale', { matrices: [GRAYSCALE], alpha: 1, blur: 0 }],
    ['blur(6px)', { matrices: [], alpha: 1, blur: 6 }],
  ]) {
    n.ctxDrawSurfaceFiltered(dst, src, 0, 0, W, H, 20, 20, W, H, filter);
    const runs = 20;
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < runs; i++) n.ctxDrawSurfaceFiltered(dst, src, 0, 0, W, H, 20, 20, W, H, filter);
    const ms = Number(process.hrtime.bigint() - t0) / 1e6 / runs;
    console.log(`surface-filtered: ${W}x${H} ${name} ${ms.toFixed(2)}ms a draw`);
  }
  n.releaseSurface(src);
  n.releaseSurface(dst);
}

if (failed) {
  console.error(`surface-filtered: ${failed} failed`);
  process.exit(1);
}
console.log('surface-filtered: ok');
