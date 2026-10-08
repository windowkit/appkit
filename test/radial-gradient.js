'use strict';
// ctxFillRadialGradient(surface, x0, y0, r0, x1, y1, r1, stops, x?, y?, w?, h?):
// canvas's createRadialGradient, which react-x11's context had nothing to
// hand to — it answered with a linear gradient along no line, so every
// radial gradient a page drew, a CSS one included, came out flat in one
// colour.
//
// Checked: the start colour at the centre, the end colour at the end
// circle and carried on past it, a colour between the two halfway out; the
// rect form fills that rect and nothing outside it; the path form fills the
// path, and the path is still there after; and two circles that do not
// share a centre move the colours with them. Exits 0 when every expectation
// held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('radial-gradient:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

const W = 100;
const px = (s, x, y) => Array.from(n.ctxGetImageData(s, x, y, 1, 1));
const near = (a, b, tol = 6) => a.every((v, i) => Math.abs(v - b[i]) <= tol);
// red at the centre to blue at 40px
const STOPS = [0, 1, 0, 0, 1, 1, 0, 0, 1, 1];

{
  const s = n.createSurface(W, W, 1);
  n.ctxFillRadialGradient(s, 50, 50, 0, 50, 50, 40, STOPS, 0, 0, W, W);
  ok(near(px(s, 50, 50), [255, 0, 0, 255]), 'red at the centre', px(s, 50, 50));
  const mid = px(s, 70, 50);
  ok(mid[0] > 90 && mid[0] < 165 && mid[2] > 90 && mid[2] < 165,
     'between the two halfway out', mid);
  ok(near(px(s, 95, 50), [0, 0, 255, 255]), 'blue past the end circle',
     px(s, 95, 50));
  ok(near(px(s, 2, 2), [0, 0, 255, 255]), 'blue in the corner', px(s, 2, 2));
  n.releaseSurface?.(s);
}

{
  // the rect form fills that rect and nothing else
  const s = n.createSurface(W, W, 1);
  n.ctxFillRadialGradient(s, 50, 50, 0, 50, 50, 40, STOPS, 30, 30, 40, 40);
  ok(px(s, 50, 50)[3] === 255, 'the rect is filled');
  ok(px(s, 10, 10)[3] === 0, 'outside the rect is not', px(s, 10, 10));
  n.releaseSurface?.(s);
}

{
  // the path form: the path filled, and kept
  const s = n.createSurface(W, W, 1);
  n.ctxBeginPath(s);
  n.ctxRect(s, 0, 0, 50, W);
  n.ctxFillRadialGradient(s, 50, 50, 0, 50, 50, 40, STOPS);
  ok(px(s, 25, 50)[3] === 255, 'the path is filled');
  ok(px(s, 75, 50)[3] === 0, 'outside the path is not', px(s, 75, 50));
  n.ctxSetFillColor(s, 0, 1, 0, 1);
  n.ctxFill(s, false);
  ok(near(px(s, 25, 50), [0, 255, 0, 255]), 'the path is still there after',
     px(s, 25, 50));
  n.releaseSurface?.(s);
}

{
  // the circles move the colours: centred at 20,50 the red is there
  const s = n.createSurface(W, W, 1);
  n.ctxFillRadialGradient(s, 20, 50, 0, 20, 50, 40, STOPS, 0, 0, W, W);
  ok(near(px(s, 20, 50), [255, 0, 0, 255]), 'red where the circle is',
     px(s, 20, 50));
  ok(near(px(s, 80, 50), [0, 0, 255, 255]), 'blue far from it', px(s, 80, 50));
  n.releaseSurface?.(s);
}

if (failed) {
  console.error(`radial-gradient: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('radial-gradient: ok');
