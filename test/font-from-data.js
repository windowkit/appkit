'use strict';
// fontFromData reads a face and installs nothing (windowkit/appkit#92):
// reading a font a caller holds as bytes must not make that file answer
// CoreText's name matching for the rest of the process.
//
// Checked: after `fontFromData`, `fontByPostScriptName` of the face's name is
// null, `listFonts({ family })` is empty and `matchFont({ families: [family] })`
// answers some other face; the handle still works — `cgFontWithSize` of its
// `cg` lays out at the face's own advances; and a second build with the same
// PostScript name gets a handle of its own, while name matching still finds
// neither. The face is built here, in memory, under a family no machine has
// installed. Exits 0 when every expectation held.

const { native: n } = require('..');

let failed = 0;
const fail = (msg, ...rest) => {
  console.error('font-from-data:', msg, ...rest);
  failed++;
};
const ok = (cond, msg, ...rest) => {
  if (!cond) fail(msg, ...rest);
};
const near = (a, b, tol = 0.01) => Math.abs(a - b) <= tol;

// --- a minimal TrueType face --------------------------------------------------

// 1000 units per em; 'A' and 'B' are filled rectangles `advances[0]` and
// `advances[1]` units wide, everything else is .notdef.
function buildFace({ family, postScriptName, advances }) {
  const u16 = (v) => [(v >> 8) & 0xff, v & 0xff];
  const u32 = (v) => [(v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff];
  const tag = (s) => [...s].map((c) => c.charCodeAt(0));
  const utf16be = (s) => [...s].flatMap((c) => u16(c.charCodeAt(0)));

  const glyphs = [{ advance: 500, contour: null }].concat(
    advances.map((advance) => ({ advance, contour: [50, 0, advance - 50, 700] })),
  );
  const glyf = [];
  const loca = [];
  for (const g of glyphs) {
    loca.push(...u16(glyf.length / 2));
    if (!g.contour) continue;
    const [x0, y0, x1, y1] = g.contour;
    glyf.push(...u16(1), ...u16(x0), ...u16(y0), ...u16(x1), ...u16(y1));
    glyf.push(...u16(3), ...u16(0), 1, 1, 1, 1); // one contour, four on-curve points
    for (const dx of [x0, 0, x1 - x0, 0]) glyf.push(...u16(dx & 0xffff));
    for (const dy of [y0, y1 - y0, 0, y0 - y1]) glyf.push(...u16(dy & 0xffff));
    if (glyf.length % 2) glyf.push(0);
  }
  loca.push(...u16(glyf.length / 2));

  // cmap format 4: 'A'..'B' -> glyphs 1..2, then the closing segment
  const cmap4 = [
    ...u16(4), ...u16(32), ...u16(0), ...u16(4), ...u16(4), ...u16(1), ...u16(0),
    ...u16(0x42), ...u16(0xffff), ...u16(0),
    ...u16(0x41), ...u16(0xffff),
    ...u16(1 - 0x41 + 0x10000), ...u16(1),
    ...u16(0), ...u16(0),
  ];
  const cmap = [...u16(0), ...u16(1), ...u16(3), ...u16(1), ...u32(12), ...cmap4];

  const names = [
    [1, family],
    [2, 'Regular'],
    [3, `${postScriptName};test`],
    [4, `${family} Regular`],
    [6, postScriptName],
  ];
  const strings = [];
  const records = [];
  for (const [id, s] of names) {
    const bytes = utf16be(s);
    records.push(...u16(3), ...u16(1), ...u16(0x409), ...u16(id), ...u16(bytes.length), ...u16(strings.length));
    strings.push(...bytes);
  }
  const name = [...u16(0), ...u16(names.length), ...u16(6 + records.length), ...records, ...strings];

  const maxAdvance = Math.max(...glyphs.map((g) => g.advance));
  const tables = {
    'OS/2': [
      ...u16(4), ...u16(500), ...u16(400), ...u16(5), ...u16(0),
      ...u16(650), ...u16(700), ...u16(0), ...u16(140),
      ...u16(650), ...u16(700), ...u16(0), ...u16(480),
      ...u16(50), ...u16(250), ...u16(0),
      ...new Array(10).fill(0),
      ...u32(1), ...u32(0), ...u32(0), ...u32(0),
      ...tag('NONE'), ...u16(0x40), ...u16(0x41), ...u16(0x42),
      ...u16(800), ...u16(0x10000 - 200), ...u16(0), ...u16(800), ...u16(200),
      ...u32(1), ...u32(0),
      ...u16(500), ...u16(700), ...u16(0), ...u16(0x20), ...u16(1),
    ],
    cmap,
    glyf,
    head: [
      ...u32(0x10000), ...u32(0x10000), ...u32(0), ...u32(0x5f0f3cf5),
      ...u16(0x000b), ...u16(1000),
      ...new Array(16).fill(0),
      ...u16(0), ...u16(0), ...u16(maxAdvance), ...u16(700),
      ...u16(0), ...u16(8), ...u16(2), ...u16(0), ...u16(0),
    ],
    hhea: [
      ...u32(0x10000), ...u16(800), ...u16(0x10000 - 200), ...u16(0),
      ...u16(maxAdvance), ...u16(0), ...u16(50), ...u16(maxAdvance - 50),
      ...u16(1), ...u16(0), ...u16(0),
      ...new Array(8).fill(0),
      ...u16(0), ...u16(glyphs.length),
    ],
    hmtx: glyphs.flatMap((g) => [...u16(g.advance), ...u16(g.contour ? 50 : 0)]),
    loca,
    maxp: [
      ...u32(0x10000), ...u16(glyphs.length), ...u16(4), ...u16(1), ...u16(0), ...u16(0),
      ...u16(2), ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u16(0),
    ],
    name,
    post: [...u32(0x30000), ...u32(0), ...u16(0x10000 - 100), ...u16(50), ...new Array(20).fill(0)],
  };

  const checksum = (bytes) => {
    let sum = 0;
    for (let i = 0; i < bytes.length; i += 4) {
      sum = (sum + ((bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3])) >>> 0;
    }
    return sum;
  };
  const tags = Object.keys(tables).sort();
  const header = [...u32(0x10000), ...u16(tags.length), ...u16(128), ...u16(3), ...u16(tags.length * 16 - 128)];
  const directory = [];
  const body = [];
  let offset = header.length + tags.length * 16;
  for (const t of tags) {
    const data = tables[t];
    const padded = data.concat(new Array((4 - (data.length % 4)) % 4).fill(0));
    directory.push(...tag(t), ...u32(checksum(padded)), ...u32(offset + body.length), ...u32(data.length));
    body.push(...padded);
  }
  const file = Buffer.from([...header, ...directory, ...body]);
  const head = file.readUInt32BE(header.length + tags.indexOf('head') * 16 + 8);
  file.writeUInt32BE((0xb1b0afba - checksum([...file])) >>> 0, head + 8);
  return file;
}

// --- reading installs nothing --------------------------------------------------

const family = 'Appkit Unregistered Test';
const postScriptName = 'AppkitUnregisteredTest-Regular';

// the name answers nothing before any bytes are read — else the rest proves nothing
ok(n.fontByPostScriptName(postScriptName, 14) === null, 'the test face is already installed');

const info = n.fontFromData(buildFace({ family, postScriptName, advances: [600, 400] }));
ok(info && info.cg, 'fontFromData reads the built face', info);
ok(info.familyName === family, 'it reports the family', info.familyName);
ok(info.postScriptName === postScriptName, 'and the PostScript name', info.postScriptName);
ok(info.weight === 400 && info.italic === false, 'and a regular weight, upright', info.weight, info.italic);

const unfound = (when) => {
  ok(n.fontByPostScriptName(postScriptName, 14) === null, `${when}: fontByPostScriptName finds the face`);
  const rows = n.listFonts({ family });
  ok(rows.length === 0, `${when}: listFonts lists the family`, rows);
  const matched = n.fontMetrics(n.matchFont({ families: [family], size: 14, weight: 400 })).postScriptName;
  ok(matched !== postScriptName, `${when}: matchFont answers the face for its family`, matched);
};
unfound('after fontFromData');

// --- the handle needs none of it -----------------------------------------------

const width = (cg, text) => n.createLayout({ spans: [{ text, font: n.cgFontWithSize(cg, 14) }] }).width;
ok(near(width(info.cg, 'A'), 8.4), "the handle lays 'A' out at its own advance", width(info.cg, 'A'));
ok(near(width(info.cg, 'AB'), 14), "and 'AB' at the two advances'", width(info.cg, 'AB'));

// --- a second build, the same PostScript name -----------------------------------

const other = n.fontFromData(buildFace({ family, postScriptName, advances: [300, 700] }));
ok(other && other.postScriptName === postScriptName, 'a second build with the same name reads', other);
ok(near(width(other.cg, 'A'), 4.2), 'its handle is its own', width(other.cg, 'A'));
ok(near(width(info.cg, 'A'), 8.4), 'and the first handle is unchanged', width(info.cg, 'A'));
unfound('after a second build');

if (failed) {
  console.error(`font-from-data: ${failed} expectation(s) failed`);
  process.exit(1);
}
console.log('font-from-data: ok');
