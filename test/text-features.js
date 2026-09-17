'use strict';
// Letter spacing and OpenType features on the text verbs
// (sidorares/react-x11#588): a readout whose digits hold their width while
// the number changes, and spaced small caps.
//
// Checked: `fontApplyFeatures` sets features by tag — an array turns tags
// on, an object sets each to its value — so the system face's proportional
// digits become tabular under `tnum` and stay proportional under
// `{ tnum: false }`; with nothing to set it answers the font it was given;
// `createLayout`'s span `letterSpacing` adds its points after every
// character, the last included, and only on its own span; `fontShapeText`
// takes the same option and its widths and advances agree with the layout's.
// Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('text-features:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};
const near = (a, b, tol = 0.01) => Math.abs(a - b) <= tol;

const font = n.matchFont({ families: ['system-ui'], size: 20 });
const width = (spans) => n.createLayout({ spans }).width;
const digits = (f) => [width([{ text: '1111', font: f }]), width([{ text: '8888', font: f }])];

// --- features ---------------------------------------------------------------

const [plain1, plain8] = digits(font);
ok(!near(plain1, plain8), 'the system face has proportional digits by default', plain1, plain8);

const tnum = n.fontApplyFeatures(font, ['tnum']);
const [tab1, tab8] = digits(tnum);
ok(near(tab1, tab8), 'tnum makes the digits one width', tab1, tab8);

const [obj1, obj8] = digits(n.fontApplyFeatures(font, { tnum: true }));
ok(near(obj1, tab1) && near(obj8, tab8), 'the object form means the same', obj1, obj8);

const [off1, off8] = digits(n.fontApplyFeatures(font, { tnum: false }));
ok(near(off1, plain1) && near(off8, plain8), '{ tnum: false } leaves them proportional', off1, off8);

ok(n.fontApplyFeatures(font, []) === font, 'nothing to set answers the font itself');
ok(n.fontApplyFeatures(font, {}) === font, 'an empty object too');
try {
  n.fontApplyFeatures({}, ['tnum']);
  fail('a non-font first argument is accepted');
} catch (err) {
  ok(err instanceof TypeError, 'a non-font first argument is a TypeError', err);
}

// --- letter spacing ---------------------------------------------------------

const abc = width([{ text: 'abc', font }]);
const spaced = width([{ text: 'abc', font, letterSpacing: 3 }]);
ok(near(spaced, abc + 9), 'three characters, three gaps — the last included', abc, spaced);

const tight = width([{ text: 'abc', font, letterSpacing: -1 }]);
ok(near(tight, abc - 3), 'negative spacing tightens', abc, tight);

const mixed = width([
  { text: 'ab', font },
  { text: 'cd', font, letterSpacing: 2 },
]);
const unmixed = width([
  { text: 'ab', font },
  { text: 'cd', font },
]);
ok(near(mixed, unmixed + 4), 'a span spaces only itself', unmixed, mixed);

const shapedPlain = n.fontShapeText(font, 'abc');
const shaped = n.fontShapeText(font, 'abc', { letterSpacing: 3 });
ok(near(shaped.width, shapedPlain.width + 9), 'fontShapeText spaces as createLayout does', shaped.width);
ok(near(shaped.width, spaced), 'and to the same width', shaped.width, spaced);
const adv = [...shaped.runs[0].advances];
const advPlain = [...shapedPlain.runs[0].advances];
ok(
  adv.length === advPlain.length && adv.every((a, i) => near(a, advPlain[i] + 3)),
  'each advance carries the gap',
  adv,
  advPlain,
);
ok(near(n.fontShapeText(font, 'abc', {}).width, shapedPlain.width), 'no option, no spacing');

if (failed) {
  console.error(`text-features: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('text-features: ok');
