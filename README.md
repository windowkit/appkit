# @windowkit/appkit

A **retained-mode AppKit backend for Node.js**: Core Animation (CALayer)
layer trees, CoreText layout and drawing, IOSurface presentation, NSMenu,
native control bezels and the privacy (TCC) authorizations. It is the macOS
half of [react-x11][react-x11].
Instead of immediate-mode draw calls, you build a persistent tree of layers, mutate their
properties, and let the macOS WindowServer composite on the GPU — with implicit animations
and correct retina handling for free.

Built as a drawing-backend experiment for [react-x11]-style reconcilers: React elements map
1:1 to layers, and `commitUpdate` becomes `layer.set(props)`.

```bash
npm install   # builds the native addon (macOS only, needs Xcode CLT)
npm run demo  # hover/click the cards; press "q" to quit
```

## What the demo shows

- **CALayer tree** — frame/bounds/position, backgroundColor, cornerRadius, borderWidth,
  shadows, opacity, zPosition, `masksToBounds` clipping
- **Implicit animations** — hover/click a card: plain `layer.set({...})` property changes
  animate at 0.25s automatically
- **CATransaction** — the orange ball tweens over 1.1s with easeInEaseOut just by grouping
  a `position` change in a transaction
- **Explicit CABasicAnimation** — the spinner runs two infinite animations
  (`transform.rotation.z` + `strokeEnd`) entirely in the render server; they stay smooth
  even if the JS thread stalls
- **CATextLayer** — retina-crisp text composited by the WindowServer
- **CoreText** — glyphs measured (`CTLine`) and rasterized (`CTFramesetter` → `CGImage`)
  then set as `layer.contents`, i.e. the glyph-atlas path
- **CAGradientLayer + layer.mask** — the footer is a gradient masked by a text layer
- **CAShapeLayer** — CGPath commands, stroke/fill, dash patterns, animatable `strokeEnd`
- **Hit testing** — native `-[CALayer hitTest:]` mapped back to JS wrapper objects
- **Events** — mouse/keyboard from the NSApp event pump delivered to a JS callback
- **Native controls** — push buttons (incl. accent-filled default), checkboxes, radios,
  popup buttons, sliders, and switches rendered by AppKit itself and composited as layer
  contents; fully interactive (pressed states, toggles, slider drag) and re-renderable in
  dark/light appearance (the "Light / Dark" button flips all of them live)

## How it runs

Node's main thread *is* the process main thread on macOS, so the addon owns
`NSApplication` directly. In pump mode, the default, nobody calls `[NSApp run]`; instead JS
drives an event pump (`nextEventMatchingMask:` with `distantPast`) off a `setInterval`.
Core Animation animations execute in the render server, so their smoothness is
independent of the pump cadence — the JS timer only affects input latency. Threaded mode
(below) turns this around: the main thread stays in `[NSApp run]` and JS moves to a
Worker.

The window uses a **layer-hosting** `NSView` (we own the whole CALayer tree) with
`isFlipped = YES`, which makes AppKit give the hosted layer a top-left origin
(`geometryFlipped`) — coordinates match what a UI toolkit expects. Two flip gotchas are
handled in native code: `hitTest:` still takes bottom-up points, and
`renderInContext:` ignores `geometryFlipped` entirely (snapshots therefore capture the
window's real composited pixels via `CGWindowListCreateImage`, which needs no
screen-recording permission for the process's own windows).

## Threaded mode: AppKit on the main thread, JS on a worker

Pump mode has two costs. Input waits for the next tick, up to 8 ms. And every modal loop
AppKit runs — live resize, menu tracking, a drag, `runModal` — runs *inside* `pump2()`,
so timers, sockets and even microtasks wait for the gesture to end (a drag once held a
25 ms interval for 31 s, sidorares/react-x11#484). Threaded mode (windowkit/appkit#49)
swaps the roles: the process main thread parks in a real `[NSApp run]` for the life of the
app, and the renderer's JS runs on a `worker_threads` Worker, which no AppKit loop can
reach. Pump mode stays the default; calling `runMain()` is the switch.

```js
// main.js — the process main thread
const { Worker } = require('node:worker_threads');
const { native } = require('@windowkit/appkit');
native.initApp();
new Worker('./renderer.js');
const code = native.runMain(); // returns when the run ends
process.exit(code ?? 0);       // only this thread may end the process

// renderer.js — the worker
const { native } = require('@windowkit/appkit');
native.connect((batch) => {
  for (const ev of batch) {
    if (ev.type === 'signal') process.emit(ev.signal); // SIGINT never reaches a Worker
    else route(ev);
  }
});
// ...and when the app is done:
native.requestExit(0);
```

| verb | |
| --- | --- |
| `runMain()` | The process main thread only. Returns the code `requestExit` gave; `null` when the connected environment ended without asking (its own `process.exit`, which in a Worker ends only the worker, or an uncaught error); `128 + n` for a signal with nobody connected to hear it. |
| `connect(onEvents)` | From the renderer's thread, one environment at a time. `onEvents(batch)` gets an array of the same event objects pump mode's callback gets one by one. |
| `requestExit(code)` | Any thread. Ends the run; `runMain` returns `code`. |
| `threaded()` | `runMain` is running. |
| `windowState(windowNumber)` | `getWindowFrame`'s shape for a `createWindow2` window, from the published copy (below); `null` for no such window. Any thread, either mode. |
| `activationPolicy()` | The published activation policy. |
| `pingUI(tag)`, `postModalLoop('menu' \| 'modal', ms)` | Test hooks: a command answered by `ui-pong { tag, mode, drained }` from the UI thread, and a pop-up menu's tracking or an `NSAlert`'s `runModal`, ended by a timer and bracketed by `modal-loop-begin` / `modal-loop-end`. |

**Events out.** Every producer builds a plain record (never a JS object off its thread).
With the channel open, records are appended to one queue, and the first append after a
delivery makes one threadsafe call. The worker takes the whole queue as one batch, so a
worker busy for 200 ms gets what it missed together. Consecutive `mousemove` in one window
folds to the latest position before it crosses. Whatever is emitted before `connect` —
the launch's URL, input that arrived while the worker started — is the first batch. A
delivery runs in a callback scope, so a microtask queued inside `onEvents` runs right
after it. An exception thrown from `onEvents`, or from any callback the bridge answers
through, is that environment's uncaught exception: `process.on('uncaughtException')` sees
it, and with no handler the worker ends, and with it the run. The channel holds the
worker's loop open while any window or status item
exists, and lets it go when none does, so an app with nothing on screen can end.

**Commands in.** The command queue is a version-0 `CFRunLoopSource` on the main run loop, in
`kCFRunLoopCommonModes`, so it is drained during menu tracking (`NSEventTrackingRunLoopMode`),
`runModal` (`NSModalPanelRunLoopMode`) and live resize too. Each drain applies its
batch inside one `CATransaction` with implicit actions off. A command that starts a modal
loop runs from a run-loop callout of its own once its drain is done, so the rest of the
batch never waits behind the gesture.

**The verbs from a worker** (windowkit/appkit#51). The verbs are the same in both modes.
Each runs inline on the main thread, as it always has, and is queued from any other
thread. From a worker, what changes is the shape of what a verb returns, because JS never
waits on the UI thread (`test/threaded-verbs.js` covers each row):

| from a worker | verbs |
| --- | --- |
| unchanged, on the calling thread | surfaces, every `ctx*`, layouts and fonts, `pasteboardTypeForMIME`, `pasteboardTypeInfo`, `contentTypeFor`, `colorSpace` |
| a command, answering nothing | `initApp`, `setActivationPolicy`, `setAppName`, `activateApp`, `showWindow`, `hideWindow`, `setWindowFrame`, `setWindowTitle`, `setWindowMinMax`, `setWindowIgnoresMouseEvents`, `invalidateWindowShadow`, `destroyWindow2`, `setCursor`, `setMainMenu`, `setDockMenu`, `setDockBadge`, `cancelUserAttention`, `setStatusItem`, `setStatusItemMenu`, `removeStatusItem`, `registerDropTypes`, `setDropResponse`, `pasteboardWriteText`, `pasteboardClear`, `cancelPanel`; the test posts `postMouseEvent`, `postKeyEvent`, `postAppleEvent`, `postAccessibilityDisplayChange` |
| a handle at the call | `createWindow2`, followed by `window-created { handle, windowNumber }`; every event about the window, input included, carries `handle`, so `ev.handle === win` |
| | `windowRootLayer`, allocated with the window |
| | `createStatusItem`: its clicks carry the handle, and it is held until `removeStatusItem` |
| | `requestUserAttention`: a bridge id |
| | `openPanel` / `savePanel`: the answer through the callback, as before |
| the published copy | `getWindowFrame`, `windowIsVisible`, `windowNumber` (all `null` until the window is made), `listScreens`, `accessibilityDisplayOptions`, `activationPolicy`, `appInfo`, `pasteboardChangeCount` |
| a callback, the last argument | `pasteboardReadText`, `snapshotWindow`, `snapshotStatusItem`, `windowNumberAtPoint`, `mainMenuInfo`, `dockMenuInfo`, `statusItemInfo`, `activateMenuItem`, `activateDockMenuItem`, `activateStatusItemMenuItem`, `clickStatusItem`, `dragItems`, `dragItemData`, `dragItemString`, `postDragEvent`. On the main thread each still answers synchronously when no callback is given. |
| events | `beginDrag`: `drag-session-began`, or `drag-session-ended` with nothing dropped. Its `provide` is a TypeError; give every value up front. |

A few verbs behave differently from a worker:
- **`setDropResponse`** cannot answer the `draggingEntered:` that is running as its event
  crosses. It sets the standing answer for what follows. To make up for it, a drop carries
  `items: [{ types, strings }]`, its text and URL representations read in.
- **An app-modal panel** can be cancelled with `cancelPanel`, because the queue drains
  inside `runModal`.
- **`sampleScreenColor` and a location permission request** make their AppKit calls on the
  UI thread.
- **`pump2` and the first-generation API** (`createWindow`, `pump`, `setEventCallback`,
  `closeWindow`, `windowScale`, `windowContentSize`, `hitTest`, `drawControl`,
  `appearanceIsDark`) throw off the main thread.

**Frames from a worker** (windowkit/appkit#52). Pixels stay on the renderer's thread:
drawing into surfaces, CoreText and `ctxGetImageData` all work there. Layer changes go to
the UI thread, a frame at a time (`test/threaded-frames.js`):

- **One batch per frame.** Between `txBegin` and `txCommit` on a worker, the layer verbs
  record into that thread's frame batch. These are `createLayer` and its kinds, `set*Props`,
  `addSublayer`, `removeFromSuperlayer`, `addAnimation`, `removeAnimation` and
  `removeAllAnimations`, `setContentsImage`, `setLayerContentsIOSurface` and `surfaceToLayer`.
  The outermost `txCommit` posts the batch as one command. The UI thread applies it in the
  order it was recorded, in one commit, with `txBegin`'s options (`disableActions`,
  `duration`, `timing`) as pump mode would have them. A layer verb outside any `txBegin` is a
  command of its own, with actions on, as in pump mode's implicit transaction.
- **Layers are handles answered at the call.** The `CALayer` is made on the UI thread when
  the frame applies, so no layer is touched by two threads. `addAnimation` still answers its
  duration at the call, and `presentationValue` takes a callback.
- **Buffers change hands by event.** `surfaceToLayer` takes the bitmap at the call, so later
  drawing does not reach the frame already posted. `setLayerContentsIOSurface` flips when
  the frame applies. The renderer must not draw into the buffer the flip replaced until
  either `surface-released { id }` names it, sent once the frame has been committed, or
  `surfaceIsInUse(surface)` answers false.

**The live-resize handshake** (windowkit/appkit#53). In pump mode a resize stays in step for
free: `window-resize` runs the renderer inside `windowDidResize:` itself, so the new frame
commits with the moved edge. From a worker the frame comes back later, and without a
handshake the edge moves first while the content catches up a frame or more behind.
`setResizeHandshake(win, { waitMs })` turns the handshake on (`0`, the default, is off):

- When the window's size changes, whether by a live resize or `setWindowFrame`, the UI thread
  sends `window-resize`.
- It then waits, never longer than `waitMs`, for a frame batch committed with that size:
  `txCommit({ width, height })`, the renderer echoing the event's size.
- It applies that batch inline, so the frame lands in the same transaction as the new
  window size.
- Each wait is reported as `resize-handshake { width, height, live, waited, met }`.
- A live resize is bracketed by `window-live-resize { phase: 'begin' | 'end' }`, in both
  modes (windowkit/appkit#63). AppKit calls nothing when the pointer stops or lifts, so the
  end is how a renderer knows to run the measured layout it deferred during the drag. The
  published window state (`getWindowFrame`, `windowState`) carries `liveResize` too.

JS never waits on the UI thread, so the worst case is the deadline. A frame that misses it
shows the last frame at the new size, with the root layer's `backgroundColor` in the newly
exposed edge. The deadline is a strict dispatch timer (`DISPATCH_TIMER_STRICT`, zero
leeway), not a plain timed wait. Under a lower-QoS task policy, as on a CI runner or under
`taskpolicy -c utility`, the kernel coalesces timers: a 15 ms timed wait woke only when the
worker's own 60 ms timer fired.

Measured by `test/threaded-resize.js` on an M1 Pro, with 3 ms of layout per frame and a
50 ms budget:

| | met | waited, p50 |
| --- | --- | --- |
| 20 `setWindowFrame` steps | 20 of 20 | 3.07 ms |
| a live resize (AppKit's own tracking, driven by posted mouse events) | 28 of 28 | 3.11 ms |
| a frame 60 ms late against a 15 ms budget | no | stopped at the deadline, ~16 ms |

**Control bezels** (windowkit/appkit#54). The NSCell or NSControl behind a bezel is made
on the UI thread. Called from a worker, they used to draw correct pixels and then crash the
process at exit.
- `measureControl(params, cb)` answers `cb({ width, height })`.
- `drawControlIntoSurface(surface, params, cb)` draws straight into the worker's surface,
  with nothing copied, and `cb()` says it is done; until then the renderer leaves the
  surface alone.

On the main thread without a callback both answer in the call, as before. Off it, a call
without a callback is a TypeError.

**Published state.** The UI thread keeps a copy, under a lock, of what a renderer reads
back synchronously: each window's content rect, visibility, occlusion, key state and
scale; the screen list; the accessibility display options; the activation policy; and the
pasteboard's change count, polled every 250 ms since another app's write announces
nothing. While `runMain` runs, `listScreens`, `accessibilityDisplayOptions` and
`pasteboardChangeCount` answer from it when called off the main thread. On the main
thread they still ask AppKit live, as in pump mode.

**Exit and signals.** Before the run stops, menu tracking is cancelled and an app-modal
loop stopped, since `[NSApp stop:]` only ends the innermost loop. A drag session or a live
resize cannot be ended from code, so the exit waits for the button to come up. While the run lasts,
SIGINT, SIGTERM and SIGHUP are ignored as signals and read through a
`DISPATCH_SOURCE_TYPE_SIGNAL`, each arriving as `signal { signal: 'SIGINT' }`.
`applicationShouldTerminate:` answers Cancel and sends `app-quit-request`, as in pump mode.
A worker's `console.log` and `process.stdout` are forwarded through the main thread's event
loop, which is parked, so write with `fs.writeSync(1, …)` on the worker. `process.exit`
there ends only the worker; ending the app is `requestExit`.

Measured by `test/threaded.js` on an M1 Pro, macOS 15.2, Node 26:

| | |
| --- | --- |
| command + event round trip | 0.06 ms p50, 0.10 ms p95 |
| a microtask queued inside a delivery | ran 0.01 ms later, p50 |
| commands sent during a pop-up menu's tracking | 65 of 65 applied inside `NSEventTrackingRunLoopMode`; the worker's 5 ms timer's worst gap 8.7 ms |
| commands sent during an `NSAlert`'s `runModal` | 80 of 80 applied inside `NSModalPanelRunLoopMode`; worst gap 7.1 ms |

## API sketch

```js
const ca = require('@windowkit/appkit');
const { app, Window, Layer, TextLayer, GradientLayer, ShapeLayer,
        transaction, withoutAnimations } = ca;

const win = new Window({ width: 800, height: 560, title: 'hi' });

const card = new Layer();
card.set({
  frame: [32, 108, 228, 128],           // top-left origin, points (not pixels)
  backgroundColor: [0.98, 0.42, 0.36, 1],
  cornerRadius: 14,
  shadowOpacity: 0.5, shadowRadius: 12, shadowOffset: [0, 6],
});
win.root.add(card);

// implicit animation: just set the property
card.set({ backgroundColor: [0.36, 0.65, 0.98, 1] });

// batched, with custom duration/curve
transaction(() => card.set({ position: [400, 300] }),
            { duration: 1.1, timing: 'easeInEaseOut' });

// no animation (e.g. initial tree construction, reconciler commits)
withoutAnimations(() => card.set({ opacity: 0.5 }));

// explicit animation on any animatable keyPath — from/to, keyframes ('values') or a
// spring ('spring'); a curve by name or by control points; see "Animations"
card.animate('transform.rotation.z',
             { from: 0, to: Math.PI * 2, duration: 1, repeat: Infinity, timing: 'linear' });
card.animate('transform.translation.y',
             { values: [0, -6, 6, -6, 0], duration: 0.3, timing: [0.33, 1, 0.68, 1], id: 'shake' });

// text, two ways
const label = new TextLayer();
label.set({ frame: [0, 14, 228, 22], contentsScale: win.scale })
     .text({ string: 'hello', fontName: 'HelveticaNeue', fontSize: 15,
             color: [1, 1, 1, 1], align: 'center' });
card.add(label);

const glyphs = ca.text.render({ text: 'CoreText', fontName: 'Menlo',
                                fontSize: 13, color: [1, 1, 1, 1], scale: win.scale });
new Layer().set({ frame: [10, 10, glyphs.width, glyphs.height] }).setImage(glyphs);
ca.text.measure({ text: 'CoreText', fontName: 'Menlo', fontSize: 13 });
// -> { width, ascent, descent, leading }

// masks, gradients, shapes
const g = new GradientLayer();
g.gradient({ colors: [[1, 0, 0, 1], [0, 0, 1, 1]], startPoint: [0, 0.5], endPoint: [1, 0.5] });
g.set({ mask: someTextLayer });

const shape = new ShapeLayer();
shape.shape({ path: [['move', 0, 0], ['line', 50, 80], ['arc', 25, 25, 20, 0, Math.PI, false]],
              strokeColor: [1, 1, 1, 1], lineWidth: 4, lineCap: 'round', fillColor: null });

// input + hit testing
app.onEvent((ev) => {          // mousedown/up/move/drag, wheel, keydown/up
  const layer = win.hitTest(ev.x, ev.y);   // deepest Layer wrapper or null
});

app.run({ onTick: () => { if (!win.visible) process.exit(0); } });

win.snapshot('/tmp/out.png'); // real composited pixels of the window
```

## Animations

Core Animation runs an animation in the render server: the pump's cadence and a busy JS
thread do not touch it. The verbs here are shaped for a renderer that keeps its own model
of what is animating and hands over only the pixels — the layer's model value set under
`disableActions`, an explicit animation carrying the presentation from where it was to
where the model now is (react-x11's
[animation design](https://github.com/sidorares/react-x11/blob/master/docs/architecture/animation.md),
[#29](https://github.com/windowkit/appkit/issues/29)).

```js
// the model goes straight to its target, with no implicit animation…
withoutAnimations(() => card.set({ opacity: 1 }));
// …and an explicit one carries the pixels there
card.animate('opacity', { from: 0, to: 1, duration: 0.2, timing: [0.33, 1, 0.68, 1], id: 'fade' });
// native.addAnimation(layer, keyPath, opts, key) is the same call, and returns the
// duration in seconds — a spring's settling time
```

Three kinds, told apart by which option is present:

| options                                                  | animation             |                                                                                                   |
| -------------------------------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------- |
| `{ from, to, duration }`                                 | `CABasicAnimation`    | `duration` defaults to 0.25s                                                                      |
| `{ values, keyTimes?, timings?, calculationMode? }`      | `CAKeyframeAnimation` | `keyTimes` one per value in 0..1, never decreasing (evenly spaced when omitted); `timings` one curve per segment; `calculationMode` `linear` (default), `discrete`, `paced`, `cubic`, `cubicPaced` |
| `{ spring: { mass, stiffness, damping, initialVelocity } \| true, from, to }` | `CASpringAnimation` | CA's defaults for what is omitted (`true` is all of them); the duration is the settling time unless a `duration` cuts it short |

A value — `from`, `to`, an entry of `values` — is a number, a point `[x, y]`, or a colour
`[r, g, b, a]` in generic RGB like every colour in this API.

Options every kind takes:

| option        |                                                                                                                                                          |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `timing`      | a curve name — `linear`, `easeIn`, `easeOut`, `easeInEaseOut`, `default`, or their CSS spellings `ease-in`, `ease-out`, `ease-in-out`, `ease` — or cubic-bezier control points `[x1, y1, x2, y2]`. An unknown name is a `TypeError` |
| `repeat`      | a count, or `Infinity`                                                                                                                                   |
| `autoreverse` | turn around at the end of each pass                                                                                                                      |
| `additive`    | the values are deltas over the model value, and several in flight on one key path sum                                                                    |
| `cumulative`  | each repetition starts where the last ended                                                                                                              |
| `delay`       | seconds before it starts; the layer shows `from` while it waits (`fillMode: backwards`)                                                                  |
| `speed`, `timeOffset` | `CAMediaTiming`'s; `speed: 0` with a `timeOffset` is an animation paused at that time                                                             |
| `hold`        | keep the final value on screen after the end (`removedOnCompletion: NO`, `fillMode: forwards`) — the model value stays what it was                        |
| `id`          | report the end as a backend event (below)                                                                                                                |

Control points rather than names are what a renderer with its own interpolator needs: the
same four numbers evaluate to the same curve on its side and in the render server, where a
name means whatever each side thinks it means — react-x11's ease-out is
cubic-bezier(0.33, 1, 0.68, 1), and CA's named `easeOut` is (0, 0, 0.58, 1), a fifth of the
range apart at t = 0.35. `transaction(fn, { duration, timing })` takes the same forms.

**Retargeting without reading back.** Set the model to the new target and add an additive
animation `from: old − new, to: 0`: the pixels carry on from wherever the previous animation
had got to, because the previous one is still running and the two sum. That covers every
numeric key path (`opacity`, `position`, `transform.*`, `cornerRadius`, …). A colour cannot
be additive; for that there is `presentationValue`.

**`native.presentationValue(layer, keyPath)`** (`layer.presentationValue(keyPath)`) — the
value the render server is showing for that key path right now, animations applied: a
number, a point or size as `[x, y]`, a rect as `[x, y, w, h]`, a colour as `[r, g, b, a]`, a
transform as its sixteen components; `null` before the layer's first commit. A colour comes
back in sRGB, the space it went in, so it can be handed straight back as a `from` —
but CA interpolates in the display's space, so the components' midpoint there is not this
space's midpoint.

**`native.colorSpace()`** — `'sRGB'`: the space every colour crossing this bridge is in —
a layer's `backgroundColor`, `borderColor` and `shadowColor`, a shape's fill and stroke,
a gradient's stops, an animation's `from`/`to`, a presentation value, a text span's ink
and the surfaces `createSurface` makes. One space, so a colour set on a layer and the
same colour rastered into a surface composite to the same pixels. (Before 0.6 the layer
half was Generic RGB, which the compositor converts on its way to the display: `#dbe7f4`
on a layer showed as (228, 236, 245) beside a surface's (219, 231, 244), and a colour
animation landed on a model value that did not match its own `to`. A caller that draws
both ways — react-x11's layer promotion — feature-detects the verb.) `speed: 0, timeOffset: t` plus a read is how a curve is sampled without
waiting for it, which is how `test/animation.js` checks every curve above.

**The end of an animation.** With an `id`, the animation's delegate forwards
`animationDidStop:finished:` through `setBackendEventCallback` as

```js
{ type: 'animation-end', id, key, keyPath, finished }
```

`finished` is `false` for an animation that was removed (`removeAnimation`,
`removeAllAnimations`) or whose layer left the tree before it ran out. It arrives inside a
`pump2()`, like a window delegate's events. Without an `id` no delegate is set and nothing is
reported.

## Native controls

There is no WindowServer API for control drawing — AppKit draws controls in-process via
the **NSCell** architecture, and cells happily draw offscreen (the technique WebKit's
`RenderThemeMac` and Firefox's `nsNativeThemeCocoa` use for native form controls).
`ca.controls.render()` rasterizes a cell at retina scale under a chosen `NSAppearance`
and returns a `CGImage` for `layer.contents`:

```js
const img = ca.controls.render({
  kind: 'push',            // 'push' | 'checkbox' | 'radio' | 'popup' | 'slider' | 'switch'
  title: 'Click me',
  pressed: false,          // drive this from your own mouse events
  state: 1,                // on/off for checkbox/radio/switch
  isDefault: true,         // push: accent-filled default button
  value: 0.5,              // slider position
  controlSize: 'regular',  // 'mini' | 'small' | 'regular' | 'large'
  appearance: 'dark',      // 'system' | 'dark' | 'light'
  scale: win.scale,
});                        // -> { image, width, height, scale } (natural cellSize if
                           //    width/height omitted)
new Layer().set({ frame: [x, y, img.width, img.height] }).setImage(img);
```

Two render paths inside `drawControl`:

- **Cell path** (`NSButtonCell`, `NSPopUpButtonCell`): `drawWithFrame:inView:` into a
  bitmap `NSGraphicsContext`, wrapped in `performAsCurrentDrawingAppearance:` so dark
  mode and the user's accent color apply.
- **Offscreen-view path** (`NSSlider`, `NSSwitch`): modern `NSSliderCell` no longer
  draws offscreen (it defers to the view's layer machinery), and `NSSwitch` has no cell
  at all, so these render a real unparented `NSControl` via
  `displayRectIgnoringOpacity:inContext:`.

The demo re-renders a control's image on each state change; a real renderer would cache
per `(kind, size, state, appearance)` and nine-slice-stretch bezels with
`layer.contentsCenter`. Menus/popovers are deliberately *not* painted — their
vibrancy materials need private API to reproduce; expose real `NSMenu` instead.

`native.postMouseEvent(win, 'down'|'up'|'move'|'drag', x, y)` synthesizes events through
the real pump — used by the demo's self-test (`CAL_CLICKS="x,y;x,y" npm run demo`).

## Surfaces: blend modes and blits

A surface (`native.createSurface(wPx, hPx, scale)`, or `createSurfaceIOSurface` for the
zero-copy presentation kind) is a `CGBitmapContext` with a top-left origin and the canvas
drawing verbs over it — `ctxFillRect`, `ctxDrawSurface`, `ctxDrawGlyphs` and the rest.
Two of those verbs are what a 2d context needs to composite one surface into another
without paying for a `CGImage`:

- **`native.ctxSetBlendMode(surface, mode)`** — canvas's `globalCompositeOperation`, in
  CoreGraphics' spelling. Every canvas name maps to an exact `CGBlendMode`:
  `source-over` (the default) through `xor` and `lighter`, and the separable and
  non-separable blend modes below them, `multiply` … `luminosity`; `clear`,
  `plus-lighter` and `plus-darker` are CoreGraphics' own and go through too. A name off
  that list leaves the mode in force alone and answers `false` — canvas's rule for an
  unknown value, so a caller can keep its own property in step — and a known one answers
  `true`. The mode is graphics state, so `ctxSave`/`ctxRestore` bracket it.

  `copy` is the one that matters for compositing: it makes a paint a *replacement*
  rather than a blend, alpha included, which is what an offscreen surface presented into
  a window wants and what `PictOp.Src` means on the X11 side.

- **`native.blitSurface(src, sx, sy, w, h, dst, dx, dy, clip?)`** — a row `memcpy` of a
  rect of one surface into another, at surfaces of any two sizes, returning the
  destination rect it actually wrote as `[x, y, w, h]` or `null` when the intersection
  came out empty. `copySurfaceRegion` is the same-size special case a swapchain wants;
  this is the general one, for a caller compositing an offscreen surface into a window at
  a translate — a terminal's grid, an element's retained scene. It is exactly what a
  `copy`-mode `ctxDrawSurface` at 1:1 under a translate-only transform produces, byte for
  byte, without building a `CGImage` of the whole source: 2000x1620 into a window-sized
  surface is 1.2ms that way and 0.42ms this way on an M1 Pro.

  Coordinates are device pixels, top-left origin — the convention `createSurface`'s CTM
  gives user space, and the one `copySurfaceRegion`'s rects already use. Neither the
  destination's CTM nor its clip is visible to a `memcpy`, so `clip`, when given, is
  `[x, y, w, h]` in the **destination's** pixels and the caller passes the clip it is
  drawing under; a damage region of several rects is several calls. The rect copied is
  the destination rect intersected with that clip and with both surfaces' bounds, the
  source origin moving with it. An IOSurface-backed surface at either end wants the usual
  `surfaceLock`/`surfaceUnlock` bracketing, and two handles onto one bitmap — a shared
  IOSurface looked up at both ends, or a surface onto itself — are refused, because
  overlapping `memcpy` rows have no defined result.

```js
const grid = native.createSurface(2000, 1620, 2);   // the offscreen scene
const win = native.createSurface(2200, 1800, 2);    // what the window presents

// the composite, clipped to the paint pass's damage rect
native.blitSurface(grid, 0, 0, 2000, 1620, win, 40, 30, [100, 100, 1200, 900]);
// -> [100, 100, 1200, 900] — the clip, which the blit covered whole

// the same pixels the slow way, for anything that is not a 1:1 translate
native.ctxSetBlendMode(win, 'copy');
native.ctxDrawSurface(win, grid, 0, 0, 2000, 1620, 40, 30, 2000, 1620);
native.ctxSetBlendMode(win, 'source-over');
```

## App lifecycle: open-URL, open-file, reopen, quit

The OS talks to the application as a whole through Apple Events: a URL for a scheme
the bundle registers (`kInternetEventClass/kAEGetURL`), a document handed over by the
Finder (`kCoreEventClass/kAEOpenDocuments`), a second launch of a running app
(`kAEReopenApplication`), and Quit from the Dock, the app menu or a logout
(`kAEQuitApplication`). `native.initApp()` installs an `NSApplicationDelegate` that
forwards them to the backend event callback and decides nothing itself:

| event              | payload                 | from                                                                                                                                                                                  |
| ------------------ | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `app-open-urls`    | `{ urls: [string] }`    | `application:openURLs:` — scheme URLs as sent, documents as `file://` URLs                                                                                                            |
| `app-reopen`       | `{ hasVisibleWindows }` | `applicationShouldHandleReopen:`, answered NO — what a second launch means is the renderer's call                                                                                     |
| `app-quit-request` | `{}`                    | `applicationShouldTerminate:`, answered Cancel while a callback is installed — the renderer quits (`process.exit`) or vetoes. With no callback the OS default stands and the process ends |

```js
native.initApp();                 // first: the delegate has to precede finishLaunching
native.setBackendEventCallback((ev) => {
  if (ev.type === 'app-open-urls') route(ev.urls);
  if (ev.type === 'app-reopen' && !ev.hasVisibleWindows) showMainWindow();
  if (ev.type === 'app-quit-request') process.exit(0);
});
setInterval(() => native.pump2(), 16);
```

Launch Services delivers the launching Apple Event inside `finishLaunching` — that is,
inside `initApp()`, before any callback exists. Whatever arrives with nobody listening
is held and replayed, in order, on the first `pump2()` that has a callback, ahead of
that tick's input. Registering the scheme itself is an install step, not runtime code:
`CFBundleURLTypes` (and `CFBundleDocumentTypes` for files) in the bundle's
`Info.plist`.

`native.postAppleEvent('open-url', url)`, `('open-documents', [paths])`, `('reopen')`
and `('quit')` build the corresponding Apple Event and dispatch it through
`NSAppleEventManager` as if it had just arrived — how `npm test` exercises the
delegate without a bundle.

## File panels

Open and save dialogs are real `NSOpenPanel` / `NSSavePanel`s owned by this process's
`NSApplication` — not a separate `osascript` — so they can run as a sheet on the window
that asked, every filter the OS type database knows gets through, and a cancel is a
cancel rather than a failed subprocess.

```js
const { native } = require('@windowkit/appkit');

// With a window handle the panel is a sheet on it: the pump keeps running and the
// callback fires on a later tick. Without one it is app-modal: the call blocks in
// AppKit's modal loop until the panel is dismissed, and the callback runs before
// the call returns.
native.openPanel({
  window: win._h,               // omit for app-modal
  directory: false,             // true: choose folders instead of files
  multiple: true,
  message: 'Pick some images',
  prompt: 'Import',             // the confirm button's label
  directoryURL: process.env.HOME,
  allowedContentTypes: ['public.png', native.contentTypeFor({ mime: 'image/jpeg' })],
}, (paths) => { /* ['/Users/…/a.png', …], or null on cancel */ });

native.savePanel({
  window: win._h,
  nameFieldStringValue: 'Untitled.txt',
  allowedContentTypes: [native.contentTypeFor({ extension: 'txt' })],
}, (path) => { /* '/Users/…/Untitled.txt', or null on cancel */ });
```

Both take `title`, `message`, `prompt`, `directoryURL` (a path or `file:` URL),
`allowedContentTypes` and `canCreateDirectories`; the open panel adds `directory` and
`multiple`, the save panel `nameFieldStringValue`. Both return a panel handle:
`native.cancelPanel(handle)` dismisses a sheet that is still up (its callback then gets
`null`) and reports whether there was one, and `destroyWindow2` answers any sheet still
attached to the window the same way, so no callback is left waiting.

Filters are UTType identifiers, the shape `NSSavePanel.allowedContentTypes` wants;
mapping extensions and MIME types onto them is the renderer's policy, and
`native.contentTypeFor({ extension })` / `({ mime })` does the lookup in the OS's own
database (`'png'` → `'public.png'`, `'application/json'` → `'public.json'`; an
extension nobody has declared still gets a dynamic type that matches exactly that
extension). An absent or empty list means any file, and so does a list the OS
recognises nothing of.


## Drag and drop

The backend surface's windows (`native.createWindow2`) take drops and begin
drags through the hosting view — `NSDraggingDestination` and
`NSDraggingSource` — with every phase reported through the backend event
callback, the window's number attached, like every other window event.
Mechanism only: the renderer keeps the policy (what to accept, what a drop
means). Type names cross the boundary as pasteboard types — UTIs such as
`public.utf8-plain-text`, `public.file-url`, `public.png` — and mapping a MIME
vocabulary onto them is the renderer's job; `pasteboardTypeForMIME(mime)` and
`pasteboardTypeInfo(uti)` read the OS's own table for it (a MIME type no
declared type claims gets a `dyn.*` identifier that every process computes
alike).

```js
const { native } = require('@windowkit/appkit');
const win = native.createWindow2({ width: 640, height: 480, title: 'drop here' });

// destination: register, then answer AppKit's questions from inside the callback
native.registerDropTypes(win, ['public.file-url', 'public.utf8-plain-text']);
native.setBackendEventCallback((ev) => {
  switch (ev.type) {
    case 'drag-enter':   // { windowNumber, x, y, gx, gy, types, itemCount, sourceMask,
    case 'drag-over':    //   operations, local, sourceWindowNumber?, sequence }
      native.setDropResponse(win, { accept: ev.types.includes('public.file-url'),
                                    operation: 'copy' });
      break;
    case 'drag-exit':    // may carry no position: a drag cancelled mid-air
      break;
    case 'drag-perform': // the drop — read the payload now
      for (let i = 0; i < ev.itemCount; i++)
        console.log(native.dragItemString(i, 'public.file-url'));
      break;
    case 'drag-session-began':  // source side: x/y in global top-left coordinates
    case 'drag-session-moved':
    case 'drag-session-ended':  // + { operation: 'copy' | 'move' | ... | 'none', dropped }
      break;
  }
});

// source: from a press, once the renderer's own threshold says it is a drag
native.beginDrag(win, {
  x: press.x, y: press.y,                                           // content coords
  items: [{ 'public.utf8-plain-text': 'hello', 'public.png': null }],  // one item; null = lazy
  provide: (type, index) => renderPng(),        // asked when a consumer reads the promise
  operations: ['copy', 'move'],
  surface: previewSurface, imageX: node.x, imageY: node.y,          // or image: text.render(...)
});
```

- **`setDropResponse` answers the question being asked.** The callback runs
  synchronously inside `draggingEntered:` / `draggingUpdated:`, so a response
  set during `drag-enter` or `drag-over` is what AppKit gets back for that
  event. It stays in force for the `drag-over` events that follow until
  changed, and resets to a refusal when a new drag enters. `{ accept: false }`
  during `drag-perform` withdraws a drop after a look at the payload.
  `operation` absent picks copy, move, link, generic, private, delete — the
  first the source allows.
- **`types` is the pasteboard's union, promised translations included**: a
  `public.png` also appears as `public.tiff` and the legacy `Apple PNG
  pasteboard type`, a file URL as `NSFilenamesPboardType`. `dragItems()` lists
  the declared types per item; `dragItemData(index, type)` returns a `Buffer`
  and `dragItemString(index, type)` a string, `null` when the item has no such
  representation. A Finder drag of three files is three items of one
  `public.file-url` each. Read during `drag-perform`: the payload is the
  source's promise, and a source may withdraw it once its session has ended.
- **`beginDrag` returns at once.** The session is begun from the real
  mouse-down when the pointer is still down in the window (the event the
  renderer's threshold logic is reacting to), and runs on AppKit's own
  tracking from there: the pointer's `mousemove` / `mouseup` stop arriving,
  and `drag-session-ended` is the release. `items` is one entry per dragging
  item, each a map of type → string | bytes | `null`, where `null` is a
  promise answered by `provide(type, index)` when a consumer reads it — so a
  representation nobody asks for is never built. `operations` is the source's
  mask (`operationsOutside` for other applications when it differs),
  `ignoreModifiers` stops Option/Command turning it into copy/link, and
  `slideBack` (default on) animates a refused drop home. The image is a
  `surface` handle or a CGImage `image` (the `text.render` / `controls.render`
  result works whole), placed at `imageX` / `imageY` — centred on the press by
  default — at its own size unless `imageWidth` / `imageHeight` say otherwise.
  A drop on one of our own windows arrives through the destination events of
  that window with `local: true` and the source's `sourceWindowNumber`.
- **A preview window of your own is the window under the pointer.** A
  renderer that draws its drag preview as a live window of its own — a
  borderless popup following the pointer, instead of the session's image —
  has put a window between the pointer and every destination, and the window
  server finds that one first. Registering it for no dragged types is not a
  way past it: the drag then simply has no destination, and the window
  beneath never hears of it; transparent pixels pass no hit either.
  `createWindow2({ …, ignoresMouseEvents: true })`, or
  `setWindowIgnoresMouseEvents(win, flag)` on a live window, makes it one
  the pointer passes through, so a click or a drag reaches whatever is
  beneath; `getWindowFrame` reports the flag beside `visible` and `key`.
  `windowNumberAtPoint(x, y, belowWindowNumber?)` is the window server's own
  answer to which window a mouse-down at a global top-left point would
  reach, any application's, or 0 — the question the flag changes — and
  handing an answer back as `belowWindowNumber` looks beneath it, which is
  how a test finds its own windows under another application's.
- **`postDragEvent(win, phase, { x, y, items, operations, local })`** drives
  the destination methods with a dragging info of the bridge's own over a
  private pasteboard — what `postMouseEvent` is to clicks. `'enter'` and
  `'over'` answer the operation the view returned (`'none'` when it refused),
  `'drop'` runs prepare + perform + conclude and answers whether the drop was
  taken. The CI smoke test and a renderer's headless tests drive drops this
  way.


## Screen colour sampling (the eyedropper)

The dropper button on a colour picker asks for one pixel of the screen, which is
precisely the thing an application cannot draw for itself. `NSColorSampler` (10.15+)
is macOS's answer: the system shows its own loupe **out of process**, the user
magnifies and clicks, and the app is told the one colour they picked. Nothing here
reads the screen, so this needs no Screen Recording grant — and the user gets the
magnifier every other Mac colour picker shows them.

```js
const { screenColor, native, app } = require('@windowkit/appkit');

app.run();                                  // the answer arrives on the main thread

const color = await screenColor.sample();
// { r, g, b } — sRGB, 0–1 floats — or null if the user dismissed the sampler
if (color) paint(`#${[color.r, color.g, color.b].map((c) => Math.round(c * 255).toString(16).padStart(2, '0')).join('')}`);

// the same thing, unwrapped: cb(err, color)
native.sampleScreenColor((err, color) => { /* color, or null on a cancel */ });
```

- **A cancel is an ordinary outcome, not an error.** Escape (or a dismissal any other
  way) answers `null`, the same shape every rung of react-x11's eyedropper ladder
  answers a cancel with; an `Error` is reserved for a colour that could not be read at
  all.
- **sRGB, 0–1 floats**, the colour space every colour crosses this bridge in and the
  shape of the `org.freedesktop.portal.Screenshot.PickColor` triple this stands in for.
  The sampler reads the pixel in the display's own space — wide-gamut on most Macs
  now — and ColorSync gamut-maps on the way, so a Display P3 red arrives as
  `{ r: 1, g: 0, b: 0 }` rather than as components outside the range.
- **One at a time.** A second `sample()` while a loupe is up joins that session rather
  than stacking a second one — AppKit's own rule, its header says a show "begins or
  attaches to an existing color sampling session" — and both callers get the same
  answer, each once.
- **Nothing dismisses it from code.** AppKit offers no such call, so the session ends
  when the user picks a colour or presses Escape; there is no `cancelPanel` counterpart
  here. Until then the pending sample holds the event loop open like pending I/O, and
  the app has to be pumping (`app.run()`) to hear the answer — it is delivered on the
  main thread, like the location grant.


## Privacy authorizations (TCC)

macOS decides per process whether an app may use the camera, microphone,
screen, accessibility, input monitoring or location, read the user's
calendars and reminders, or send Apple Events to another app. The bridge is
mechanism only: read the status, raise the system prompt where a framework
offers one, and deep-link to the Settings pane where it does not. Policy —
when to ask, what to do with a refusal — stays in the renderer.

```js
const { permissions, native } = require('@windowkit/appkit');

permissions.status('camera');             // 'authorized' | 'denied' | 'restricted' | 'notDetermined'
await permissions.request('microphone');  // raises the system prompt; resolves to granted (boolean)
permissions.status('automation', { target: 'com.apple.finder' });  // Apple Events, per target app
permissions.status('calendars');          // the four words, or 'writeOnly' — macOS 14's save-only grant
await permissions.request('calendars', { access: 'write-only' });  // the narrower prompt; granted when write-only or full access is held
permissions.openSettings('screen-recording');  // System Settings › Privacy & Security › Screen Recording

// the natives underneath, callback-shaped
native.authorizationStatus(kind, opts?);                          // never prompts
native.requestAuthorization(kind, opts?, (granted, status) => {}); // once, asynchronously
native.openPrivacySettings(kind?);                                // no kind: the Privacy pane itself
```

| kind                     | status                                         | request                                    | notes                                                                                                                                                              |
| ------------------------ | ---------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `camera`, `microphone`   | `AVCaptureDevice authorizationStatusForMediaType:` | `requestAccessForMediaType:`           | all four statuses; the prompt is in-process and the answer arrives when the user clicks                                                                            |
| `screen-recording`       | `CGPreflightScreenCaptureAccess`               | `CGRequestScreenCaptureAccess`             | a bool, so never `notDetermined`; the "prompt" is the system's go-to-Settings dialog (shown once) and the request resolves at once. A new grant needs a process restart |
| `accessibility`          | `AXIsProcessTrusted`                           | `AXIsProcessTrustedWithOptions` + prompt   | a bool, so never `notDetermined`; go-to-Settings dialog, resolves at once, the grant applies live                                                                   |
| `input-monitoring`       | `IOHIDCheckAccess` (listen)                    | `IOHIDRequestAccess`                       | granted / denied / unknown → `notDetermined`; the request posts the prompt and resolves at once, `notDetermined` while it is still up                              |
| `automation`             | `AEDeterminePermissionToAutomateTarget`        | the same, asking                           | needs `{ target: bundleId }` of a **running** app, otherwise throws — TCC only answers for a running target. Asking blocks until answered, so it runs off the main thread |
| `location`               | `CLLocationManager.authorizationStatus`        | `requestWhenInUseAuthorization`            | the answer comes through the delegate on the main run loop, i.e. while `app.run()` is pumping                                                                      |
| `calendars`, `reminders` | `EKEventStore authorizationStatusForEntityType:` | `requestFullAccessToEventsWithCompletion:`, `requestWriteOnlyAccessToEventsWithCompletion:`, `requestFullAccessToRemindersWithCompletion:` (14+; `requestAccessToEntityType:completion:` before) | the fifth word: on macOS 14+ the status can be `writeOnly`, the partial grant that lets an app save items it cannot read. It crosses as it is — a writer treats it as granted, a reader as denied, and that is the renderer's call. `{ access: 'write-only' }` asks calendars for just that grant (reminders have no such grant: a TypeError); `granted` in the answer is whether the level asked for is held afterwards, so a write-only request is granted by write-only or full access. One `EKEventStore` serves the process, created by the first request — creating a store never prompts, only the request does — and it is the store the calendar-reading verbs share |

- A request answers **once, asynchronously** — never inside the call — and
  holds the event loop open until then, like pending I/O.
- **Attribution.** A bare `node` process is attributed to its *responsible
  process* (Terminal, an IDE) or to `node` itself, and prompts with no
  usage-description strings. A bundled app must carry the keys
  (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
  `NSLocationUsageDescription`, `NSAppleEventsUsageDescription`; for
  EventKit on macOS 14+ `NSCalendarsFullAccessUsageDescription`,
  `NSCalendarsWriteOnlyAccessUsageDescription` and
  `NSRemindersFullAccessUsageDescription`, and before 14
  `NSCalendarsUsageDescription` / `NSRemindersUsageDescription`); without
  them the request never prompts, or TCC ends the process. A sandboxed build
  also needs the App Sandbox's one EventKit entitlement,
  `com.apple.security.personal-information.calendars`.
- **A refusal is an answer; a prompt nobody saw is not.** After a calendars
  or reminders request the status is what the request reads back: `denied`
  when the user refused, and still `notDetermined` when nothing was shown
  (a bundle without the usage string, a process TCC cannot attribute) —
  measured on macOS 15.2, a bundle without the keys gets its answer within
  a few milliseconds, `granted` false and the status unchanged. The bridge
  does not tell those apart; the renderer re-reads and decides.
- **Folders** (Desktop, Documents, Downloads) need nothing native: reading the
  directory *is* the prompt and `EPERM` is the denial. `openSettings` also
  takes `'files-and-folders'` and `'full-disk-access'` for their panes.
- `restricted` is MDM or parental controls: the user cannot grant it.
## Calendars (EventKit)

Every account the user added in System Settings › Internet Accounts — iCloud,
Google, Exchange, CalDAV, a subscribed feed — is served by one framework,
`EKEventStore`: the macOS counterpart of Evolution Data Server plus GNOME
Online Accounts, where the desktop did the OAuth and the app never sees a
credential. Reading and writing go through the same store and the same
grant. Mechanism only — which calendars to show, how to draw an all-day
span, when to re-query and what to put in an event stay in the renderer.

```js
const { calendars, permissions, native } = require('@windowkit/appkit');

await permissions.request('calendars');          // the TCC grant — "Privacy authorizations" above

const list = await calendars.list();
// [{ id, title, color: [r, g, b, a] | null, type: 'local' | 'calDAV' | 'exchange' |
//    'subscription' | 'birthday', source: { id, title, type }, immutable,
//    allowsModifications, subscribed }]

const day = 24 * 60 * 60 * 1000;
const events = await calendars.eventsBetween({ start: Date.now(), end: Date.now() + 7 * day });
// the occurrences in the range, recurrences already expanded, sorted by start
const oneCalendar = await calendars.eventsBetween({
  start: new Date('2026-09-01'), end: new Date('2026-10-01'), calendars: [list[0].id],
});

native.setBackendEventCallback((ev) => {
  // 'calendar-store-changed' {}   something in the store changed: query again
});

// writing: the same store, the full grant or macOS 14's write-only one
const home = await calendars.defaultCalendar();   // where a save with no calendar goes, or null
const id = await calendars.saveEvent({
  title: 'Dentist', start: new Date('2026-10-05T09:00'), end: new Date('2026-10-05T10:00'),
  location: '12 High St', alarms: [{ offset: -15 * 60 }],
  recurrence: { frequency: 'weekly', daysOfWeek: [{ day: 2 }], count: 6 },   // six Mondays
});
const [, second] = await calendars.eventsBetween({ start, end, calendars: [home.id] });
await calendars.saveEvent({ id, occurrenceDate: second.occurrenceDate, start: later, end: later + hour }, { span: 'this' });
await calendars.saveEvent({ id, occurrenceDate: second.occurrenceDate, title: 'Orthodontist' }, { span: 'future' });
await calendars.removeEvent(id, { span: 'future' });   // the whole series, from its first occurrence
// a batch: nothing reaches the database until commit(); reset() forgets it instead
await calendars.saveEvent(a, { commit: false });
await calendars.saveEvent(b, { commit: false });
await calendars.commit();

// the natives underneath, callback-shaped
native.calendars(cb);                                   // cb(err, [calendar])
native.eventsBetween({ start, end, calendars? }, cb);   // epoch ms; cb(err, [event])
native.defaultCalendar(cb);                             // cb(err, calendar | null)
native.saveEvent(props, opts?, cb);                     // cb(err, id)
native.removeEvent(id, opts?, cb);                      // opts: { span, commit, occurrenceDate }; cb(err)
native.commitCalendarStore(cb);                         // cb(err)
native.resetCalendarStore(cb);                          // cb(null)
native.postCalendarStoreChanged();                      // test-only: the notification EventKit posts
```

| event field                     | what                                                                                                                                                                       |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`, `itemId`, `externalId`    | `eventIdentifier`, `calendarItemIdentifier`, `calendarItemExternalIdentifier` — `null` where the store has none (a local calendar's items carry no external id). Every occurrence of a series shares the series' `id`; a detached occurrence gets its own, the series' with `/RID=<slot>` appended |
| `calendar`                      | the `id` of the calendar it is in                                                                                                                                          |
| `title`, `location`, `notes`, `url` | strings, or `null` where the item has none — never `''` for absent                                                                                                     |
| `start`, `end`                  | epoch ms, as the store reports them                                                                                                                                        |
| `allDay`, `timeZone`            | `isAllDay`; the event's time-zone identifier (`'Europe/London'`) or `null` for a floating one                                                                               |
| `status`                        | `'none'`, `'confirmed'`, `'tentative'`, `'cancelled'`                                                                                                                      |
| `availability`                  | `'notSupported'`, `'busy'`, `'free'`, `'tentative'`, `'unavailable'`                                                                                                       |
| `recurring`, `detached`         | `hasRecurrenceRules`; whether this occurrence was edited away from its series                                                                                              |
| `occurrenceDate`                | where the occurrence sits in the series (epoch ms). For a detached occurrence that was moved, macOS 15.2 reports the start it was moved *to* (the original slot survives as the `RID=` in its `externalId`), not the documented original date — pass it back as reported |
| `organizer`, `attendees`        | present only when the event has them: `{ name, url, status, role, type, isCurrentUser }` — `url` is the `mailto:` the account gave, `status` `'unknown'` … `'inProcess'`, `role` `'required'`/`'optional'`/`'chair'`/`'nonParticipant'`, `type` `'person'`/`'room'`/`'resource'`/`'group'` |
| `recurrence`                    | present only on a recurring event: its rule in the shape `saveEvent` takes (below), so it can be read, changed and written back. The framework allows several rules on an item; the first is carried, which is the only one Calendar or any account writes |
| `alarms`                        | present only when the event has alarms: `[{ offset: seconds from the start, negative before it } \| { at: epoch ms }]` |

`saveEvent(props, opts?)` — every field but the ones that identify the event
is optional. On an existing event a field left out stays as it is and `null`
clears it; on a new one `start` and `end` are required.

| prop                                       | what                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`, `occurrenceDate`                     | neither: a new event. `id` names an existing one (`eventWithIdentifier:`); with `occurrenceDate` — as `eventsBetween` reported it for that occurrence — one occurrence of a recurring event, found through the same predicate the reads use; without it the first occurrence, which with `span: 'future'` is the whole series                                  |
| `calendar`                                 | a calendar id. A new event without one goes to `defaultCalendar()`; on an existing event it is a move, which an invitation refuses (`EKErrorInvitesCannotBeMoved`)                                                                                                                                                                                         |
| `title`, `location`, `notes`, `url`, `timeZone` | strings, or `null` to clear. `url` must be absolute (`https://…`), `timeZone` an identifier (`'Europe/London'`), `null` for a floating event                                                                                                                                                                                                               |
| `start`, `end`                             | epoch ms, or a `Date` through the wrapper. Inverted ones are the framework's to refuse (`EKErrorDatesInverted`)                                                                                                                                                                                                                                             |
| `allDay`                                   | in the store's own convention, the one `eventsBetween` reports: `start` at local midnight, `end` at the last second of the last day. An exclusive end — the next midnight — makes a two-day event (measured: it reads back as 48 hours)                                                                                                                       |
| `availability`                             | `'busy'`, `'free'`, `'tentative'`, `'unavailable'`                                                                                                                                                                                                                                                                                                        |
| `recurrence`                               | `EKRecurrenceRule`'s own vocabulary, what its initialiser takes: `{ frequency: 'daily' \| 'weekly' \| 'monthly' \| 'yearly', interval?, until? \| count?, daysOfWeek?: [{ day: 1..7 (Sunday = 1), week? }], daysOfMonth?, monthsOfYear?, weeksOfYear?, daysOfYear?, setPositions? }` — `until` epoch ms, `count` occurrences, neither for never; the arrays as iCalendar's BYDAY, BYMONTHDAY, BYMONTH, BYWEEKNO, BYYEARDAY, BYSETPOS, negatives counting from the end; `week` on a day only in a monthly (±1..5) or yearly (±1..53) rule. `null` removes the rule. Not an RRULE string: a consumer holding iCalendar text parses it on its own side |
| `alarms`                                   | `[{ offset: seconds from the start, negative before it }]` or `[{ at: epoch ms }]`; `null` or `[]` removes them                                                                                                                                                                                                                                             |
| `opts.span`                                | `'this'` (the default) or `'future'`: how far a change to — or the removal of — a recurring event reaches, `EKSpanThisEvent` / `EKSpanFutureEvents`. `'this'` on one occurrence detaches it (it then carries its own `id`); `'future'` from a middle occurrence splits the series there, and what follows answers under a new `id` — though the account keeps it with the original object, so removing `'future'` from an earlier occurrence takes the split-off part and any detached occurrence with it |
| `opts.commit`                              | `true` by default. `false` leaves the change pending for `commit()` — `commitCalendarStore` — and `reset()` forgets what is pending; the id is answered either way                                                                                                                                                                                          |

- **Reading needs the full grant.** Both verbs answer an error naming the
  status — `notDetermined`, `denied`, `restricted`, or macOS 14's `writeOnly`,
  which may save what it cannot read — rather than an empty list, so "no
  events" and "not allowed to look" stay distinguishable. Neither verb
  prompts: ask for `'calendars'` first. They share the one `EKEventStore` the
  grant created, and `refreshSourcesIfNecessary` runs before a listing so a
  calendar just added in Settings is there (the refresh itself is
  asynchronous; what it pulls in arrives as a change event).
- **Four years.** `predicateForEventsWithStartDate:endDate:calendars:` is
  limited to a four-year span, so a longer range is a `TypeError` at the
  bridge rather than a silently truncated answer — chunk it. An `end` before
  the `start` is one too, and so is a `calendars` filter naming nothing: an
  empty list would reach the predicate as "every calendar", the opposite of
  what it says. An id that names no calendar is an error through the
  callback, not a widened query.
- **All-day events cross as the store reports them**: `allDay` true, `start`
  at local midnight and `end` at the last second of the last day (23:59:59),
  *not* an exclusive end. Normalising is the renderer's job; the bridge is
  mechanism, and `test/calendars.js` pins the convention so a renderer's
  normalisation has something to be checked against.
- **Off the JS thread.** `eventsMatchingPredicate:` is synchronous and can
  take a while over many calendars, so both verbs run on a background queue
  and answer through a thread-safe function — never inside the call — holding
  the loop open like pending I/O until they do. What the framework hands back
  is copied into plain objects on that queue, so nothing EventKit-owned
  crosses to JS. Colours are converted to sRGB like every other colour on
  this bridge.
- **The change event.** EventKit posts one notification for *any* change, and
  its documented contract is "re-fetch": `'calendar-store-changed'` carries
  nothing, and the answer to it is to query again. The observer is installed
  with the process's store — i.e. from the first EventKit call, before a
  listener could exist — and a change that arrives before
  `setBackendEventCallback` is held and replayed at the start of the next
  `pump2()`, coalesced into one. The framework coalesces too, and a duplicate
  is harmless to a renderer whose answer is to re-query.
- **Writing needs either grant.** A save, a removal, a commit and the
  default calendar answer under the full grant or macOS 14's `writeOnly`
  one, and an error naming the status otherwise. Under write-only the store
  cannot read back what it saved — `eventWithIdentifier:` answers nil — so
  changing or removing an event by id is refused as the EKError it is
  (`EKErrorEventStoreNotAuthorized`) rather than reported as success; what
  a write-only app can do is add. Measured on 15.2: `defaultCalendar()`
  answers a stand-in the framework makes for the grant — id
  `VIRTUAL_APP_CALENDAR_UUID`, title "Calendar", a source called "Account"
  — and a save into it, or with no calendar named, lands in the user's real
  default calendar; `list()` and `eventsBetween()` answer the error naming
  `writeOnly`.
- **What the framework refuses crosses as its error, never as a bare
  boolean.** The rejection carries `code` (the `EKErrorCode` number),
  `domain` (`'EKErrorDomain'`) and `reason`, the code's name from the
  framework's own header — `EKErrorCalendarReadOnly`, `EKErrorNoCalendar`,
  `EKErrorDatesInverted`, `EKErrorInvitesCannotBeMoved` … — so a consumer
  can switch on the word; the message carries the framework's own text. An
  id that names no event, a calendar id that names none, an `occurrenceDate`
  that is not one of the series: errors through the callback with the
  bridge's own message. What the framework *raises* — a rule it cannot
  build, an object from another store — is caught and crosses the same way
  rather than ending the process. A save that finds nothing changed is not a
  failure.
- **Writes are serial.** Every write runs on one serial queue at the reads'
  QoS — off the JS thread, answered through a thread-safe function, never
  inside the call — and one after another in the order asked, which is what
  makes a batch (`commit: false` … `commit()`) mean something. A commit,
  the consumer's own included, is followed by `'calendar-store-changed'`,
  so a change made here and one made elsewhere look the same to the reader,
  which is correct.
- **No system sheet.** There is no `EKEventEditViewController` on macOS, so
  there is nothing to defer to; this is API only, and the renderer draws the
  editor.
- **Not here:** reminders (`EKReminder` has its own predicate and its own
  grant), calendars themselves (`saveCalendar:`), and attendees, which an
  account manages through its invitations.

## Status item (the menu-bar extra)

`NSStatusItem` is the tray. An item shows an image or a title (or both) in the
system status bar with a tooltip, and either owns a menu or reports clicks. The
menu takes the same item spec `setMainMenu` does, so the tray, the app menu bar
and — through react-x11's dbusmenu adapter — a Linux panel share one authoring
model; activations arrive as the same `menu-activate` events, tagged `menu: 'status'`.

```js
const { native } = require('@windowkit/appkit');
native.setBackendEventCallback((ev) => {
  if (ev.type === 'status-item-click') {      // only without a menu
    // ev.statusItem === item; ev.kind: 'left' | 'right' | 'middle'
    // ev.x/y/width/height: the item's screen rect, top-left global — the
    // anchor for a popup of your own; plus shift/control/option/command
  }
  if (ev.type === 'menu-activate') { /* ev.id from the spec below */ }
});

const item = native.createStatusItem({
  image: 'bell.badge',       // SF Symbol name — or a surface handle, or PNG bytes
  title: '3',                // beside the image, or alone
  tooltip: 'Notifications',
  length: 'variable',        // 'variable' | 'square' | points
});
native.setStatusItemMenu(item, [               // setMainMenu's item vocabulary
  { id: 1, title: 'Open', iconName: 'macwindow' },
  { separator: true },
  { id: 2, title: 'Quit', key: 'q' },
]);
native.setStatusItem(item, { title: '', visible: false });   // in-place patch
native.setStatusItemMenu(item, null);          // back to click events
native.removeStatusItem(item);
```

Images are **template** by default (`imageTemplate: false` keeps their colours),
so a bitmap icon follows the bar's light/dark the way a symbol does; a surface's
bitmap is taken at the surface's scale, and `imageSize: [w, h]` overrides the
size in points. With a menu set, a left or right click tracks the menu and no
click event fires; a middle click is reported either way. The item stays in
the bar until `removeStatusItem`, whatever happens to the handle, and it is
visible at creation unless told otherwise — AppKit's own memory of a hidden
item (user defaults, by creation order) does not carry over.

For tests: `statusItemInfo(item)` returns what the bar shows (title, tooltip,
visibility, image, length, the menu in `mainMenuInfo`'s shape, the screen
rect), `activateStatusItemMenuItem(item, [i, j, ...])` fires a menu item by
index path, `clickStatusItem(item, kind)` posts a real press-and-release into
the item's window (pump afterwards; declined for left/right while a menu is
set, since that click would open it), and `snapshotStatusItem(item, file)`
writes the composited item to a PNG.

## Dock & app presence

The handful of things an app shows outside its own windows — the Dock tile and the name
the Dock, the ⌘-Tab switcher and the menu bar print for it — as flat natives on
`ca.native`. Mechanism only: counts, reasons and timing stay in the renderer.

```js
const { native } = require('@windowkit/appkit');

// Activation policy. Decide it before the first window so an agent app never
// flashes a Dock tile: 'regular' (Dock tile, menu bar, ⌘-Tab entry),
// 'accessory' (none of those, windows still work — LSUIElement), 'prohibited'.
native.initApp({ activationPolicy: 'accessory' });
native.setActivationPolicy('regular');       // live switch afterwards -> bool

native.setDockBadge('3');                    // NSDockTile.badgeLabel; null clears
const id = native.requestUserAttention('critical'); // Dock bounce until activated;
                                                    // 'informational' bounces once
native.cancelUserAttention(id);              // ignored while the app is active anyway

// Dock menu (right-click the tile): one menu's worth of the item vocabulary
// setMainMenu takes. Activations arrive on the backend event callback as
// { type: 'menu-activate', id, menu: 'dock' } — menu-bar items say menu: 'main',
// status-item menus menu: 'status'.
native.setDockMenu([{ id: 7, title: 'New Window' }, { separator: true },
                    { id: 8, title: 'Recent', items: [{ id: 9, title: '…' }] }]);
native.setDockMenu(null);

// The display name. Best-effort: an unbundled process (node, bun) is renamed in
// LaunchServices' record of it, which is what the Dock and the switcher read; a
// bundle's Info.plist wins when it declares CFBundleName/CFBundleDisplayName (-> false).
native.setAppName('My App');

native.appInfo(); // -> { activationPolicy, name, dockBadge, active }
```

**Under a launcher** (windowkit/appkit#64), the app's own code may not have run when the app
launches. A threaded-mode launcher calls `initApp()` and `runMain()` on the main thread
before its worker has imported the app's entry, so the app's `initApp({ activationPolicy })`
from the worker comes after `finishLaunching`, by which time an agent app has already shown
its Dock tile. Two ways to set the policy before launch:
- **`APPKIT_ACTIVATION_POLICY=regular|accessory|prohibited`** is read as the app launches,
  whichever call launches it. An unknown name is reported on stderr, and the app launches
  regular.
- **`runMain({ activationPolicy })`** is the policy to launch with when `runMain` is what
  launches the app. If the app is already up, it is a live switch, as `setActivationPolicy` is.

A policy the code gives before launch (`initApp`, `setActivationPolicy`, `runMain`) wins
over the variable. A bundled app says the same with `LSUIElement` in its Info.plist.

`dockMenuInfo()` and `activateDockMenuItem([i, j, …])` mirror `mainMenuInfo()` and
`activateMenuItem()` for tests; both go through the delegate method the Dock itself calls.

## Desktop notifications (UNUserNotificationCenter)

Banners, the Notification Center list and action buttons through the
`UserNotifications` framework — the macOS counterpart of freedesktop's
`org.freedesktop.Notifications`, and the API that replaced the deprecated
`NSUserNotification`. Mechanism only: what to say, when to ask, and what to do
with a refusal stay in the renderer.

```js
const { notifications, native } = require('@windowkit/appkit');

const s = await notifications.settings();
// { available: false, bundleIdentifier: null, reason }            — a bare `node`: fall to another rung
// { available: true, bundleIdentifier, authorizationStatus,        — 'notDetermined' | 'denied' | 'authorized' | 'provisional'
//   alert, sound, badge, notificationCenter, lockScreen,           — 'notSupported' | 'disabled' | 'enabled'
//   criticalAlert, alertStyle, showPreviews, timeSensitive }

await notifications.requestAuthorization(['alert', 'sound', 'badge']);   // the system prompt, once per app -> granted
notifications.setCategories([
  { id: 'download', actions: [{ id: 'open', title: 'Open', foreground: true },
                              { id: 'trash', title: 'Delete', destructive: true }] },
]);
const id = await notifications.post({ title: 'Export finished', body: 'report.pdf — 2.4 MB',
                                      sound: 'default', categoryId: 'download',
                                      userInfo: { path: '/tmp/report.pdf' } });
await notifications.update(id, { title: 'Export finished', body: 'opened' });  // same identifier: replaced in place
notifications.remove(id);                                                    // out of Notification Center

native.setBackendEventCallback((ev) => {
  // 'notification-action'    { identifier, actionId, categoryId, userInfo }   actionId 'default' = a click on the banner
  // 'notification-dismissed' { identifier, reason: 'dismissed', categoryId, userInfo }
});

// the natives underneath, callback-shaped
native.notificationSettings(cb);                             // never throws; cb(settings) once, asynchronously
native.requestNotificationAuthorization(options, cb);        // cb(granted, error)
native.setNotificationCategories(categories);                // replaces the set
native.postNotification(props, cb?) -> identifier;           // cb(error | null) once the system has taken it
native.updateNotification(identifier, props, cb?);           // = post with that identifier
native.removeNotification(identifier | [identifiers]);       // delivered and pending
native.deliveredNotifications(cb); native.notificationCategories(cb);   // readback
native.postNotificationResponse({ identifier, actionId?, dismissed?, ... }); // test-only: a response as the
                                                             // delegate would queue it (no bundle needed)
```

- **The bundle-identity constraint.** The system attributes every banner to an
  app bundle — a `CFBundleIdentifier` Launch Services can see — and
  `UNUserNotificationCenter` raises (`bundleProxyForCurrentProcess is nil`) in
  a process that is none, which is what a bare `node` is. The centre is probed
  once, at `require` time, behind that check; the outcome is
  `settings().available`, with the reason when false. Every other call throws
  an `Error` in that state — never a silent drop — so check `available` and
  fall to another rung (`osascript display notification`, say). To run as a
  bundle, put the executable in `Name.app/Contents/MacOS/` with an
  `Info.plist` that names it and carries `CFBundleIdentifier`, and sign it
  (`codesign --force --deep --sign - Name.app` is enough locally).
- **Authorization** is the system's prompt, shown once per bundle id; until it
  is granted a post is refused with `UNErrorCodeNotificationsNotAllowed`
  (`error.code === 1`, `error.domain === 'UNErrorDomain'`), and the system
  keeps no categories for the app (`notificationCategories` reads back
  empty). The bridge keeps the last set and hands it over again when a
  request is granted.
- **The delegate** is installed at `require` time, before `initApp()` finishes
  launching, so a click that launched the app is delivered too. Responses are
  marshalled onto node's loop and emitted through the backend callback;
  anything that arrives before `setBackendEventCallback` is held and replayed
  at the start of the next `pump2()`, ahead of that tick's input. While the
  app is frontmost, `willPresent` still shows the banner (list and sound too).
- **Dismissals.** The system reports an explicit dismissal only for a category
  carrying `UNNotificationCategoryOptionCustomDismissAction`; every category
  set here carries it (`customDismissAction: false` opts out), and a
  notification with no `categoryId` is filed under a bridge-owned category
  that has it. A banner that times out into Notification Center, or is
  removed by `removeNotification`, is not reported by the system and produces
  no event. `'default'` is the `actionId` of a click on the banner itself, so
  it is not a name for an action of your own.
- `userInfo` is opaque: `JSON.stringify`'d on the way in and parsed back on
  the way out, so whatever JSON can carry round-trips exactly.

## Accessibility display options (reduce motion)

System Settings › Accessibility › Display, as `NSWorkspace` reports it — the switch a renderer
reads before it starts anything that moves on its own ([#31](https://github.com/windowkit/appkit/issues/31)):

```js
native.accessibilityDisplayOptions();
// -> { reduceMotion, reduceTransparency, increaseContrast, differentiateWithoutColor, invertColors }
accessibility.displayOptions();   // the same, on the wrapper
```

A change arrives as a backend event with the same five fields:

```js
{ type: 'accessibility-display-changed', reduceMotion, reduceTransparency, increaseContrast,
  differentiateWithoutColor, invertColors }
```

It comes from `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification`, delivered on the
main thread inside a `pump2()` like every other event. Nothing is held for a listener that is
not there yet — a setting is a fact rather than a message — so **install the callback, then
query**: the query is the state, the events are what changes it from then on.

Mechanism only: what to do with `reduceMotion` is the renderer's (react-x11: looping
`animation`s never start, a `transition` that ends still runs).

`native.postAccessibilityDisplayChange()` posts the same notification through the same centre,
so the observer path can be exercised without touching the user's settings — test-only, like
`postAppleEvent`; `test/accessibility-display.js` is the check.

## Mapping to a React reconciler

The shape of a host config on top of this:

| Reconciler op        | @windowkit/appkit                                        |
| -------------------- | -------------------------------------------------------- |
| `createInstance`     | `new Layer()` / `new TextLayer()` / ... per element type |
| `appendChild`        | `parent.add(child)`                                      |
| `removeChild`        | `child.remove()`                                         |
| `commitUpdate`       | `layer.set(diffedProps)`                                 |
| commit batch         | wrap in `withoutAnimations()` (or a `transaction()` to get animated updates for free) |
| `getPublicInstance`  | the `Layer` wrapper (hit-testing gives it back for events) |

Because the tree is retained and properties are mutable, the reconciler diff maps directly
onto layer mutations — no repaint pass, no damage rects; the WindowServer recomposites
only what changed.

## Caveats (POC)

- The pump-on-a-timer model means live window resizing/dragging runs AppKit's internal
  modal loops; input during those is choppy (Core Animation itself is unaffected).
  Threaded mode (above) is the way out.
- No `NSWindowDelegate` wiring yet — window resize is observable only by polling
  `win.size`; sublayers don't autolayout (by design — the reconciler owns layout).
- One shared event callback for all windows; per-window routing would need the window
  handle in the event payload.
- Layer handles are released on GC via External finalizers; native side keeps its own
  retains through the layer tree, so lifetime is safe but not tuned.
- `x64`/`arm64` follows whatever node arch you build with; no prebuilds.

[react-x11]: https://github.com/sidorares/react-x11
