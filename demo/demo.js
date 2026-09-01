'use strict';
// Demo scene: everything here is retained-mode — we only mutate layer
// properties; the WindowServer composites and animates on the GPU.
//
//   node demo/demo.js
//
// Interactions: hover a card (implicit border/scale animation), click a card
// (color toggle + bounce), press "q" to quit. The orange ball moves inside a
// clipped panel via CATransaction every 1.4s.

const ca = require('..');
const { app, Window, Layer, TextLayer, GradientLayer, ShapeLayer, transaction, withoutAnimations } = ca;

const W = 800, H = 640;
const win = new Window({ width: W, height: H, title: '@windowkit/appkit — Core Animation from Node.js' });
const root = win.root;

// Build the initial tree without implicit animations (so it doesn't fade in).
let cards = [];
let ball, panel;

withoutAnimations(() => {
  // --- background gradient ---------------------------------------------------
  const bg = new GradientLayer();
  bg.set({ frame: [0, 0, W, H] }).gradient({
    colors: [[0.07, 0.08, 0.16, 1], [0.13, 0.07, 0.22, 1], [0.05, 0.12, 0.2, 1]],
    startPoint: [0, 0], endPoint: [1, 1],
  });
  root.add(bg);

  // --- title: CATextLayer (retina-crisp, WindowServer-composited) ------------
  const title = new TextLayer();
  title
    .set({ frame: [32, 22, W - 64, 34], contentsScale: win.scale })
    .text({ string: '@windowkit/appkit — CALayer scene graph from JavaScript',
            fontName: 'HelveticaNeue-Bold', fontSize: 22, color: [1, 1, 1, 1] });
  root.add(title);

  // --- subtitle: CoreText -> CGImage glyph buffer -> layer.contents ----------
  const sub = ca.text.render({
    text: 'CoreText path: glyphs measured & rasterized to a CGImage, set as layer contents',
    fontName: 'Menlo', fontSize: 12.5, color: [0.66, 0.73, 0.92, 1], scale: win.scale,
  });
  const subLayer = new Layer();
  subLayer.set({ frame: [33, 60, sub.width, sub.height], contentsScale: win.scale });
  subLayer.setImage(sub);
  root.add(subLayer);

  // --- cards: cornerRadius + shadow + hover/click ----------------------------
  const cardColors = [
    { base: [0.98, 0.42, 0.36, 1], alt: [0.36, 0.65, 0.98, 1], label: 'implicit anims' },
    { base: [0.42, 0.78, 0.55, 1], alt: [0.9, 0.62, 0.25, 1], label: 'cornerRadius' },
    { base: [0.55, 0.48, 0.95, 1], alt: [0.95, 0.48, 0.75, 1], label: 'shadows + hitTest' },
  ];
  cards = cardColors.map((c, i) => {
    const card = new Layer();
    card.set({
      frame: [32 + i * 252, 108, 228, 128],
      backgroundColor: c.base,
      cornerRadius: 14,
      shadowOpacity: 0.5, shadowRadius: 12, shadowOffset: [0, 6], shadowColor: [0, 0, 0, 1],
    });
    card._colors = c; card._on = false;

    const label = new TextLayer();
    label
      .set({ frame: [0, 14, 228, 22], contentsScale: win.scale })
      .text({ string: c.label, fontName: 'HelveticaNeue-Medium', fontSize: 15,
              color: [1, 1, 1, 0.95], align: 'center' });
    card.add(label);

    const hint = new TextLayer();
    hint
      .set({ frame: [0, 96, 228, 16], contentsScale: win.scale })
      .text({ string: 'hover me · click me', fontName: 'HelveticaNeue', fontSize: 11,
              color: [1, 1, 1, 0.7], align: 'center' });
    card.add(hint);

    root.add(card);
    return card;
  });

  // --- spinner: CAShapeLayer arc, two infinite explicit animations -----------
  const spinner = new ShapeLayer();
  spinner
    .set({ bounds: [44, 44], position: [W - 56, 46] })
    .shape({
      path: [['arc', 22, 22, 17, 0, Math.PI * 1.5, false]],
      fillColor: null, strokeColor: [1, 1, 1, 0.9], lineWidth: 4, lineCap: 'round',
    });
  root.add(spinner);
  spinner.animate('transform.rotation.z',
    { from: 0, to: Math.PI * 2, duration: 1.0, repeat: Infinity, timing: 'linear' }, 'spin');
  spinner.animate('strokeEnd',
    { from: 0.15, to: 1.0, duration: 0.9, repeat: Infinity, autoreverse: true, timing: 'easeInEaseOut' }, 'grow');

  // --- clipped panel with a ball moved via CATransaction ---------------------
  panel = new Layer();
  panel.set({
    frame: [32, 350, W - 64, 190],
    backgroundColor: [1, 1, 1, 0.06],
    cornerRadius: 16,
    borderWidth: 1, borderColor: [1, 1, 1, 0.15],
    masksToBounds: true, // ball is clipped by the rounded panel
  });
  root.add(panel);

  const panelLabel = new TextLayer();
  panelLabel
    .set({ frame: [16, 12, 620, 16], contentsScale: win.scale })
    .text({ string: 'CATransaction(duration: 1.1, easeInEaseOut) · masksToBounds clipping',
            fontName: 'Menlo', fontSize: 11, color: [1, 1, 1, 0.55] });
  panel.add(panelLabel);

  ball = new Layer();
  ball.set({
    bounds: [28, 28], position: [60, 100],
    backgroundColor: [1, 0.6, 0.2, 1], cornerRadius: 14,
    shadowOpacity: 0.6, shadowRadius: 8, shadowOffset: [0, 3], shadowColor: [1, 0.6, 0.2, 1],
  });
  panel.add(ball);

  // --- footer: gradient text via layer.mask ----------------------------------
  const footer = new GradientLayer();
  footer.set({ frame: [32, 566, W - 64, 30] }).gradient({
    colors: [[0.98, 0.45, 0.55, 1], [0.55, 0.65, 1, 1], [0.35, 0.95, 0.85, 1]],
    startPoint: [0, 0.5], endPoint: [1, 0.5],
  });
  const maskText = new TextLayer();
  maskText
    .set({ frame: [0, 0, W - 64, 30], contentsScale: win.scale })
    .text({ string: 'GPU compositing · implicit animations · retina text · layer masks',
            fontName: 'HelveticaNeue-Bold', fontSize: 17, color: [1, 1, 1, 1], align: 'center' });
  footer.set({ mask: maskText });
  root.add(footer);
});

// --- native controls: offscreen NSCell bezels composited as layers -----------
// Each control is just a layer whose contents is an AppKit-rendered CGImage;
// state changes re-render the image (cheap, cacheable per state in a real app).

let ctlAppearance = 'dark'; // matches the scene; the "Light" button flips it
const controlLayers = [];

function makeControl(kind, opts, x, y, action) {
  const layer = new Layer();
  const st = { kind, x, y, title: opts.title, on: !!opts.on, pressed: false,
               isDefault: !!opts.isDefault, value: opts.value,
               width: opts.width, height: opts.height };
  const rerender = () => {
    const img = ca.controls.render({
      kind, title: st.title, state: st.on ? 1 : 0, pressed: st.pressed,
      isDefault: st.isDefault, value: st.value, width: st.width, height: st.height,
      scale: win.scale, appearance: ctlAppearance,
    });
    withoutAnimations(() => {
      layer.set({ frame: [st.x, st.y, img.width, img.height], contentsScale: win.scale });
      layer.setImage(img);
    });
    st.w = img.width; st.h = img.height;
  };
  layer._ctl = { st, rerender, action };
  rerender();
  root.add(layer);
  controlLayers.push(layer);
  return layer;
}

const controlsLabel = new TextLayer();
controlsLabel
  .set({ frame: [32, 246, 700, 14], contentsScale: win.scale })
  .text({ string: 'NSCell path: native bezels drawn by AppKit offscreen, composited as layer contents',
          fontName: 'Menlo', fontSize: 11, color: [1, 1, 1, 0.55] });
root.add(controlsLabel);

let clicks = 0;
const clickLabel = new TextLayer();
clickLabel
  .set({ frame: [672, 273, 100, 16], contentsScale: win.scale })
  .text({ string: 'clicks: 0', fontName: 'Menlo', fontSize: 12, color: [1, 1, 1, 0.7] });
root.add(clickLabel);

makeControl('push', { title: 'Click me' }, 32, 268, () => {
  clickLabel.text({ string: `clicks: ${++clicks}` });
});
makeControl('push', { title: 'Light / Dark', isDefault: true }, 130, 268, () => {
  ctlAppearance = ctlAppearance === 'dark' ? 'light' : 'dark';
  controlLayers.forEach((l) => l._ctl.rerender());
});
makeControl('popup', { title: 'Popup', width: 110 }, 258, 268, () => {});
let moverDuration = 1.1;
makeControl('switch', { on: false }, 384, 268, (st) => { moverDuration = st.on ? 3.0 : 1.1; });
const switchLabel = new TextLayer();
switchLabel
  .set({ frame: [430, 273, 60, 16], contentsScale: win.scale })
  .text({ string: 'slow-mo', fontName: 'Menlo', fontSize: 12, color: [1, 1, 1, 0.7] });
root.add(switchLabel);
const slider = makeControl('slider', { value: 0.5, width: 170, height: 22 }, 480, 268, null);

makeControl('checkbox', { title: 'Card shadows', on: true }, 32, 308, (st) => {
  cards.forEach((c) => c.set({ shadowOpacity: st.on ? 0.5 : 0 }));
});
makeControl('checkbox', { title: 'Ball visible', on: true }, 170, 308, (st) => {
  ball.set({ hidden: !st.on });
});
const radios = ['orange', 'mint', 'sky'].map((name, i) =>
  makeControl('radio', { title: name, on: i === 0 }, 310 + i * 92, 308, (st, layer) => {
    radios.forEach((r) => { r._ctl.st.on = r === layer; r._ctl.rerender(); });
    const colors = { orange: [1, 0.6, 0.2, 1], mint: [0.35, 0.9, 0.6, 1], sky: [0.35, 0.7, 1, 1] };
    ball.set({ backgroundColor: colors[name], shadowColor: colors[name] });
  }));

const setSlider = (x) => {
  const st = slider._ctl.st;
  st.value = Math.min(1, Math.max(0, (x - st.x) / st.w));
  slider._ctl.rerender();
  ball.set({ transform: { scale: 0.5 + st.value * 1.8 } }); // implicit anim
};

// --- interactions ------------------------------------------------------------

const cardOf = (layer) => {
  while (layer && !cards.includes(layer)) layer = layer.parent;
  return layer || null;
};

const controlAt = (x, y) => {
  const l = win.hitTest(x, y);
  return l && l._ctl ? l : null;
};

let hovered = null;
let activeControl = null;  // push/popup being held down
let draggingSlider = null;

app.onEvent((ev) => {
  if (ev.type === 'mousemove') {
    const c = cardOf(win.hitTest(ev.x, ev.y));
    if (c !== hovered) {
      // Plain property sets — Core Animation animates these implicitly.
      if (hovered) hovered.set({ borderWidth: 0, transform: null });
      hovered = c;
      if (hovered) hovered.set({ borderWidth: 2, borderColor: [1, 1, 1, 0.9],
                                 transform: { scale: 1.05 } });
    }
  } else if (ev.type === 'mousedown') {
    const ctl = controlAt(ev.x, ev.y);
    if (ctl) {
      const { st, rerender, action } = ctl._ctl;
      if (st.kind === 'push' || st.kind === 'popup') {
        st.pressed = true; rerender();
        activeControl = ctl;
      } else if (st.kind === 'checkbox' || st.kind === 'switch') {
        st.on = !st.on; rerender();
        if (action) action(st, ctl);
      } else if (st.kind === 'radio') {
        if (action) action(st, ctl);
      } else if (st.kind === 'slider') {
        draggingSlider = ctl; setSlider(ev.x);
      }
      return;
    }
    const c = cardOf(win.hitTest(ev.x, ev.y));
    if (c) {
      c._on = !c._on;
      c.set({ backgroundColor: c._on ? c._colors.alt : c._colors.base }); // implicit color anim
      c.animate('transform.translation.y', { from: 0, to: -14, duration: 0.12, autoreverse: true }, 'bounce');
    }
  } else if (ev.type === 'mousedrag') {
    if (draggingSlider) setSlider(ev.x);
  } else if (ev.type === 'mouseup') {
    draggingSlider = null;
    if (activeControl) {
      const { st, rerender, action } = activeControl._ctl;
      st.pressed = false; rerender();
      if (controlAt(ev.x, ev.y) === activeControl && action) action(st, activeControl);
      activeControl = null;
    }
  } else if (ev.type === 'keydown' && ev.chars === 'q') {
    win.close();
  }
});

// Move the ball with an explicit, slow transaction — position tweens over 1.1s.
const mover = setInterval(() => {
  if (!win.visible) return;
  const { width, height } = { width: W - 64, height: 190 };
  const x = 24 + Math.random() * (width - 48);
  const y = 36 + Math.random() * (height - 60);
  transaction(() => ball.set({ position: [x, y] }), { duration: moverDuration, timing: 'easeInEaseOut' });
}, 1400);

app.run({
  onTick: () => {
    if (!win.visible) {
      clearInterval(mover);
      app.stop();
      process.exit(0);
    }
  },
});

console.log('demo running — hover/click the cards, press "q" (or close the window) to quit');

// CAL_CLICKS="x,y;x,y" posts synthetic clicks through the real event pump.
if (process.env.CAL_CLICKS) {
  const pts = process.env.CAL_CLICKS.split(';').map((s) => s.split(',').map(Number));
  pts.forEach(([x, y], i) => {
    setTimeout(() => {
      ca.native.postMouseEvent(win._h, 'down', x, y);
      ca.native.postMouseEvent(win._h, 'up', x, y);
    }, 400 + i * 150);
  });
}

// Headless-ish self test: CAL_SNAPSHOT=/path/out.png CAL_EXIT_MS=1500 node demo/demo.js
if (process.env.CAL_SNAPSHOT) {
  console.log('windowNumber:', ca.native.windowNumber(win._h));
  setTimeout(() => {
    const ok = win.snapshot(process.env.CAL_SNAPSHOT);
    console.log('snapshot:', ok ? process.env.CAL_SNAPSHOT : 'FAILED');
    process.exit(ok ? 0 : 1);
  }, Number(process.env.CAL_EXIT_MS || 1500));
}
