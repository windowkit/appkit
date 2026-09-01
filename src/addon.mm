// node-calayers: retained-mode CALayer / CoreText backend for Node.js (POC)
//
// Design: node's main thread IS the process main thread on macOS, so we can own
// NSApplication from JS. We never call [NSApp run]; instead JS drives an event
// pump (nextEventMatchingMask with distantPast) on a timer. Core Animation
// runs its animations in the render server (WindowServer), so animations stay
// smooth regardless of pump cadence.

#include <napi.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>

#include <cmath>
#include <string>

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
static CGColorRef MakeColor(Napi::Value v) {
  Napi::Array a = v.As<Napi::Array>();
  double r = a.Get(0u).As<Napi::Number>().DoubleValue();
  double g = a.Get(1u).As<Napi::Number>().DoubleValue();
  double b = a.Get(2u).As<Napi::Number>().DoubleValue();
  double al = a.Length() > 3 ? a.Get(3u).As<Napi::Number>().DoubleValue() : 1.0;
  return CGColorCreateGenericRGB(r, g, b, al);
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

static bool gAppInited = false;

static void EnsureApp() {
  if (gAppInited) return;
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
  }
  gAppInited = true;
}

static Napi::Value InitApp(const Napi::CallbackInfo& info) {
  EnsureApp();
  return info.Env().Undefined();
}

static Napi::Value CreateWindowFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
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

static Napi::Value WindowRootLayer(const Napi::CallbackInfo& info) {
  NSWindow* win = Deref<NSWindow*>(info[0]);
  return WrapRetained(info.Env(), win.contentView.layer);
}

static Napi::Value WindowScale(const Napi::CallbackInfo& info) {
  NSWindow* win = Deref<NSWindow*>(info[0]);
  return Napi::Number::New(info.Env(), win.backingScaleFactor);
}

static Napi::Value WindowContentSize(const Napi::CallbackInfo& info) {
  NSWindow* win = Deref<NSWindow*>(info[0]);
  NSSize s = win.contentView.bounds.size;
  Napi::Array a = Napi::Array::New(info.Env(), 2);
  a.Set(0u, s.width);
  a.Set(1u, s.height);
  return a;
}

static Napi::Value WindowIsVisible(const Napi::CallbackInfo& info) {
  NSWindow* win = Deref<NSWindow*>(info[0]);
  return Napi::Boolean::New(info.Env(), win.isVisible);
}

static Napi::Value WindowNumber(const Napi::CallbackInfo& info) {
  NSWindow* win = Deref<NSWindow*>(info[0]);
  return Napi::Number::New(info.Env(), (double)win.windowNumber);
}

static Napi::Value CloseWindow(const Napi::CallbackInfo& info) {
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
static Napi::Value PostMouseEvent(const Napi::CallbackInfo& info) {
  NSWindow* win = Deref<NSWindow*>(info[0]);
  std::string t = info[1].As<Napi::String>().Utf8Value();
  double x = info[2].As<Napi::Number>().DoubleValue();
  double y = info[3].As<Napi::Number>().DoubleValue();
  NSEventType type;
  if (t == "down") type = NSEventTypeLeftMouseDown;
  else if (t == "up") type = NSEventTypeLeftMouseUp;
  else if (t == "drag") type = NSEventTypeLeftMouseDragged;
  else type = NSEventTypeMouseMoved;
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
  return info.Env().Undefined();
}

static Napi::Value SetEventCallback(const Napi::CallbackInfo& info) {
  if (info[0].IsFunction()) {
    gEventCb = Napi::Persistent(info[0].As<Napi::Function>());
  } else {
    gEventCb.Reset();
  }
  return info.Env().Undefined();
}

static Napi::Value Pump(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
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

static Napi::Value CreateLayer(const Napi::CallbackInfo& info) {
  return WrapRetained(info.Env(), [CALayer layer]);
}
static Napi::Value CreateTextLayer(const Napi::CallbackInfo& info) {
  CATextLayer* t = [CATextLayer layer];
  t.contentsScale = 2.0;  // sane retina default; overridable via contentsScale
  return WrapRetained(info.Env(), t);
}
static Napi::Value CreateGradientLayer(const Napi::CallbackInfo& info) {
  return WrapRetained(info.Env(), [CAGradientLayer layer]);
}
static Napi::Value CreateShapeLayer(const Napi::CallbackInfo& info) {
  return WrapRetained(info.Env(), [CAShapeLayer layer]);
}

static Napi::Value AddSublayer(const Napi::CallbackInfo& info) {
  CALayer* parent = Deref<CALayer*>(info[0]);
  CALayer* child = Deref<CALayer*>(info[1]);
  [parent addSublayer:child];
  return info.Env().Undefined();
}

static Napi::Value RemoveFromSuperlayer(const Napi::CallbackInfo& info) {
  CALayer* l = Deref<CALayer*>(info[0]);
  [l removeFromSuperlayer];
  return info.Env().Undefined();
}

static void ApplyTransform(CALayer* L, Napi::Value v) {
  if (v.IsNull() || v.IsUndefined()) {
    L.transform = CATransform3DIdentity;
    return;
  }
  Napi::Object t = v.As<Napi::Object>();
  CATransform3D m = CATransform3DIdentity;
  m = CATransform3DTranslate(m, NumOr(t, "translateX", 0), NumOr(t, "translateY", 0), 0);
  double rot = NumOr(t, "rotate", 0);  // radians
  if (rot != 0) m = CATransform3DRotate(m, rot, 0, 0, 1);
  double s = NumOr(t, "scale", 1);
  double sx = NumOr(t, "scaleX", s), sy = NumOr(t, "scaleY", s);
  if (sx != 1 || sy != 1) m = CATransform3DScale(m, sx, sy, 1);
  L.transform = m;
}

static void SetColorProp(CALayer* L, Napi::Object o, const char* key,
                         void (^setter)(CGColorRef)) {
  if (!o.Has(key)) return;
  Napi::Value v = o.Get(key);
  if (v.IsNull()) {
    setter(NULL);
  } else {
    CGColorRef c = MakeColor(v);
    setter(c);
    CGColorRelease(c);
  }
}

static void ApplyLayerProps(CALayer* L, Napi::Object o) {
  if (o.Has("frame")) L.frame = RectFrom(o.Get("frame"));
  if (o.Has("bounds")) {
    // [w, h] or [x, y, w, h] — the four-element form carries a bounds
    // ORIGIN, which is Core Animation's native scroll: the layer shows its
    // sublayers shifted by (-x, -y) with nothing repainted.
    Napi::Array a = o.Get("bounds").As<Napi::Array>();
    if (a.Length() >= 4) {
      L.bounds = CGRectMake(a.Get(0u).As<Napi::Number>().DoubleValue(),
                            a.Get(1u).As<Napi::Number>().DoubleValue(),
                            a.Get(2u).As<Napi::Number>().DoubleValue(),
                            a.Get(3u).As<Napi::Number>().DoubleValue());
    } else {
      L.bounds = CGRectMake(0, 0, a.Get(0u).As<Napi::Number>().DoubleValue(),
                            a.Get(1u).As<Napi::Number>().DoubleValue());
    }
  }
  if (o.Has("position")) L.position = PointFrom(o.Get("position"));
  if (o.Has("anchorPoint")) L.anchorPoint = PointFrom(o.Get("anchorPoint"));
  if (o.Has("zPosition")) L.zPosition = NumOr(o, "zPosition", 0);
  SetColorProp(L, o, "backgroundColor", ^(CGColorRef c) { L.backgroundColor = c; });
  SetColorProp(L, o, "borderColor", ^(CGColorRef c) { L.borderColor = c; });
  SetColorProp(L, o, "shadowColor", ^(CGColorRef c) { L.shadowColor = c; });
  if (o.Has("cornerRadius")) L.cornerRadius = NumOr(o, "cornerRadius", 0);
  if (o.Has("borderWidth")) L.borderWidth = NumOr(o, "borderWidth", 0);
  if (o.Has("opacity")) L.opacity = (float)NumOr(o, "opacity", 1);
  if (o.Has("hidden")) L.hidden = BoolOr(o, "hidden", false);
  if (o.Has("masksToBounds")) L.masksToBounds = BoolOr(o, "masksToBounds", false);
  if (o.Has("shadowOpacity")) L.shadowOpacity = (float)NumOr(o, "shadowOpacity", 0);
  if (o.Has("shadowRadius")) L.shadowRadius = NumOr(o, "shadowRadius", 3);
  if (o.Has("shadowOffset")) {
    CGPoint p = PointFrom(o.Get("shadowOffset"));
    L.shadowOffset = CGSizeMake(p.x, p.y);
  }
  if (o.Has("contentsScale")) L.contentsScale = NumOr(o, "contentsScale", 1);
  if (o.Has("name")) L.name = ToNSString(o.Get("name"));
  if (o.Has("mask")) {
    Napi::Value v = o.Get("mask");
    L.mask = (v.IsNull() || v.IsUndefined()) ? nil : Deref<CALayer*>(v);
  }
  if (o.Has("transform")) ApplyTransform(L, o.Get("transform"));
  if (o.Has("contents")) {
    Napi::Value v = o.Get("contents");
    if (v.IsNull()) L.contents = nil;
  }
}

static Napi::Value SetLayerProps(const Napi::CallbackInfo& info) {
  CALayer* L = Deref<CALayer*>(info[0]);
  ApplyLayerProps(L, info[1].As<Napi::Object>());
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// CATextLayer
// ---------------------------------------------------------------------------

static Napi::Value SetTextProps(const Napi::CallbackInfo& info) {
  CATextLayer* T = (CATextLayer*)Deref<CALayer*>(info[0]);
  Napi::Object o = info[1].As<Napi::Object>();
  if (o.Has("fontSize")) T.fontSize = NumOr(o, "fontSize", 14);
  if (o.Has("fontName")) {
    NSString* name = ToNSString(o.Get("fontName"));
    CTFontRef f = CTFontCreateWithName((__bridge CFStringRef)name,
                                       T.fontSize > 0 ? T.fontSize : 14, NULL);
    T.font = f;
    CFRelease(f);
  }
  if (o.Has("string")) T.string = ToNSString(o.Get("string"));
  SetColorProp(T, o, "color", ^(CGColorRef c) { T.foregroundColor = c; });
  if (o.Has("align")) {
    NSString* a = ToNSString(o.Get("align"));
    if ([a isEqualToString:@"center"]) T.alignmentMode = kCAAlignmentCenter;
    else if ([a isEqualToString:@"right"]) T.alignmentMode = kCAAlignmentRight;
    else if ([a isEqualToString:@"justified"]) T.alignmentMode = kCAAlignmentJustified;
    else T.alignmentMode = kCAAlignmentLeft;
  }
  if (o.Has("wrapped")) T.wrapped = BoolOr(o, "wrapped", false);
  if (o.Has("truncation")) {
    NSString* t = ToNSString(o.Get("truncation"));
    if ([t isEqualToString:@"start"]) T.truncationMode = kCATruncationStart;
    else if ([t isEqualToString:@"end"]) T.truncationMode = kCATruncationEnd;
    else if ([t isEqualToString:@"middle"]) T.truncationMode = kCATruncationMiddle;
    else T.truncationMode = kCATruncationNone;
  }
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// CAGradientLayer
// ---------------------------------------------------------------------------

static Napi::Value SetGradientProps(const Napi::CallbackInfo& info) {
  CAGradientLayer* G = (CAGradientLayer*)Deref<CALayer*>(info[0]);
  Napi::Object o = info[1].As<Napi::Object>();
  if (o.Has("colors")) {
    Napi::Array arr = o.Get("colors").As<Napi::Array>();
    NSMutableArray* colors = [NSMutableArray arrayWithCapacity:arr.Length()];
    for (uint32_t i = 0; i < arr.Length(); i++) {
      [colors addObject:CFBridgingRelease(MakeColor(arr.Get(i)))];
    }
    G.colors = colors;
  }
  if (o.Has("locations")) {
    Napi::Array arr = o.Get("locations").As<Napi::Array>();
    NSMutableArray* locs = [NSMutableArray arrayWithCapacity:arr.Length()];
    for (uint32_t i = 0; i < arr.Length(); i++) {
      [locs addObject:@(arr.Get(i).As<Napi::Number>().DoubleValue())];
    }
    G.locations = locs;
  }
  if (o.Has("startPoint")) G.startPoint = PointFrom(o.Get("startPoint"));
  if (o.Has("endPoint")) G.endPoint = PointFrom(o.Get("endPoint"));
  if (o.Has("type")) {
    NSString* t = ToNSString(o.Get("type"));
    if ([t isEqualToString:@"radial"]) G.type = kCAGradientLayerRadial;
    else if ([t isEqualToString:@"conic"]) G.type = kCAGradientLayerConic;
    else G.type = kCAGradientLayerAxial;
  }
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
  CAShapeLayer* S = (CAShapeLayer*)Deref<CALayer*>(info[0]);
  Napi::Object o = info[1].As<Napi::Object>();
  if (o.Has("path")) {
    CGPathRef p = BuildPath(o.Get("path").As<Napi::Array>());
    S.path = p;
    CGPathRelease(p);
  }
  SetColorProp(S, o, "fillColor", ^(CGColorRef c) { S.fillColor = c; });
  SetColorProp(S, o, "strokeColor", ^(CGColorRef c) { S.strokeColor = c; });
  if (o.Has("lineWidth")) S.lineWidth = NumOr(o, "lineWidth", 1);
  if (o.Has("strokeStart")) S.strokeStart = NumOr(o, "strokeStart", 0);
  if (o.Has("strokeEnd")) S.strokeEnd = NumOr(o, "strokeEnd", 1);
  if (o.Has("lineCap")) {
    NSString* c = ToNSString(o.Get("lineCap"));
    if ([c isEqualToString:@"round"]) S.lineCap = kCALineCapRound;
    else if ([c isEqualToString:@"square"]) S.lineCap = kCALineCapSquare;
    else S.lineCap = kCALineCapButt;
  }
  if (o.Has("lineDashPattern")) {
    Napi::Array arr = o.Get("lineDashPattern").As<Napi::Array>();
    NSMutableArray* d = [NSMutableArray arrayWithCapacity:arr.Length()];
    for (uint32_t i = 0; i < arr.Length(); i++)
      [d addObject:@(arr.Get(i).As<Napi::Number>().DoubleValue())];
    S.lineDashPattern = d;
  }
  if (o.Has("fillRule")) {
    S.fillRule = [ToNSString(o.Get("fillRule")) isEqualToString:@"evenodd"]
                     ? kCAFillRuleEvenOdd : kCAFillRuleNonZero;
  }
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// animations & transactions
// ---------------------------------------------------------------------------

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

static CAMediaTimingFunction* TimingFn(NSString* name) {
  if ([name isEqualToString:@"linear"]) return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
  if ([name isEqualToString:@"easeIn"]) return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
  if ([name isEqualToString:@"easeOut"]) return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  if ([name isEqualToString:@"easeInEaseOut"]) return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault];
}

// addAnimation(layer, keyPath, opts, key)
static Napi::Value AddAnimation(const Napi::CallbackInfo& info) {
  CALayer* L = Deref<CALayer*>(info[0]);
  NSString* keyPath = ToNSString(info[1]);
  Napi::Object o = info[2].As<Napi::Object>();
  NSString* key = info.Length() > 3 && info[3].IsString() ? ToNSString(info[3]) : keyPath;

  CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:keyPath];
  if (o.Has("from")) a.fromValue = AnimValue(o.Get("from"));
  if (o.Has("to")) a.toValue = AnimValue(o.Get("to"));
  a.duration = NumOr(o, "duration", 0.25);
  double rep = NumOr(o, "repeat", 0);
  if (rep > 0) a.repeatCount = std::isinf(rep) ? HUGE_VALF : (float)rep;
  a.autoreverses = BoolOr(o, "autoreverse", false);
  if (o.Has("timing")) a.timingFunction = TimingFn(ToNSString(o.Get("timing")));
  if (BoolOr(o, "hold", false)) {
    a.removedOnCompletion = NO;
    a.fillMode = kCAFillModeForwards;
  }
  [L addAnimation:a forKey:key];
  return info.Env().Undefined();
}

static Napi::Value RemoveAnimation(const Napi::CallbackInfo& info) {
  CALayer* L = Deref<CALayer*>(info[0]);
  [L removeAnimationForKey:ToNSString(info[1])];
  return info.Env().Undefined();
}

static Napi::Value RemoveAllAnimations(const Napi::CallbackInfo& info) {
  CALayer* L = Deref<CALayer*>(info[0]);
  [L removeAllAnimations];
  return info.Env().Undefined();
}

static Napi::Value TxBegin(const Napi::CallbackInfo& info) {
  [CATransaction begin];
  if (info.Length() > 0 && info[0].IsObject()) {
    Napi::Object o = info[0].As<Napi::Object>();
    if (o.Has("duration")) [CATransaction setAnimationDuration:NumOr(o, "duration", 0.25)];
    if (BoolOr(o, "disableActions", false)) [CATransaction setDisableActions:YES];
    if (o.Has("timing")) [CATransaction setAnimationTimingFunction:TimingFn(ToNSString(o.Get("timing")))];
  }
  return info.Env().Undefined();
}

static Napi::Value TxCommit(const Napi::CallbackInfo& info) {
  [CATransaction commit];
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// hit testing
// ---------------------------------------------------------------------------

static Napi::Value HitTest(const Napi::CallbackInfo& info) {
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
                                    : CGColorCreateGenericRGB(0, 0, 0, 1);
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
  CALayer* L = Deref<CALayer*>(info[0]);
  CGImageRef img = (CGImageRef)info[1].As<Napi::External<void>>().Data();
  L.contents = (__bridge id)img;
  if (info.Length() > 2 && info[2].IsNumber())
    L.contentsScale = info[2].As<Napi::Number>().DoubleValue();
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

static Napi::Value AppearanceIsDark(const Napi::CallbackInfo& info) {
  EnsureApp();
  NSAppearanceName n = [NSApp.effectiveAppearance
      bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
  return Napi::Boolean::New(info.Env(), [n isEqualToString:NSAppearanceNameDarkAqua]);
}

// ---------------------------------------------------------------------------
// snapshot (renderInContext -> PNG) — for debugging / headless verification
// ---------------------------------------------------------------------------

static Napi::Value SnapshotWindow(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSWindow* win = Deref<NSWindow*>(info[0]);
  NSString* path = ToNSString(info[1]);

  // Capture our own window's real composited pixels (allowed without the
  // screen-recording permission for windows the process owns). This shows the
  // true WindowServer output, including geometryFlipped, masks, and shadows.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  bool withShadow = info.Length() > 2 && info[2].ToBoolean().Value();
  CGImageRef img = CGWindowListCreateImage(
      CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)win.windowNumber,
      withShadow
          ? (CGWindowImageOption)kCGWindowImageBestResolution
          : (CGWindowImageOption)(kCGWindowImageBoundsIgnoreFraming |
                                  kCGWindowImageBestResolution));
#pragma clang diagnostic pop
  if (!img) return Napi::Boolean::New(env, false);

  NSURL* url = [NSURL fileURLWithPath:path];
  CGImageDestinationRef dst =
      CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
  bool ok = false;
  if (dst) {
    CGImageDestinationAddImage(dst, img, NULL);
    ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
  }
  CGImageRelease(img);
  return Napi::Boolean::New(env, ok);
}

// ---------------------------------------------------------------------------
// module init
// ---------------------------------------------------------------------------

// src/backend.mm — the react-x11 backend surface (windows with delegates,
// enriched events, CG surfaces, CoreText layouts, pasteboard, screens).
void InitBackend(Napi::Env env, Napi::Object exports);

static Napi::Object Init(Napi::Env env, Napi::Object exports) {
#define FN(js, fn) exports.Set(js, Napi::Function::New(env, fn))
  FN("initApp", InitApp);
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
  FN("hitTest", HitTest);
  FN("measureText", MeasureText);
  FN("createTextImage", CreateTextImage);
  FN("setContentsImage", SetContentsImage);
  FN("drawControl", DrawControl);
  FN("appearanceIsDark", AppearanceIsDark);
#undef FN
  InitBackend(env, exports);
  return exports;
}

NODE_API_MODULE(calayers, Init)
