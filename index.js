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

  // Explicit CABasicAnimation on any animatable keyPath, e.g.
  // 'transform.rotation.z', 'position', 'opacity', 'strokeEnd', 'backgroundColor'.
  animate(keyPath, opts = {}, key = keyPath) {
    native.addAnimation(this._h, keyPath, opts, key);
    return this;
  }

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

// Group property changes into one CATransaction (shared animation duration/timing).
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

module.exports = {
  app, Window, Layer, TextLayer, GradientLayer, ShapeLayer,
  transaction, withoutAnimations, text, controls, native,
};
