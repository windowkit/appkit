// @windowkit/appkit: retained-mode CALayer / CoreText backend for Node.js
//
// Design: node's main thread IS the process main thread on macOS, so we can own
// NSApplication from JS. We never call [NSApp run]; instead JS drives an event
// pump (nextEventMatchingMask with distantPast) on a timer. Core Animation
// runs its animations in the render server (WindowServer), so animations stay
// smooth regardless of pump cadence.

#include <napi.h>
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

static NSString* ToNSString(Napi::Value v) {
  std::string s = v.As<Napi::String>().Utf8Value();
  return [NSString stringWithUTF8String:s.c_str()];
}

static double NumOr(Napi::Object o, const char* k, double d) {
  if (!o.Has(k)) return d;
  Napi::Value v = o.Get(k);
  return v.IsNumber() ? v.As<Napi::Number>().DoubleValue() : d;
}

static bool BoolOr(Napi::Object o, const char* k, bool d) {
  if (!o.Has(k)) return d;
  Napi::Value v = o.Get(k);
  return v.IsBoolean() ? v.As<Napi::Boolean>().Value() : d;
}

static NSString* StrOr(Napi::Object o, const char* k, NSString* d) {
  if (!o.Has(k)) return d;
  Napi::Value v = o.Get(k);
  return v.IsString() ? ToNSString(v) : d;
}

// [r,g,b] or [r,g,b,a], components 0..1 — caller owns the returned color.
//
// sRGB, like every other colour this bridge makes: the surfaces
// (createSurface, backend.mm), a text span's ink, an animation's from/to
// (BMakeColor). This one used to be Generic RGB, which the compositor
// converts on its way to the display, so a layer's backgroundColor came out
// paler than the same colour rastered into a surface — #dbe7f4 showed as
// (228, 236, 245) beside a bitmap's (219, 231, 244) — and a colour animation
// landed on a model value that did not match its own `to`. One space
// everywhere, and `colorSpace()` says so.
static CGColorRef MakeColor(Napi::Value v) {
  Napi::Array a = v.As<Napi::Array>();
  double r = a.Get(0u).As<Napi::Number>().DoubleValue();
  double g = a.Get(1u).As<Napi::Number>().DoubleValue();
  double b = a.Get(2u).As<Napi::Number>().DoubleValue();
  double al = a.Length() > 3 ? a.Get(3u).As<Napi::Number>().DoubleValue() : 1.0;
  return CGColorCreateSRGB(r, g, b, al);
}

// The colour space every colour crossing this bridge is in — layer
// properties, animation values, presentation values, surfaces. A caller
// that rasters in sRGB can feature-detect that a layer colour will match.
static Napi::Value ColorSpace(const Napi::CallbackInfo& info) {
  return Napi::String::New(info.Env(), "sRGB");
}

static CGPoint PointFrom(Napi::Value v) {
  Napi::Array a = v.As<Napi::Array>();
  return CGPointMake(a.Get(0u).As<Napi::Number>().DoubleValue(),
                     a.Get(1u).As<Napi::Number>().DoubleValue());
}

static CGRect RectFrom(Napi::Value v) {
  Napi::Array a = v.As<Napi::Array>();
  return CGRectMake(a.Get(0u).As<Napi::Number>().DoubleValue(),
                    a.Get(1u).As<Napi::Number>().DoubleValue(),
                    a.Get(2u).As<Napi::Number>().DoubleValue(),
                    a.Get(3u).As<Napi::Number>().DoubleValue());
}

template <typename T>
static T Deref(Napi::Value v) {
  return (__bridge T)(v.As<Napi::External<void>>().Data());
}

#include <pthread.h>

#include "channel.h"

// The first-generation window API (createWindow, setEventCallback, pump,
// closeWindow, windowScale, windowContentSize, hitTest, drawControl,
// appearanceIsDark) is pump mode's: called off the main thread it is an
// Error, never a crash on AppKit's thread checks. The verbs the backend's
// windows share (windowRootLayer, windowNumber, windowIsVisible,
// snapshotWindow, postMouseEvent) follow threaded mode instead.
static bool PumpModeOnly(const Napi::CallbackInfo& info, const char* name) {
  if (pthread_main_np()) return true;
  Napi::Error::New(info.Env(), std::string(name) +
                                   ": the first-generation API is pump mode's — "
                                   "call it on the main thread")
      .ThrowAsJavaScriptException();
  return false;
}

// windowIsVisible from the published copy (backend.mm).
bool CALWindowVisible(long number, bool* visible);

// A worker's window handle (createWindow2 off the main thread), or nil.
static CALHandle* WindowHandleOf(Napi::Value v) {
  id target = CALHandleTarget(v);
  return [target isKindOfClass:[CALHandle class]] ? (CALHandle*)target : nil;
}

// Wrap an ObjC object as an External holding a +1 retain, released on GC.
static Napi::Value WrapRetained(Napi::Env env, id obj) {
  void* p = (void*)CFBridgingRetain(obj);
  return Napi::External<void>::New(env, p, [](Napi::Env, void* d) { CFRelease(d); });
}

// ---------------------------------------------------------------------------
// app / window
// ---------------------------------------------------------------------------

@interface CALHostView : NSView
@end
@implementation CALHostView
- (BOOL)acceptsFirstResponder { return YES; }
// AppKit forces the hosted layer's geometryFlipped to match isFlipped, so this
// is what actually gives the layer tree a top-left origin.
- (BOOL)isFlipped { return YES; }
// Swallow keys so unhandled keyDown doesn't beep; JS observes keys in the pump.
- (void)keyDown:(NSEvent*)event { (void)event; }
@end

// src/backend.mm owns the NSApplication setup (activation policy, no window
// tabbing, the app delegate that must precede finishLaunching); both faces
// of the addon share the one call so finishLaunching runs once.
void BEnsureApp();
static void EnsureApp() { BEnsureApp(); }

static Napi::Value CreateWindowFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!PumpModeOnly(info, "createWindow")) return env.Undefined();
  EnsureApp();
  double w = info[0].As<Napi::Number>().DoubleValue();
  double h = info[1].As<Napi::Number>().DoubleValue();
  NSString* title = info.Length() > 2 && info[2].IsString() ? ToNSString(info[2]) : @"";

  NSWindow* win;
  @autoreleasepool {
    NSRect rect = NSMakeRect(0, 0, w, h);
    win = [[NSWindow alloc]
        initWithContentRect:rect
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.releasedWhenClosed = NO;
    win.tabbingMode = NSWindowTabbingModeDisallowed;
    win.title = title;
    win.acceptsMouseMovedEvents = YES;

    // Layer-hosting view: we own the CALayer tree entirely.
    CALHostView* view = [[CALHostView alloc] initWithFrame:rect];
    CALayer* root = [CALayer layer];
    root.geometryFlipped = YES;  // top-left origin, like every UI toolkit
    [view setLayer:root];
    [view setWantsLayer:YES];
    win.contentView = view;
    root.contentsScale = win.backingScaleFactor;

    [win center];
    [win makeKeyAndOrderFront:nil];
    [win makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
  }
  return WrapRetained(env, win);
}

// From a worker: the root layer's handle, allocated with the window's (the
// layer verbs that take it are windowkit/appkit#52's).
static Napi::Value WindowRootLayer(const Napi::CallbackInfo& info) {
  if (!pthread_main_np()) {
    CALHandle* h = WindowHandleOf(info[0]);
    if (!h || !h->part_) return info.Env().Null();
    return CALWrapHandle(info.Env(), h->part_, false);
  }
  NSWindow* win = CALResolve(CALHandleTarget(info[0]));
  return WrapRetained(info.Env(), win.contentView.layer);
}

static Napi::Value WindowScale(const Napi::CallbackInfo& info) {
  if (!PumpModeOnly(info, "windowScale")) return info.Env().Undefined();
  NSWindow* win = Deref<NSWindow*>(info[0]);
  return Napi::Number::New(info.Env(), win.backingScaleFactor);
}

static Napi::Value WindowContentSize(const Napi::CallbackInfo& info) {
  if (!PumpModeOnly(info, "windowContentSize")) return info.Env().Undefined();
  NSWindow* win = Deref<NSWindow*>(info[0]);
  NSSize s = win.contentView.bounds.size;
  Napi::Array a = Napi::Array::New(info.Env(), 2);
  a.Set(0u, s.width);
  a.Set(1u, s.height);
  return a;
}

// From a worker: the published copy, null until the window is made.
static Napi::Value WindowIsVisible(const Napi::CallbackInfo& info) {
  if (!pthread_main_np()) {
    CALHandle* h = WindowHandleOf(info[0]);
    bool visible = false;
    if (!h || !CALWindowVisible(h->number_.load(), &visible)) return info.Env().Null();
    return Napi::Boolean::New(info.Env(), visible);
  }
  NSWindow* win = CALResolve(CALHandleTarget(info[0]));
  return Napi::Boolean::New(info.Env(), win.isVisible);
}

// From a worker: the number once the window is made, null before.
static Napi::Value WindowNumber(const Napi::CallbackInfo& info) {
  if (!pthread_main_np()) {
    CALHandle* h = WindowHandleOf(info[0]);
    long n = h ? h->number_.load() : 0;
    return n ? Napi::Value(Napi::Number::New(info.Env(), (double)n)) : info.Env().Null();
  }
  NSWindow* win = CALResolve(CALHandleTarget(info[0]));
  return Napi::Number::New(info.Env(), (double)win.windowNumber);
}

static Napi::Value CloseWindow(const Napi::CallbackInfo& info) {
  if (!PumpModeOnly(info, "closeWindow")) return info.Env().Undefined();
  NSWindow* win = Deref<NSWindow*>(info[0]);
  [win close];
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// event pump
// ---------------------------------------------------------------------------

static Napi::FunctionReference gEventCb;

static void DispatchEvent(Napi::Env env, NSEvent* e) {
  if (gEventCb.IsEmpty()) return;
  const char* type = nullptr;
  bool mouse = false, key = false, wheel = false;
  switch (e.type) {
    case NSEventTypeLeftMouseDown:  type = "mousedown"; mouse = true; break;
    case NSEventTypeLeftMouseUp:    type = "mouseup"; mouse = true; break;
    case NSEventTypeRightMouseDown: type = "rightdown"; mouse = true; break;
    case NSEventTypeRightMouseUp:   type = "rightup"; mouse = true; break;
    case NSEventTypeMouseMoved:     type = "mousemove"; mouse = true; break;
    case NSEventTypeLeftMouseDragged: type = "mousedrag"; mouse = true; break;
    case NSEventTypeScrollWheel:    type = "wheel"; mouse = true; wheel = true; break;
    case NSEventTypeKeyDown:        type = "keydown"; key = true; break;
    case NSEventTypeKeyUp:          type = "keyup"; key = true; break;
    default: return;
  }
  if (mouse && !e.window) return;  // e.g. moves outside any of our windows
  Napi::HandleScope scope(env);
  Napi::Object ev = Napi::Object::New(env);
  ev.Set("type", type);
  if (mouse && e.window) {
    NSView* v = e.window.contentView;
    NSPoint p = [v convertPoint:e.locationInWindow fromView:nil];
    ev.Set("x", p.x);
    ev.Set("y", v.isFlipped ? p.y : v.bounds.size.height - p.y);  // top-left origin
  }
  if (wheel) {
    ev.Set("dx", e.scrollingDeltaX);
    ev.Set("dy", e.scrollingDeltaY);
  }
  if (key) {
    ev.Set("keyCode", (double)e.keyCode);
    NSString* ch = e.charactersIgnoringModifiers;
    if (ch) ev.Set("chars", ch.UTF8String);
    ev.Set("repeat", (bool)e.isARepeat);
  }
  gEventCb.Call({ev});
}

// postMouseEvent(win, 'down'|'up'|'move'|'drag', x, y) — synthesizes an event
// through the normal pump path (top-left coords). Handy for automated tests.
// A command in threaded mode, like every test-only post.
static Napi::Value PostMouseEvent(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  std::string t = info[1].As<Napi::String>().Utf8Value();
  double x = info[2].As<Napi::Number>().DoubleValue();
  double y = info[3].As<Napi::Number>().DoubleValue();
  NSEventType type;
  if (t == "down") type = NSEventTypeLeftMouseDown;
  else if (t == "up") type = NSEventTypeLeftMouseUp;
  else if (t == "drag") type = NSEventTypeLeftMouseDragged;
  else type = NSEventTypeMouseMoved;
  CALOnUI(^{
    NSWindow* win = CALResolve(target);
    if (!win) return;
    NSView* v = win.contentView;
    NSPoint wp = [v convertPoint:NSMakePoint(x, y) toView:nil];  // v is flipped
    NSEvent* e = [NSEvent mouseEventWithType:type
                                    location:wp
                               modifierFlags:0
                                   timestamp:[[NSProcessInfo processInfo] systemUptime]
                                windowNumber:win.windowNumber
                                     context:nil
                                 eventNumber:0
                                  clickCount:1
                                    pressure:1];
    [NSApp postEvent:e atStart:NO];
  });
  return info.Env().Undefined();
}

static Napi::Value SetEventCallback(const Napi::CallbackInfo& info) {
  if (!PumpModeOnly(info, "setEventCallback")) return info.Env().Undefined();
  if (info[0].IsFunction()) {
    gEventCb = Napi::Persistent(info[0].As<Napi::Function>());
    gEventCb.SuppressDestruct();  // static: outlives the env, see backend.mm
  } else {
    gEventCb.Reset();
  }
  return info.Env().Undefined();
}

static Napi::Value Pump(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!PumpModeOnly(info, "pump")) return env.Undefined();
  EnsureApp();
  @autoreleasepool {
    while (true) {
      NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                      untilDate:[NSDate distantPast]
                                         inMode:NSDefaultRunLoopMode
                                        dequeue:YES];
      if (!e) break;
      DispatchEvent(env, e);
      [NSApp sendEvent:e];
    }
    [CATransaction flush];
  }
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// layers
// ---------------------------------------------------------------------------
//
// Frames from a worker (windowkit/appkit#52). On the main thread (pump mode)
// every layer verb acts in the call, as it always has. Off it a layer is the
// UI thread's to touch, and a frame's changes have to land in one commit
// with nothing between them: a verb called between txBegin and txCommit
// records into its thread's open batch, and the outermost txCommit posts
// the batch as one command, applied on the UI thread in the order it was
// recorded. txBegin and txCommit are recorded too, so what applies is the
// very sequence of Core Animation calls pump mode would make — inside the
// drain's transaction, so one commit, with actions as the frame asked for
// them. A verb outside any txBegin is a command of its own, in a transaction
// with actions on, as pump mode's implicit transaction has them. Arguments
// are read on the calling thread into plain values (colours, paths,
// transforms and animation objects are thread-safe to make); a layer is
// made on the UI thread when its create applies, behind a handle answered
// at the call.

struct FrameBatch {
  int depth = 0;
  std::vector<dispatch_block_t> ops;
};
static thread_local FrameBatch tlFrame;

// Set while the UI thread applies a worker's layer changes, whose replaced
// IOSurfaces are then reported.
static bool gApplyingWorkerFrame = false;
static std::vector<uint32_t> gReleasedSurfaces;  // the UI thread's

static void RunLayerOp(dispatch_block_t op) {
  @try {
    op();
  } @catch (NSException* e) {
    fprintf(stderr, "@windowkit/appkit: a layer change raised %s: %s\n",
            e.name.UTF8String, e.reason.UTF8String ?: "");
  }
}

// The IOSurfaces a worker's frame took off its layers, as
// `surface-released { id }`: from a block, which runs after the source
// callout that queued it — after the drain's commit — so the new buffer has
// gone to the render server before the renderer hears it may draw into the
// old one. (Whether the old one is still scanning out is IOSurfaceIsInUse's
// to say: surfaceIsInUse.)
static void FlushReleasedSurfaces() {
  if (gReleasedSurfaces.empty()) return;
  std::vector<uint32_t> ids = std::move(gReleasedSurfaces);
  gReleasedSurfaces.clear();
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
    for (uint32_t id : ids)
      CALEmit(std::move(CALEvent("surface-released").Num("id", (double)id)));
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

void CALNoteContentsReplaced(id layer, id next) {
  if (!gApplyingWorkerFrame) return;
  id old = ((CALayer*)layer).contents;
  if (!old || old == next ||
      CFGetTypeID((__bridge CFTypeRef)old) != IOSurfaceGetTypeID())
    return;
  gReleasedSurfaces.push_back(IOSurfaceGetID((__bridge IOSurfaceRef)old));
}

void CALOnLayers(dispatch_block_t op) {
  if (pthread_main_np()) {
    op();
    return;
  }
  if (tlFrame.depth > 0) {
    tlFrame.ops.push_back(op);
    return;
  }
  CALOnUI(^{
    gApplyingWorkerFrame = true;
    [CATransaction begin];
    [CATransaction setDisableActions:NO];
    RunLayerOp(op);
    [CATransaction commit];
    gApplyingWorkerFrame = false;
    FlushReleasedSurfaces();
  });
}

// A layer: made in the call on the main thread; from a worker, a handle now
// and the layer when its create applies.
static Napi::Value NewLayer(const Napi::CallbackInfo& info, CALayer* (^make)(void)) {
  if (pthread_main_np()) return WrapRetained(info.Env(), make());
  CALHandle* h = CALNewHandle();
  Napi::Value v = CALWrapHandle(info.Env(), h, false);
  CALOnLayers(^{ h->object_ = make(); });
  return v;
}

static Napi::Value CreateLayer(const Napi::CallbackInfo& info) {
  return NewLayer(info, ^CALayer* { return [CALayer layer]; });
}
static Napi::Value CreateTextLayer(const Napi::CallbackInfo& info) {
  return NewLayer(info, ^CALayer* {
    CATextLayer* t = [CATextLayer layer];
    t.contentsScale = 2.0;  // sane retina default; overridable via contentsScale
    return t;
  });
}
static Napi::Value CreateGradientLayer(const Napi::CallbackInfo& info) {
  return NewLayer(info, ^CALayer* { return [CAGradientLayer layer]; });
}
static Napi::Value CreateShapeLayer(const Napi::CallbackInfo& info) {
  return NewLayer(info, ^CALayer* { return [CAShapeLayer layer]; });
}

static Napi::Value AddSublayer(const Napi::CallbackInfo& info) {
  id parent = CALHandleTarget(info[0]), child = CALHandleTarget(info[1]);
  CALOnLayers(^{
    CALayer* p = CALResolve(parent);
    CALayer* c = CALResolve(child);
    if (p && c) [p addSublayer:c];
  });
  return info.Env().Undefined();
}

static Napi::Value RemoveFromSuperlayer(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  CALOnLayers(^{ [(CALayer*)CALResolve(target) removeFromSuperlayer]; });
  return info.Env().Undefined();
}

static CATransform3D TransformFrom(Napi::Value v) {
  if (v.IsNull() || v.IsUndefined()) return CATransform3DIdentity;
  Napi::Object t = v.As<Napi::Object>();
  CATransform3D m = CATransform3DIdentity;
  m = CATransform3DTranslate(m, NumOr(t, "translateX", 0), NumOr(t, "translateY", 0), 0);
  double rot = NumOr(t, "rotate", 0);  // radians
  if (rot != 0) m = CATransform3DRotate(m, rot, 0, 0, 1);
  double s = NumOr(t, "scale", 1);
  double sx = NumOr(t, "scaleX", s), sy = NumOr(t, "scaleY", s);
  if (sx != 1 || sy != 1) m = CATransform3DScale(m, sx, sy, 1);
  return m;
}

// A colour property as given: absent, null (cleared) or a colour.
struct ColorProp {
  bool given = false;
  id color = nil;  // a CGColor, owned by ARC through the bridge; nil clears
};

static ColorProp ColorPropOf(Napi::Object o, const char* key) {
  ColorProp c;
  if (!o.Has(key)) return c;
  c.given = true;
  Napi::Value v = o.Get(key);
  if (!v.IsNull()) c.color = CFBridgingRelease(MakeColor(v));
  return c;
}

static CGColorRef ColorOf(const ColorProp& c) { return (__bridge CGColorRef)c.color; }

// setLayerProps' object, read on the calling thread; only what is present
// is applied.
struct LayerPropsSpec {
  bool hasFrame = false, hasBounds = false, hasPosition = false, hasAnchor = false;
  CGRect frame = CGRectZero, bounds = CGRectZero;
  CGPoint position = CGPointZero, anchor = CGPointZero;
  bool hasZ = false;
  double z = 0;
  ColorProp background, border, shadow;
  bool hasCorner = false, hasBorderWidth = false, hasOpacity = false, hasHidden = false;
  bool hasMasks = false, hasShadowOpacity = false, hasShadowRadius = false;
  bool hasShadowOffset = false, hasContentsScale = false, hasName = false;
  bool hasMask = false, hasTransform = false, clearContents = false;
  double corner = 0, borderWidth = 0, shadowRadius = 3, contentsScale = 1;
  float opacity = 1, shadowOpacity = 0;
  bool hidden = false, masks = false;
  CGSize shadowOffset = CGSizeZero;
  NSString* name = nil;
  id mask = nil;  // a layer target; nil clears
  CATransform3D transform = CATransform3DIdentity;
};

static LayerPropsSpec ParseLayerProps(Napi::Object o) {
  LayerPropsSpec s;
  if (o.Has("frame")) {
    s.hasFrame = true;
    s.frame = RectFrom(o.Get("frame"));
  }
  if (o.Has("bounds")) {
    // [w, h] or [x, y, w, h] — the four-element form carries a bounds
    // ORIGIN, which is Core Animation's native scroll: the layer shows its
    // sublayers shifted by (-x, -y) with nothing repainted.
    s.hasBounds = true;
    Napi::Array a = o.Get("bounds").As<Napi::Array>();
    if (a.Length() >= 4) {
      s.bounds = CGRectMake(a.Get(0u).As<Napi::Number>().DoubleValue(),
                            a.Get(1u).As<Napi::Number>().DoubleValue(),
                            a.Get(2u).As<Napi::Number>().DoubleValue(),
                            a.Get(3u).As<Napi::Number>().DoubleValue());
    } else {
      s.bounds = CGRectMake(0, 0, a.Get(0u).As<Napi::Number>().DoubleValue(),
                            a.Get(1u).As<Napi::Number>().DoubleValue());
    }
  }
  if (o.Has("position")) {
    s.hasPosition = true;
    s.position = PointFrom(o.Get("position"));
  }
  if (o.Has("anchorPoint")) {
    s.hasAnchor = true;
    s.anchor = PointFrom(o.Get("anchorPoint"));
  }
  if (o.Has("zPosition")) {
    s.hasZ = true;
    s.z = NumOr(o, "zPosition", 0);
  }
  s.background = ColorPropOf(o, "backgroundColor");
  s.border = ColorPropOf(o, "borderColor");
  s.shadow = ColorPropOf(o, "shadowColor");
  if ((s.hasCorner = o.Has("cornerRadius"))) s.corner = NumOr(o, "cornerRadius", 0);
  if ((s.hasBorderWidth = o.Has("borderWidth"))) s.borderWidth = NumOr(o, "borderWidth", 0);
  if ((s.hasOpacity = o.Has("opacity"))) s.opacity = (float)NumOr(o, "opacity", 1);
  if ((s.hasHidden = o.Has("hidden"))) s.hidden = BoolOr(o, "hidden", false);
  if ((s.hasMasks = o.Has("masksToBounds"))) s.masks = BoolOr(o, "masksToBounds", false);
  if ((s.hasShadowOpacity = o.Has("shadowOpacity")))
    s.shadowOpacity = (float)NumOr(o, "shadowOpacity", 0);
  if ((s.hasShadowRadius = o.Has("shadowRadius"))) s.shadowRadius = NumOr(o, "shadowRadius", 3);
  if ((s.hasShadowOffset = o.Has("shadowOffset"))) {
    CGPoint p = PointFrom(o.Get("shadowOffset"));
    s.shadowOffset = CGSizeMake(p.x, p.y);
  }
  if ((s.hasContentsScale = o.Has("contentsScale")))
    s.contentsScale = NumOr(o, "contentsScale", 1);
  if ((s.hasName = o.Has("name"))) s.name = ToNSString(o.Get("name"));
  if ((s.hasMask = o.Has("mask"))) {
    Napi::Value v = o.Get("mask");
    s.mask = (v.IsNull() || v.IsUndefined()) ? nil : CALHandleTarget(v);
  }
  if ((s.hasTransform = o.Has("transform"))) s.transform = TransformFrom(o.Get("transform"));
  if (o.Has("contents")) s.clearContents = o.Get("contents").IsNull();
  return s;
}

// On the UI thread, in the order the keys have always been applied.
static void ApplyLayerProps(CALayer* L, const LayerPropsSpec& s) {
  if (s.hasFrame) L.frame = s.frame;
  if (s.hasBounds) L.bounds = s.bounds;
  if (s.hasPosition) L.position = s.position;
  if (s.hasAnchor) L.anchorPoint = s.anchor;
  if (s.hasZ) L.zPosition = s.z;
  if (s.background.given) L.backgroundColor = ColorOf(s.background);
  if (s.border.given) L.borderColor = ColorOf(s.border);
  if (s.shadow.given) L.shadowColor = ColorOf(s.shadow);
  if (s.hasCorner) L.cornerRadius = s.corner;
  if (s.hasBorderWidth) L.borderWidth = s.borderWidth;
  if (s.hasOpacity) L.opacity = s.opacity;
  if (s.hasHidden) L.hidden = s.hidden;
  if (s.hasMasks) L.masksToBounds = s.masks;
  if (s.hasShadowOpacity) L.shadowOpacity = s.shadowOpacity;
  if (s.hasShadowRadius) L.shadowRadius = s.shadowRadius;
  if (s.hasShadowOffset) L.shadowOffset = s.shadowOffset;
  if (s.hasContentsScale) L.contentsScale = s.contentsScale;
  if (s.hasName) L.name = s.name;
  if (s.hasMask) L.mask = s.mask ? CALResolve(s.mask) : nil;
  if (s.hasTransform) L.transform = s.transform;
  if (s.clearContents) {
    CALNoteContentsReplaced(L, nil);
    L.contents = nil;
  }
}

static Napi::Value SetLayerProps(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  LayerPropsSpec s = ParseLayerProps(info[1].As<Napi::Object>());
  CALOnLayers(^{
    CALayer* L = CALResolve(target);
    if (L) ApplyLayerProps(L, s);
  });
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// CATextLayer
// ---------------------------------------------------------------------------

static Napi::Value SetTextProps(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  Napi::Object o = info[1].As<Napi::Object>();
  bool hasSize = o.Has("fontSize");
  double size = NumOr(o, "fontSize", 14);
  NSString* fontName = o.Has("fontName") ? ToNSString(o.Get("fontName")) : nil;
  NSString* string = o.Has("string") ? ToNSString(o.Get("string")) : nil;
  ColorProp color = ColorPropOf(o, "color");
  NSString* align = o.Has("align") ? ToNSString(o.Get("align")) : nil;
  int wrapped = o.Has("wrapped") ? (int)BoolOr(o, "wrapped", false) : -1;
  NSString* truncation = o.Has("truncation") ? ToNSString(o.Get("truncation")) : nil;
  CALOnLayers(^{
    CATextLayer* T = (CATextLayer*)CALResolve(target);
    if (!T) return;
    if (hasSize) T.fontSize = size;
    if (fontName) {
      CTFontRef f = CTFontCreateWithName((__bridge CFStringRef)fontName,
                                         T.fontSize > 0 ? T.fontSize : 14, NULL);
      T.font = f;
      CFRelease(f);
    }
    if (string) T.string = string;
    if (color.given) T.foregroundColor = ColorOf(color);
    if (align) {
      if ([align isEqualToString:@"center"]) T.alignmentMode = kCAAlignmentCenter;
      else if ([align isEqualToString:@"right"]) T.alignmentMode = kCAAlignmentRight;
      else if ([align isEqualToString:@"justified"]) T.alignmentMode = kCAAlignmentJustified;
      else T.alignmentMode = kCAAlignmentLeft;
    }
    if (wrapped >= 0) T.wrapped = wrapped;
    if (truncation) {
      if ([truncation isEqualToString:@"start"]) T.truncationMode = kCATruncationStart;
      else if ([truncation isEqualToString:@"end"]) T.truncationMode = kCATruncationEnd;
      else if ([truncation isEqualToString:@"middle"]) T.truncationMode = kCATruncationMiddle;
      else T.truncationMode = kCATruncationNone;
    }
  });
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// CAGradientLayer
// ---------------------------------------------------------------------------

static Napi::Value SetGradientProps(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  Napi::Object o = info[1].As<Napi::Object>();
  NSMutableArray* colors = nil;
  if (o.Has("colors")) {
    Napi::Array arr = o.Get("colors").As<Napi::Array>();
    colors = [NSMutableArray arrayWithCapacity:arr.Length()];
    for (uint32_t i = 0; i < arr.Length(); i++) {
      [colors addObject:CFBridgingRelease(MakeColor(arr.Get(i)))];
    }
  }
  NSMutableArray* locs = nil;
  if (o.Has("locations")) {
    Napi::Array arr = o.Get("locations").As<Napi::Array>();
    locs = [NSMutableArray arrayWithCapacity:arr.Length()];
    for (uint32_t i = 0; i < arr.Length(); i++) {
      [locs addObject:@(arr.Get(i).As<Napi::Number>().DoubleValue())];
    }
  }
  bool hasStart = o.Has("startPoint"), hasEnd = o.Has("endPoint");
  CGPoint start = hasStart ? PointFrom(o.Get("startPoint")) : CGPointZero;
  CGPoint end = hasEnd ? PointFrom(o.Get("endPoint")) : CGPointZero;
  NSString* type = o.Has("type") ? ToNSString(o.Get("type")) : nil;
  CALOnLayers(^{
    CAGradientLayer* G = (CAGradientLayer*)CALResolve(target);
    if (!G) return;
    if (colors) G.colors = colors;
    if (locs) G.locations = locs;
    if (hasStart) G.startPoint = start;
    if (hasEnd) G.endPoint = end;
    if (type) {
      if ([type isEqualToString:@"radial"]) G.type = kCAGradientLayerRadial;
      else if ([type isEqualToString:@"conic"]) G.type = kCAGradientLayerConic;
      else G.type = kCAGradientLayerAxial;
    }
  });
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// CAShapeLayer
// ---------------------------------------------------------------------------

static CGPathRef BuildPath(Napi::Array ops) {
  CGMutablePathRef p = CGPathCreateMutable();
  for (uint32_t i = 0; i < ops.Length(); i++) {
    Napi::Array op = ops.Get(i).As<Napi::Array>();
    std::string cmd = op.Get(0u).As<Napi::String>().Utf8Value();
    auto n = [&](uint32_t idx) { return op.Get(idx).As<Napi::Number>().DoubleValue(); };
    if (cmd == "move") CGPathMoveToPoint(p, NULL, n(1), n(2));
    else if (cmd == "line") CGPathAddLineToPoint(p, NULL, n(1), n(2));
    else if (cmd == "curve") CGPathAddCurveToPoint(p, NULL, n(1), n(2), n(3), n(4), n(5), n(6));
    else if (cmd == "quad") CGPathAddQuadCurveToPoint(p, NULL, n(1), n(2), n(3), n(4));
    else if (cmd == "arc") CGPathAddArc(p, NULL, n(1), n(2), n(3), n(4), n(5),
                                        op.Length() > 6 && op.Get(6u).As<Napi::Boolean>().Value());
    else if (cmd == "rect") CGPathAddRect(p, NULL, CGRectMake(n(1), n(2), n(3), n(4)));
    else if (cmd == "ellipse") CGPathAddEllipseInRect(p, NULL, CGRectMake(n(1), n(2), n(3), n(4)));
    else if (cmd == "roundRect") CGPathAddRoundedRect(p, NULL, CGRectMake(n(1), n(2), n(3), n(4)), n(5), n(5));
    else if (cmd == "close") CGPathCloseSubpath(p);
  }
  return p;
}

static Napi::Value SetShapeProps(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  Napi::Object o = info[1].As<Napi::Object>();
  // a CGPath is immutable once built, so the one made here is the one set
  id path = o.Has("path") ? CFBridgingRelease(BuildPath(o.Get("path").As<Napi::Array>())) : nil;
  bool hasPath = o.Has("path");
  ColorProp fill = ColorPropOf(o, "fillColor"), stroke = ColorPropOf(o, "strokeColor");
  bool hasWidth = o.Has("lineWidth"), hasStart = o.Has("strokeStart"), hasEnd = o.Has("strokeEnd");
  double width = NumOr(o, "lineWidth", 1), start = NumOr(o, "strokeStart", 0),
         end = NumOr(o, "strokeEnd", 1);
  NSString* cap = o.Has("lineCap") ? ToNSString(o.Get("lineCap")) : nil;
  NSMutableArray* dash = nil;
  if (o.Has("lineDashPattern")) {
    Napi::Array arr = o.Get("lineDashPattern").As<Napi::Array>();
    dash = [NSMutableArray arrayWithCapacity:arr.Length()];
    for (uint32_t i = 0; i < arr.Length(); i++)
      [dash addObject:@(arr.Get(i).As<Napi::Number>().DoubleValue())];
  }
  int evenOdd = o.Has("fillRule")
                    ? (int)[ToNSString(o.Get("fillRule")) isEqualToString:@"evenodd"]
                    : -1;
  CALOnLayers(^{
    CAShapeLayer* S = (CAShapeLayer*)CALResolve(target);
    if (!S) return;
    if (hasPath) S.path = (__bridge CGPathRef)path;
    if (fill.given) S.fillColor = ColorOf(fill);
    if (stroke.given) S.strokeColor = ColorOf(stroke);
    if (hasWidth) S.lineWidth = width;
    if (hasStart) S.strokeStart = start;
    if (hasEnd) S.strokeEnd = end;
    if (cap) {
      if ([cap isEqualToString:@"round"]) S.lineCap = kCALineCapRound;
      else if ([cap isEqualToString:@"square"]) S.lineCap = kCALineCapSquare;
      else S.lineCap = kCALineCapButt;
    }
    if (dash) S.lineDashPattern = dash;
    if (evenOdd >= 0) S.fillRule = evenOdd ? kCAFillRuleEvenOdd : kCAFillRuleNonZero;
  });
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// animations & transactions
// ---------------------------------------------------------------------------
//
// Mechanism for a renderer that keeps its own model of what is animating
// (react-x11's transitions and loops, windowkit/appkit#29): the layer's
// model value is set under disableActions and an explicit animation carries
// the pixels from `from` to `to` — or through `values` — while the render
// server interpolates. Beyond CA's own vocabulary, four things let a
// renderer's timing model stay the truth about an animation it no longer
// ticks: a curve given as control points, which the renderer can evaluate
// identically on its side (a name means whatever each side thinks it
// means); an additive animation, so a retarget carries on from wherever the
// last one got to with nothing read back; a delay that shows `from` while it
// waits; and the presentation value plus the completion event, which say
// where an animation is and when it stopped.

// The completion event goes out through the backend's one event path
// (channel.h, included above).

static bool ThrowType(Napi::Env env, const char* msg) {
  Napi::TypeError::New(env, msg).ThrowAsJavaScriptException();
  return false;
}

// A number, a point [x, y] or a colour [r, g, b(, a)] — the value types a key
// path takes here. nil for anything else, which the caller reports.
static id AnimValue(Napi::Value v) {
  if (v.IsNumber()) return @(v.As<Napi::Number>().DoubleValue());
  if (v.IsArray()) {
    Napi::Array a = v.As<Napi::Array>();
    if (a.Length() == 2) {
      return [NSValue valueWithPoint:NSMakePoint(a.Get(0u).As<Napi::Number>().DoubleValue(),
                                                 a.Get(1u).As<Napi::Number>().DoubleValue())];
    }
    if (a.Length() >= 3) return CFBridgingRelease(MakeColor(v));  // color
  }
  return nil;
}

// A timing function: one of CA's names (their CSS spellings are accepted
// too — they are the same four curves), or the control points of a cubic
// bezier. nil with a TypeError pending for anything else: an animation on
// the wrong curve is the kind of bug nobody files, they just think the app
// feels off.
static CAMediaTimingFunction* TimingFrom(Napi::Env env, Napi::Value v) {
  if (v.IsString()) {
    NSString* name = ToNSString(v);
    if ([name isEqualToString:@"linear"])
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    if ([name isEqualToString:@"easeIn"] || [name isEqualToString:@"ease-in"])
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    if ([name isEqualToString:@"easeOut"] || [name isEqualToString:@"ease-out"])
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    if ([name isEqualToString:@"easeInEaseOut"] || [name isEqualToString:@"ease-in-out"])
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if ([name isEqualToString:@"default"] || [name isEqualToString:@"ease"])
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault];
    ThrowType(env, "timing: expected linear, easeIn, easeOut, easeInEaseOut, default "
                   "(or the CSS spellings) or control points [x1, y1, x2, y2]");
    return nil;
  }
  if (v.IsArray()) {
    Napi::Array a = v.As<Napi::Array>();
    float p[4] = {0, 0, 0, 0};
    bool ok = a.Length() == 4;
    for (uint32_t i = 0; ok && i < 4; i++) {
      Napi::Value e = a.Get(i);
      ok = e.IsNumber() && std::isfinite(e.As<Napi::Number>().DoubleValue());
      if (ok) p[i] = (float)e.As<Napi::Number>().DoubleValue();
    }
    // x is time: it has to stay inside the unit interval for the curve to be
    // a function of it. y may overshoot — that is what a back-out curve is.
    if (ok) ok = p[0] >= 0 && p[0] <= 1 && p[2] >= 0 && p[2] <= 1;
    if (!ok) {
      ThrowType(env, "timing: control points are [x1, y1, x2, y2], finite, with x1 and x2 in 0..1");
      return nil;
    }
    return [CAMediaTimingFunction functionWithControlPoints:p[0]:p[1]:p[2]:p[3]];
  }
  ThrowType(env, "timing: expected a curve name or control points [x1, y1, x2, y2]");
  return nil;
}

// The completion event. A delegate is set only when the caller passes an
// `id`, so an animation nobody wants to hear about costs nothing; CAAnimation
// holds its delegate strongly, so this lives exactly as long as the animation.
// animationDidStop: arrives on the main thread from the run loop — inside
// pump2() in pump mode, like a window delegate's methods, where it reaches
// JS inline; inside [NSApp run] in threaded mode, where it crosses to the
// connected environment like every other event. `finished` is NO for an
// animation that was removed, or whose layer left the tree, before it ran
// out.
@interface CALAnimationDelegate : NSObject <CAAnimationDelegate>
@property(nonatomic, copy) NSString* animId;
@property(nonatomic, copy) NSString* key;
@property(nonatomic, copy) NSString* keyPath;
@end

@implementation CALAnimationDelegate
- (void)animationDidStop:(CAAnimation*)anim finished:(BOOL)flag {
  if (!CALListening()) return;
  CALEvent ev("animation-end");
  ev.Str("id", self.animId.UTF8String);
  ev.Str("key", self.key.UTF8String);
  ev.Str("keyPath", self.keyPath.UTF8String);
  ev.Bool("finished", flag);
  CALEmit(std::move(ev));
}
@end

// What every animation kind shares: repetition, the curve, additive, a
// delay, speed/timeOffset, hold, and the completion delegate. false with a
// TypeError pending.
// *delay: the delay asked for, whose begin time is set as the animation is
// added (on the UI thread, in the layer's own time).
static bool ApplyTiming(Napi::Env env, CAPropertyAnimation* a, Napi::Object o,
                        NSString* key, double* delayOut) {
  double rep = NumOr(o, "repeat", 0);
  if (rep > 0) a.repeatCount = std::isinf(rep) ? HUGE_VALF : (float)rep;
  a.autoreverses = BoolOr(o, "autoreverse", false);
  if (o.Has("timing")) {
    CAMediaTimingFunction* fn = TimingFrom(env, o.Get("timing"));
    if (!fn) return false;
    a.timingFunction = fn;
  }
  // Additive: the animation's values are deltas over the model value, and
  // several in flight on one key path sum. That is how a retarget stays
  // continuous — the model goes straight to the new target, the animation
  // runs (old − new) → 0 — and why nothing has to be read back for it.
  a.additive = BoolOr(o, "additive", false);
  a.cumulative = BoolOr(o, "cumulative", false);
  // speed 0 with a timeOffset is an animation paused at that time: how a
  // caller pauses one, and how a test samples a curve without waiting for it
  if (o.Has("speed")) a.speed = (float)NumOr(o, "speed", 1);
  if (o.Has("timeOffset")) a.timeOffset = NumOr(o, "timeOffset", 0);
  bool hold = BoolOr(o, "hold", false);
  double delay = NumOr(o, "delay", 0);
  *delayOut = delay;
  if (delay > 0) {
    // the layer shows `from` while it waits, rather than the model value
    // it is about to leave and then snap back from
    a.fillMode = hold ? kCAFillModeBoth : kCAFillModeBackwards;
  }
  if (hold) {
    a.removedOnCompletion = NO;
    if (delay <= 0) a.fillMode = kCAFillModeForwards;
  }
  if (o.Has("id")) {
    Napi::Value idv = o.Get("id");
    if (!idv.IsString()) return ThrowType(env, "id: expected a string");
    CALAnimationDelegate* d = [CALAnimationDelegate new];
    d.animId = ToNSString(idv);
    d.key = key;
    d.keyPath = a.keyPath;
    a.delegate = d;
  }
  return true;
}

static bool ReadFromTo(Napi::Env env, CABasicAnimation* a, Napi::Object o) {
  if (o.Has("from")) {
    id v = AnimValue(o.Get("from"));
    if (!v) return ThrowType(env, "from: expected a number, [x, y] or [r, g, b, a]");
    a.fromValue = v;
  }
  if (o.Has("to")) {
    id v = AnimValue(o.Get("to"));
    if (!v) return ThrowType(env, "to: expected a number, [x, y] or [r, g, b, a]");
    a.toValue = v;
  }
  return true;
}

// addAnimation(layer, keyPath, opts, key) -> the animation's duration in
// seconds, which for a spring is its settling time — the number a caller
// needs to know when the animation is over.
//
//   { from, to, duration }                              CABasicAnimation
//   { values, keyTimes?, timings?, calculationMode? }   CAKeyframeAnimation
//   { spring: { mass, stiffness, damping, initialVelocity } | true, from, to }
//                                                       CASpringAnimation
// plus, for any of them: repeat, autoreverse, timing (a name or control
// points), additive, cumulative, delay, speed, timeOffset, hold, and id —
// with an id the animation reports its end as an `animation-end` backend
// event { id, key, keyPath, finished }.
//
// The animation object is built in the call, on whichever thread (a plain
// model object; the validation throws there), and added where layers are
// touched — in the call on the main thread, with the frame from a worker.
static Napi::Value AddAnimation(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  id target = CALHandleTarget(info[0]);
  NSString* keyPath = ToNSString(info[1]);
  Napi::Object o = info[2].As<Napi::Object>();
  NSString* key = info.Length() > 3 && info[3].IsString() ? ToNSString(info[3]) : keyPath;

  bool keyframe = o.Has("values");
  bool spring = o.Has("spring");
  if (keyframe && spring) {
    ThrowType(env, "values and spring are two different animations; pass one of them");
    return env.Undefined();
  }

  CAPropertyAnimation* a = nil;
  if (keyframe) {
    CAKeyframeAnimation* k = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    Napi::Value vv = o.Get("values");
    if (!vv.IsArray() || vv.As<Napi::Array>().Length() < 2) {
      ThrowType(env, "values: expected an array of at least two values");
      return env.Undefined();
    }
    Napi::Array varr = vv.As<Napi::Array>();
    NSMutableArray* values = [NSMutableArray arrayWithCapacity:varr.Length()];
    for (uint32_t i = 0; i < varr.Length(); i++) {
      id v = AnimValue(varr.Get(i));
      if (!v) {
        ThrowType(env, "values: each entry is a number, [x, y] or [r, g, b, a]");
        return env.Undefined();
      }
      [values addObject:v];
    }
    k.values = values;
    if (o.Has("keyTimes")) {
      Napi::Value kv = o.Get("keyTimes");
      bool ok = kv.IsArray() && kv.As<Napi::Array>().Length() == varr.Length();
      NSMutableArray* times = [NSMutableArray arrayWithCapacity:varr.Length()];
      double last = 0;
      for (uint32_t i = 0; ok && i < varr.Length(); i++) {
        Napi::Value t = kv.As<Napi::Array>().Get(i);
        double d = t.IsNumber() ? t.As<Napi::Number>().DoubleValue() : -1;
        ok = d >= last && d <= 1 && (i > 0 || d == 0);
        last = d;
        [times addObject:@(d)];
      }
      if (!ok) {
        ThrowType(env, "keyTimes: one per value, from 0 to at most 1, never decreasing");
        return env.Undefined();
      }
      k.keyTimes = times;
    }
    if (o.Has("timings")) {
      Napi::Value tv = o.Get("timings");
      if (!tv.IsArray() || tv.As<Napi::Array>().Length() != varr.Length() - 1) {
        ThrowType(env, "timings: one curve per segment, so one fewer than values");
        return env.Undefined();
      }
      NSMutableArray* fns = [NSMutableArray arrayWithCapacity:varr.Length() - 1];
      for (uint32_t i = 0; i + 1 < varr.Length(); i++) {
        CAMediaTimingFunction* fn = TimingFrom(env, tv.As<Napi::Array>().Get(i));
        if (!fn) return env.Undefined();
        [fns addObject:fn];
      }
      k.timingFunctions = fns;
    }
    if (o.Has("calculationMode")) {
      NSString* mode = StrOr(o, "calculationMode", @"linear");
      if ([mode isEqualToString:@"linear"]) k.calculationMode = kCAAnimationLinear;
      else if ([mode isEqualToString:@"discrete"]) k.calculationMode = kCAAnimationDiscrete;
      else if ([mode isEqualToString:@"paced"]) k.calculationMode = kCAAnimationPaced;
      else if ([mode isEqualToString:@"cubic"]) k.calculationMode = kCAAnimationCubic;
      else if ([mode isEqualToString:@"cubicPaced"]) k.calculationMode = kCAAnimationCubicPaced;
      else {
        ThrowType(env, "calculationMode: expected linear, discrete, paced, cubic or cubicPaced");
        return env.Undefined();
      }
    }
    k.duration = NumOr(o, "duration", 0.25);
    a = k;
  } else if (spring) {
    CASpringAnimation* s = [CASpringAnimation animationWithKeyPath:keyPath];
    Napi::Value sv = o.Get("spring");
    if (sv.IsObject()) {
      Napi::Object so = sv.As<Napi::Object>();
      // checked before they are set: CA refuses a bad value with a log line
      // and keeps its default, which would make the check below pass
      double mass = NumOr(so, "mass", s.mass);
      double stiffness = NumOr(so, "stiffness", s.stiffness);
      double damping = NumOr(so, "damping", s.damping);
      double velocity = NumOr(so, "initialVelocity", s.initialVelocity);
      if (!(mass > 0 && stiffness > 0 && damping >= 0 && std::isfinite(velocity))) {
        ThrowType(env, "spring: mass and stiffness are positive, damping is not negative");
        return env.Undefined();
      }
      s.mass = mass;
      s.stiffness = stiffness;
      s.damping = damping;
      s.initialVelocity = velocity;
    } else if (!(sv.IsBoolean() && sv.As<Napi::Boolean>().Value())) {
      ThrowType(env, "spring: expected { mass, stiffness, damping, initialVelocity } or true for CA's defaults");
      return env.Undefined();
    }
    if (!ReadFromTo(env, s, o)) return env.Undefined();
    // CA's default duration is 0.25s and would cut the spring off mid-swing;
    // it settles when the physics says, unless the caller cuts it themselves
    s.duration = o.Has("duration") ? NumOr(o, "duration", 0.25) : s.settlingDuration;
    a = s;
  } else {
    CABasicAnimation* b = [CABasicAnimation animationWithKeyPath:keyPath];
    if (!ReadFromTo(env, b, o)) return env.Undefined();
    b.duration = NumOr(o, "duration", 0.25);
    a = b;
  }
  double delay = 0;
  if (!ApplyTiming(env, a, o, key, &delay)) return env.Undefined();
  double duration = a.duration;
  CALOnLayers(^{
    CALayer* L = CALResolve(target);
    if (!L) return;
    // in the layer's own time — the media time unless the layer itself has
    // been slowed or offset
    if (delay > 0) a.beginTime = [L convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
    [L addAnimation:a forKey:key];
  });
  return Napi::Number::New(env, duration);
}

static Napi::Value RemoveAnimation(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  NSString* key = ToNSString(info[1]);
  CALOnLayers(^{ [(CALayer*)CALResolve(target) removeAnimationForKey:key]; });
  return info.Env().Undefined();
}

static Napi::Value RemoveAllAnimations(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  CALOnLayers(^{ [(CALayer*)CALResolve(target) removeAllAnimations]; });
  return info.Env().Undefined();
}

// A CA value back to JS: a number; a point or size as [x, y]; a rect as
// [x, y, w, h]; a colour as [r, g, b, a] in generic RGB; a transform as its
// sixteen components, row by row. null for anything else.
static Napi::Value JSFromCAValue(Napi::Env env, id v) {
  if (!v) return env.Null();
  if ([v isKindOfClass:[NSNumber class]]) return Napi::Number::New(env, [(NSNumber*)v doubleValue]);
  if ([v isKindOfClass:[NSValue class]]) {
    NSValue* nv = (NSValue*)v;
    const char* t = nv.objCType;
    Napi::Array arr = Napi::Array::New(env);
    if (strcmp(t, @encode(CGPoint)) == 0) {
      CGPoint p = nv.pointValue;
      arr.Set(0u, p.x); arr.Set(1u, p.y);
    } else if (strcmp(t, @encode(CGSize)) == 0) {
      CGSize s = nv.sizeValue;
      arr.Set(0u, s.width); arr.Set(1u, s.height);
    } else if (strcmp(t, @encode(CGRect)) == 0) {
      CGRect r = nv.rectValue;
      arr.Set(0u, r.origin.x); arr.Set(1u, r.origin.y);
      arr.Set(2u, r.size.width); arr.Set(3u, r.size.height);
    } else if (strcmp(t, @encode(CATransform3D)) == 0) {
      CATransform3D m = nv.CATransform3DValue;
      const CGFloat* c = &m.m11;
      for (uint32_t i = 0; i < 16; i++) arr.Set(i, (double)c[i]);
    } else {
      return env.Null();
    }
    return arr;
  }
  if (CFGetTypeID((__bridge CFTypeRef)v) == CGColorGetTypeID()) {
    CGColorRef c = (__bridge CGColorRef)v;
    // read back in the space colours go in by (MakeColor), so a value that
    // went out comes back as the same numbers
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef conv = CGColorCreateCopyByMatchingToColorSpace(rgb, kCGRenderingIntentDefault, c, NULL);
    CGColorSpaceRelease(rgb);
    CGColorRef src = conv ? conv : c;
    const CGFloat* comps = CGColorGetComponents(src);
    size_t n = CGColorGetNumberOfComponents(src);
    Napi::Array arr = Napi::Array::New(env, 4);
    if (n == 4) {
      for (uint32_t i = 0; i < 4; i++) arr.Set(i, (double)comps[i]);
    } else if (n == 2) {
      arr.Set(0u, (double)comps[0]); arr.Set(1u, (double)comps[0]);
      arr.Set(2u, (double)comps[0]); arr.Set(3u, (double)comps[1]);
    } else {
      if (conv) CGColorRelease(conv);
      return env.Null();
    }
    if (conv) CGColorRelease(conv);
    return arr;
  }
  return env.Null();
}

// presentationValue(layer, keyPath) -> the value the render server is
// showing for that key path right now, animations applied — or null before
// the layer's first commit. The model value is what the caller set; this is
// where the pixels are, which is the `from` an interrupted colour animation
// needs and the number a test reads a curve back through. From a worker,
// presentationValue(layer, keyPath, cb): the render server's state is read
// on the UI thread.
static Napi::Value PresentationValue(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  NSString* keyPath = ToNSString(info[1]);
  return CALAnswer(info, "presentationValue", ^CALValueBlock {
    CALayer* p = ((CALayer*)CALResolve(target)).presentationLayer;
    id v = nil;
    if (p) {
      @try {
        v = [p valueForKeyPath:keyPath];
      } @catch (NSException* e) {
        v = nil;
      }
    }
    // an NSNumber, an NSValue or a CGColor: immutable, made into JS on the
    // caller's thread
    return ^Napi::Value(Napi::Env e) { return JSFromCAValue(e, v); };
  });
}

// txBegin(opts?) / txCommit(). On the main thread a Core Animation
// transaction, as always. From a worker the frame batch: txBegin opens it
// (or nests inside it), and the txCommit that closes the outermost one
// posts the whole batch as one command.
static Napi::Value TxBegin(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CAMediaTimingFunction* timing = nil;
  bool hasTiming = false;
  if (info.Length() > 0 && info[0].IsObject()) {
    Napi::Object o = info[0].As<Napi::Object>();
    if (o.Has("timing")) {
      hasTiming = true;
      timing = TimingFrom(env, o.Get("timing"));
      // a bad curve is reported before anything is begun, so a throw here
      // leaves no transaction open
      if (!timing) return env.Undefined();
    }
  }
  bool hasDuration = false, disable = false;
  double duration = 0.25;
  if (info.Length() > 0 && info[0].IsObject()) {
    Napi::Object o = info[0].As<Napi::Object>();
    hasDuration = o.Has("duration");
    duration = NumOr(o, "duration", 0.25);
    disable = BoolOr(o, "disableActions", false);
  }
  if (pthread_main_np()) {
    [CATransaction begin];
    if (hasDuration) [CATransaction setAnimationDuration:duration];
    if (disable) [CATransaction setDisableActions:YES];
    if (hasTiming) [CATransaction setAnimationTimingFunction:timing];
    return env.Undefined();
  }
  // Recorded with its options stated in full: it applies inside the drain's
  // own transaction, whose actions are off, and a frame that did not ask
  // for that has them on, as in pump mode.
  tlFrame.depth++;
  tlFrame.ops.push_back(^{
    [CATransaction begin];
    [CATransaction setDisableActions:disable];
    if (hasDuration) [CATransaction setAnimationDuration:duration];
    if (hasTiming) [CATransaction setAnimationTimingFunction:timing];
  });
  return env.Undefined();
}

static Napi::Value TxCommit(const Napi::CallbackInfo& info) {
  if (pthread_main_np()) {
    [CATransaction commit];
    return info.Env().Undefined();
  }
  if (tlFrame.depth == 0) return info.Env().Undefined();  // nothing open
  // txCommit({ width, height }) on the outermost commit: the size this frame
  // was painted at, which a window's resize handshake waits for
  // (setResizeHandshake, windowkit/appkit#53)
  bool sized = false;
  double width = 0, height = 0;
  if (info.Length() > 0 && info[0].IsObject()) {
    Napi::Object o = info[0].As<Napi::Object>();
    if (o.Get("width").IsNumber() && o.Get("height").IsNumber()) {
      sized = true;
      width = NumOr(o, "width", 0);
      height = NumOr(o, "height", 0);
    }
  }
  tlFrame.ops.push_back(^{ [CATransaction commit]; });
  if (--tlFrame.depth > 0) return info.Env().Undefined();
  std::vector<dispatch_block_t> ops = std::move(tlFrame.ops);
  tlFrame.ops.clear();
  CALPostFrame(^{
    gApplyingWorkerFrame = true;
    for (dispatch_block_t op : ops) RunLayerOp(op);
    gApplyingWorkerFrame = false;
    FlushReleasedSurfaces();
  }, sized, width, height);
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// hit testing
// ---------------------------------------------------------------------------

static Napi::Value HitTest(const Napi::CallbackInfo& info) {
  if (!PumpModeOnly(info, "hitTest")) return info.Env().Undefined();
  Napi::Env env = info.Env();
  CALayer* root = Deref<CALayer*>(info[0]);
  double x = info[1].As<Napi::Number>().DoubleValue();
  double y = info[2].As<Napi::Number>().DoubleValue();
  // hitTest: takes the point in the receiver's superlayer space, which stays
  // bottom-up even when geometryFlipped flips the sublayer layout.
  if (root.geometryFlipped) y = CGRectGetHeight(root.bounds) - y;
  CALayer* hit = [root hitTest:CGPointMake(x, y)];
  if (hit && hit.name) return Napi::String::New(env, hit.name.UTF8String);
  return env.Null();
}

// ---------------------------------------------------------------------------
// CoreText: measure + render to CGImage
// ---------------------------------------------------------------------------

static NSAttributedString* AttrString(Napi::Object o, CGColorRef* outColor) {
  NSString* text = StrOr(o, "text", @"");
  NSString* fontName = StrOr(o, "fontName", @"Helvetica");
  double fontSize = NumOr(o, "fontSize", 14);
  CGColorRef color = o.Has("color") ? MakeColor(o.Get("color"))
                                    : CGColorCreateSRGB(0, 0, 0, 1);
  CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)fontName, fontSize, NULL);
  NSDictionary* attrs = @{
    (__bridge id)kCTFontAttributeName : (__bridge id)font,
    (__bridge id)kCTForegroundColorAttributeName : (__bridge id)color,
  };
  NSAttributedString* as = [[NSAttributedString alloc] initWithString:text attributes:attrs];
  CFRelease(font);
  *outColor = color;  // caller releases
  return as;
}

static Napi::Value MeasureText(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CGColorRef color;
  NSAttributedString* as = AttrString(info[0].As<Napi::Object>(), &color);
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
  CGFloat ascent, descent, leading;
  double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
  CFRelease(line);
  CGColorRelease(color);
  Napi::Object r = Napi::Object::New(env);
  r.Set("width", width);
  r.Set("ascent", ascent);
  r.Set("descent", descent);
  r.Set("leading", leading);
  return r;
}

// createTextImage({text, fontName, fontSize, color, maxWidth, scale})
//   -> { image: External<CGImage>, width, height, scale }   (width/height in points)
static Napi::Value CreateTextImage(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Object o = info[0].As<Napi::Object>();
  double scale = NumOr(o, "scale", 2);
  double maxWidth = NumOr(o, "maxWidth", 100000);

  CGColorRef color;
  NSAttributedString* as = AttrString(o, &color);
  CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)as);
  CFRange fit;
  CGSize sz = CTFramesetterSuggestFrameSizeWithConstraints(
      fs, CFRangeMake(0, 0), NULL, CGSizeMake(maxWidth, CGFLOAT_MAX), &fit);
  double wpt = ceil(sz.width) + 1, hpt = ceil(sz.height) + 1;
  size_t pw = (size_t)ceil(wpt * scale), ph = (size_t)ceil(hpt * scale);

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, pw, ph, 8, 0, cs,
      kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host);
  CGContextScaleCTM(ctx, scale, scale);

  CGPathRef path = CGPathCreateWithRect(CGRectMake(0, 0, wpt, hpt), NULL);
  CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, NULL);
  CTFrameDraw(frame, ctx);
  CGImageRef img = CGBitmapContextCreateImage(ctx);

  CFRelease(frame);
  CGPathRelease(path);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  CFRelease(fs);
  CGColorRelease(color);

  Napi::Object r = Napi::Object::New(env);
  r.Set("image", Napi::External<void>::New(env, (void*)img, [](Napi::Env, void* d) {
          CGImageRelease((CGImageRef)d);
        }));
  r.Set("width", wpt);
  r.Set("height", hpt);
  r.Set("scale", scale);
  return r;
}

// setContentsImage(layer, imageExternal, contentsScale?)
static Napi::Value SetContentsImage(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  id img = (__bridge id)(CGImageRef)info[1].As<Napi::External<void>>().Data();
  bool hasScale = info.Length() > 2 && info[2].IsNumber();
  double scale = hasScale ? info[2].As<Napi::Number>().DoubleValue() : 1;
  CALOnLayers(^{
    CALayer* L = CALResolve(target);
    if (!L) return;
    CALNoteContentsReplaced(L, img);
    L.contents = img;
    if (hasScale) L.contentsScale = scale;
  });
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// native controls: NSCell rendered offscreen (the WebKit/Firefox technique)
// ---------------------------------------------------------------------------

static NSView* DummyDrawView() {
  // Cells only use the view for flippedness/appearance queries; it never needs
  // to be in a window.
  static CALHostView* v = nil;
  if (!v) v = [[CALHostView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 1000)];
  return v;
}

// drawControl({kind, title, state, pressed, enabled, isDefault, value,
//              controlSize, appearance, width, height, scale})
//   kind: 'push' | 'checkbox' | 'radio' | 'popup' | 'slider'
//   -> { image: External<CGImage>, width, height, scale }  (points)
// width/height default to the cell's natural cellSize (slider must pass them).
static Napi::Value DrawControl(const Napi::CallbackInfo& info) {
  if (!PumpModeOnly(info, "drawControl")) return info.Env().Undefined();
  Napi::Env env = info.Env();
  EnsureApp();
  Napi::Object o = info[0].As<Napi::Object>();
  NSString* kind = StrOr(o, "kind", @"push");
  NSString* title = StrOr(o, "title", @"");
  double scale = NumOr(o, "scale", 2);
  bool pressed = BoolOr(o, "pressed", false);
  bool enabled = BoolOr(o, "enabled", true);
  int state = (int)NumOr(o, "state", 0);  // 0 off, 1 on

  NSCell* cell = nil;
  if ([kind isEqualToString:@"checkbox"] || [kind isEqualToString:@"radio"] ||
      [kind isEqualToString:@"push"]) {
    NSButtonCell* c = [[NSButtonCell alloc] initTextCell:title];
    if ([kind isEqualToString:@"checkbox"]) {
      c.buttonType = NSButtonTypeSwitch;
    } else if ([kind isEqualToString:@"radio"]) {
      c.buttonType = NSButtonTypeRadio;
    } else {
      c.buttonType = NSButtonTypeMomentaryPushIn;
      c.bezelStyle = NSBezelStylePush;
      if (BoolOr(o, "isDefault", false)) c.keyEquivalent = @"\r";  // accent fill
    }
    c.state = state == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    cell = c;
  } else if ([kind isEqualToString:@"popup"]) {
    NSPopUpButtonCell* c = [[NSPopUpButtonCell alloc] initTextCell:@"" pullsDown:NO];
    [c addItemWithTitle:title];
    cell = c;
  }

  // Controls whose cells no longer draw offscreen (NSSliderCell renders via
  // the view's layer machinery) or that have no cell at all (NSSwitch): use a
  // real offscreen NSControl and displayRectIgnoringOpacity:inContext:.
  NSControl* viewControl = nil;
  if ([kind isEqualToString:@"slider"]) {
    NSSlider* s = [[NSSlider alloc] init];
    s.minValue = 0;
    s.maxValue = 1;
    s.doubleValue = NumOr(o, "value", 0.5);
    viewControl = s;
  } else if ([kind isEqualToString:@"switch"]) {
    NSSwitch* s = [[NSSwitch alloc] init];
    s.state = state == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    viewControl = s;
  }

  if (!cell && !viewControl) {
    Napi::Error::New(env, "unknown control kind").ThrowAsJavaScriptException();
    return env.Undefined();
  }

  NSString* sz = StrOr(o, "controlSize", @"regular");
  NSControlSize csize = NSControlSizeRegular;
  if ([sz isEqualToString:@"small"]) csize = NSControlSizeSmall;
  else if ([sz isEqualToString:@"mini"]) csize = NSControlSizeMini;
  else if ([sz isEqualToString:@"large"]) csize = NSControlSizeLarge;

  double w = NumOr(o, "width", 0), h = NumOr(o, "height", 0);
  if (cell) {
    cell.controlSize = csize;
    cell.font = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:csize]];
    cell.enabled = enabled;
    cell.highlighted = pressed;
    NSSize natural = cell.cellSize;
    if (w <= 0) w = ceil(natural.width);
    if (h <= 0) h = ceil(natural.height);
  } else {
    viewControl.controlSize = csize;
    viewControl.enabled = enabled;
    NSSize natural = viewControl.intrinsicContentSize;
    if (w <= 0) w = natural.width > 0 ? ceil(natural.width) : 100;
    if (h <= 0) h = natural.height > 0 ? ceil(natural.height) : 22;
  }

  size_t pw = (size_t)ceil(w * scale), ph = (size_t)ceil(h * scale);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, pw, ph, 8, 0, cs,
      kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host);
  CGContextScaleCTM(ctx, scale, scale);
  // NSGraphicsContext flipped:YES expects a CTM that already puts the origin
  // at the top-left.
  CGContextTranslateCTM(ctx, 0, h);
  CGContextScaleCTM(ctx, 1, -1);

  NSGraphicsContext* g = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:g];

  NSString* apName = StrOr(o, "appearance", @"system");
  NSAppearance* ap = NSApp.effectiveAppearance;
  if ([apName isEqualToString:@"dark"]) ap = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  else if ([apName isEqualToString:@"light"]) ap = [NSAppearance appearanceNamed:NSAppearanceNameAqua];

  if (viewControl) {
    viewControl.frame = NSMakeRect(0, 0, w, h);
    viewControl.appearance = ap;
    [viewControl layoutSubtreeIfNeeded];
    [viewControl displayRectIgnoringOpacity:viewControl.bounds inContext:g];
  } else {
    [ap performAsCurrentDrawingAppearance:^{
      [cell drawWithFrame:NSMakeRect(0, 0, w, h) inView:DummyDrawView()];
    }];
  }

  [NSGraphicsContext restoreGraphicsState];
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);

  Napi::Object r = Napi::Object::New(env);
  r.Set("image", Napi::External<void>::New(env, (void*)img, [](Napi::Env, void* d) {
          CGImageRelease((CGImageRef)d);
        }));
  r.Set("width", w);
  r.Set("height", h);
  r.Set("scale", scale);
  return r;
}

// setLayerContentsIOSurface(layer, iosurfaceId) — the receiving end of an
// IOSurface render target (x11-dri's appleCreateTarget): the id is process-
// global, so the GPU addon and this one never share a pointer. The layer
// retains the surface; our lookup reference goes with the change. From a
// worker the flip happens when the frame applies, so the renderer may not
// draw into the buffer it replaced until `surface-released` names it (or
// surfaceIsInUse says it is off glass).
static Napi::Value SetLayerContentsIOSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  id target = CALHandleTarget(info[0]);
  uint32_t sid = info[1].As<Napi::Number>().Uint32Value();
  IOSurfaceRef surface = IOSurfaceLookup(sid);
  if (!surface) {
    Napi::Error::New(env, "IOSurfaceLookup: no surface with that id")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  id s = CFBridgingRelease(surface);  // held until the change has been made
  CALOnLayers(^{
    CALayer* L = CALResolve(target);
    if (!L) return;
    // its own transaction, actions off: a present is a buffer flip, and the
    // implicit action for `contents` would turn it into a crossfade
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALNoteContentsReplaced(L, s);
    L.contents = s;
    [CATransaction commit];
  });
  return env.Undefined();
}

static Napi::Value AppearanceIsDark(const Napi::CallbackInfo& info) {
  if (!PumpModeOnly(info, "appearanceIsDark")) return info.Env().Undefined();
  EnsureApp();
  NSAppearanceName n = [NSApp.effectiveAppearance
      bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
  return Napi::Boolean::New(info.Env(), [n isEqualToString:NSAppearanceNameDarkAqua]);
}

// ---------------------------------------------------------------------------
// snapshot (renderInContext -> PNG) — for debugging / headless verification
// ---------------------------------------------------------------------------

// snapshotWindow(win, path, withShadow?, cb?) -> bool; off the main thread
// the answer comes through cb (the last argument).
static Napi::Value SnapshotWindow(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  NSString* path = ToNSString(info[1]);
  bool withShadow =
      info.Length() > 2 && !info[2].IsFunction() && info[2].ToBoolean().Value();
  return CALAnswer(info, "snapshotWindow", ^CALValueBlock {
    NSWindow* win = CALResolve(target);
    bool ok = false;
    if (win) {
      // Capture our own window's real composited pixels (allowed without the
      // screen-recording permission for windows the process owns). This
      // shows the true WindowServer output, including geometryFlipped, masks,
      // and shadows.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      CGImageRef img = CGWindowListCreateImage(
          CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)win.windowNumber,
          withShadow
              ? (CGWindowImageOption)kCGWindowImageBestResolution
              : (CGWindowImageOption)(kCGWindowImageBoundsIgnoreFraming |
                                      kCGWindowImageBestResolution));
#pragma clang diagnostic pop
      if (img) {
        NSURL* url = [NSURL fileURLWithPath:path];
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
        if (dst) {
          CGImageDestinationAddImage(dst, img, NULL);
          ok = CGImageDestinationFinalize(dst);
          CFRelease(dst);
        }
        CGImageRelease(img);
      }
    }
    return ^Napi::Value(Napi::Env e) { return Napi::Boolean::New(e, ok); };
  });
}

// ---------------------------------------------------------------------------
// module init
// ---------------------------------------------------------------------------

// src/backend.mm — the react-x11 backend surface (initApp and the app
// delegate, windows with delegates, enriched events, CG surfaces, CoreText
// layouts, pasteboard, screens).
void InitBackend(Napi::Env env, Napi::Object exports);
// src/permissions.mm — privacy (TCC) authorizations: status, the system
// prompt where a framework offers one, the Settings pane otherwise.
void InitPermissions(Napi::Env env, Napi::Object exports);
// src/notifications.mm — user notifications through UNUserNotificationCenter:
// settings, authorization, categories, post/update/remove, action events.
void InitNotifications(Napi::Env env, Napi::Object exports);
// src/calendars.mm — the user's calendars and the occurrences in a range
// through EventKit, and the store's change notification as a backend event.
void InitCalendars(Napi::Env env, Napi::Object exports);
// src/screencolor.mm — the eyedropper: one colour off the screen through
// NSColorSampler, the system's own out-of-process sampler.
void InitScreenColor(Napi::Env env, Napi::Object exports);
// src/threaded.mm — threaded mode: runMain parks the main thread in
// [NSApp run], commands in through the main run loop, events out in batches.
void InitThreaded(Napi::Env env, Napi::Object exports);

static Napi::Object Init(Napi::Env env, Napi::Object exports) {
#define FN(js, fn) exports.Set(js, Napi::Function::New(env, fn))
  FN("pump", Pump);
  FN("setEventCallback", SetEventCallback);
  FN("postMouseEvent", PostMouseEvent);
  FN("createWindow", CreateWindowFn);
  FN("windowRootLayer", WindowRootLayer);
  FN("windowScale", WindowScale);
  FN("windowContentSize", WindowContentSize);
  FN("windowIsVisible", WindowIsVisible);
  FN("windowNumber", WindowNumber);
  FN("closeWindow", CloseWindow);
  FN("snapshotWindow", SnapshotWindow);
  FN("createLayer", CreateLayer);
  FN("createTextLayer", CreateTextLayer);
  FN("createGradientLayer", CreateGradientLayer);
  FN("createShapeLayer", CreateShapeLayer);
  FN("addSublayer", AddSublayer);
  FN("removeFromSuperlayer", RemoveFromSuperlayer);
  FN("setLayerProps", SetLayerProps);
  FN("setTextProps", SetTextProps);
  FN("setGradientProps", SetGradientProps);
  FN("setShapeProps", SetShapeProps);
  FN("addAnimation", AddAnimation);
  FN("removeAnimation", RemoveAnimation);
  FN("removeAllAnimations", RemoveAllAnimations);
  FN("txBegin", TxBegin);
  FN("txCommit", TxCommit);
  FN("presentationValue", PresentationValue);
  FN("colorSpace", ColorSpace);
  FN("hitTest", HitTest);
  FN("measureText", MeasureText);
  FN("createTextImage", CreateTextImage);
  FN("setContentsImage", SetContentsImage);
  FN("setLayerContentsIOSurface", SetLayerContentsIOSurface);
  FN("drawControl", DrawControl);
  FN("appearanceIsDark", AppearanceIsDark);
#undef FN
  InitBackend(env, exports);
  InitPermissions(env, exports);
  InitNotifications(env, exports);
  InitCalendars(env, exports);
  InitScreenColor(env, exports);
  InitThreaded(env, exports);
  return exports;
}

NODE_API_MODULE(calayers, Init)
