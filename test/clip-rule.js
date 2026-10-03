'use strict';
// ctxClip(surface, evenOdd): the fill rule of a clip, as ctxFill takes it.
// canvas's clip(path, 'evenodd') is how ntk's SvgView cuts an element to a
// <clipPath> with clip-rule="evenodd" (sidorares/ntk#529), and react-x11's
// context had nothing to hand it to — CtxClip always cut nonzero, so a ring
// clipped a fill to the whole square around it.
//
// Checked: a ring of two rects wound the same way clips evenodd to the
// ring, its hole left alone; without the flag, or with it false, the same
// path clips nonzero, hole and all, as every caller before it had; and one
// rect clips the same under either rule. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('clip-rule:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

const W = 60;
const alpha = (s, x, y) => n.ctxGetImageData(s, x, y, 1, 1)[3];

/** fill the whole surface through a clip to `path`, with `args` after it */
function clipped(path, ...args) {
  const s = n.createSurface(W, W, 1);
  n.ctxSave(s);
  n.ctxBeginPath(s);
  path(s);
  n.ctxClip(s, ...args);
  n.ctxSetFillColor(s, 0, 0, 0, 1);
  n.ctxFillRect(s, 0, 0, W, W);
  n.ctxRestore(s);
  return s;
}

// a 40px square with a 20px hole, both wound the same way: nonzero fills
// the hole, evenodd leaves it
const ring = (s) => {
  n.ctxRect(s, 10, 10, 40, 40);
  n.ctxRect(s, 20, 20, 20, 20);
};
const square = (s) => n.ctxRect(s, 10, 10, 40, 40);

{
  const s = clipped(ring, true);
  ok(alpha(s, 15, 15) === 255, 'evenodd: the ring is drawn');
  ok(alpha(s, 30, 30) === 0, 'evenodd: the hole is not', alpha(s, 30, 30));
  ok(alpha(s, 5, 5) === 0, 'evenodd: nothing outside it');
  n.releaseSurface?.(s);
}

for (const [name, args] of [
  ['no flag', []],
  ['false', [false]],
]) {
  const s = clipped(ring, ...args);
  ok(alpha(s, 15, 15) === 255, `${name}: the ring is drawn`);
  ok(alpha(s, 30, 30) === 255, `${name}: nonzero fills the hole`, alpha(s, 30, 30));
  ok(alpha(s, 5, 5) === 0, `${name}: nothing outside it`);
  n.releaseSurface?.(s);
}

{
  // one rect is one subpath wound once: either rule cuts the same pixels,
  // which is what lets a caller treat an evenodd rect clip as the rect
  const a = clipped(square, true);
  const b = clipped(square, false);
  const pa = n.ctxGetImageData(a, 0, 0, W, W);
  const pb = n.ctxGetImageData(b, 0, 0, W, W);
  let differ = 0;
  for (let i = 3; i < pa.length; i += 4) if (pa[i] !== pb[i]) differ++;
  ok(differ === 0, `one rect clips alike under both rules, ${differ} pixels apart`);
  n.releaseSurface?.(a);
  n.releaseSurface?.(b);
}

if (failed) {
  console.error(`clip-rule: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('clip-rule: ok');
