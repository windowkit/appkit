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
- **`postDragEvent(win, phase, { x, y, items, operations, local })`** drives
  the destination methods with a dragging info of the bridge's own over a
  private pasteboard — what `postMouseEvent` is to clicks. `'enter'` and
  `'over'` answer the operation the view returned (`'none'` when it refused),
  `'drop'` runs prepare + perform + conclude and answers whether the drop was
  taken. The CI smoke test and a renderer's headless tests drive drops this
  way.

## Privacy authorizations (TCC)

macOS decides per process whether an app may use the camera, microphone,
screen, accessibility, input monitoring or location, or send Apple Events to
another app. The bridge is mechanism only: read the status, raise the system
prompt where a framework offers one, and deep-link to the Settings pane where
it does not. Policy — when to ask, what to do with a refusal — stays in the
renderer.

```js
const { permissions, native } = require('@windowkit/appkit');

permissions.status('camera');             // 'authorized' | 'denied' | 'restricted' | 'notDetermined'
await permissions.request('microphone');  // raises the system prompt; resolves to granted (boolean)
permissions.status('automation', { target: 'com.apple.finder' });  // Apple Events, per target app
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

- A request answers **once, asynchronously** — never inside the call — and
  holds the event loop open until then, like pending I/O.
- **Attribution.** A bare `node` process is attributed to its *responsible
  process* (Terminal, an IDE) or to `node` itself, and prompts with no
  usage-description strings. A bundled app must carry the keys
  (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
  `NSLocationUsageDescription`, `NSAppleEventsUsageDescription`); without
  them the request never prompts, or TCC ends the process.
- **Folders** (Desktop, Documents, Downloads) need nothing native: reading the
  directory *is* the prompt and `EPERM` is the denial. `openSettings` also
  takes `'files-and-folders'` and `'full-disk-access'` for their panes.
- `restricted` is MDM or parental controls: the user cannot grant it.

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
