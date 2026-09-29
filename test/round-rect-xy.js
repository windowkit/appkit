'use strict';
// ctxRoundRectXY: a rounded rect whose corners are elliptical, each with its
// own pair of radii — canvas's roundRect with `{ x, y }` radii, which
// react-x11's context had been handing ctxRoundRect as NaN and so drawing
// square (sidorares/react-x11, the shadow-tiles change).
//
// Checked: an elliptical corner is cut as an ellipse, shallow where it is
// wider than tall; the corner opposite is its own; a corner with no extent
// on one axis is square, not cut off diagonally; with every corner circular
// it fills what ctxRoundRect fills, to the antialiasing; and it is one
// closed subpath, so an evenodd fill of a rect around it leaves a hole of
// its shape. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('round-rect-xy:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

const W = 220;
const H = 140;
const alpha = (s, x, y) => n.ctxGetImageData(s, x, y, 1, 1)[3];

function filled(draw, evenodd = false) {
  const s = n.createSurface(W, H, 1);
  n.ctxSetFillColor(s, 0, 0, 0, 1);
  n.ctxBeginPath(s);
  draw(s);
  n.ctxFill(s, evenodd);
  return s;
}

// --- an elliptical corner ---------------------------------------------------
{
  // top left 60 across and 12 down; top right circular 20; bottom right
  // 30 x 50; bottom left square
  const s = filled((s) =>
    n.ctxRoundRectXY(s, 10, 10, 200, 120, 60, 12, 20, 20, 30, 50, 0, 0),
  );
  ok(alpha(s, 11, 11) === 0, 'the very top left corner is cut away');
  ok(alpha(s, 50, 11) === 255, 'along the top, past most of the shallow ellipse, it is in');
  // at 6 below the top, half way down that corner, a circle of its height
  // would be in two pixels from the edge; the ellipse is in only past 8
  ok(alpha(s, 13, 16) === 0, 'the ellipse is shallow', alpha(s, 13, 16));
  ok(alpha(s, 20, 16) === 255, '…and in, once past it', alpha(s, 20, 16));
  ok(alpha(s, 208, 12) === 0, 'the top right corner is its own, circular');
  ok(alpha(s, 208, 40) === 255);
  ok(alpha(s, 208, 100) === 0, 'the bottom right is tall: still cut 30 up');
  ok(alpha(s, 180, 128) === 255, '…and in along the bottom past it');
  ok(alpha(s, 11, 128) === 255, 'the bottom left is square');
  n.releaseSurface?.(s);
}

// --- no extent on one axis ---------------------------------------------------
{
  const s = filled((s) =>
    n.ctxRoundRectXY(s, 10, 10, 200, 120, 40, 0, 0, 30, 20, 20, 20, 20),
  );
  ok(alpha(s, 11, 11) === 255, 'a corner 40 across and 0 down is square');
  ok(alpha(s, 208, 11) === 255, 'and so is one 0 across and 30 down');
  ok(alpha(s, 30, 11) === 255, 'nothing is cut diagonally along the top');
  n.releaseSurface?.(s);
}

// --- the circular case is ctxRoundRect's ------------------------------------
{
  const a = filled((s) => n.ctxRoundRect(s, 10, 10, 200, 120, 16, 8, 30, 0));
  const b = filled((s) =>
    n.ctxRoundRectXY(s, 10, 10, 200, 120, 16, 16, 8, 8, 30, 30, 0, 0),
  );
  const pa = n.ctxGetImageData(a, 0, 0, W, H);
  const pb = n.ctxGetImageData(b, 0, 0, W, H);
  let worst = 0;
  for (let i = 3; i < pa.length; i += 4) worst = Math.max(worst, Math.abs(pa[i] - pb[i]));
  ok(worst <= 8, `circular corners fill as ctxRoundRect does, off by ${worst}`);
  n.releaseSurface?.(a);
  n.releaseSurface?.(b);
}

// --- one closed subpath ------------------------------------------------------
{
  const s = filled((s) => {
    n.ctxRect(s, 0, 0, W, H);
    n.ctxRoundRectXY(s, 20, 20, 180, 100, 40, 20, 40, 20, 40, 20, 40, 20);
  }, true);
  ok(alpha(s, 5, 5) === 255, 'the frame is filled');
  ok(alpha(s, 110, 70) === 0, 'the hole is not');
  ok(alpha(s, 22, 22) === 255, 'and the hole has the ellipse corners');
  n.releaseSurface?.(s);
}

if (failed) {
  console.error(`round-rect-xy: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('round-rect-xy: ok');
