'use strict';
// pasteboardWrite (sidorares/react-x11 clipboard images): the general
// pasteboard written with several representations at once, so an image can be
// copied with a caption beside it, which pasteboardWriteText cannot do.
//
// Checked: one item with a PNG and a string puts both on the pasteboard — the
// string reads back through pasteboardReadText, and the PNG's exact bytes read
// back through AppleScript, which asks the system rather than this addon;
// the change count moves; a later write replaces the earlier one rather than
// adding to it; a null value is dropped; and anything but an object is a
// TypeError that leaves the pasteboard alone.
//
// It writes the user's real pasteboard: the text that was there is put back
// at the end (an image that was there is not). Exits 0 when every expectation
// held.

const { execFileSync } = require('child_process');
const { native: n } = require('..');

// a 1×1 PNG
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

let failures = 0;
function check(ok, what) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) failures++;
}

/** The pasteboard's PNG, as the system hands it to AppleScript, or null. */
function systemPng() {
  try {
    const out = execFileSync(
      'osascript',
      ['-e', 'the clipboard as «class PNGf»'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
    );
    const hex = /«data PNGf([0-9A-F]*)»/.exec(out);
    return hex ? Buffer.from(hex[1], 'hex') : null;
  } catch {
    return null;
  }
}

const saved = n.pasteboardReadText();
try {
  const before = n.pasteboardChangeCount();
  n.pasteboardWrite({
    'public.png': PNG,
    'public.utf8-plain-text': 'a 1×1 picture',
  });
  check(n.pasteboardChangeCount() > before, 'the change count moves');
  check(
    n.pasteboardReadText() === 'a 1×1 picture',
    'the string reads back as the text',
  );
  const png = systemPng();
  check(
    png !== null && png.equals(PNG),
    `the PNG reads back byte for byte (${png ? png.length : 'no'} bytes)`,
  );

  // typed arrays carry the same bytes; a later write replaces, not adds
  n.pasteboardWrite([{ 'public.png': new Uint8Array(PNG), 'x.none': null }]);
  check(n.pasteboardReadText() === null, 'a second write replaces the first');
  const again = systemPng();
  check(again !== null && again.equals(PNG), 'a typed array is the same bytes');

  const count = n.pasteboardChangeCount();
  let threw = null;
  try {
    n.pasteboardWrite('just text');
  } catch (err) {
    threw = err;
  }
  check(threw instanceof TypeError, 'a string is a TypeError');
  check(n.pasteboardChangeCount() === count, '…and changes nothing');
} finally {
  if (saved != null) n.pasteboardWriteText(saved);
  else n.pasteboardClear();
}

process.exit(failures ? 1 : 0);
