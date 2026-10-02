'use strict';
// A file played by AVFoundation (src/player.mm): createPlayer's layer shows
// the clip on screen, its events say what the item is and what it is doing,
// playerSet and playerSeek steer it, and playerCopyFrame draws the frame
// showing into a surface in the colours the layer shows it in — read back
// through snapshotWindow, the window server's composite, beside the layer.
//
// test/fixtures/clip.mp4 is 1.5s of one colour, 160x90 H.264 tagged BT.709
// throughout, written by
//
//   ffmpeg -f lavfi -i color=c=0xE07030:s=160x90:r=30:d=1.5 \
//     -vf scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,\
//         setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv \
//     -c:v libx264 -preset veryslow -crf 18 -movflags +faststart -an clip.mp4
//
// Exits 0 when every expectation held.

const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { native } = require('..');

const CLIP = path.join(__dirname, 'fixtures', 'clip.mp4');

const fail = (msg, ...rest) => {
  console.error('player:', msg, ...rest);
  process.exit(1);
};

function pumpUntil(pred, ms = 5000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const tick = setInterval(() => {
      native.pump2();
      if (pred()) {
        clearInterval(tick);
        resolve();
      } else if (Date.now() > deadline) {
        clearInterval(tick);
        reject(new Error('timed out'));
      }
    }, 8);
  });
}
const pumpFor = (ms) => pumpUntil(() => false, ms).catch(() => {});

// test/surface-colorspace.js's reader: 8- or 16-bit RGB(A), not interlaced
function readPng(file) {
  const buf = fs.readFileSync(file);
  let width = 0, height = 0, depth = 0, type = 0;
  const idat = [];
  for (let o = 8; o < buf.length; ) {
    const len = buf.readUInt32BE(o);
    const kind = buf.toString('latin1', o + 4, o + 8);
    const data = buf.subarray(o + 8, o + 8 + len);
    if (kind === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      depth = data[8];
      type = data[9];
      if (data[12] !== 0) throw new Error('interlaced PNG');
    } else if (kind === 'IDAT') idat.push(data);
    o += 12 + len;
  }
  const channels = { 2: 3, 6: 4 }[type];
  if (!channels || (depth !== 8 && depth !== 16)) throw new Error(`PNG type ${type}/${depth}`);
  const bpp = (channels * depth) / 8;
  const stride = width * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const px = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const out = px.subarray(y * stride, (y + 1) * stride);
    const up = y ? px.subarray((y - 1) * stride, y * stride) : null;
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? out[i - bpp] : 0;
      const b = up ? up[i] : 0;
      const c = up && i >= bpp ? up[i - bpp] : 0;
      let v = line[i];
      if (filter === 1) v += a;
      else if (filter === 2) v += b;
      else if (filter === 3) v += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      out[i] = v & 0xff;
    }
  }
  const rgb = (x, y) => {
    const i = y * stride + x * bpp;
    const at = (k) => (depth === 8 ? px[i + k] : px[i + 2 * k]);
    return [at(0), at(1), at(2)];
  };
  return { width, height, rgb };
}

const W = 220;
const H = 120;

(async () => {
  try {
    native.createPlayer('');
    fail('an empty url was taken');
  } catch (e) {
    if (!/a path or a URL string/.test(e.message)) fail('the refusal says', e.message);
  }

  native.initApp();
  const events = [];
  native.setBackendEventCallback((ev) => {
    if (String(ev.type).startsWith('player-')) events.push(ev);
  });
  const of = (id, type) => events.filter((e) => e.id === id && e.type === type);
  const win = native.createWindow2({ width: W, height: H, x: 220, y: 220, title: 'player' });
  native.showWindow(win, false);
  await pumpUntil(() => native.getWindowFrame(win)?.visible === true).catch(() => fail('the window never showed'));
  const root = native.windowRootLayer(win);
  native.setLayerProps(root, { backgroundColor: [1, 1, 1, 1] });

  // --- playing, on a layer ------------------------------------------------------
  const { id, layer } = native.createPlayer(CLIP, { autoPlay: true, muted: true, loop: true });
  if (typeof id !== 'number') fail('createPlayer answered no id');
  native.setLayerProps(layer, { frame: [10, 10, 80, 45] });
  native.addSublayer(root, layer);
  await pumpUntil(() => of(id, 'player-metadata').length > 0).catch(() => fail('no player-metadata', events));
  const meta = of(id, 'player-metadata')[0];
  if (meta.width !== 160 || meta.height !== 90) fail('the clip is 160x90; metadata says', meta);
  if (!(Math.abs(meta.duration - 1.5) < 0.1)) fail('the clip is 1.5s; metadata says', meta.duration);
  await pumpUntil(() => of(id, 'player-state').some((e) => e.playing)).catch(() => fail('it never said it was playing', events));
  await pumpUntil(() => of(id, 'player-time').length >= 2).catch(() => fail('no player-time while playing'));

  // --- the frame showing, drawn into a bitmap -----------------------------------
  const surface = native.createSurface(160, 90, 1);
  let copied = null;
  await pumpUntil(() => (copied = native.playerCopyFrame(id, surface)) !== null).catch(() =>
    fail('playerCopyFrame never had a frame'),
  );
  if (copied.width !== 160 || copied.height !== 90 || copied.written !== true) fail('the copy says', copied);
  if (native.playerCopyFrame(id, surface) !== null && native.playerCopyFrame(id, surface) !== null) {
    fail('a frame copied twice: playerCopyFrame answers null when nothing is newer');
  }
  const drawnLayer = native.createLayer();
  native.setLayerProps(drawnLayer, { frame: [110, 10, 80, 45] });
  native.addSublayer(root, drawnLayer);
  native.surfaceToLayer(surface, drawnLayer);
  // a surface of another size is told the size and left alone
  const small = native.createSurface(16, 9, 1);
  let other = null;
  await pumpUntil(() => (other = native.playerCopyFrame(id, small)) !== null).catch(() => {});
  if (other && other.written !== false) fail('a frame was written into a surface of another size', other);

  native.pump2();
  await pumpFor(500);
  const shot = path.join(os.tmpdir(), `appkit-player-${process.pid}.png`);
  if (!native.snapshotWindow(win, shot)) fail('snapshotWindow wrote nothing');
  const png = readPng(shot);
  if (process.env.KEEP_SHOT) fs.copyFileSync(shot, process.env.KEEP_SHOT);
  fs.unlinkSync(shot);
  const k = png.width / W;
  const top = png.height - Math.round(H * k);
  const at = (x, y) => png.rgb(Math.round(x * k), top + Math.round(y * k));
  const onLayer = at(50, 32);
  const drawn = at(150, 32);
  const near = (a, b, d) => a.every((v, i) => Math.abs(v - b[i]) <= d);
  if (near(onLayer, [255, 255, 255], 8)) fail('the player layer showed nothing', onLayer);
  if (!near(onLayer, drawn, 3)) fail('the clip on a layer shows', onLayer, 'and copied into a bitmap', drawn);

  // --- looping: past the end it starts again, and says nothing of an end ----------
  const wrapped = () => {
    const t = of(id, 'player-time').map((e) => e.currentTime);
    return t.some((v, i) => i > 0 && v < t[i - 1] - 0.5);
  };
  await pumpUntil(wrapped, 4000).catch(() => fail('a looping clip never started again', of(id, 'player-time')));
  if (of(id, 'player-ended').length) fail('a looping clip said it ended');

  // --- steering it ----------------------------------------------------------------
  native.playerSet(id, { paused: true });
  await pumpUntil(() => of(id, 'player-state').at(-1)?.playing === false).catch(() => fail('pausing said nothing'));
  const before = of(id, 'player-time').length;
  native.playerSeek(id, 1.2);
  await pumpUntil(() => of(id, 'player-time').length > before).catch(() => fail('a seek said no time'));
  const landed = of(id, 'player-time').at(-1).currentTime;
  if (!(Math.abs(landed - 1.2) < 0.05)) fail('a seek to 1.2s landed at', landed);
  // not looping, at twice the rate: it ends, and says so
  native.playerSet(id, { loop: false, rate: 2, paused: false });
  await pumpUntil(() => of(id, 'player-ended').length > 0).catch(() => fail('the end of the clip said nothing'));

  // --- a URL that is not there ----------------------------------------------------
  const missing = native.createPlayer(path.join(os.tmpdir(), `no-such-clip-${process.pid}.mp4`));
  await pumpUntil(() => of(missing.id, 'player-error').length > 0).catch(() => fail('a missing file said nothing'));
  native.releasePlayer(missing.id);

  // --- let go -----------------------------------------------------------------------
  native.releasePlayer(id);
  native.removeFromSuperlayer(layer);
  const after = events.length;
  await pumpFor(600);
  if (events.slice(after).some((e) => e.id === id)) fail('a released player went on talking');
  if (native.playerCopyFrame(id, surface) !== null) fail('a released player had a frame');
  native.destroyWindow2(win);
  console.log('player: ok', JSON.stringify({ meta, onLayer, drawn, landed }));
  process.exit(0);
})().catch((e) => fail(e && e.stack ? e.stack : e));
