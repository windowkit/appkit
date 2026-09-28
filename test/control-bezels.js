'use strict';
// The flexible push (sidorares/react-x11, a native <Button> whose label
// wraps): `kind: 'flexiblePush'` is NSBezelStyleFlexiblePush, the push
// button stretched to its frame, where `push` keeps one height and draws it
// centred in a taller frame.
//
// Checked: both kinds measure and an unknown one still throws; the push's
// ink is the same 22pt (18 small) in every frame, while the flexible push
// inks its frame to the same margins however tall it is; at the push's own
// height the two draw the same pixels over the same ink box, plain, pressed
// and in both appearances; and the flexible push takes the default button's
// accent. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('control-bezels:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};

const SCALE = 2;

/** Draw `params` into a `w` x `h` pt frame; the pixels and their ink box. */
function draw(params, w, h) {
  const pw = Math.round(w * SCALE);
  const ph = Math.round(h * SCALE);
  const s = n.createSurface(pw, ph, SCALE);
  n.drawControlIntoSurface(s, params);
  const buf = n.ctxGetImageData(s, 0, 0, pw, ph);
  let x0 = pw;
  let x1 = -1;
  let y0 = ph;
  let y1 = -1;
  for (let y = 0; y < ph; y++) {
    for (let x = 0; x < pw; x++) {
      if (buf[(y * pw + x) * 4 + 3] > 8) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  return { buf, pw, ph, ink: { x0, x1, y0, y1 } };
}

/** The `w` x `h` px region of `d` at its ink box's top-left corner. */
function inkRegion(d, w, h) {
  const out = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) {
    const at = ((d.ink.y0 + y) * d.pw + d.ink.x0) * 4;
    Buffer.from(d.buf.buffer, d.buf.byteOffset + at, w * 4).copy(out, y * w * 4);
  }
  return out;
}

const maxDiff = (a, b) => {
  let m = 0;
  for (let i = 0; i < a.length; i++) m = Math.max(m, Math.abs(a[i] - b[i]));
  return m;
};

// --- both kinds measure; an unknown one does not ----------------------------
for (const controlSize of ['regular', 'small']) {
  const m = n.measureControl({ kind: 'flexiblePush', controlSize });
  ok(m && m.width > 0 && m.height > 0, `flexiblePush measures (${controlSize})`, m);
}
{
  let threw = null;
  try {
    n.measureControl({ kind: 'flexible-push' });
  } catch (err) {
    threw = err;
  }
  ok(threw && /unknown control kind/.test(threw.message), 'an unknown kind throws', threw);
}

// --- one height, or stretched to the frame ------------------------------------
for (const controlSize of ['regular', 'small']) {
  const push = n.measureControl({ kind: 'push', controlSize });
  const flex = n.measureControl({ kind: 'flexiblePush', controlSize });
  const tallest = { push: new Set(), flex: new Set() };
  const margins = new Set();
  for (const extra of [0, 16, 32]) {
    const p = draw({ kind: 'push', controlSize, appearance: 'light' }, 120, push.height + extra);
    tallest.push.add(p.ink.y1 - p.ink.y0 + 1);
    const f = draw({ kind: 'flexiblePush', controlSize, appearance: 'light' }, 120, flex.height + extra);
    tallest.flex.add(f.ink.y1 - f.ink.y0 + 1);
    margins.add(`${f.ink.y0}/${f.ph - 1 - f.ink.y1}`);
  }
  ok(tallest.push.size === 1, `the push is one height in every frame (${controlSize})`, [...tallest.push]);
  ok(tallest.flex.size === 3, `the flexible push grows with its frame (${controlSize})`, [...tallest.flex]);
  ok(margins.size === 1, `to the same margins (${controlSize})`, [...margins]);
}

// --- at one line, the same pixels ---------------------------------------------
for (const controlSize of ['regular', 'small']) {
  const push = n.measureControl({ kind: 'push', controlSize });
  const flex = n.measureControl({ kind: 'flexiblePush', controlSize });
  const scanP = draw({ kind: 'push', controlSize, state: 1 }, 120, push.height);
  const scanF = draw({ kind: 'flexiblePush', controlSize, state: 1 }, 120, flex.height);
  const inkH = scanP.ink.y1 - scanP.ink.y0 + 1;
  ok(scanF.ink.y1 - scanF.ink.y0 + 1 === inkH, `one line is one push tall (${controlSize})`);
  const inkW = 200; // px, well inside both frames
  for (const appearance of ['light', 'dark']) {
    for (const pressed of [false, true]) {
      const params = { controlSize, appearance, pressed };
      const a = inkRegion(draw({ ...params, kind: 'push' }, 120, push.height), inkW, inkH);
      const b = inkRegion(draw({ ...params, kind: 'flexiblePush' }, 120, flex.height), inkW, inkH);
      const d = maxDiff(a, b);
      ok(d <= 2, `push and flexiblePush agree at one line (${controlSize} ${appearance}${pressed ? ' pressed' : ''})`, d);
    }
  }
  // …and the default button is accent-filled in both
  const plain = inkRegion(draw({ kind: 'flexiblePush', controlSize, appearance: 'light' }, 120, flex.height), inkW, inkH);
  const def = inkRegion(draw({ kind: 'flexiblePush', controlSize, appearance: 'light', isDefault: true }, 120, flex.height), inkW, inkH);
  ok(maxDiff(plain, def) > 40, `the default flexible push takes the accent (${controlSize})`);
}

if (failed) {
  console.error(`control-bezels: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('control-bezels: ok');
