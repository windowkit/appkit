'use strict';
// The screen colour sampler (windowkit/appkit#46): NSColorSampler, the
// eyedropper's macOS rung. What runs unattended is the half that never puts
// the loupe on screen —
//
//   the verb and its wrapper being there for the capability check a consumer
//   makes, the argument shapes (every bad one a TypeError before anything is
//   shown, with no callback ever called), and a refused sample holding
//   neither a callback nor the event loop
//
// — because the session AppKit puts up ends only when a person picks a colour
// or presses Escape: nothing dismisses it from code, which is why the file
// panels' cancelPanel test has no counterpart here.
//
// The other half is one command away, by hand:
//
//   APPKIT_SAMPLE_COLOR=1 node test/screencolor.js
//
// which shows the real sampler, asks for a second sample while it is up to
// see that the two join one session rather than stacking two loupes, and
// prints what both callbacks got.
//
// Exits 0 when every expectation held.

const { native, screenColor } = require('..');

const fail = (msg, ...rest) => {
  console.error('screencolor:', msg, ...rest);
  process.exit(1);
};

// --- by hand: the sampler itself -------------------------------------------

function byHand() {
  const answers = [];
  const deadline = Date.now() + 120000;
  console.log('screencolor: the sampler is coming up — give it a moment, then click a colour (or press Escape to cancel)');
  // the wrapper, which is what a consumer calls
  screenColor.sample().then(
    (color) => answers.push(color),
    (err) => fail('the sample rejected', err),
  );
  setTimeout(() => {
    // a second sample while the first is still up: one session, two answers
    let sync = true;
    native.sampleScreenColor((err, color) => {
      if (sync) fail('the joined sample answered inside the call');
      if (err) fail('the joined sample answered an error', err);
      answers.push(color);
    });
    sync = false;
  }, 400);
  const pump = setInterval(() => {
    native.pump2();
    if (answers.length === 2) {
      clearInterval(pump);
      const [first, joined] = answers;
      if (JSON.stringify(first) !== JSON.stringify(joined)) {
        fail('the joined sample got a different answer', first, joined);
      }
      console.log('screencolor OK:', first === null ? 'cancelled' : JSON.stringify(first),
                  '— both callbacks answered once, from the one session');
      process.exit(0);
    } else if (Date.now() > deadline) {
      fail('timed out waiting for the sampler; answers so far:', answers);
    }
  }, 16);
}

// --- unattended: the shapes ------------------------------------------------

function shapes() {
  // 1. the verb and its wrapper are what a consumer feature-detects
  if (typeof native.sampleScreenColor !== 'function') fail('native.sampleScreenColor is not a function');
  if (typeof screenColor.sample !== 'function') fail('screenColor.sample is not a function');

  // 2. a call that is not one is refused before anything is shown, and a
  //    callback handed over in some other shape is never reached
  let called = 0;
  const cb = () => { called++; };
  const bad = [
    ['no callback', () => native.sampleScreenColor()],
    ['null for one', () => native.sampleScreenColor(null)],
    ['one inside an object', () => native.sampleScreenColor({ cb })],
    ['a string', () => native.sampleScreenColor('cb')],
  ];
  for (const [what, fn] of bad) {
    let err;
    try { fn(); } catch (e) { err = e; }
    if (!(err instanceof TypeError)) fail(what + ': expected a TypeError, got', err);
    if (!/expected a callback/.test(err.message)) fail(what + ': message', err.message);
  }

  // 3. nothing above held the loop: an unreferenced timer only fires if
  //    something else keeps the process alive — which a sampler that had
  //    been shown would, for as long as it was up
  setTimeout(() => fail('still running 3 s later: a refused sample held the loop open'), 3000).unref();
  process.on('exit', (code) => {
    if (code === 0 && called) fail('a refused sample called its callback');
  });
  console.log('screencolor OK:', bad.length, 'bad shapes refused, nothing shown');
}

if (process.env.APPKIT_SAMPLE_COLOR) byHand();
else shapes();
