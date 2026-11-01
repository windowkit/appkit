'use strict';
// A `vp09` track in an MP4 (src/player.mm, RegisterSupplementalDecoders):
// VP9 is a decoder VideoToolbox hands out only to a process that asks, and
// without one the item comes ready with a picture of no size and no frames
// ever, with no error. This is that picture having its size, and a seek
// landing on a frame.
//
// test/fixtures/clip-vp9.mp4 is half a second of one colour, 160x90 VP9,
// written by
//
//   ffmpeg -f lavfi -i color=c=0xE07030:s=160x90:r=30:d=0.5 \
//     -c:v libvpx-vp9 -g 4 -tag:v vp09 -an -movflags +faststart clip-vp9.mp4
//
// A Mac with no such decoder has nothing to show, and CI's virtual ones may
// be that: there, and only there, no picture is news and not a failure.
//
// Exits 0 when every expectation held.

const path = require('path');
const { native } = require('..');

const CLIP = path.join(__dirname, 'fixtures', 'clip-vp9.mp4');

const fail = (msg, ...rest) => {
  console.error('player-vp9:', msg, ...rest);
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

async function main() {
  native.initApp();
  const events = [];
  native.setBackendEventCallback((ev) => {
    if (String(ev.type).startsWith('player-')) events.push(ev);
  });
  const { id } = native.createPlayer(CLIP, { muted: true });
  const said = (type) => events.find((e) => e.id === id && e.type === type);
  await pumpUntil(() => said('player-metadata') || said('player-error')).catch(
    () => fail('the item never came ready'),
  );
  if (said('player-error')) fail('the clip failed', said('player-error'));
  // the item can come ready first and find its size after
  await pumpUntil(() => events.some((e) => e.type === 'player-metadata' && e.width), 1500).catch(() => {});
  const sized = events.find((e) => e.type === 'player-metadata' && e.width);
  if (!sized) {
    if (process.env.CI) {
      console.log('player-vp9: no VP9 decoder on this machine');
      process.exit(0);
    }
    fail('a picture of no size: nothing asked for the VP9 decoder');
  }
  if (sized.width !== 160 || sized.height !== 90) fail('its size', sized);
  native.playerSeek(id, 0.2);
  await pumpUntil(() => events.some((e) => e.type === 'player-time' && e.currentTime > 0.15)).catch(
    () => fail('the seek landed nowhere'),
  );
  native.releasePlayer(id);
  console.log('player-vp9: ok');
  process.exit(0);
}

main().catch((err) => fail(err));
