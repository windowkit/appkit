'use strict';
// The animation verbs (windowkit/appkit#29), read back through the
// presentation layer — the value the render server is showing — so what is
// checked is the animation CA runs, not the options that went in. Where a
// curve is sampled, the animation is frozen (speed 0, timeOffset t) and the
// sample is exact; where time has to pass (delay, completion), the pump runs
// and the tolerances are wide. Exits 0 when every expectation held.
//
// Checked: control points evaluate as a cubic bezier (the ease-out cubic's
// twin against a reference, and against CA's named easeIn); a keyframe
// animation follows its keyTimes and per-segment curves; an additive
// animation is a delta over the model value; a spring settles on `to` in the
// time it reports; a delay shows `from` while it waits and the model after;
// completion arrives as an event with the id, key, key path and whether it
// finished; the value types round-trip (point, colour, a transform
// component); and a bad shape is a TypeError with no animation added.

const { native } = require('..');

const fail = (msg, ...rest) => {
  console.error('animation:', msg, ...rest);
  process.exit(1);
};
const near = (a, b, tol) => typeof a === 'number' && Math.abs(a - b) <= tol;
const received = [];

function pumpUntil(pred, ms = 3000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const tick = setInterval(() => {
      native.pump2();
      if (pred()) {
        clearInterval(tick);
        resolve();
      } else if (Date.now() > deadline) {
        clearInterval(tick);
        reject(new Error('timed out; received so far: ' + JSON.stringify(received)));
      }
    }, 8);
  });
}
const pumpFor = (ms) => pumpUntil(() => false, ms).catch(() => {});
const ends = () => received.filter((e) => e.type === 'animation-end');

// a change under disableActions, committed, and the tree pumped once so the
// presentation layer exists and reflects it
function commit(fn) {
  native.txBegin({ disableActions: true });
  try { fn(); } finally { native.txCommit(); }
  native.pump2();
}

// a frozen animation: what the curve gives at `at` seconds into it. Never
// exactly the duration: CA folds that instant onto the start of the next
// cycle even for an animation that has none, so an end is sampled a
// millisecond early.
function sample(layer, keyPath, opts, at) {
  commit(() => native.addAnimation(layer, keyPath, { ...opts, speed: 0, timeOffset: at }, 'sample'));
  const v = native.presentationValue(layer, keyPath);
  commit(() => native.removeAnimation(layer, 'sample'));
  return v;
}

function throwsType(fn, what) {
  let threw = false;
  try { fn(); } catch (e) { threw = e instanceof TypeError; }
  if (!threw) fail('accepted a bad ' + what);
}

(async () => {
  native.initApp();
  native.setBackendEventCallback((ev) => received.push(ev));
  const win = native.createWindow2({ width: 160, height: 120, title: 'animation' });
  native.showWindow(win, false);
  const root = native.windowRootLayer(win);
  const layer = native.createLayer();
  commit(() => {
    native.addSublayer(root, layer);
    native.setLayerProps(layer, { frame: [10, 10, 60, 40], backgroundColor: [0, 0, 1, 1], opacity: 1 });
  });
  if (native.presentationValue(layer, 'opacity') !== 1) fail('no presentation layer after the first commit', native.presentationValue(layer, 'opacity'));

  // 1. control points are a cubic bezier: the ease-out cubic's twin at its
  //    midpoint against the reference (0.8722), CA's named easeIn against its
  //    control points (0.42, 0, 1, 1) — 0.3154 — and linear as the sanity line
  const linear = sample(layer, 'opacity', { from: 0, to: 1, duration: 1, timing: 'linear' }, 0.5);
  if (!near(linear, 0.5, 0.01)) fail('linear at 0.5', linear);
  const easeOutCubic = sample(layer, 'opacity', { from: 0, to: 1, duration: 1, timing: [0.33, 1, 0.68, 1] }, 0.5);
  if (!near(easeOutCubic, 0.8722, 0.01)) fail('control points [0.33, 1, 0.68, 1] at 0.5', easeOutCubic);
  const easeInNamed = sample(layer, 'opacity', { from: 0, to: 1, duration: 1, timing: 'easeIn' }, 0.5);
  const easeInPoints = sample(layer, 'opacity', { from: 0, to: 1, duration: 1, timing: [0.42, 0, 1, 1] }, 0.5);
  if (!near(easeInNamed, 0.3154, 0.01) || !near(easeInPoints, easeInNamed, 0.005)) fail('easeIn by name and by control points', easeInNamed, easeInPoints);
  const cssName = sample(layer, 'opacity', { from: 0, to: 1, duration: 1, timing: 'ease-in' }, 0.5);
  if (!near(cssName, easeInNamed, 0.005)) fail('the CSS spelling is the same curve', cssName);

  // 2. keyframes: values through keyTimes, and a curve per segment
  const kf = sample(layer, 'opacity', { values: [0, 1, 0], keyTimes: [0, 0.5, 1], duration: 1 }, 0.25);
  if (!near(kf, 0.5, 0.01)) fail('keyframes at 0.25', kf);
  const kfCurved = sample(layer, 'opacity', { values: [0, 1, 0], keyTimes: [0, 0.5, 1], timings: [[0.33, 1, 0.68, 1], 'linear'], duration: 1 }, 0.25);
  if (!near(kfCurved, 0.8722, 0.01)) fail('keyframes with an eased first segment at 0.25', kfCurved);
  const kfEven = sample(layer, 'opacity', { values: [0, 1, 0, 1], duration: 1 }, 0.5);
  if (!near(kfEven, 0.5, 0.01)) fail('keyframes evenly spaced at 0.5', kfEven);

  // 3. additive: a delta over the model. The model is 1; the animation runs
  //    -1 → 0, so the pixels start at 0 and arrive at the model.
  const addStart = sample(layer, 'opacity', { from: -1, to: 0, duration: 1, additive: true, timing: 'linear' }, 0);
  const addMid = sample(layer, 'opacity', { from: -1, to: 0, duration: 1, additive: true, timing: 'linear' }, 0.5);
  const addEnd = sample(layer, 'opacity', { from: -1, to: 0, duration: 1, additive: true, timing: 'linear' }, 0.999);
  if (!near(addStart, 0, 0.01) || !near(addMid, 0.5, 0.01) || !near(addEnd, 1, 0.01)) fail('additive over a model of 1', addStart, addMid, addEnd);

  // 4. a spring reports its settling time, and has settled by then
  let settling;
  commit(() => { settling = native.addAnimation(layer, 'opacity', { spring: { mass: 1, stiffness: 100, damping: 10 }, from: 0, to: 1, speed: 0, timeOffset: 0 }, 'spring'); });
  if (!(settling > 0.5 && settling < 10)) fail('spring settling duration', settling);
  const springStart = native.presentationValue(layer, 'opacity');
  commit(() => native.removeAnimation(layer, 'spring'));
  const springEnd = sample(layer, 'opacity', { spring: true, from: 0, to: 1 }, settling - 0.001);
  const springMid = sample(layer, 'opacity', { spring: { stiffness: 100, damping: 10 }, from: 0, to: 1 }, settling / 4);
  if (!near(springStart, 0, 0.01) || !near(springEnd, 1, 0.02) || !(springMid > 0.2)) fail('spring from 0 to 1', springStart, springMid, springEnd);
  const cut = native.addAnimation(layer, 'opacity', { spring: true, from: 0, to: 1, duration: 0.3, speed: 0 }, 'cut');
  if (cut !== 0.3) fail('a spring with an explicit duration keeps it', cut);
  commit(() => native.removeAnimation(layer, 'cut'));

  // 5. a delay: `from` shows while it waits (fill backwards), then the
  //    animation runs and is gone, leaving the model
  commit(() => native.addAnimation(layer, 'opacity', { from: 0, to: 1, duration: 0.2, delay: 0.6 }, 'delayed'));
  await pumpFor(100);
  const duringDelay = native.presentationValue(layer, 'opacity');
  if (!near(duringDelay, 0, 0.01)) fail('during the delay the layer shows `from`', duringDelay);
  await pumpFor(1200);
  const afterDelay = native.presentationValue(layer, 'opacity');
  if (!near(afterDelay, 1, 0.01)) fail('after the delayed animation the model shows', afterDelay);

  // 6. completion: an id makes the end an event; finished says whether it
  //    ran out or was removed
  const started = ends().length;
  commit(() => native.addAnimation(layer, 'opacity', { from: 0, to: 1, duration: 0.1, id: 'fade' }, 'fade'));
  await pumpUntil(() => ends().length === started + 1);
  const done = ends()[started];
  if (done.id !== 'fade' || done.key !== 'fade' || done.keyPath !== 'opacity' || done.finished !== true) fail('completion event', done);
  commit(() => native.addAnimation(layer, 'opacity', { from: 0, to: 1, duration: 5, id: 'cancelled' }, 'long'));
  commit(() => native.removeAnimation(layer, 'long'));
  await pumpUntil(() => ends().length === started + 2);
  const cancelled = ends()[started + 1];
  if (cancelled.id !== 'cancelled' || cancelled.key !== 'long' || cancelled.finished !== false) fail('a removed animation reports finished: false', cancelled);
  const silent = ends().length;
  commit(() => native.addAnimation(layer, 'opacity', { from: 0, to: 1, duration: 0.05 }, 'quiet'));
  await pumpFor(200);
  if (ends().length !== silent) fail('an animation without an id reports nothing');

  // 7. value types round-trip: a point, a colour, a transform component
  const pos = sample(layer, 'position', { from: [0, 0], to: [100, 50], duration: 1, timing: 'linear' }, 0.5);
  if (!Array.isArray(pos) || !near(pos[0], 50, 0.5) || !near(pos[1], 25, 0.5)) fail('position at 0.5', pos);
  // A colour comes back in the space it went in — sRGB, like every colour
  // this bridge makes, which `colorSpace()` says — so it can be handed
  // straight back as a `from`. CA interpolates in the display's space, where
  // the components' midpoint is not this space's midpoint — so the check is
  // that the mix is between its ends, not where exactly.
  if (native.colorSpace() !== 'sRGB') fail('colorSpace', native.colorSpace());
  const color = sample(layer, 'backgroundColor', { from: [1, 0, 0, 1], to: [0, 0, 1, 1], duration: 1, timing: 'linear' }, 0.5);
  if (!Array.isArray(color) || color.length !== 4 || !(color[0] > 0.2 && color[0] < 0.8 && color[2] > 0.2 && color[2] < 0.8) || !near(color[3], 1, 0.01)) fail('backgroundColor at 0.5', color);
  const same = sample(layer, 'backgroundColor', { from: [0.2, 0.6, 0.9, 0.5], to: [0.2, 0.6, 0.9, 0.5], duration: 1 }, 0.5);
  if (!Array.isArray(same) || !near(same[0], 0.2, 0.02) || !near(same[1], 0.6, 0.02) || !near(same[2], 0.9, 0.02) || !near(same[3], 0.5, 0.01)) fail('a colour round-trips in its own space', same);
  const rot = sample(layer, 'transform.rotation.z', { from: 0, to: Math.PI, duration: 1, timing: 'linear' }, 0.5);
  if (!near(rot, Math.PI / 2, 0.01)) fail('transform.rotation.z at 0.5', rot);
  const shown = native.presentationValue(layer, 'backgroundColor');
  if (!Array.isArray(shown) || !near(shown[2], 1, 0.01)) fail('the model colour reads back', shown);
  if (native.presentationValue(native.createLayer(), 'opacity') !== null) fail('an uncommitted layer has no presentation value');

  // 8. a transaction takes control points too, and a bad one throws before
  //    anything is begun
  native.txBegin({ duration: 0.3, timing: [0.33, 1, 0.68, 1] });
  native.setLayerProps(layer, { opacity: 0.5 });
  native.txCommit();
  native.pump2();
  throwsType(() => native.txBegin({ timing: 'bogus' }), 'transaction timing');
  commit(() => native.setLayerProps(layer, { opacity: 1 }));

  // 9. bad shapes are TypeErrors, and add nothing
  throwsType(() => native.addAnimation(layer, 'opacity', { from: 0, to: 1, timing: 'bogus' }, 'bad'), 'timing name');
  throwsType(() => native.addAnimation(layer, 'opacity', { from: 0, to: 1, timing: [0, 0, 1] }, 'bad'), 'timing with three points');
  throwsType(() => native.addAnimation(layer, 'opacity', { from: 0, to: 1, timing: [2, 0, 1, 1] }, 'bad'), 'timing with x outside 0..1');
  throwsType(() => native.addAnimation(layer, 'opacity', { values: [0, 'x'] }, 'bad'), 'keyframe value');
  throwsType(() => native.addAnimation(layer, 'opacity', { values: [0, 1, 0], keyTimes: [0, 1] }, 'bad'), 'keyTimes count');
  throwsType(() => native.addAnimation(layer, 'opacity', { values: [0, 1, 0], keyTimes: [0, 0.8, 0.5] }, 'bad'), 'decreasing keyTimes');
  throwsType(() => native.addAnimation(layer, 'opacity', { values: [0, 1, 0], timings: ['linear'] }, 'bad'), 'timings count');
  throwsType(() => native.addAnimation(layer, 'opacity', { values: [0, 1], spring: true }, 'bad'), 'values with spring');
  throwsType(() => native.addAnimation(layer, 'opacity', { spring: { mass: 0 }, to: 1 }, 'bad'), 'spring mass');
  throwsType(() => native.addAnimation(layer, 'opacity', { from: 'zero', to: 1 }, 'bad'), 'from');
  throwsType(() => native.addAnimation(layer, 'opacity', { from: 0, to: 1, id: 7 }, 'bad'), 'id');
  throwsType(() => native.addAnimation(layer, 'opacity', { values: [0, 1], calculationMode: 'wavy' }, 'bad'), 'calculationMode');
  native.pump2();
  if (near(native.presentationValue(layer, 'opacity'), 1, 0.01) !== true) fail('a rejected animation was added anyway', native.presentationValue(layer, 'opacity'));

  native.destroyWindow2(win);
  console.log('animation OK');
  process.exit(0);
})().catch((e) => fail(e.message));
