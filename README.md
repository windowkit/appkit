# @windowkit/appkit

A **retained-mode AppKit backend for Node.js**: Core Animation (CALayer)
layer trees, CoreText layout and drawing, IOSurface presentation, NSMenu and
native control bezels. It is the macOS half of [react-x11][react-x11].
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
`NSApplication` directly. Nobody calls `[NSApp run]`; instead JS drives an event pump
(`nextEventMatchingMask:` with `distantPast`) off a `setInterval`. Core Animation
animations execute in the render server, so their smoothness is independent of the pump
cadence — the JS timer only affects input latency.

The window uses a **layer-hosting** `NSView` (we own the whole CALayer tree) with
`isFlipped = YES`, which makes AppKit give the hosted layer a top-left origin
(`geometryFlipped`) — coordinates match what a UI toolkit expects. Two flip gotchas are
handled in native code: `hitTest:` still takes bottom-up points, and
`renderInContext:` ignores `geometryFlipped` entirely (snapshots therefore capture the
window's real composited pixels via `CGWindowListCreateImage`, which needs no
screen-recording permission for the process's own windows).

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

// explicit animation on any animatable keyPath
card.animate('transform.rotation.z',
             { from: 0, to: Math.PI * 2, duration: 1, repeat: Infinity, timing: 'linear' });

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
- No `NSWindowDelegate` wiring yet — window resize is observable only by polling
  `win.size`; sublayers don't autolayout (by design — the reconciler owns layout).
- One shared event callback for all windows; per-window routing would need the window
  handle in the event payload.
- Layer handles are released on GC via External finalizers; native side keeps its own
  retains through the layer tree, so lifetime is safe but not tuned.
- `x64`/`arm64` follows whatever node arch you build with; no prebuilds.

[react-x11]: https://github.com/sidorares/react-x11
