'use strict';

if (process.platform !== 'darwin') {
  throw new Error('@windowkit/appkit is macOS-only (Core Animation backend)');
}

const fs = require('fs');
const path = require('path');

// A local build wins (dev iteration), then the prebuilt binary bundled in
// the npm tarball for this platform/arch (see scripts/install.js — the
// package works even when install scripts are disabled), then a clear error.
function loadNative() {
  const candidates = [
    'build/Release/calayers.node',
    'build/Debug/calayers.node',
    `prebuilds/${process.platform}-${process.arch}/calayers.node`,
  ];
  const errors = [];
  for (const rel of candidates) {
    const abs = path.join(__dirname, rel);
    if (!fs.existsSync(abs)) continue;
    try {
      return require(abs);
    } catch (e) {
      errors.push(`  ${rel}: ${e.message}`);
    }
  }
  throw new Error(
    `@windowkit/appkit: no loadable native binary for ${process.platform}-${process.arch}\n` +
      (errors.length ? `tried:\n${errors.join('\n')}\n` : '') +
      'rebuild with: npm rebuild @windowkit/appkit --build-from-source (needs the Xcode command-line tools)',
  );
}

const native = loadNative();

// name -> wrapper, so native hitTest results map back to JS objects
const layersByName = new Map();
let seq = 0;

class Layer {
  constructor(handle) {
    this._h = handle || native.createLayer();
    this._name = 'layer:' + ++seq;
    native.setLayerProps(this._h, { name: this._name });
    layersByName.set(this._name, this);
    this.parent = null;
    this.children = [];
  }

  // Retained-mode property update. Changes to position/bounds/backgroundColor/
  // opacity/cornerRadius/transform/... on layers already in a tree get implicit
  // 0.25s animations from Core Animation unless wrapped in withoutAnimations().
  set(props) {
    if (props.mask instanceof Layer) props = { ...props, mask: props.mask._h };
    native.setLayerProps(this._h, props);
    return this;
  }

  add(child) {
    native.addSublayer(this._h, child._h);
    child.parent = this;
    this.children.push(child);
    return child;
  }

  remove() {
    native.removeFromSuperlayer(this._h);
    if (this.parent) {
      const i = this.parent.children.indexOf(this);
      if (i >= 0) this.parent.children.splice(i, 1);
      this.parent = null;
    }
  }

  // Explicit animation on any animatable keyPath, e.g. 'transform.rotation.z',
  // 'position', 'opacity', 'strokeEnd', 'backgroundColor': a CABasicAnimation
  // ({ from, to }), a CAKeyframeAnimation ({ values }) or a CASpringAnimation
  // ({ spring }) — README "Animations" lists the options. Returns the layer;
  // native.addAnimation returns the duration the animation will take (a
  // spring's settling time).
  animate(keyPath, opts = {}, key = keyPath) {
    native.addAnimation(this._h, keyPath, opts, key);
    return this;
  }

  // The value the render server is showing for a key path right now,
  // animations applied — null before the layer's first commit.
  presentationValue(keyPath) { return native.presentationValue(this._h, keyPath); }

  removeAnimation(key) { native.removeAnimation(this._h, key); }
  removeAllAnimations() { native.removeAllAnimations(this._h); }

  // img is the result of text.render() (or any {image, scale})
  setImage(img, scale) {
    native.setContentsImage(this._h, img.image, scale ?? img.scale);
    return this;
  }
}

class TextLayer extends Layer {
  constructor() { super(native.createTextLayer()); }
  // {string, fontName, fontSize, color, align, wrapped, truncation}
  text(props) { native.setTextProps(this._h, props); return this; }
}

class GradientLayer extends Layer {
  constructor() { super(native.createGradientLayer()); }
  // {colors: [[r,g,b,a],...], locations, startPoint, endPoint, type}
  gradient(props) { native.setGradientProps(this._h, props); return this; }
}

class ShapeLayer extends Layer {
  constructor() { super(native.createShapeLayer()); }
  // {path: [['move',x,y],['line',x,y],['arc',cx,cy,r,a0,a1,cw],...],
  //  fillColor, strokeColor, lineWidth, strokeStart, strokeEnd, lineCap, ...}
  shape(props) { native.setShapeProps(this._h, props); return this; }
}

class Window {
  constructor({ width = 640, height = 480, title = '' } = {}) {
    native.initApp();
    this._h = native.createWindow(width, height, title);
    this.root = new Layer(native.windowRootLayer(this._h));
    this.scale = native.windowScale(this._h); // backing scale (2 on retina)
  }
  get size() {
    const s = native.windowContentSize(this._h);
    return { width: s[0], height: s[1] };
  }
  get visible() { return native.windowIsVisible(this._h); }
  hitTest(x, y) {
    const name = native.hitTest(this.root._h, x, y);
    return (name && layersByName.get(name)) || null;
  }
  close() { native.closeWindow(this._h); }
  snapshot(file) { return native.snapshotWindow(this._h, file); } // renderInContext -> PNG
}

// Group property changes into one CATransaction (shared animation duration and
// timing — a curve name or cubic-bezier control points [x1, y1, x2, y2]).
function transaction(fn, opts = {}) {
  native.txBegin(opts);
  try { fn(); } finally { native.txCommit(); }
}

// Suppress implicit animations for this batch of changes.
function withoutAnimations(fn) {
  transaction(fn, { disableActions: true });
}

let timer = null;
const app = {
  onEvent(fn) { native.setEventCallback(fn); },
  // Drives the NSApplication event pump off node's event loop. Core Animation
  // itself animates in the render server, independent of this cadence.
  run({ fps = 60, onTick } = {}) {
    if (timer) return;
    native.initApp();
    timer = setInterval(() => {
      native.pump();
      if (onTick) onTick();
    }, Math.max(4, Math.floor(1000 / fps)));
  },
  stop() {
    if (timer) { clearInterval(timer); timer = null; }
  },
  pump: () => native.pump(),
};

const text = {
  // CoreText-rendered glyphs -> CGImage, for glyph-atlas style text.
  // {text, fontName, fontSize, color, maxWidth, scale} -> {image, width, height, scale}
  render: (opts) => native.createTextImage(opts),
  // {text, fontName, fontSize} -> {width, ascent, descent, leading}
  measure: (opts) => native.measureText(opts),
};

const controls = {
  // Native control bezels via offscreen NSCell drawing (WebKit/Firefox technique).
  // {kind: 'push'|'checkbox'|'radio'|'popup'|'slider', title, state, pressed,
  //  enabled, isDefault, value, controlSize, appearance: 'system'|'dark'|'light',
  //  width, height, scale} -> {image, width, height, scale}
  // width/height default to the cell's natural size (sliders must pass them).
  render: (opts) => native.drawControl(opts),
  isDark: () => native.appearanceIsDark(),
};

// Privacy (TCC) authorizations. kind: 'camera' | 'microphone' |
// 'screen-recording' | 'accessibility' | 'input-monitoring' | 'location' |
// 'automation' (with { target: bundleId }) | 'calendars' | 'reminders'
// (EventKit; calendars takes { access: 'full' | 'write-only' }, full by
// default). Status and request never touch policy: the renderer decides when
// to ask and what to do with a refusal.
const permissions = {
  // -> 'authorized' | 'denied' | 'restricted' | 'notDetermined', or
  // 'writeOnly' for calendars and reminders on macOS 14+: the app may save
  // items it cannot read, which is granted to a writer and denied to a reader
  // — the word crosses as it is so the caller can decide. Never prompts.
  status: (kind, opts) => native.authorizationStatus(kind, opts),
  // Raises the system prompt where macOS has one; resolves to granted — the
  // level asked for is held afterwards (for calendars with
  // { access: 'write-only' }, write-only or full). Screen recording and
  // accessibility can only be granted in Settings, so their prompt is the
  // system's go-to-Settings dialog and this resolves at once.
  request: (kind, opts) =>
    new Promise((resolve) => native.requestAuthorization(kind, opts, resolve)),
  // Best-effort deep link to the Privacy pane (or its top level with no kind);
  // also takes 'files-and-folders' and 'full-disk-access'.
  openSettings: (kind) => native.openPrivacySettings(kind),
};

// Desktop notifications through UNUserNotificationCenter — the macOS
// counterpart of org.freedesktop.Notifications. Mechanism only: what to say,
// when to ask and what to do with a refusal stay in the renderer. Banners
// are attributed to an app bundle, so a bare `node` process can post none:
// read settings().available first (it carries the reason when false) and
// fall to another rung; every other call throws in that state rather than
// dropping silently. Responses arrive as backend events, through
// native.setBackendEventCallback: 'notification-action' { identifier,
// actionId ('default' for a click on the banner itself), categoryId,
// userInfo } and 'notification-dismissed' { identifier, reason, ... }.
const notifications = {
  // -> { available: false, bundleIdentifier, reason } | { available: true,
  //      bundleIdentifier, authorizationStatus: 'notDetermined' | 'denied' |
  //      'authorized' | 'provisional', alert, sound, badge, ... }
  settings: () => new Promise((resolve) => native.notificationSettings(resolve)),
  // The system prompt, once per app; resolves to granted (boolean).
  requestAuthorization: (options = ['alert', 'sound', 'badge']) =>
    new Promise((resolve, reject) =>
      native.requestNotificationAuthorization(options, (granted, err) =>
        err ? reject(err) : resolve(granted))),
  // [{ id, actions: [{ id, title, destructive?, foreground? }] }] — the action
  // sets a notification's categoryId can name; replaces the whole set.
  setCategories: (categories) => native.setNotificationCategories(categories),
  // { identifier?, title, subtitle?, body?, sound?: 'default' | null,
  //   categoryId?, userInfo?, threadId?, badge? } -> identifier, once the
  // system has accepted it (rejects while the app is not authorized).
  post: (props) =>
    new Promise((resolve, reject) => {
      const id = native.postNotification(props, (err) => (err ? reject(err) : resolve(id)));
    }),
  // The same identifier again replaces the banner in place.
  update: (identifier, props) =>
    new Promise((resolve, reject) => {
      native.updateNotification(identifier, props, (err) => (err ? reject(err) : resolve(identifier)));
    }),
  remove: (identifiers) => native.removeNotification(identifiers),
  // readback: what is in Notification Center for this app, and the categories
  delivered: () => new Promise((resolve) => native.deliveredNotifications(resolve)),
  categories: () => new Promise((resolve) => native.notificationCategories(resolve)),
};

// A Date is a convenience of the wrapper's; the bridge takes epoch ms, and
// anything else is left alone so it is refused there rather than coerced.
const toMs = (v) => (v instanceof Date ? v.getTime() : v);

// The same for every date in a save: start, end, the occurrence, the
// recurrence's until, an absolute alarm. A spread leaves absent fields
// undefined, which the bridge reads as absent.
const eventMs = (p) => {
  const out = { ...p, start: toMs(p.start), end: toMs(p.end), occurrenceDate: toMs(p.occurrenceDate) };
  if (p.recurrence && typeof p.recurrence === 'object') out.recurrence = { ...p.recurrence, until: toMs(p.recurrence.until) };
  if (Array.isArray(p.alarms)) out.alarms = p.alarms.map((a) => (a && a.at instanceof Date ? { ...a, at: a.at.getTime() } : a));
  return out;
};
const optsMs = (o) => (o && o.occurrenceDate instanceof Date ? { ...o, occurrenceDate: o.occurrenceDate.getTime() } : o);

// The user's calendars, the occurrences in a date range, and the writes —
// an event put in, changed or taken out — through EventKit (EKEventStore):
// every account added in System Settings › Internet Accounts (iCloud,
// Google, Exchange, CalDAV, a subscribed feed) is served by it, and the
// desktop did the OAuth, so the app never sees a credential. Mechanism only:
// which calendars to show, how to render an all-day span, when to re-query
// and what to put in an event stay in the renderer.
//
// Reading needs the 'calendars' authorization (permissions.request); a write
// is content with macOS 14's write-only grant too. Without one these reject
// with an error naming the status rather than answering an empty list, so
// "no events" and "not allowed to look" stay apart. A change to anything in
// the store — the consumer's own commit included — arrives as a
// 'calendar-store-changed' backend event (native.setBackendEventCallback)
// whose only sensible answer is to query again; the observer is in place
// from the first EventKit call.
const calendars = {
  // -> [{ id, title, color: [r, g, b, a] | null (sRGB), type: 'local' |
  //      'calDAV' | 'exchange' | 'subscription' | 'birthday', source: { id,
  //      title, type }, immutable, allowsModifications, subscribed }]
  list: () =>
    new Promise((resolve, reject) =>
      native.calendars((err, list) => (err ? reject(err) : resolve(list)))),
  // { start, end, calendars?: [id] } — epoch ms or Date, at most a four-year
  // span (EventKit's own limit on the predicate; chunk anything longer).
  // Resolves to the occurrences in the range, recurrences already expanded by
  // the framework, sorted by start. All-day events come back as the store
  // reports them: allDay true, start at local midnight, end at the last
  // second of the last day — normalising that is the renderer's job.
  eventsBetween: ({ start, end, calendars: ids } = {}) =>
    new Promise((resolve, reject) =>
      native.eventsBetween(
        { start: toMs(start), end: toMs(end), calendars: ids },
        (err, events) => (err ? reject(err) : resolve(events)),
      )),
  // -> the calendar a save with no calendar goes to (defaultCalendarForNewEvents),
  //    in the shape list() gives, or null when the store has none
  defaultCalendar: () =>
    new Promise((resolve, reject) =>
      native.defaultCalendar((err, cal) => (err ? reject(err) : resolve(cal)))),
  // { id?, occurrenceDate?, calendar?, title?, start, end, allDay?, location?,
  //   notes?, url?, timeZone?, availability?, recurrence?, alarms? } — epoch ms
  // or Date. No id creates an event (start and end required; the default
  // calendar when none is named); an id changes that event, and with
  // occurrenceDate the one occurrence of a recurring one, a field absent
  // left as it is and null cleared. opts: { span: 'this' | 'future', commit }.
  // Resolves to the event's id. What the framework refuses rejects with its
  // EKError: { code, domain: 'EKErrorDomain', reason: 'EKErrorCalendarReadOnly' }.
  saveEvent: (props = {}, opts) =>
    new Promise((resolve, reject) =>
      native.saveEvent(eventMs(props), opts, (err, id) => (err ? reject(err) : resolve(id)))),
  // (id, { span, commit, occurrenceDate }) — the same span; the occurrence
  // when one is named.
  removeEvent: (id, opts) =>
    new Promise((resolve, reject) =>
      native.removeEvent(id, optsMs(opts), (err) => (err ? reject(err) : resolve()))),
  // A batch: saves and removes with { commit: false } wait for this, in the
  // order they were asked; reset() forgets them instead.
  commit: () =>
    new Promise((resolve, reject) =>
      native.commitCalendarStore((err) => (err ? reject(err) : resolve()))),
  reset: () => new Promise((resolve) => native.resetCalendarStore(resolve)),
};

// One colour off the screen — the eyedropper — through NSColorSampler, the
// system's own sampler: the loupe is drawn out of process, so this needs no
// Screen Recording grant and the user gets the magnifier every other Mac
// colour picker shows. Mechanism only: what the colour means past this — the
// hex a component paints with, whether a cancel resolves null or rejects —
// stays in the renderer.
//
// Nothing dismisses the sampler from code (AppKit offers no such call): the
// session ends when the user picks a colour or presses Escape, and until
// then the pending sample holds the event loop open. The answer arrives on
// the main thread, so the app has to be pumping (app.run()) to hear it.
const screenColor = {
  // -> { r, g, b } in sRGB, 0–1 floats (the Screenshot portal's (ddd) shape),
  //    or null when the user dismissed the sampler without picking: a cancel
  //    is an ordinary outcome, not an error. A sample asked for while one is
  //    already showing joins that session rather than stacking a second
  //    loupe, and both get the same answer.
  sample: () =>
    new Promise((resolve, reject) =>
      native.sampleScreenColor((err, color) => (err ? reject(err) : resolve(color)))),
};

const accessibility = {
  // System Settings › Accessibility › Display, as NSWorkspace reports it:
  // { reduceMotion, reduceTransparency, increaseContrast, differentiateWithoutColor, invertColors }.
  // A change arrives as an 'accessibility-display-changed' backend event with the same fields;
  // install the callback first, then read this (README "Accessibility display options").
  displayOptions: () => native.accessibilityDisplayOptions(),
};

module.exports = {
  app, Window, Layer, TextLayer, GradientLayer, ShapeLayer,
  transaction, withoutAnimations, text, controls, permissions, notifications, calendars,
  screenColor, accessibility, native,
};
