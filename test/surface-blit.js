'use strict';
// blitSurface and ctxSetBlendMode (sidorares/react-x11#498): the two verbs a
// 2d context needs to composite one surface into another the cheap way —
// `globalCompositeOperation` as one property on both backends, and a row
// memcpy for the case that property makes reachable, a `copy` of a whole
// surface into a bigger one at a translate.
//
// Checked: a blit lands the source rect at the destination point and touches
// nothing else; the returned rect is what actually moved; a sub-rect of the
// source; a clip rect trims the destination and drags the source origin with
// it; the context's own CG clip is invisible to the memcpy (which is why the
// verb takes a clip at all); every edge clamps and a fully-off blit answers
// null; alpha is copied, not blended; the blit is byte-identical to the
// CGImage path it replaces (`copy` mode, 1:1, translate only); a padded row
// stride on either side copies exactly; two handles onto one IOSurface are
// refused, as is a released one; and the blend modes composite as canvas
// says, save/restore bracket them, an unknown name changes nothing and
// answers false. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('surface-blit:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => { if (!cond) fail(msg, ...rest); };

// a surface filled with one colour, and pixel readback as straight RGBA
function surface(w, h, [r, g, b, a] = [0, 0, 0, 0]) {
  const s = n.createSurface(w, h, 1);
  n.ctxSetFillColor(s, r, g, b, a);
  n.ctxFillRect(s, 0, 0, w, h);
  return s;
}
const px = (s, x, y) => [...n.ctxGetImageData(s, x, y, 1, 1)];
const all = (s, w, h) => Buffer.from(n.ctxGetImageData(s, 0, 0, w, h));
const eq = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

const RED = [255, 0, 0, 255];
const BLUE = [0, 0, 255, 255];
const GREEN = [0, 255, 0, 255];

// a 8x8 red source with a 2x2 green square at (1, 1)
function src8() {
  const s = surface(8, 8, [1, 0, 0, 1]);
  n.ctxSetFillColor(s, 0, 1, 0, 1);
  n.ctxFillRect(s, 1, 1, 2, 2);
  return s;
}

// --- a whole source composited at a translate --------------------------------
{
  const src = src8();
  const dst = surface(16, 16, [0, 0, 1, 1]);
  const moved = n.blitSurface(src, 0, 0, 8, 8, dst, 4, 4);
  ok(eq(moved, [4, 4, 8, 8]), 'whole blit reported', moved);
  ok(eq(px(dst, 4, 4), RED), 'top-left of the blit', px(dst, 4, 4));
  ok(eq(px(dst, 5, 5), GREEN), 'the green square moved with it', px(dst, 5, 5));
  ok(eq(px(dst, 11, 11), RED), 'bottom-right of the blit', px(dst, 11, 11));
  ok(eq(px(dst, 3, 3), BLUE), 'one pixel outside is untouched', px(dst, 3, 3));
  ok(eq(px(dst, 12, 12), BLUE), 'past the far edge is untouched', px(dst, 12, 12));
  n.releaseSurface(src);
  n.releaseSurface(dst);
}

// --- a sub-rect of the source ------------------------------------------------
{
  const src = src8();
  const dst = surface(16, 16, [0, 0, 1, 1]);
  // just the green square
  ok(eq(n.blitSurface(src, 1, 1, 2, 2, dst, 0, 0), [0, 0, 2, 2]), 'sub-rect reported');
  ok(eq(px(dst, 0, 0), GREEN) && eq(px(dst, 1, 1), GREEN), 'the sub-rect is the green square');
  ok(eq(px(dst, 2, 2), BLUE), 'and nothing beyond it', px(dst, 2, 2));
  n.releaseSurface(src);
  n.releaseSurface(dst);
}

// --- a clip rect trims the destination, the source origin following ----------
{
  const src = src8();
  const dst = surface(16, 16, [0, 0, 1, 1]);
  // the blit would cover 4..11; the clip lets 6..9 through
  const moved = n.blitSurface(src, 0, 0, 8, 8, dst, 4, 4, [6, 6, 4, 4]);
  ok(eq(moved, [6, 6, 4, 4]), 'clipped blit reported', moved);
  ok(eq(px(dst, 5, 5), BLUE), 'outside the clip is untouched', px(dst, 5, 5));
  ok(eq(px(dst, 10, 10), BLUE), 'past the clip is untouched', px(dst, 10, 10));
  // dst(6,6) must be src(2,2) — the origin moved by what the clip took off,
  // and src(2,2) is the far corner of the green square
  ok(eq(px(dst, 6, 6), GREEN), 'inside the clip carries the right source pixel', px(dst, 6, 6));
  ok(eq(px(dst, 7, 7), RED), 'and the pixel past it is the source pixel past it', px(dst, 7, 7));
  const unclipped = surface(16, 16, [0, 0, 1, 1]);
  n.blitSurface(src, 0, 0, 8, 8, unclipped, 4, 4);
  for (let y = 6; y < 10; y++)
    for (let x = 6; x < 10; x++)
      ok(eq(px(dst, x, y), px(unclipped, x, y)), 'clipped pixels match the unclipped blit at', x, y);
  ok(n.blitSurface(src, 0, 0, 8, 8, dst, 4, 4, [40, 40, 4, 4]) === null, 'a clip that misses copies nothing');
  let err;
  try { n.blitSurface(src, 0, 0, 8, 8, dst, 4, 4, [1, 2]); } catch (e) { err = e; }
  ok(err instanceof TypeError, 'a short clip is a TypeError, not a silent full blit', err);
  n.releaseSurface(src);
  n.releaseSurface(dst);
  n.releaseSurface(unclipped);
}

// --- why the clip is a parameter: a memcpy cannot see the context's clip -----
{
  const src = src8();
  const dst = surface(16, 16, [0, 0, 1, 1]);
  n.ctxSave(dst);
  n.ctxBeginPath(dst);
  n.ctxRect(dst, 6, 6, 4, 4);
  n.ctxClip(dst);
  n.blitSurface(src, 0, 0, 8, 8, dst, 4, 4);
  n.ctxRestore(dst);
  ok(eq(px(dst, 4, 4), RED), 'the blit ignored the CG clip — pass a clip rect instead', px(dst, 4, 4));
  // and the clip is real for drawing verbs, so this is a property of the memcpy
  const drawn = surface(16, 16, [0, 0, 1, 1]);
  n.ctxSave(drawn);
  n.ctxBeginPath(drawn);
  n.ctxRect(drawn, 6, 6, 4, 4);
  n.ctxClip(drawn);
  n.ctxSetFillColor(drawn, 1, 0, 0, 1);
  n.ctxFillRect(drawn, 0, 0, 16, 16);
  n.ctxRestore(drawn);
  ok(eq(px(drawn, 4, 4), BLUE), 'a fill under the same clip is clipped', px(drawn, 4, 4));
  n.releaseSurface(src);
  n.releaseSurface(dst);
  n.releaseSurface(drawn);
}

// --- every edge clamps -------------------------------------------------------
{
  const src = src8();
  const dst = surface(16, 16, [0, 0, 1, 1]);
  ok(eq(n.blitSurface(src, 0, 0, 8, 8, dst, -3, -3), [0, 0, 5, 5]), 'clamped at the top-left');
  ok(eq(px(dst, 0, 0), RED), 'and the source moved by the same amount', px(dst, 0, 0));
  ok(eq(px(dst, 5, 5), BLUE), 'the clamped edge stops where it should', px(dst, 5, 5));
  ok(eq(n.blitSurface(src, 0, 0, 8, 8, dst, 12, 12), [12, 12, 4, 4]), 'clamped at the bottom-right');
  ok(eq(n.blitSurface(src, -2, -2, 8, 8, dst, 0, 0), [2, 2, 6, 6]), 'a source rect starting off the source');
  ok(eq(n.blitSurface(src, 4, 4, 8, 8, dst, 0, 0), [0, 0, 4, 4]), 'a source rect running past the source');
  ok(n.blitSurface(src, 0, 0, 8, 8, dst, 16, 0) === null, 'entirely past the right edge copies nothing');
  ok(n.blitSurface(src, 0, 0, 8, 8, dst, 0, -8) === null, 'entirely above the top copies nothing');
  ok(n.blitSurface(src, 0, 0, 0, 0, dst, 0, 0) === null, 'an empty rect copies nothing');
  ok(n.blitSurface(src, 0, 0, -4, 4, dst, 0, 0) === null, 'a negative width copies nothing');
  n.releaseSurface(src);
  n.releaseSurface(dst);
}

// --- alpha is copied, not blended: this is the `copy` op ---------------------
{
  const src = surface(4, 4, [0, 1, 0, 0.5]);
  const dst = surface(4, 4, [1, 0, 0, 1]);
  n.blitSurface(src, 0, 0, 4, 4, dst, 0, 0);
  const p = px(dst, 1, 1);
  ok(p[3] === 128 && p[1] > 240 && p[0] < 8, 'a half-alpha source replaces the opaque destination', p);
  n.releaseSurface(src);
  n.releaseSurface(dst);
}

// --- the blit is the CGImage path it replaces, byte for byte ----------------
{
  const src = src8();
  const viaBlit = surface(16, 16, [0, 0, 1, 1]);
  const viaImage = surface(16, 16, [0, 0, 1, 1]);
  n.blitSurface(src, 0, 0, 8, 8, viaBlit, 5, 3);
  n.ctxSetBlendMode(viaImage, 'copy');
  n.ctxDrawSurface(viaImage, src, 0, 0, 8, 8, 5, 3, 8, 8);
  n.ctxSetBlendMode(viaImage, 'source-over');
  ok(all(viaBlit, 16, 16).equals(all(viaImage, 16, 16)),
     'blitSurface differs from a copy-mode drawSurface at 1:1');
  n.releaseSurface(src);
  n.releaseSurface(viaBlit);
  n.releaseSurface(viaImage);
}

// --- padded row strides: a bitmap's row is not always w * 4 bytes -----------
{
  // CGBitmapContextCreate aligns rows, so an odd width leaves slack at the end
  // of every row that neither the source's nor the destination's copy may walk
  // into. Every pixel of the destination is checked, not a sample of them.
  for (const [sw, dw] of [[17, 23], [23, 17], [5, 4097]]) {
    const src = surface(sw, 9, [1, 0, 0, 1]);
    n.ctxSetFillColor(src, 0, 1, 0, 1);
    n.ctxFillRect(src, sw - 1, 8, 1, 1); // the last pixel of the last row
    const dst = surface(dw, 11, [0, 0, 1, 1]);
    const [, , w, h] = n.blitSurface(src, 0, 0, sw, 9, dst, 1, 1);
    let bad = null;
    for (let y = 0; y < 11 && !bad; y++)
      for (let x = 0; x < dw && !bad; x++) {
        const inside = x >= 1 && x < 1 + w && y >= 1 && y < 1 + h;
        const want = inside ? px(src, x - 1, y - 1) : BLUE;
        if (!eq(px(dst, x, y), want)) bad = [x, y, px(dst, x, y), want];
      }
    ok(!bad, `a ${sw}px-wide source into a ${dw}px-wide destination`, bad);
    n.releaseSurface(src);
    n.releaseSurface(dst);
  }
}

// --- IOSurface ends: one bitmap under two handles is refused ----------------
{
  const io = n.createSurfaceIOSurface(16, 16, 1, true);
  const src = src8();
  n.surfaceLock(io.handle);
  n.ctxSetFillColor(io.handle, 0, 0, 1, 1);
  n.ctxFillRect(io.handle, 0, 0, 16, 16);
  ok(eq(n.blitSurface(src, 0, 0, 8, 8, io.handle, 2, 2), [2, 2, 8, 8]), 'a blit into an IOSurface');
  ok(eq(px(io.handle, 3, 3), GREEN), 'lands in the shared bytes', px(io.handle, 3, 3));
  n.surfaceUnlock(io.handle);

  const same = n.surfaceFromIOSurfaceID(io.iosurfaceId, 1);
  let err;
  try { n.blitSurface(same.handle, 0, 0, 8, 8, io.handle, 0, 0); } catch (e) { err = e; }
  ok(err instanceof Error && /one bitmap/.test(err.message),
     'two handles onto one IOSurface must be refused', err);
  err = undefined;
  try { n.blitSurface(io.handle, 0, 0, 4, 4, io.handle, 4, 4); } catch (e) { err = e; }
  ok(err instanceof Error && /one bitmap/.test(err.message), 'a surface onto itself is refused', err);
  n.releaseSurface(same.handle);
  n.releaseSurface(io.handle);
  n.releaseSurface(src);
}

// --- a released handle throws, as everywhere else ---------------------------
{
  const src = src8();
  const dst = surface(8, 8, [0, 0, 1, 1]);
  n.releaseSurface(src);
  for (const [args, what] of [
    [[src, 0, 0, 8, 8, dst, 0, 0], 'a released source'],
    [[dst, 0, 0, 8, 8, src, 0, 0], 'a released destination'],
  ]) {
    let err;
    try { n.blitSurface(...args); } catch (e) { err = e; }
    ok(err instanceof Error && /released/.test(err.message), what + ' throws', err);
  }
  let err;
  try { n.blitSurface({}, 0, 0, 8, 8, dst, 0, 0); } catch (e) { err = e; }
  ok(err instanceof TypeError, 'a non-handle is a TypeError', err);
  n.releaseSurface(dst);
}

// --- ctxSetBlendMode ---------------------------------------------------------
{
  // source-over is the default and blends; copy replaces, alpha and all
  const over = surface(4, 4, [1, 0, 0, 1]);
  n.ctxSetFillColor(over, 0, 1, 0, 0.5);
  n.ctxFillRect(over, 0, 0, 4, 4);
  const blended = px(over, 1, 1);
  ok(blended[3] === 255 && blended[0] > 100 && blended[1] > 100,
     'the default is source-over: a half-alpha fill blends', blended);

  const copied = surface(4, 4, [1, 0, 0, 1]);
  ok(n.ctxSetBlendMode(copied, 'copy') === true, "'copy' is a known mode");
  n.ctxSetFillColor(copied, 0, 1, 0, 0.5);
  n.ctxFillRect(copied, 0, 0, 4, 4);
  const replaced = px(copied, 1, 1);
  ok(replaced[3] === 128 && replaced[1] > 240 && replaced[0] < 8,
     "'copy' replaces the destination, alpha included", replaced);

  // an unknown name is ignored — the mode in force stays in force
  ok(n.ctxSetBlendMode(copied, 'not-a-mode') === false, 'an unknown mode answers false');
  n.ctxSetFillColor(copied, 0, 0, 1, 0.25);
  n.ctxFillRect(copied, 0, 0, 4, 4);
  const still = px(copied, 1, 1);
  ok(still[3] === 64 && still[2] > 240, 'an unknown mode left `copy` in force', still);

  // gstate, so save/restore brackets it
  const bracketed = surface(4, 4, [1, 0, 0, 1]);
  n.ctxSave(bracketed);
  n.ctxSetBlendMode(bracketed, 'copy');
  n.ctxRestore(bracketed);
  n.ctxSetFillColor(bracketed, 0, 1, 0, 0.5);
  n.ctxFillRect(bracketed, 0, 0, 4, 4);
  ok(px(bracketed, 1, 1)[3] === 255, 'ctxRestore put source-over back', px(bracketed, 1, 1));

  // destination-out erases
  const erased = surface(4, 4, [1, 0, 0, 1]);
  n.ctxSetBlendMode(erased, 'destination-out');
  n.ctxSetFillColor(erased, 0, 0, 0, 1);
  n.ctxFillRect(erased, 0, 0, 2, 2);
  ok(px(erased, 0, 0)[3] === 0, "'destination-out' erased the destination", px(erased, 0, 0));
  ok(px(erased, 3, 3)[3] === 255, 'and left the rest', px(erased, 3, 3));

  // every name canvas has, and CoreGraphics' three extras
  const names = [
    'source-over', 'source-in', 'source-out', 'source-atop', 'destination-over',
    'destination-in', 'destination-out', 'destination-atop', 'lighter', 'copy', 'xor',
    'multiply', 'screen', 'overlay', 'darken', 'lighten', 'color-dodge', 'color-burn',
    'hard-light', 'soft-light', 'difference', 'exclusion', 'hue', 'saturation', 'color',
    'luminosity', 'clear', 'plus-lighter', 'plus-darker',
  ];
  for (const name of names)
    ok(n.ctxSetBlendMode(erased, name) === true, 'a blend mode was not accepted:', name);
  for (const bad of ['', 'source over', 'SOURCE-OVER', 'normal'])
    ok(n.ctxSetBlendMode(erased, bad) === false, 'accepted a name it should not have:', bad);

  for (const s of [over, copied, bracketed, erased]) n.releaseSurface(s);
}

if (failed) {
  console.error(`surface-blit: ${failed} check(s) failed`);
  process.exit(1);
}
console.log('surface-blit OK');
