// node-calayers backend.mm — the surface the react-x11 Cocoa backend consumes.
//
// Everything here is mechanism, no policy: windows with delegates and
// per-window event routing, an enriched event pump, CoreGraphics bitmap
// surfaces with a canvas-shaped drawing API, a CoreText layout engine
// (measure + draw + caret/hit geometry), pasteboard text, screen lists and
// cursors. The retained-layer API stays in addon.mm; this file is what a
// renderer paints and listens through.
//
// Coordinate rule, stated once: every point that crosses this boundary is
// TOP-LEFT origin. Window frames and screen rects are top-left in global
// coordinates (y grows down from the top of the primary screen); event
// positions are top-left in the window's content view; surfaces are y-down
// like a canvas. The flips against Cocoa's bottom-up world happen here and
// nowhere else.

#include <napi.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#include <objc/runtime.h>

#include <cmath>
#include <string>
#include <vector>

// --- helpers (self-contained: addon.mm keeps its own copies) ---------------

static NSString* BToNSString(Napi::Value v) {
  std::string s = v.As<Napi::String>().Utf8Value();
  return [NSString stringWithUTF8String:s.c_str()];
}

static double BNumOr(Napi::Object o, const char* k, double d) {
  if (!o.Has(k)) return d;
  Napi::Value v = o.Get(k);
  return v.IsNumber() ? v.As<Napi::Number>().DoubleValue() : d;
}

static bool BBoolOr(Napi::Object o, const char* k, bool d) {
  if (!o.Has(k)) return d;
  Napi::Value v = o.Get(k);
  return v.IsBoolean() ? v.As<Napi::Boolean>().Value() : d;
}

template <typename T>
static T BDeref(Napi::Value v) {
  return (__bridge T)(v.As<Napi::External<void>>().Data());
}

static Napi::Value BWrapRetained(Napi::Env env, id obj) {
  void* p = (void*)CFBridgingRetain(obj);
  return Napi::External<void>::New(env, p,
                                   [](Napi::Env, void* d) { CFRelease(d); });
}

// [r,g,b,a] 0..1 -> CGColor (caller releases)
static CGColorRef BMakeColor(Napi::Value v) {
  Napi::Array a = v.As<Napi::Array>();
  double r = a.Get(0u).As<Napi::Number>().DoubleValue();
  double g = a.Get(1u).As<Napi::Number>().DoubleValue();
  double b = a.Get(2u).As<Napi::Number>().DoubleValue();
  double al =
      a.Length() > 3 ? a.Get(3u).As<Napi::Number>().DoubleValue() : 1.0;
  return CGColorCreateSRGB(r, g, b, al);
}

static void BEnsureApp() {
  static bool inited = false;
  if (inited) return;
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
  }
  inited = true;
}

// The top of the primary screen, for global coordinate flips. The primary
// screen is the one whose Cocoa frame origin is (0,0); its top edge is the
// global top-left origin's y=0.
static CGFloat PrimaryScreenTop() {
  NSScreen* primary = NSScreen.screens.firstObject;
  return primary ? NSMaxY(primary.frame) : 0;
}

// ---------------------------------------------------------------------------
// the event callback (backend flavour — richer payloads than addon.mm's)
// ---------------------------------------------------------------------------

static Napi::FunctionReference gBackendCb;
// Re-entrancy guard: delegate methods fire inside [NSApp sendEvent:] (live
// resize, window moves), and each call into JS may pump more native work.
// The guard only protects against dispatching with no callback installed.
static bool HasBackendCb() { return !gBackendCb.IsEmpty(); }

static void EmitToJS(Napi::Env env, Napi::Object ev) {
  if (!HasBackendCb()) return;
  gBackendCb.Call({ev});
}

// Window bookkeeping: delegate + view need to reach the JS callback with the
// window's number attached, and windowShouldClose needs to answer NO while
// telling JS. One delegate class serves every window.

@interface CALBackendDelegate : NSObject <NSWindowDelegate> {
 @public
  napi_env env_;
}
@end

static Napi::Object WindowEvent(Napi::Env env, NSWindow* win,
                                const char* type) {
  Napi::Object ev = Napi::Object::New(env);
  ev.Set("type", type);
  ev.Set("windowNumber", (double)win.windowNumber);
  return ev;
}

static void EmitWindowGeometry(Napi::Env env, NSWindow* win, const char* type,
                               bool live) {
  if (!HasBackendCb()) return;
  Napi::HandleScope scope(env);
  Napi::Object ev = WindowEvent(env, win, type);
  NSRect content = [win contentRectForFrameRect:win.frame];
  ev.Set("width", content.size.width);
  ev.Set("height", content.size.height);
  ev.Set("x", content.origin.x);
  ev.Set("y", PrimaryScreenTop() - (content.origin.y + content.size.height));
  ev.Set("live", live);
  EmitToJS(env, ev);
}

@implementation CALBackendDelegate
- (void)windowDidResize:(NSNotification*)n {
  NSWindow* win = n.object;
  EmitWindowGeometry(Napi::Env(env_), win, "window-resize", win.inLiveResize);
}
- (void)windowDidMove:(NSNotification*)n {
  EmitWindowGeometry(Napi::Env(env_), (NSWindow*)n.object, "window-move",
                     false);
}
- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (HasBackendCb()) {
    Napi::Env env(env_);
    Napi::HandleScope scope(env);
    EmitToJS(env, WindowEvent(env, sender, "window-close-request"));
  }
  return NO;  // closing is the renderer's decision, never AppKit's
}
- (void)windowDidBecomeKey:(NSNotification*)n {
  Napi::Env env(env_);
  Napi::HandleScope scope(env);
  EmitToJS(env, WindowEvent(env, (NSWindow*)n.object, "window-focus"));
}
- (void)windowDidResignKey:(NSNotification*)n {
  Napi::Env env(env_);
  Napi::HandleScope scope(env);
  EmitToJS(env, WindowEvent(env, (NSWindow*)n.object, "window-blur"));
}
- (void)windowDidChangeBackingProperties:(NSNotification*)n {
  NSWindow* win = n.object;
  Napi::Env env(env_);
  Napi::HandleScope scope(env);
  Napi::Object ev = WindowEvent(env, win, "window-scale");
  ev.Set("scale", win.backingScaleFactor);
  EmitToJS(env, ev);
}
@end

static char kDelegateKey;

// ---------------------------------------------------------------------------
// the hosting view: flipped, layer-hosting, with a tracking area for
// enter/exit/moved even in non-key windows (menus are non-activating panels)
// ---------------------------------------------------------------------------

@interface CALBackendView : NSView {
 @public
  NSTrackingArea* tracking_;
}
@end
@implementation CALBackendView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)keyDown:(NSEvent*)event { (void)event; }  // no beep; JS observes keys
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (tracking_) [self removeTrackingArea:tracking_];
  tracking_ = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                    NSTrackingActiveAlways | NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:tracking_];
}
// First click on a non-key window should act, not just focus — a menu item
// in a panel, a button in an unfocused window. Every X11 app behaves so.
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
@end

// A panel that can host popups without stealing key status from the owner
// window (menus, tooltips, dropdowns).
@interface CALBackendPanel : NSPanel
@end
@implementation CALBackendPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// A borderless window that can still take the keyboard (managed dialogs
// with decorations:false, plain toplevels drawn frameless).
@interface CALBackendKeyWindow : NSWindow
@end
@implementation CALBackendKeyWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

// ---------------------------------------------------------------------------
// createWindow2 / window management
// ---------------------------------------------------------------------------

// createWindow2({ width, height,          // content size, points
//                 title, kind,            // 'normal' | 'popup' | 'borderless'
//                 x, y,                   // top-left global, points (optional)
//                 resizable, opaque, hasShadow, level,   // level: 'normal'|'popup'|'floating'
//                 backgroundColor })      // [r,g,b,a] or absent
static Napi::Value CreateWindow2(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  BEnsureApp();
  Napi::Object o = info[0].As<Napi::Object>();
  double w = BNumOr(o, "width", 640), h = BNumOr(o, "height", 480);
  std::string kind = o.Has("kind") && o.Get("kind").IsString()
                         ? o.Get("kind").As<Napi::String>().Utf8Value()
                         : "normal";
  bool resizable = BBoolOr(o, "resizable", true);

  NSWindow* win;
  @autoreleasepool {
    NSRect rect = NSMakeRect(0, 0, w, h);
    if (kind == "popup") {
      win = [[CALBackendPanel alloc]
          initWithContentRect:rect
                    styleMask:(NSWindowStyleMaskBorderless |
                               NSWindowStyleMaskNonactivatingPanel)
                      backing:NSBackingStoreBuffered
                        defer:NO];
      win.level = NSPopUpMenuWindowLevel;
      ((NSPanel*)win).worksWhenModal = YES;
    } else if (kind == "borderless") {
      win = [[CALBackendKeyWindow alloc]
          initWithContentRect:rect
                    styleMask:NSWindowStyleMaskBorderless
                      backing:NSBackingStoreBuffered
                        defer:NO];
    } else {
      NSWindowStyleMask mask = NSWindowStyleMaskTitled |
                               NSWindowStyleMaskClosable |
                               NSWindowStyleMaskMiniaturizable;
      if (resizable) mask |= NSWindowStyleMaskResizable;
      win = [[NSWindow alloc] initWithContentRect:rect
                                        styleMask:mask
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    }
    win.releasedWhenClosed = NO;
    win.acceptsMouseMovedEvents = YES;
    if (o.Has("title") && o.Get("title").IsString())
      win.title = BToNSString(o.Get("title"));
    if (o.Has("level") && o.Get("level").IsString()) {
      std::string level = o.Get("level").As<Napi::String>().Utf8Value();
      if (level == "popup") win.level = NSPopUpMenuWindowLevel;
      else if (level == "floating") win.level = NSFloatingWindowLevel;
    }
    if (o.Has("hasShadow")) win.hasShadow = BBoolOr(o, "hasShadow", true);
    if (o.Has("opaque")) {
      win.opaque = BBoolOr(o, "opaque", true);
      if (!win.opaque) win.backgroundColor = NSColor.clearColor;
    }

    CALBackendView* view = [[CALBackendView alloc] initWithFrame:rect];
    CALayer* root = [CALayer layer];
    root.geometryFlipped = YES;
    [view setLayer:root];
    [view setWantsLayer:YES];
    win.contentView = view;
    root.contentsScale = win.backingScaleFactor;
    if (o.Has("backgroundColor") && o.Get("backgroundColor").IsArray()) {
      CGColorRef c = BMakeColor(o.Get("backgroundColor"));
      root.backgroundColor = c;
      CGColorRelease(c);
    }

    // Placement: explicit top-left global coordinates, or centered.
    if (o.Has("x") && o.Get("x").IsNumber() && o.Has("y") &&
        o.Get("y").IsNumber()) {
      double x = BNumOr(o, "x", 0), y = BNumOr(o, "y", 0);
      NSRect frame = [win frameRectForContentRect:NSMakeRect(0, 0, w, h)];
      CGFloat titlebar = frame.size.height - h;
      // y is the CONTENT's top edge in top-left global coordinates.
      [win setFrameOrigin:NSMakePoint(x, PrimaryScreenTop() - y - h)];
      (void)titlebar;
    } else {
      [win center];
    }

    CALBackendDelegate* delegate = [[CALBackendDelegate alloc] init];
    delegate->env_ = (napi_env)env;
    win.delegate = delegate;
    objc_setAssociatedObject(win, &kDelegateKey, delegate,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [win makeFirstResponder:view];
  }
  return BWrapRetained(env, win);
}

// showWindow(win, activate) — map. Popups order front without activating.
static Napi::Value ShowWindowFn(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  bool activate = info.Length() > 1 && info[1].ToBoolean().Value();
  if (activate) {
    [win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
  } else {
    [win orderFrontRegardless];
  }
  return info.Env().Undefined();
}

static Napi::Value HideWindowFn(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  [win orderOut:nil];
  return info.Env().Undefined();
}

static Napi::Value SetWindowTitle(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  win.title = BToNSString(info[1]);
  return info.Env().Undefined();
}

// setWindowFrame(win, x, y, w, h) — any argument may be null to keep it.
// x/y are the content's top-left in global top-left coordinates, points.
static Napi::Value SetWindowFrame(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  NSRect content = [win contentRectForFrameRect:win.frame];
  double topY = PrimaryScreenTop() - (content.origin.y + content.size.height);
  double x = info[1].IsNumber() ? info[1].As<Napi::Number>().DoubleValue()
                                : content.origin.x;
  double y = info[2].IsNumber() ? info[2].As<Napi::Number>().DoubleValue()
                                : topY;
  double w = info[3].IsNumber() ? info[3].As<Napi::Number>().DoubleValue()
                                : content.size.width;
  double h = info[4].IsNumber() ? info[4].As<Napi::Number>().DoubleValue()
                                : content.size.height;
  NSRect newContent =
      NSMakeRect(x, PrimaryScreenTop() - y - h, w, h);
  [win setFrame:[win frameRectForContentRect:newContent] display:YES];
  return info.Env().Undefined();
}

// -> { x, y, width, height, scale, visible, key } — content rect, top-left
// global coordinates, points.
static Napi::Value GetWindowFrame(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  NSRect content = [win contentRectForFrameRect:win.frame];
  Napi::Object r = Napi::Object::New(env);
  r.Set("x", content.origin.x);
  r.Set("y", PrimaryScreenTop() - (content.origin.y + content.size.height));
  r.Set("width", content.size.width);
  r.Set("height", content.size.height);
  r.Set("scale", win.backingScaleFactor);
  r.Set("visible", (bool)win.isVisible);
  r.Set("key", (bool)win.isKeyWindow);
  return r;
}

static Napi::Value SetWindowMinMax(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  Napi::Object o = info[1].As<Napi::Object>();
  if (o.Has("minWidth") || o.Has("minHeight"))
    win.contentMinSize =
        NSMakeSize(BNumOr(o, "minWidth", 0), BNumOr(o, "minHeight", 0));
  if (o.Has("maxWidth") || o.Has("maxHeight"))
    win.contentMaxSize = NSMakeSize(BNumOr(o, "maxWidth", 100000),
                                    BNumOr(o, "maxHeight", 100000));
  return info.Env().Undefined();
}

static Napi::Value DestroyWindow2(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  win.delegate = nil;
  objc_setAssociatedObject(win, &kDelegateKey, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [win orderOut:nil];
  [win close];
  return info.Env().Undefined();
}

static Napi::Value ActivateApp(const Napi::CallbackInfo& info) {
  BEnsureApp();
  [NSApp activateIgnoringOtherApps:YES];
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// pump2: the enriched event stream
// ---------------------------------------------------------------------------

static void DispatchEvent2(Napi::Env env, NSEvent* e) {
  if (!HasBackendCb()) return;
  const char* type = nullptr;
  bool mouse = false, key = false, wheel = false, crossing = false;
  switch (e.type) {
    case NSEventTypeLeftMouseDown: type = "mousedown"; mouse = true; break;
    case NSEventTypeLeftMouseUp: type = "mouseup"; mouse = true; break;
    case NSEventTypeRightMouseDown: type = "mousedown"; mouse = true; break;
    case NSEventTypeRightMouseUp: type = "mouseup"; mouse = true; break;
    case NSEventTypeOtherMouseDown: type = "mousedown"; mouse = true; break;
    case NSEventTypeOtherMouseUp: type = "mouseup"; mouse = true; break;
    case NSEventTypeMouseMoved: type = "mousemove"; mouse = true; break;
    case NSEventTypeLeftMouseDragged: type = "mousemove"; mouse = true; break;
    case NSEventTypeRightMouseDragged: type = "mousemove"; mouse = true; break;
    case NSEventTypeOtherMouseDragged: type = "mousemove"; mouse = true; break;
    case NSEventTypeScrollWheel: type = "wheel"; mouse = true; wheel = true; break;
    case NSEventTypeKeyDown: type = "keydown"; key = true; break;
    case NSEventTypeKeyUp: type = "keyup"; key = true; break;
    case NSEventTypeMouseEntered: type = "mouseenter"; crossing = true; break;
    case NSEventTypeMouseExited: type = "mouseleave"; crossing = true; break;
    case NSEventTypeFlagsChanged: type = "flagschanged"; key = true; break;
    default: return;
  }
  if ((mouse || crossing) && !e.window) return;

  Napi::HandleScope scope(env);
  Napi::Object ev = Napi::Object::New(env);
  ev.Set("type", type);
  if (e.window) ev.Set("windowNumber", (double)e.window.windowNumber);
  ev.Set("time", e.timestamp * 1000.0);

  NSEventModifierFlags f = e.modifierFlags;
  ev.Set("shift", (bool)(f & NSEventModifierFlagShift));
  ev.Set("control", (bool)(f & NSEventModifierFlagControl));
  ev.Set("option", (bool)(f & NSEventModifierFlagOption));
  ev.Set("command", (bool)(f & NSEventModifierFlagCommand));
  ev.Set("capsLock", (bool)(f & NSEventModifierFlagCapsLock));

  if ((mouse || crossing) && e.window) {
    NSView* v = e.window.contentView;
    NSPoint p = [v convertPoint:e.locationInWindow fromView:nil];
    ev.Set("x", p.x);
    ev.Set("y", v.isFlipped ? p.y : v.bounds.size.height - p.y);
    // and the same point in global top-left coordinates, for popups
    NSRect r = [e.window
        convertRectToScreen:NSMakeRect(e.locationInWindow.x,
                                       e.locationInWindow.y, 0, 0)];
    ev.Set("gx", r.origin.x);
    ev.Set("gy", PrimaryScreenTop() - r.origin.y);
  }
  if (mouse && !wheel && !crossing) {
    // 0 left, 1 right, 2 middle in AppKit; X buttons are 1 left, 2 middle,
    // 3 right. Translate here so JS never sees AppKit numbering.
    long b = e.buttonNumber;
    long xbutton = b == 0 ? 1 : b == 1 ? 3 : b == 2 ? 2 : (long)b + 1;
    if (e.type == NSEventTypeMouseMoved ||
        e.type == NSEventTypeLeftMouseDragged ||
        e.type == NSEventTypeRightMouseDragged ||
        e.type == NSEventTypeOtherMouseDragged) {
      xbutton = 0;
    }
    ev.Set("button", (double)xbutton);
    if (e.type == NSEventTypeLeftMouseDown ||
        e.type == NSEventTypeRightMouseDown ||
        e.type == NSEventTypeOtherMouseDown ||
        e.type == NSEventTypeLeftMouseUp ||
        e.type == NSEventTypeRightMouseUp ||
        e.type == NSEventTypeOtherMouseUp) {
      ev.Set("clickCount", (double)e.clickCount);
    }
  }
  if (wheel) {
    ev.Set("dx", e.scrollingDeltaX);
    ev.Set("dy", e.scrollingDeltaY);
    ev.Set("precise", (bool)e.hasPreciseScrollingDeltas);
    ev.Set("momentum", e.momentumPhase != NSEventPhaseNone);
  }
  if (key && e.type != NSEventTypeFlagsChanged) {
    ev.Set("keyCode", (double)e.keyCode);
    NSString* chars = e.characters;
    NSString* ignoring = e.charactersIgnoringModifiers;
    if (chars) ev.Set("chars", chars.UTF8String);
    if (ignoring) ev.Set("charsShifted", ignoring.UTF8String);
    if (@available(macOS 10.15, *)) {
      NSString* base = [e charactersByApplyingModifiers:0];
      if (base) ev.Set("charsBase", base.UTF8String);
    }
    ev.Set("repeat", (bool)e.isARepeat);
  }
  EmitToJS(env, ev);
}

static Napi::Value SetBackendEventCallback(const Napi::CallbackInfo& info) {
  if (info[0].IsFunction()) {
    gBackendCb = Napi::Persistent(info[0].As<Napi::Function>());
  } else {
    gBackendCb.Reset();
  }
  return info.Env().Undefined();
}

static Napi::Value Pump2(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  BEnsureApp();
  @autoreleasepool {
    while (true) {
      NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                      untilDate:[NSDate distantPast]
                                         inMode:NSDefaultRunLoopMode
                                        dequeue:YES];
      if (!e) break;
      DispatchEvent2(env, e);
      [NSApp sendEvent:e];
    }
    [CATransaction flush];
  }
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// surfaces: CGBitmapContext with canvas-shaped drawing
// ---------------------------------------------------------------------------

struct CALSurface {
  CGContextRef ctx = nullptr;
  size_t width = 0, height = 0;  // pixels
  double scale = 1;
};

static CALSurface* SurfaceFrom(Napi::Value v) {
  return (CALSurface*)v.As<Napi::External<void>>().Data();
}

// createSurface(widthPx, heightPx, scale) — top-left origin, y down (the
// base CTM flips Cocoa's bottom-up bitmap once, here).
static Napi::Value CreateSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  size_t w = (size_t)info[0].As<Napi::Number>().Int64Value();
  size_t h = (size_t)info[1].As<Napi::Number>().Int64Value();
  double scale = info.Length() > 2 ? info[2].As<Napi::Number>().DoubleValue() : 1;
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, w, h, 8, 0, cs,
      kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    Napi::Error::New(env, "createSurface: CGBitmapContextCreate failed")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CGContextTranslateCTM(ctx, 0, (CGFloat)h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
  auto* s = new CALSurface{ctx, w, h, scale};
  return Napi::External<void>::New(env, s, [](Napi::Env, void* d) {
    auto* s = (CALSurface*)d;
    CGContextRelease(s->ctx);
    delete s;
  });
}

static Napi::Value SurfaceSize(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  Napi::Object r = Napi::Object::New(info.Env());
  r.Set("width", (double)s->width);
  r.Set("height", (double)s->height);
  r.Set("scale", s->scale);
  return r;
}

// ---------------------------------------------------------------------------
// the macOS main menu — the global-menu adapter's native half. The JS side
// owns the item model (react-x11's dbusmenu snapshot machinery, stable ids
// via IdAllocator); this side turns one spec into an NSMenu tree and fires
// a backend event with the item's id on activation, delivered through the
// same callback every other event takes. Menu tracking is one of AppKit's
// modal loops, and those already call into JS here (live resize does), so
// activation needs no extra plumbing.
// ---------------------------------------------------------------------------

static NSString* BStrOr(Napi::Object o, const char* k, NSString* d);

@interface CALMenuTarget : NSObject {
 @public
  napi_env env_;
}
- (void)activate:(NSMenuItem*)sender;
@end
@implementation CALMenuTarget
- (void)activate:(NSMenuItem*)sender {
  Napi::Env env(env_);
  Napi::HandleScope scope(env);
  Napi::Object ev = Napi::Object::New(env);
  ev.Set("type", "menu-activate");
  ev.Set("id", (double)sender.tag);
  EmitToJS(env, ev);
}
@end

static CALMenuTarget* gMenuTarget = nil;

static NSMenu* BuildMenuFrom(Napi::Env env, Napi::Array items);

static NSMenuItem* BuildMenuItem(Napi::Env env, Napi::Object o) {
  if (BBoolOr(o, "separator", false)) return [NSMenuItem separatorItem];
  NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:BStrOr(o, "title", @"")
                                              action:nil
                                       keyEquivalent:@""];
  it.tag = (NSInteger)BNumOr(o, "id", 0);
  it.enabled = BBoolOr(o, "enabled", true);
  it.hidden = BBoolOr(o, "hidden", false);
  it.state = BBoolOr(o, "checked", false) ? NSControlStateValueOn
                                          : NSControlStateValueOff;
  NSString* key = BStrOr(o, "key", @"");
  if (key.length) {
    it.keyEquivalent = key;
    it.keyEquivalentModifierMask =
        (NSUInteger)BNumOr(o, "modifiers", NSEventModifierFlagCommand);
  }
  bool hasChildren = false;
  if (o.Has("items")) {
    Napi::Value v = o.Get("items");
    if (v.IsArray() && v.As<Napi::Array>().Length() > 0) {
      NSMenu* sub = BuildMenuFrom(env, v.As<Napi::Array>());
      sub.title = it.title;
      it.submenu = sub;
      hasChildren = true;
    }
  }
  if (!hasChildren) {
    it.target = gMenuTarget;
    it.action = @selector(activate:);
  }
  return it;
}

static NSMenu* BuildMenuFrom(Napi::Env env, Napi::Array items) {
  NSMenu* m = [[NSMenu alloc] initWithTitle:@""];
  // we own enabled/hidden; AppKit's validation would grey everything whose
  // target it cannot interrogate
  m.autoenablesItems = NO;
  for (uint32_t i = 0; i < items.Length(); i++) {
    Napi::Value v = items.Get(i);
    if (!v.IsObject()) continue;
    [m addItem:BuildMenuItem(env, v.As<Napi::Object>())];
  }
  return m;
}

// setMainMenu(spec) — spec: [{title, items: [...]}, ...]. Entry 0 is the
// app menu (macOS shows the process name for its title regardless).
static Napi::Value SetMainMenuFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  BEnsureApp();
  if (!gMenuTarget) gMenuTarget = [CALMenuTarget new];
  gMenuTarget->env_ = env;
  Napi::Array spec = info[0].As<Napi::Array>();
  NSMenu* main = [[NSMenu alloc] initWithTitle:@"MainMenu"];
  main.autoenablesItems = NO;
  for (uint32_t i = 0; i < spec.Length(); i++) {
    Napi::Value v = spec.Get(i);
    if (!v.IsObject()) continue;
    Napi::Object m = v.As<Napi::Object>();
    NSString* title = BStrOr(m, "title", @"");
    NSMenuItem* holder = [[NSMenuItem alloc] initWithTitle:title
                                                    action:nil
                                             keyEquivalent:@""];
    Napi::Value items = m.Get("items");
    NSMenu* sub = items.IsArray()
                      ? BuildMenuFrom(env, items.As<Napi::Array>())
                      : [[NSMenu alloc] initWithTitle:title];
    sub.autoenablesItems = NO;
    sub.title = title;
    holder.submenu = sub;
    [main addItem:holder];
  }
  [NSApp setMainMenu:main];
  return env.Undefined();
}

static Napi::Object MenuInfo(Napi::Env env, NSMenu* menu) {
  Napi::Object out = Napi::Object::New(env);
  out.Set("title", [menu.title UTF8String]);
  Napi::Array arr = Napi::Array::New(env, menu.numberOfItems);
  for (NSInteger i = 0; i < menu.numberOfItems; i++) {
    NSMenuItem* it = [menu itemAtIndex:i];
    Napi::Object io = Napi::Object::New(env);
    io.Set("title", [it.title UTF8String]);
    io.Set("id", (double)it.tag);
    io.Set("enabled", (bool)it.enabled);
    io.Set("hidden", (bool)it.hidden);
    io.Set("separator", (bool)it.separatorItem);
    io.Set("checked", it.state == NSControlStateValueOn);
    io.Set("key", [it.keyEquivalent UTF8String]);
    if (it.submenu) io.Set("submenu", MenuInfo(env, it.submenu));
    arr.Set((uint32_t)i, io);
  }
  out.Set("items", arr);
  return out;
}

// mainMenuInfo() — the installed menu bar as data, for tests.
static Napi::Value MainMenuInfoFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSMenu* main = [NSApp mainMenu];
  if (!main) return env.Null();
  return MenuInfo(env, main);
}

// activateMenuItem([i, j, ...]) — walk the installed bar by index and fire
// the leaf's action, the way tracking would. For tests.
static Napi::Value ActivateMenuItemFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Array path = info[0].As<Napi::Array>();
  NSMenu* menu = [NSApp mainMenu];
  if (!menu) return Napi::Boolean::New(env, false);
  for (uint32_t d = 0; d + 1 < path.Length(); d++) {
    NSInteger i = (NSInteger)path.Get(d).As<Napi::Number>().Int64Value();
    if (i < 0 || i >= menu.numberOfItems) return Napi::Boolean::New(env, false);
    menu = [menu itemAtIndex:i].submenu;
    if (!menu) return Napi::Boolean::New(env, false);
  }
  NSInteger leaf = (NSInteger)
      path.Get(path.Length() - 1).As<Napi::Number>().Int64Value();
  if (leaf < 0 || leaf >= menu.numberOfItems)
    return Napi::Boolean::New(env, false);
  [menu performActionForItemAtIndex:leaf];
  return Napi::Boolean::New(env, true);
}

// ---------------------------------------------------------------------------
// native control bezels — NSCell/NSControl rendered offscreen (the WebKit/
// Gecko form-control technique), measured and drawn in one vocabulary so the
// JS side can cache by parameters. Everything is in points; the surface's
// own scale says how many pixels a point is worth.
// ---------------------------------------------------------------------------

static NSString* BStrOr(Napi::Object o, const char* k, NSString* d) {
  if (!o.Has(k)) return d;
  Napi::Value v = o.Get(k);
  return v.IsString() ? BToNSString(v) : d;
}

static NSView* BezelDrawView() {
  // Cells only consult the view for flippedness and appearance; it never
  // needs a window.
  static CALBackendView* v = nil;
  if (!v) v = [[CALBackendView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 1000)];
  return v;
}

// The two render paths AppKit leaves us: classic cells draw offscreen via
// drawWithFrame:, while NSSlider's cell now renders through the view's layer
// machinery and NSSwitch has no cell at all — those go through a real
// offscreen NSControl and displayRectIgnoringOpacity:inContext:.
struct BezelControl {
  NSCell* cell = nil;
  NSControl* view = nil;
};

static BezelControl BuildBezel(Napi::Env env, Napi::Object o) {
  BezelControl out;
  NSString* kind = BStrOr(o, "kind", @"push");
  bool pressed = BBoolOr(o, "pressed", false);
  bool enabled = BBoolOr(o, "enabled", true);
  int state = (int)BNumOr(o, "state", 0);  // 0 off, 1 on

  if ([kind isEqualToString:@"checkbox"] || [kind isEqualToString:@"radio"] ||
      [kind isEqualToString:@"push"]) {
    NSButtonCell* c = [[NSButtonCell alloc] initTextCell:BStrOr(o, "title", @"")];
    if ([kind isEqualToString:@"checkbox"]) {
      c.buttonType = NSButtonTypeSwitch;
    } else if ([kind isEqualToString:@"radio"]) {
      c.buttonType = NSButtonTypeRadio;
    } else {
      c.buttonType = NSButtonTypeMomentaryPushIn;
      c.bezelStyle = NSBezelStylePush;
      // the Return key equivalent is what makes AppKit fill it with the
      // user's accent — the "default button" look
      if (BBoolOr(o, "isDefault", false)) c.keyEquivalent = @"\r";
    }
    c.state = state == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    out.cell = c;
  } else if ([kind isEqualToString:@"popup"]) {
    NSPopUpButtonCell* c = [[NSPopUpButtonCell alloc] initTextCell:@"" pullsDown:NO];
    [c addItemWithTitle:BStrOr(o, "title", @"")];
    out.cell = c;
  } else if ([kind isEqualToString:@"slider"]) {
    NSSlider* s = [[NSSlider alloc] init];
    s.minValue = 0;
    s.maxValue = 1;
    s.doubleValue = BNumOr(o, "value", 0.5);
    out.view = s;
  } else if ([kind isEqualToString:@"switch"]) {
    NSSwitch* s = [[NSSwitch alloc] init];
    s.state = state == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    out.view = s;
  } else {
    Napi::Error::New(env, "unknown control kind").ThrowAsJavaScriptException();
    return out;
  }

  NSString* sz = BStrOr(o, "controlSize", @"regular");
  NSControlSize csize = NSControlSizeRegular;
  if ([sz isEqualToString:@"small"]) csize = NSControlSizeSmall;
  else if ([sz isEqualToString:@"mini"]) csize = NSControlSizeMini;
  else if ([sz isEqualToString:@"large"]) csize = NSControlSizeLarge;

  if (out.cell) {
    out.cell.controlSize = csize;
    out.cell.font =
        [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:csize]];
    out.cell.enabled = enabled;
    out.cell.highlighted = pressed;
  } else if (out.view) {
    out.view.controlSize = csize;
    out.view.enabled = enabled;
  }
  return out;
}

static NSAppearance* BezelAppearance(Napi::Object o) {
  NSString* name = BStrOr(o, "appearance", @"system");
  if ([name isEqualToString:@"dark"])
    return [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  if ([name isEqualToString:@"light"])
    return [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  return NSApp.effectiveAppearance;
}

// measureControl({kind, controlSize, title?}) -> {width, height} in points —
// the control's natural size, which is the size the bezel is *designed* at:
// stretching a checkbox distorts it, so layout adopts these.
static Napi::Value MeasureControl(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  BEnsureApp();
  Napi::Object o = info[0].As<Napi::Object>();
  BezelControl c = BuildBezel(env, o);
  if (env.IsExceptionPending()) return env.Undefined();
  double w = 0, h = 0;
  if (c.cell) {
    NSSize natural = c.cell.cellSize;
    w = ceil(natural.width);
    h = ceil(natural.height);
  } else if (c.view) {
    NSSize natural = c.view.intrinsicContentSize;
    w = natural.width > 0 ? ceil(natural.width) : 100;
    h = natural.height > 0 ? ceil(natural.height) : 22;
  }
  Napi::Object r = Napi::Object::New(env);
  r.Set("width", w);
  r.Set("height", h);
  return r;
}

// drawControlIntoSurface(surface, params) — render the bezel to fill the
// whole surface (surface px / scale = the frame in points). Clears first:
// bezels are alpha-composited art, not opaque tiles.
static Napi::Value DrawControlIntoSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  BEnsureApp();
  CALSurface* s = SurfaceFrom(info[0]);
  Napi::Object o = info[1].As<Napi::Object>();
  BezelControl c = BuildBezel(env, o);
  if (env.IsExceptionPending()) return env.Undefined();

  double scale = s->scale > 0 ? s->scale : 1;
  double w = s->width / scale, h = s->height / scale;

  CGContextSaveGState(s->ctx);
  // the surface's base CTM is already top-left-origin device pixels; clear
  // in that space, then move to points for AppKit
  CGContextClearRect(s->ctx, CGRectMake(0, 0, (CGFloat)s->width, (CGFloat)s->height));
  CGContextScaleCTM(s->ctx, scale, scale);

  NSGraphicsContext* g =
      [NSGraphicsContext graphicsContextWithCGContext:s->ctx flipped:YES];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:g];

  NSAppearance* ap = BezelAppearance(o);
  if (c.view) {
    c.view.frame = NSMakeRect(0, 0, w, h);
    c.view.appearance = ap;
    [c.view layoutSubtreeIfNeeded];
    [c.view displayRectIgnoringOpacity:c.view.bounds inContext:g];
  } else if (c.cell) {
    NSCell* cell = c.cell;
    [ap performAsCurrentDrawingAppearance:^{
      [cell drawWithFrame:NSMakeRect(0, 0, w, h) inView:BezelDrawView()];
    }];
  }

  [NSGraphicsContext restoreGraphicsState];
  CGContextRestoreGState(s->ctx);
  return env.Undefined();
}

// --- drawing verbs. All take the surface handle first. ---------------------

static Napi::Value CtxSave(const Napi::CallbackInfo& info) {
  CGContextSaveGState(SurfaceFrom(info[0])->ctx);
  return info.Env().Undefined();
}
static Napi::Value CtxRestore(const Napi::CallbackInfo& info) {
  CGContextRestoreGState(SurfaceFrom(info[0])->ctx);
  return info.Env().Undefined();
}
static Napi::Value CtxTranslate(const Napi::CallbackInfo& info) {
  CGContextTranslateCTM(SurfaceFrom(info[0])->ctx,
                        info[1].As<Napi::Number>().DoubleValue(),
                        info[2].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxScale(const Napi::CallbackInfo& info) {
  CGContextScaleCTM(SurfaceFrom(info[0])->ctx,
                    info[1].As<Napi::Number>().DoubleValue(),
                    info[2].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxTransform(const Napi::CallbackInfo& info) {
  CGContextConcatCTM(SurfaceFrom(info[0])->ctx,
                     CGAffineTransformMake(
                         info[1].As<Napi::Number>().DoubleValue(),
                         info[2].As<Napi::Number>().DoubleValue(),
                         info[3].As<Napi::Number>().DoubleValue(),
                         info[4].As<Napi::Number>().DoubleValue(),
                         info[5].As<Napi::Number>().DoubleValue(),
                         info[6].As<Napi::Number>().DoubleValue()));
  return info.Env().Undefined();
}

static Napi::Value CtxRotate(const Napi::CallbackInfo& info) {
  CGContextRotateCTM(SurfaceFrom(info[0])->ctx,
                     info[1].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxBeginPath(const Napi::CallbackInfo& info) {
  CGContextBeginPath(SurfaceFrom(info[0])->ctx);
  return info.Env().Undefined();
}
static Napi::Value CtxMoveTo(const Napi::CallbackInfo& info) {
  CGContextMoveToPoint(SurfaceFrom(info[0])->ctx,
                       info[1].As<Napi::Number>().DoubleValue(),
                       info[2].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxLineTo(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  double x = info[1].As<Napi::Number>().DoubleValue();
  double y = info[2].As<Napi::Number>().DoubleValue();
  if (CGContextIsPathEmpty(s->ctx)) CGContextMoveToPoint(s->ctx, x, y);
  else CGContextAddLineToPoint(s->ctx, x, y);
  return info.Env().Undefined();
}
static Napi::Value CtxRect(const Napi::CallbackInfo& info) {
  CGContextAddRect(SurfaceFrom(info[0])->ctx,
                   CGRectMake(info[1].As<Napi::Number>().DoubleValue(),
                              info[2].As<Napi::Number>().DoubleValue(),
                              info[3].As<Napi::Number>().DoubleValue(),
                              info[4].As<Napi::Number>().DoubleValue()));
  return info.Env().Undefined();
}
// roundRect(surface, x, y, w, h, r0, r1, r2, r3) — per-corner radii,
// top-left/top-right/bottom-right/bottom-left, already clamped by JS.
static Napi::Value CtxRoundRect(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  double x = info[1].As<Napi::Number>().DoubleValue();
  double y = info[2].As<Napi::Number>().DoubleValue();
  double w = info[3].As<Napi::Number>().DoubleValue();
  double h = info[4].As<Napi::Number>().DoubleValue();
  double tl = info[5].As<Napi::Number>().DoubleValue();
  double tr = info[6].As<Napi::Number>().DoubleValue();
  double br = info[7].As<Napi::Number>().DoubleValue();
  double bl = info[8].As<Napi::Number>().DoubleValue();
  CGMutablePathRef p = CGPathCreateMutable();
  CGPathMoveToPoint(p, NULL, x + tl, y);
  CGPathAddLineToPoint(p, NULL, x + w - tr, y);
  CGPathAddArcToPoint(p, NULL, x + w, y, x + w, y + tr, tr);
  CGPathAddLineToPoint(p, NULL, x + w, y + h - br);
  CGPathAddArcToPoint(p, NULL, x + w, y + h, x + w - br, y + h, br);
  CGPathAddLineToPoint(p, NULL, x + bl, y + h);
  CGPathAddArcToPoint(p, NULL, x, y + h, x, y + h - bl, bl);
  CGPathAddLineToPoint(p, NULL, x, y + tl);
  CGPathAddArcToPoint(p, NULL, x, y, x + tl, y, tl);
  CGPathCloseSubpath(p);
  CGContextAddPath(s->ctx, p);
  CGPathRelease(p);
  return info.Env().Undefined();
}
static Napi::Value CtxArc(const Napi::CallbackInfo& info) {
  // arc(surface, x, y, r, a0, a1, anticlockwise). The base CTM is y-flipped,
  // so CG's notion of clockwise inverts: pass the flag through directly and
  // the on-screen result matches canvas.
  CGContextAddArc(SurfaceFrom(info[0])->ctx,
                  info[1].As<Napi::Number>().DoubleValue(),
                  info[2].As<Napi::Number>().DoubleValue(),
                  info[3].As<Napi::Number>().DoubleValue(),
                  info[4].As<Napi::Number>().DoubleValue(),
                  info[5].As<Napi::Number>().DoubleValue(),
                  info[6].ToBoolean().Value() ? 0 : 1);
  return info.Env().Undefined();
}
static Napi::Value CtxEllipse(const Napi::CallbackInfo& info) {
  CGContextAddEllipseInRect(
      SurfaceFrom(info[0])->ctx,
      CGRectMake(info[1].As<Napi::Number>().DoubleValue() -
                     info[3].As<Napi::Number>().DoubleValue(),
                 info[2].As<Napi::Number>().DoubleValue() -
                     info[4].As<Napi::Number>().DoubleValue(),
                 info[3].As<Napi::Number>().DoubleValue() * 2,
                 info[4].As<Napi::Number>().DoubleValue() * 2));
  return info.Env().Undefined();
}
static Napi::Value CtxCurveTo(const Napi::CallbackInfo& info) {
  CGContextAddCurveToPoint(SurfaceFrom(info[0])->ctx,
                           info[1].As<Napi::Number>().DoubleValue(),
                           info[2].As<Napi::Number>().DoubleValue(),
                           info[3].As<Napi::Number>().DoubleValue(),
                           info[4].As<Napi::Number>().DoubleValue(),
                           info[5].As<Napi::Number>().DoubleValue(),
                           info[6].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxQuadTo(const Napi::CallbackInfo& info) {
  CGContextAddQuadCurveToPoint(SurfaceFrom(info[0])->ctx,
                               info[1].As<Napi::Number>().DoubleValue(),
                               info[2].As<Napi::Number>().DoubleValue(),
                               info[3].As<Napi::Number>().DoubleValue(),
                               info[4].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxClosePath(const Napi::CallbackInfo& info) {
  CGContextClosePath(SurfaceFrom(info[0])->ctx);
  return info.Env().Undefined();
}

static Napi::Value CtxSetFillColor(const Napi::CallbackInfo& info) {
  CGContextSetRGBFillColor(SurfaceFrom(info[0])->ctx,
                           info[1].As<Napi::Number>().DoubleValue(),
                           info[2].As<Napi::Number>().DoubleValue(),
                           info[3].As<Napi::Number>().DoubleValue(),
                           info[4].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxSetStrokeColor(const Napi::CallbackInfo& info) {
  CGContextSetRGBStrokeColor(SurfaceFrom(info[0])->ctx,
                             info[1].As<Napi::Number>().DoubleValue(),
                             info[2].As<Napi::Number>().DoubleValue(),
                             info[3].As<Napi::Number>().DoubleValue(),
                             info[4].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxSetLineWidth(const Napi::CallbackInfo& info) {
  CGContextSetLineWidth(SurfaceFrom(info[0])->ctx,
                        info[1].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxSetGlobalAlpha(const Napi::CallbackInfo& info) {
  CGContextSetAlpha(SurfaceFrom(info[0])->ctx,
                    info[1].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxSetLineCap(const Napi::CallbackInfo& info) {
  std::string cap = info[1].As<Napi::String>().Utf8Value();
  CGContextSetLineCap(SurfaceFrom(info[0])->ctx,
                      cap == "round"    ? kCGLineCapRound
                      : cap == "square" ? kCGLineCapSquare
                                        : kCGLineCapButt);
  return info.Env().Undefined();
}
static Napi::Value CtxSetLineJoin(const Napi::CallbackInfo& info) {
  std::string join = info[1].As<Napi::String>().Utf8Value();
  CGContextSetLineJoin(SurfaceFrom(info[0])->ctx,
                       join == "round"   ? kCGLineJoinRound
                       : join == "bevel" ? kCGLineJoinBevel
                                         : kCGLineJoinMiter);
  return info.Env().Undefined();
}
static Napi::Value CtxSetLineDash(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  Napi::Array a = info[1].As<Napi::Array>();
  double offset =
      info.Length() > 2 ? info[2].As<Napi::Number>().DoubleValue() : 0;
  std::vector<CGFloat> lengths;
  for (uint32_t i = 0; i < a.Length(); i++)
    lengths.push_back(a.Get(i).As<Napi::Number>().DoubleValue());
  CGContextSetLineDash(s->ctx, offset, lengths.empty() ? NULL : lengths.data(),
                       lengths.size());
  return info.Env().Undefined();
}

// Canvas keeps the path across fill/stroke/clip; CG consumes it. Copy before,
// re-add after — the CTM is unchanged in between, so the round trip is exact.
static void KeepPathAround(CGContextRef ctx, void (^op)(void)) {
  CGPathRef kept = CGContextCopyPath(ctx);
  op();
  if (kept) {
    CGContextAddPath(ctx, kept);
    CGPathRelease(kept);
  }
}

static Napi::Value CtxFill(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  bool evenOdd = info.Length() > 1 && info[1].ToBoolean().Value();
  KeepPathAround(s->ctx, ^{
    if (evenOdd) CGContextEOFillPath(s->ctx);
    else CGContextFillPath(s->ctx);
  });
  return info.Env().Undefined();
}
static Napi::Value CtxStroke(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  KeepPathAround(s->ctx, ^{ CGContextStrokePath(s->ctx); });
  return info.Env().Undefined();
}
static Napi::Value CtxClip(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  KeepPathAround(s->ctx, ^{ CGContextClip(s->ctx); });
  return info.Env().Undefined();
}

static Napi::Value CtxFillRect(const Napi::CallbackInfo& info) {
  CGContextFillRect(SurfaceFrom(info[0])->ctx,
                    CGRectMake(info[1].As<Napi::Number>().DoubleValue(),
                               info[2].As<Napi::Number>().DoubleValue(),
                               info[3].As<Napi::Number>().DoubleValue(),
                               info[4].As<Napi::Number>().DoubleValue()));
  return info.Env().Undefined();
}
static Napi::Value CtxStrokeRect(const Napi::CallbackInfo& info) {
  CGContextStrokeRect(SurfaceFrom(info[0])->ctx,
                      CGRectMake(info[1].As<Napi::Number>().DoubleValue(),
                                 info[2].As<Napi::Number>().DoubleValue(),
                                 info[3].As<Napi::Number>().DoubleValue(),
                                 info[4].As<Napi::Number>().DoubleValue()));
  return info.Env().Undefined();
}
static Napi::Value CtxClearRect(const Napi::CallbackInfo& info) {
  CGContextClearRect(SurfaceFrom(info[0])->ctx,
                     CGRectMake(info[1].As<Napi::Number>().DoubleValue(),
                                info[2].As<Napi::Number>().DoubleValue(),
                                info[3].As<Napi::Number>().DoubleValue(),
                                info[4].As<Napi::Number>().DoubleValue()));
  return info.Env().Undefined();
}
// fillRects(surface, flat [x,y,w,h,...]) — one call for a batch of fills.
static Napi::Value CtxFillRects(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  Napi::Array a = info[1].As<Napi::Array>();
  std::vector<CGRect> rects;
  for (uint32_t i = 0; i + 3 < a.Length(); i += 4) {
    rects.push_back(CGRectMake(a.Get(i).As<Napi::Number>().DoubleValue(),
                               a.Get(i + 1).As<Napi::Number>().DoubleValue(),
                               a.Get(i + 2).As<Napi::Number>().DoubleValue(),
                               a.Get(i + 3).As<Napi::Number>().DoubleValue()));
  }
  if (!rects.empty()) CGContextFillRects(s->ctx, rects.data(), rects.size());
  return info.Env().Undefined();
}

// fillLinearGradient(surface, x0, y0, x1, y1, stops [offset,r,g,b,a,...],
//                    mode: 0 = fill current path, 1 = fill rect args follow)
static Napi::Value CtxFillLinearGradient(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  double x0 = info[1].As<Napi::Number>().DoubleValue();
  double y0 = info[2].As<Napi::Number>().DoubleValue();
  double x1 = info[3].As<Napi::Number>().DoubleValue();
  double y1 = info[4].As<Napi::Number>().DoubleValue();
  Napi::Array stopsArr = info[5].As<Napi::Array>();
  std::vector<CGFloat> locs;
  std::vector<CGFloat> comps;
  for (uint32_t i = 0; i + 4 < stopsArr.Length(); i += 5) {
    locs.push_back(stopsArr.Get(i).As<Napi::Number>().DoubleValue());
    comps.push_back(stopsArr.Get(i + 1).As<Napi::Number>().DoubleValue());
    comps.push_back(stopsArr.Get(i + 2).As<Napi::Number>().DoubleValue());
    comps.push_back(stopsArr.Get(i + 3).As<Napi::Number>().DoubleValue());
    comps.push_back(stopsArr.Get(i + 4).As<Napi::Number>().DoubleValue());
  }
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGGradientRef grad = CGGradientCreateWithColorComponents(
      cs, comps.data(), locs.data(), locs.size());
  CGColorSpaceRelease(cs);
  CGContextSaveGState(s->ctx);
  if (info.Length() > 6 && info[6].IsNumber()) {
    // clip to the given rect (fillRect with a gradient fillStyle)
    CGContextClipToRect(s->ctx,
                        CGRectMake(info[6].As<Napi::Number>().DoubleValue(),
                                   info[7].As<Napi::Number>().DoubleValue(),
                                   info[8].As<Napi::Number>().DoubleValue(),
                                   info[9].As<Napi::Number>().DoubleValue()));
  } else {
    KeepPathAround(s->ctx, ^{ CGContextClip(s->ctx); });
  }
  CGContextDrawLinearGradient(
      s->ctx, grad, CGPointMake(x0, y0), CGPointMake(x1, y1),
      kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
  CGContextRestoreGState(s->ctx);
  CGGradientRelease(grad);
  return info.Env().Undefined();
}

// drawSurface(dst, src, sx, sy, sw, sh, dx, dy, dw, dh)
static Napi::Value CtxDrawSurface(const Napi::CallbackInfo& info) {
  CALSurface* dst = SurfaceFrom(info[0]);
  CALSurface* src = SurfaceFrom(info[1]);
  double sx = info[2].As<Napi::Number>().DoubleValue();
  double sy = info[3].As<Napi::Number>().DoubleValue();
  double sw = info[4].As<Napi::Number>().DoubleValue();
  double sh = info[5].As<Napi::Number>().DoubleValue();
  double dx = info[6].As<Napi::Number>().DoubleValue();
  double dy = info[7].As<Napi::Number>().DoubleValue();
  double dw = info[8].As<Napi::Number>().DoubleValue();
  double dh = info[9].As<Napi::Number>().DoubleValue();
  CGImageRef whole = CGBitmapContextCreateImage(src->ctx);
  if (!whole) return info.Env().Undefined();
  CGImageRef part = whole;
  bool cropped = false;
  if (sx != 0 || sy != 0 || sw != (double)src->width ||
      sh != (double)src->height) {
    part = CGImageCreateWithImageInRect(whole, CGRectMake(sx, sy, sw, sh));
    cropped = true;
  }
  if (part) {
    // the base CTM is flipped; flip back around the destination rect so the
    // image lands upright
    CGContextSaveGState(dst->ctx);
    CGContextTranslateCTM(dst->ctx, dx, dy + dh);
    CGContextScaleCTM(dst->ctx, 1, -1);
    CGContextDrawImage(dst->ctx, CGRectMake(0, 0, dw, dh), part);
    CGContextRestoreGState(dst->ctx);
  }
  if (cropped && part) CGImageRelease(part);
  CGImageRelease(whole);
  return info.Env().Undefined();
}

// putImageData(surface, buffer RGBA straight, w, h, dx, dy) — writes pixels
// directly, transform- and clip-free, per the canvas contract.
static Napi::Value CtxPutImageData(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  Napi::Buffer<uint8_t> buf = info[1].As<Napi::Buffer<uint8_t>>();
  long w = info[2].As<Napi::Number>().Int64Value();
  long h = info[3].As<Napi::Number>().Int64Value();
  long dx = info[4].As<Napi::Number>().Int64Value();
  long dy = info[5].As<Napi::Number>().Int64Value();
  uint8_t* dst = (uint8_t*)CGBitmapContextGetData(s->ctx);
  size_t stride = CGBitmapContextGetBytesPerRow(s->ctx);
  if (!dst) return info.Env().Undefined();
  const uint8_t* src = buf.Data();
  for (long row = 0; row < h; row++) {
    long ty = dy + row;
    if (ty < 0 || ty >= (long)s->height) continue;
    for (long col = 0; col < w; col++) {
      long tx = dx + col;
      if (tx < 0 || tx >= (long)s->width) continue;
      const uint8_t* p = src + (row * w + col) * 4;
      uint8_t r = p[0], g = p[1], b = p[2], a = p[3];
      // premultiply, stored little-endian BGRA (ByteOrder32Host + AlphaFirst)
      uint8_t* q = dst + ty * stride + tx * 4;
      q[0] = (uint8_t)((b * a + 127) / 255);
      q[1] = (uint8_t)((g * a + 127) / 255);
      q[2] = (uint8_t)((r * a + 127) / 255);
      q[3] = a;
    }
  }
  return info.Env().Undefined();
}

// getImageData(surface, x, y, w, h) -> Buffer RGBA straight
static Napi::Value CtxGetImageData(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALSurface* s = SurfaceFrom(info[0]);
  long x = info[1].As<Napi::Number>().Int64Value();
  long y = info[2].As<Napi::Number>().Int64Value();
  long w = info[3].As<Napi::Number>().Int64Value();
  long h = info[4].As<Napi::Number>().Int64Value();
  Napi::Buffer<uint8_t> out = Napi::Buffer<uint8_t>::New(env, (size_t)(w * h * 4));
  uint8_t* dst = out.Data();
  const uint8_t* srcBase = (const uint8_t*)CGBitmapContextGetData(s->ctx);
  size_t stride = CGBitmapContextGetBytesPerRow(s->ctx);
  for (long row = 0; row < h; row++) {
    long sy = y + row;
    for (long col = 0; col < w; col++) {
      long sx = x + col;
      uint8_t* q = dst + (row * w + col) * 4;
      if (!srcBase || sx < 0 || sy < 0 || sx >= (long)s->width ||
          sy >= (long)s->height) {
        q[0] = q[1] = q[2] = q[3] = 0;
        continue;
      }
      const uint8_t* p = srcBase + sy * stride + sx * 4;
      uint8_t b = p[0], g = p[1], r = p[2], a = p[3];
      if (a == 0) {
        q[0] = q[1] = q[2] = q[3] = 0;
      } else {
        q[0] = (uint8_t)std::min(255l, (long)r * 255 / a);
        q[1] = (uint8_t)std::min(255l, (long)g * 255 / a);
        q[2] = (uint8_t)std::min(255l, (long)b * 255 / a);
        q[3] = a;
      }
    }
  }
  return out;
}

// surfaceToLayer(surface, layer) — hand the bitmap to a layer as contents.
// CGBitmapContextCreateImage is copy-on-write, so this is cheap per frame.
static Napi::Value SurfaceToLayer(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  CALayer* L = BDeref<CALayer*>(info[1]);
  CGImageRef img = CGBitmapContextCreateImage(s->ctx);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  L.contents = (__bridge id)img;
  L.contentsScale = s->scale;
  [CATransaction commit];
  CGImageRelease(img);
  return info.Env().Undefined();
}

// scrollSurface(surface, x, y, w, h, dx, dy) — scroll the pixels WITHIN
// the rect by (dx, dy), ntk Window.scrollRegion's exact contract: the
// destination band is rect ∩ (rect + delta), so nothing is ever written
// outside the rect (an upward scroll used to stamp the moved band over
// whatever sat above the viewport). Returns whether anything moved.
static Napi::Value ScrollSurface(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  long x = info[1].As<Napi::Number>().Int64Value();
  long y = info[2].As<Napi::Number>().Int64Value();
  long w = info[3].As<Napi::Number>().Int64Value();
  long h = info[4].As<Napi::Number>().Int64Value();
  long dx = info[5].As<Napi::Number>().Int64Value();
  long dy = info[6].As<Napi::Number>().Int64Value();
  uint8_t* base = (uint8_t*)CGBitmapContextGetData(s->ctx);
  size_t stride = CGBitmapContextGetBytesPerRow(s->ctx);
  if (!base || (dx == 0 && dy == 0))
    return Napi::Boolean::New(info.Env(), false);
  auto clampL = [](long v, long lo, long hi) {
    return v < lo ? lo : v > hi ? hi : v;
  };
  long sw = (long)s->width, sh = (long)s->height;
  long x0 = clampL(x, 0, sw), y0 = clampL(y, 0, sh);
  long x1 = clampL(x + w, 0, sw), y1 = clampL(y + h, 0, sh);
  // the band that survives: dest = clamped rect ∩ (clamped rect + delta)
  long dstX0 = std::max(x0, x0 + dx);
  long dstY0 = std::max(y0, y0 + dy);
  long dstX1 = std::min(x1, x1 + dx);
  long dstY1 = std::min(y1, y1 + dy);
  if (dstX1 <= dstX0 || dstY1 <= dstY0)
    return Napi::Boolean::New(info.Env(), false);
  long copyW = dstX1 - dstX0;
  if (dy <= 0) {
    for (long ty = dstY0; ty < dstY1; ty++) {
      memmove(base + ty * stride + dstX0 * 4,
              base + (ty - dy) * stride + (dstX0 - dx) * 4,
              (size_t)copyW * 4);
    }
  } else {
    for (long ty = dstY1 - 1; ty >= dstY0; ty--) {
      memmove(base + ty * stride + dstX0 * 4,
              base + (ty - dy) * stride + (dstX0 - dx) * 4,
              (size_t)copyW * 4);
    }
  }
  return Napi::Boolean::New(info.Env(), true);
}

// ---------------------------------------------------------------------------
// fonts + text layout (CoreText)
// ---------------------------------------------------------------------------

// matchFont({ families: [..], size, weight (100-900), italic }) -> font handle
static NSFont* ResolveFamily(NSString* family, double size, double weight,
                             bool italic) {
  NSFontWeight w = NSFontWeightRegular;
  if (weight <= 150) w = NSFontWeightUltraLight;
  else if (weight <= 250) w = NSFontWeightThin;
  else if (weight <= 350) w = NSFontWeightLight;
  else if (weight <= 450) w = NSFontWeightRegular;
  else if (weight <= 550) w = NSFontWeightMedium;
  else if (weight <= 650) w = NSFontWeightSemibold;
  else if (weight <= 750) w = NSFontWeightBold;
  else if (weight <= 850) w = NSFontWeightHeavy;
  else w = NSFontWeightBlack;

  NSFont* font = nil;
  NSString* lower = family.lowercaseString;
  if ([lower isEqualToString:@"sans-serif"] ||
      [lower isEqualToString:@"system-ui"] || [lower isEqualToString:@"ui-sans-serif"]) {
    font = [NSFont systemFontOfSize:size weight:w];
  } else if ([lower isEqualToString:@"monospace"] ||
             [lower isEqualToString:@"ui-monospace"]) {
    if (@available(macOS 10.15, *)) {
      font = [NSFont monospacedSystemFontOfSize:size weight:w];
    } else {
      font = [NSFont fontWithName:@"Menlo" size:size];
    }
  } else if ([lower isEqualToString:@"serif"]) {
    font = [NSFont fontWithName:@"Times New Roman" size:size];
  } else if ([lower isEqualToString:@"cursive"]) {
    font = [NSFont fontWithName:@"Snell Roundhand" size:size];
  } else {
    // A named family. Build a descriptor so weight/width participate in
    // matching; verify the match really is this family (CoreText silently
    // falls back to Helvetica otherwise, which must read as "not found"
    // so the next family in the list gets its turn).
    NSMutableDictionary* traits = [NSMutableDictionary dictionary];
    traits[NSFontWeightTrait] = @(w);
    if (italic) traits[NSFontSlantTrait] = @(0.2);
    NSFontDescriptor* d = [NSFontDescriptor fontDescriptorWithFontAttributes:@{
      NSFontFamilyAttribute : family,
      NSFontTraitsAttribute : traits,
    }];
    font = [NSFont fontWithDescriptor:d size:size];
    if (font && ![font.familyName isEqualToString:family] &&
        ![font.familyName.lowercaseString isEqualToString:lower]) {
      // try by PostScript / display name before giving up
      NSFont* byName = [NSFont fontWithName:family size:size];
      font = byName &&
                     ([byName.familyName.lowercaseString isEqualToString:lower] ||
                      [byName.fontName.lowercaseString isEqualToString:lower])
                 ? byName
                 : nil;
    }
    if (font && weight >= 550) {
      NSFont* bolder = [[NSFontManager sharedFontManager]
          convertFont:font
          toHaveTrait:NSBoldFontMask];
      if (bolder) font = bolder;
    }
  }
  if (font && italic) {
    NSFont* it = [[NSFontManager sharedFontManager] convertFont:font
                                                    toHaveTrait:NSItalicFontMask];
    if (it) font = it;
  }
  return font;
}

static Napi::Value MatchFont(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Object o = info[0].As<Napi::Object>();
  double size = BNumOr(o, "size", 14);
  double weight = BNumOr(o, "weight", 400);
  bool italic = BBoolOr(o, "italic", false);
  NSFont* font = nil;
  if (o.Has("families") && o.Get("families").IsArray()) {
    Napi::Array fams = o.Get("families").As<Napi::Array>();
    for (uint32_t i = 0; i < fams.Length() && !font; i++) {
      if (!fams.Get(i).IsString()) continue;
      font = ResolveFamily(BToNSString(fams.Get(i)), size, weight, italic);
    }
  }
  if (!font) {
    NSFontWeight w = weight >= 550 ? NSFontWeightSemibold : NSFontWeightRegular;
    font = [NSFont systemFontOfSize:size weight:w];
  }
  return BWrapRetained(env, font);
}

static Napi::Value FontMetrics(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSFont* font = BDeref<NSFont*>(info[0]);
  CTFontRef ct = (__bridge CTFontRef)font;
  Napi::Object r = Napi::Object::New(env);
  r.Set("ascent", CTFontGetAscent(ct));
  r.Set("descent", CTFontGetDescent(ct));
  r.Set("leading", CTFontGetLeading(ct));
  r.Set("capHeight", CTFontGetCapHeight(ct));
  r.Set("xHeight", CTFontGetXHeight(ct));
  r.Set("size", CTFontGetSize(ct));
  r.Set("familyName", font.familyName ? font.familyName.UTF8String : "");
  r.Set("postScriptName", font.fontName.UTF8String);
  return r;
}

static Napi::Value FontHasGlyph(const Napi::CallbackInfo& info) {
  NSFont* font = BDeref<NSFont*>(info[0]);
  std::string ch = info[1].As<Napi::String>().Utf8Value();
  NSString* s = [NSString stringWithUTF8String:ch.c_str()];
  if (s.length == 0) return Napi::Boolean::New(info.Env(), false);
  unichar buf[2];
  NSUInteger len = std::min((NSUInteger)2, s.length);
  [s getCharacters:buf range:NSMakeRange(0, len)];
  CGGlyph glyphs[2];
  bool ok = CTFontGetGlyphsForCharacters((__bridge CTFontRef)font, buf, glyphs,
                                         (CFIndex)len);
  return Napi::Boolean::New(info.Env(), ok);
}

// --- direct font handles (custom faces that bypass registry matching) -----

static double CssWeightOfCTFont(CTFontRef ct) {
  double weight = 400;
  CFDictionaryRef traits = CTFontCopyTraits(ct);
  if (traits) {
    CFNumberRef w =
        (CFNumberRef)CFDictionaryGetValue(traits, kCTFontWeightTrait);
    if (w) {
      double t = 0;
      CFNumberGetValue(w, kCFNumberDoubleType, &t);
      // AppKit's weight trait scale, approximately, back to CSS steps
      weight = t <= -0.5   ? 200
               : t <= -0.25 ? 300
               : t < 0.1    ? 400
               : t < 0.27   ? 500
               : t < 0.35   ? 600
               : t < 0.5    ? 700
               : t < 0.62   ? 800
                            : 900;
    }
    CFRelease(traits);
  }
  return weight;
}

// fontFromData(buffer) -> { cg: External<CGFont>, familyName,
// postScriptName, weight, italic }. The CGFont is the process's own handle
// to the face — no registry round trip, so a face CoreText refuses to
// register (in-memory data) still renders. Registration is attempted as a
// best effort so descriptor matching elsewhere can also find it.
static Napi::Value FontFromData(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Buffer<uint8_t> buf = info[0].As<Napi::Buffer<uint8_t>>();
  CFDataRef data = CFDataCreate(NULL, buf.Data(), (CFIndex)buf.Length());
  CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
  CFRelease(data);
  CGFontRef cg = provider ? CGFontCreateWithDataProvider(provider) : NULL;
  if (provider) CGDataProviderRelease(provider);
  if (!cg) return env.Null();
  CTFontManagerRegisterGraphicsFont(cg, NULL);  // best effort
  CTFontRef ct = CTFontCreateWithGraphicsFont(cg, 12, NULL, NULL);
  Napi::Object r = Napi::Object::New(env);
  r.Set("cg", Napi::External<void>::New(env, (void*)cg, [](Napi::Env, void* d) {
          CGFontRelease((CGFontRef)d);
        }));
  CFStringRef fam = CTFontCopyFamilyName(ct);
  CFStringRef ps = CTFontCopyPostScriptName(ct);
  if (fam) {
    r.Set("familyName", [(__bridge NSString*)fam UTF8String]);
    CFRelease(fam);
  }
  if (ps) {
    r.Set("postScriptName", [(__bridge NSString*)ps UTF8String]);
    CFRelease(ps);
  }
  r.Set("weight", CssWeightOfCTFont(ct));
  r.Set("italic",
        (bool)(CTFontGetSymbolicTraits(ct) & kCTFontTraitItalic));
  CFRelease(ct);
  return r;
}

// cgFontWithSize(cgExternal, size) -> CTFont handle (what layouts take)
static Napi::Value CgFontWithSize(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CGFontRef cg = (CGFontRef)info[0].As<Napi::External<void>>().Data();
  double size = info[1].As<Napi::Number>().DoubleValue();
  CTFontRef ct = CTFontCreateWithGraphicsFont(cg, size, NULL, NULL);
  if (!ct) return env.Null();
  return Napi::External<void>::New(env, (void*)ct, [](Napi::Env, void* d) {
    CFRelease(d);
  });
}

// fontByPostScriptName(name, size) -> CTFont handle or null. Exact: a
// fallback answer (a substituted face) reads as null so the caller can try
// the next route.
static Napi::Value FontByPostScriptName(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSString* name = BToNSString(info[0]);
  double size = info[1].As<Napi::Number>().DoubleValue();
  CTFontRef ct =
      CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
  if (!ct) return env.Null();
  CFStringRef got = CTFontCopyPostScriptName(ct);
  bool exact = got && [(__bridge NSString*)got isEqualToString:name];
  if (got) CFRelease(got);
  if (!exact) {
    CFRelease(ct);
    return env.Null();
  }
  return Napi::External<void>::New(env, (void*)ct, [](Napi::Env, void* d) {
    CFRelease(d);
  });
}

// fontApplyVariations(ctExternal, { wght: 600, opsz: 28, ... }) -> CTFont
static Napi::Value FontApplyVariations(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CTFontRef base = (CTFontRef)info[0].As<Napi::External<void>>().Data();
  Napi::Object vars = info[1].As<Napi::Object>();
  Napi::Array names = vars.GetPropertyNames();
  NSMutableDictionary* axes = [NSMutableDictionary dictionary];
  for (uint32_t i = 0; i < names.Length(); i++) {
    std::string tag = names.Get(i).As<Napi::String>().Utf8Value();
    if (tag.size() != 4) continue;
    Napi::Value v = vars.Get(tag.c_str());
    if (!v.IsNumber()) continue;
    uint32_t code = ((uint32_t)tag[0] << 24) | ((uint32_t)tag[1] << 16) |
                    ((uint32_t)tag[2] << 8) | (uint32_t)tag[3];
    axes[@(code)] = @(v.As<Napi::Number>().DoubleValue());
  }
  if (axes.count == 0) return info[0];
  CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(
      (__bridge CFDictionaryRef)
          @{(__bridge id)kCTFontVariationAttribute : axes});
  CTFontRef ct =
      CTFontCreateCopyWithAttributes(base, CTFontGetSize(base), NULL, d);
  CFRelease(d);
  if (!ct) return info[0];
  return Napi::External<void>::New(env, (void*)ct, [](Napi::Env, void* d2) {
    CFRelease(d2);
  });
}

// listFonts({ family? , limit? }) -> [{ postScriptName, familyName,
// styleName, path }]. With a family: that family's faces, in CoreText's
// matching order. Without: every installed face (bounded by limit).
static Napi::Value ListFonts(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Object o = info.Length() > 0 && info[0].IsObject()
                       ? info[0].As<Napi::Object>()
                       : Napi::Object::New(env);
  long limit = (long)BNumOr(o, "limit", 400);
  NSString* family = o.Has("family") && o.Get("family").IsString()
                         ? BToNSString(o.Get("family"))
                         : nil;
  CFArrayRef matches = NULL;
  if (family && family.length > 0) {
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(
        (__bridge CFDictionaryRef)
            @{(__bridge id)kCTFontFamilyNameAttribute : family});
    matches = CTFontDescriptorCreateMatchingFontDescriptors(d, NULL);
    CFRelease(d);
  } else {
    CTFontCollectionRef all = CTFontCollectionCreateFromAvailableFonts(NULL);
    matches = CTFontCollectionCreateMatchingFontDescriptors(all);
    CFRelease(all);
  }
  Napi::Array out = Napi::Array::New(env);
  if (!matches) return out;
  CFIndex count = CFArrayGetCount(matches);
  uint32_t written = 0;
  for (CFIndex i = 0; i < count && written < (uint32_t)limit; i++) {
    CTFontDescriptorRef d =
        (CTFontDescriptorRef)CFArrayGetValueAtIndex(matches, i);
    Napi::Object row = Napi::Object::New(env);
    CFStringRef ps = (CFStringRef)CTFontDescriptorCopyAttribute(
        d, kCTFontNameAttribute);
    CFStringRef fam = (CFStringRef)CTFontDescriptorCopyAttribute(
        d, kCTFontFamilyNameAttribute);
    CFStringRef styleName = (CFStringRef)CTFontDescriptorCopyAttribute(
        d, kCTFontStyleNameAttribute);
    CFURLRef url =
        (CFURLRef)CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute);
    if (ps) row.Set("postScriptName", [(__bridge NSString*)ps UTF8String]);
    if (fam) row.Set("familyName", [(__bridge NSString*)fam UTF8String]);
    if (styleName) row.Set("styleName", [(__bridge NSString*)styleName UTF8String]);
    if (url) {
      NSString* path = ((__bridge NSURL*)url).path;
      if (path) row.Set("path", path.UTF8String);
    }
    if (ps) CFRelease(ps);
    if (fam) CFRelease(fam);
    if (styleName) CFRelease(styleName);
    if (url) CFRelease(url);
    out.Set(written++, row);
  }
  CFRelease(matches);
  return out;
}

// loadFontData(buffer) -> registers the font with CoreText, returns the
// PostScript name (for app-supplied font files — react-x11's loadFont()).
static Napi::Value LoadFontData(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Buffer<uint8_t> buf = info[0].As<Napi::Buffer<uint8_t>>();
  CFDataRef data = CFDataCreate(NULL, buf.Data(), (CFIndex)buf.Length());
  CTFontDescriptorRef desc = CTFontManagerCreateFontDescriptorFromData(data);
  CFRelease(data);
  if (!desc) return env.Null();
  CFErrorRef err = NULL;
  CTFontManagerRegisterFontDescriptors((__bridge CFArrayRef)@[ (__bridge id)desc ],
                                       kCTFontManagerScopeProcess, YES, NULL);
  (void)err;
  CTFontRef font = CTFontCreateWithFontDescriptor(desc, 12, NULL);
  CFRelease(desc);
  if (!font) return env.Null();
  CFStringRef ps = CTFontCopyPostScriptName(font);
  CFStringRef fam = CTFontCopyFamilyName(font);
  CFRelease(font);
  Napi::Object r = Napi::Object::New(env);
  r.Set("postScriptName", [( __bridge NSString*)ps UTF8String]);
  r.Set("familyName", [( __bridge NSString*)fam UTF8String]);
  CFRelease(ps);
  CFRelease(fam);
  return r;
}

// --- the layout object -----------------------------------------------------

struct CALRun {
  double x = 0, width = 0;
  long start = 0, end = 0;  // UTF-16 units
  bool rtl = false;
};

struct CALLine {
  CTLineRef line = nullptr;
  double x = 0, y = 0, width = 0, height = 0, baseline = 0, ascent = 0,
         descent = 0;
  long start = 0, end = 0;  // UTF-16 units
  bool hardBreak = false;   // the line ends with a newline it owns
  std::vector<CALRun> runs;
};

struct CALLayout {
  std::vector<CALLine> lines;
  double width = 0, height = 0;
  ~CALLayout() {
    for (auto& l : lines)
      if (l.line) CFRelease(l.line);
  }
};

static CALLayout* LayoutFrom(Napi::Value v) {
  return (CALLayout*)v.As<Napi::External<void>>().Data();
}

// createLayout({ spans: [{text, font (handle), color:[r,g,b,a]}],
//                maxWidth?, align: 0 left | 0.5 center | 1 right,
//                lineHeight?, maxLines?, ellipsis?, rtl? })
// -> { handle, width, height,
//      lines: [{x,y,width,height,baseline,descent,start,end,
//               runs:[{x,width,start,end,rtl}]}] }
static Napi::Value CreateLayout(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Object o = info[0].As<Napi::Object>();
  double maxWidth = BNumOr(o, "maxWidth", 0);
  bool bounded = maxWidth > 0 && std::isfinite(maxWidth);
  double flush = BNumOr(o, "align", 0);
  double lineHeight = BNumOr(o, "lineHeight", 0);
  long maxLines = (long)BNumOr(o, "maxLines", 0);
  bool ellipsis = BBoolOr(o, "ellipsis", false);
  bool rtl = BBoolOr(o, "rtl", false);
  if (ellipsis && maxLines <= 0) maxLines = 1;

  NSMutableAttributedString* as = [[NSMutableAttributedString alloc] init];
  NSDictionary* lastAttrs = nil;
  Napi::Array spans = o.Get("spans").As<Napi::Array>();
  for (uint32_t i = 0; i < spans.Length(); i++) {
    Napi::Object span = spans.Get(i).As<Napi::Object>();
    NSString* text = span.Has("text") && span.Get("text").IsString()
                         ? BToNSString(span.Get("text"))
                         : @"";
    if (text.length == 0) continue;
    NSFont* font = BDeref<NSFont*>(span.Get("font"));
    NSMutableParagraphStyle* para = [[NSMutableParagraphStyle alloc] init];
    para.baseWritingDirection =
        rtl ? NSWritingDirectionRightToLeft : NSWritingDirectionLeftToRight;
    NSMutableDictionary* attrs = [NSMutableDictionary dictionary];
    attrs[(__bridge id)kCTFontAttributeName] = font;
    attrs[NSParagraphStyleAttributeName] = para;
    if (span.Has("color") && span.Get("color").IsArray()) {
      CGColorRef color = BMakeColor(span.Get("color"));
      attrs[(__bridge id)kCTForegroundColorAttributeName] =
          (__bridge id)color;
      CGColorRelease(color);
    } else {
      // no colour on the span: the glyphs take the drawing context's fill,
      // exactly like fillText — the contract layout.draw() has on ntk
      attrs[(__bridge id)kCTForegroundColorFromContextAttributeName] = @YES;
    }
    lastAttrs = attrs;
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:text
                                                               attributes:attrs]];
  }

  auto* layout = new CALLayout();
  long total = (long)as.length;
  if (total > 0) {
    CTTypesetterRef ts =
        CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    double y = 0;
    long start = 0;
    long lineIndex = 0;
    double breakWidth = bounded ? maxWidth : 1e9;
    while (start < total) {
      long count =
          (long)CTTypesetterSuggestLineBreak(ts, start, breakWidth);
      if (count <= 0) count = 1;
      bool lastAllowed = maxLines > 0 && lineIndex == maxLines - 1;
      bool more = start + count < total;
      CTLineRef line = nullptr;
      long lineEnd = start + count;
      if (lastAllowed && more && ellipsis && lastAttrs) {
        // shape the whole remainder, then truncate it into the width
        CTLineRef whole =
            CTTypesetterCreateLine(ts, CFRangeMake(start, total - start));
        NSAttributedString* tokenStr =
            [[NSAttributedString alloc] initWithString:@"…"
                                            attributes:lastAttrs];
        CTLineRef token = CTLineCreateWithAttributedString(
            (__bridge CFAttributedStringRef)tokenStr);
        line = CTLineCreateTruncatedLine(whole, bounded ? maxWidth : 1e9,
                                         kCTLineTruncationEnd, token);
        if (!line) {
          line = whole;
        } else {
          CFRelease(whole);
        }
        CFRelease(token);
        lineEnd = total;
      } else {
        line = CTTypesetterCreateLine(ts, CFRangeMake(start, count));
      }
      CGFloat ascent = 0, descent = 0, leading = 0;
      double lw = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
      double natural = ascent + descent + leading;
      double advance = natural * (lineHeight > 0 ? lineHeight : 1);
      CALLine L;
      L.line = line;
      L.width = lw;
      L.height = advance;
      L.ascent = ascent;
      L.descent = descent;
      L.y = y;
      L.baseline = y + ascent;
      L.start = start;
      L.end = lineEnd;
      if (lineEnd > start) {
        unichar last = [[as string] characterAtIndex:(NSUInteger)(lineEnd - 1)];
        L.hardBreak =
            last == '\n' || last == '\r' || last == 0x2028 || last == 0x2029;
      }
      if (bounded && flush > 0) {
        L.x = CTLineGetPenOffsetForFlush(line, flush, maxWidth);
      }
      // runs, for selection bands
      CFArrayRef runs = CTLineGetGlyphRuns(line);
      for (CFIndex ri = 0; ri < CFArrayGetCount(runs); ri++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, ri);
        CFRange range = CTRunGetStringRange(run);
        CGFloat rascent, rdescent, rleading;
        double rwidth = CTRunGetTypographicBounds(run, CFRangeMake(0, 0),
                                                  &rascent, &rdescent,
                                                  &rleading);
        double rx = 0;
        if (CTRunGetGlyphCount(run) > 0) {
          const CGPoint* positions = CTRunGetPositionsPtr(run);
          if (positions) {
            rx = positions[0].x;
          } else {
            CGPoint first;
            CTRunGetPositions(run, CFRangeMake(0, 1), &first);
            rx = first.x;
          }
        }
        CALRun R;
        R.x = rx;
        R.width = rwidth;
        R.start = range.location;
        R.end = range.location + range.length;
        R.rtl = (CTRunGetStatus(run) & kCTRunStatusRightToLeft) != 0;
        L.runs.push_back(R);
      }
      layout->lines.push_back(L);
      layout->width = std::max(layout->width, lw);
      y += advance;
      lineIndex++;
      start = lineEnd;
      if (maxLines > 0 && lineIndex >= maxLines) break;
    }
    layout->height = y;
    CFRelease(ts);
  }

  Napi::Object r = Napi::Object::New(env);
  r.Set("handle", Napi::External<void>::New(env, layout, [](Napi::Env, void* d) {
          delete (CALLayout*)d;
        }));
  r.Set("width", layout->width);
  r.Set("height", layout->height);
  Napi::Array lines = Napi::Array::New(env, layout->lines.size());
  for (size_t i = 0; i < layout->lines.size(); i++) {
    const CALLine& L = layout->lines[i];
    Napi::Object lo = Napi::Object::New(env);
    lo.Set("x", L.x);
    lo.Set("y", L.y);
    lo.Set("width", L.width);
    lo.Set("height", L.height);
    lo.Set("baseline", L.baseline);
    lo.Set("ascent", L.ascent);
    lo.Set("descent", L.descent);
    lo.Set("start", (double)L.start);
    lo.Set("end", (double)L.end);
    Napi::Array runs = Napi::Array::New(env, L.runs.size());
    for (size_t j = 0; j < L.runs.size(); j++) {
      const CALRun& R = L.runs[j];
      Napi::Object ro = Napi::Object::New(env);
      ro.Set("x", R.x);
      ro.Set("width", R.width);
      ro.Set("start", (double)R.start);
      ro.Set("end", (double)R.end);
      ro.Set("rtl", R.rtl);
      runs.Set((uint32_t)j, ro);
    }
    lo.Set("runs", runs);
    lines.Set((uint32_t)i, lo);
  }
  r.Set("lines", lines);
  return r;
}

// drawLayout(surface, layoutHandle, x, y) — honours the surface CTM and clip.
static Napi::Value DrawLayout(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  CALLayout* layout = LayoutFrom(info[1]);
  double x = info[2].As<Napi::Number>().DoubleValue();
  double y = info[3].As<Napi::Number>().DoubleValue();
  CGContextRef ctx = s->ctx;
  CGContextSaveGState(ctx);
  // The base CTM is y-flipped for canvas semantics; text needs unflipping
  // per glyph run. Standard recipe: flip the text matrix, position each
  // line at its baseline in the flipped space.
  CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
  for (const CALLine& L : layout->lines) {
    CGContextSetTextPosition(ctx, x + L.x, y + L.baseline);
    CTLineDraw(L.line, ctx);
  }
  CGContextRestoreGState(ctx);
  return info.Env().Undefined();
}

// drawLayoutGradient(surface, layoutHandle, x, y, x0, y0, x1, y1,
//                    stops [offset,r,g,b,a,...])
// The glyph outlines become the clip and a linear gradient fills through
// them — gradient text ink, canvas-style.
static Napi::Value DrawLayoutGradient(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  CALLayout* layout = LayoutFrom(info[1]);
  double x = info[2].As<Napi::Number>().DoubleValue();
  double y = info[3].As<Napi::Number>().DoubleValue();
  double gx0 = info[4].As<Napi::Number>().DoubleValue();
  double gy0 = info[5].As<Napi::Number>().DoubleValue();
  double gx1 = info[6].As<Napi::Number>().DoubleValue();
  double gy1 = info[7].As<Napi::Number>().DoubleValue();
  Napi::Array stopsArr = info[8].As<Napi::Array>();
  std::vector<CGFloat> locs;
  std::vector<CGFloat> comps;
  for (uint32_t i = 0; i + 4 < stopsArr.Length(); i += 5) {
    locs.push_back(stopsArr.Get(i).As<Napi::Number>().DoubleValue());
    for (uint32_t c = 1; c <= 4; c++)
      comps.push_back(stopsArr.Get(i + c).As<Napi::Number>().DoubleValue());
  }
  CGContextRef ctx = s->ctx;
  CGContextSaveGState(ctx);
  // CTLineDraw saves/restores the graphics state internally, so a clip
  // accumulated through kCGTextClip is popped with it — the classic trap.
  // Build the outline path by hand instead: every glyph's path, flipped
  // around its baseline into this surface's y-down space.
  CGMutablePathRef outline = CGPathCreateMutable();
  for (const CALLine& L : layout->lines) {
    CFArrayRef runs = CTLineGetGlyphRuns(L.line);
    for (CFIndex ri = 0; ri < CFArrayGetCount(runs); ri++) {
      CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, ri);
      CFDictionaryRef attrs = CTRunGetAttributes(run);
      CTFontRef font =
          (CTFontRef)CFDictionaryGetValue(attrs, kCTFontAttributeName);
      if (!font) continue;
      CFIndex count = CTRunGetGlyphCount(run);
      std::vector<CGGlyph> glyphs((size_t)count);
      std::vector<CGPoint> positions((size_t)count);
      CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs.data());
      CTRunGetPositions(run, CFRangeMake(0, 0), positions.data());
      for (CFIndex g = 0; g < count; g++) {
        CGAffineTransform t = {1, 0, 0, -1,
                               x + L.x + positions[(size_t)g].x,
                               y + L.baseline - positions[(size_t)g].y};
        CGPathRef gp = CTFontCreatePathForGlyph(font, glyphs[(size_t)g], &t);
        if (gp) {
          CGPathAddPath(outline, NULL, gp);
          CGPathRelease(gp);
        }
      }
    }
  }
  CGContextBeginPath(ctx);
  CGContextAddPath(ctx, outline);
  CGPathRelease(outline);
  CGContextClip(ctx);
  if (!locs.empty()) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef grad = CGGradientCreateWithColorComponents(
        cs, comps.data(), locs.data(), locs.size());
    CGColorSpaceRelease(cs);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(gx0, gy0),
                                CGPointMake(gx1, gy1),
                                kCGGradientDrawsBeforeStartLocation |
                                    kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(grad);
  }
  CGContextRestoreGState(ctx);
  return info.Env().Undefined();
}

// ctxSetShadow(surface, blur, dx, dy, r, g, b, a) — blur <= 0 clears.
static Napi::Value CtxSetShadow(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  double blur = info[1].As<Napi::Number>().DoubleValue();
  if (blur <= 0) {
    CGContextSetShadowWithColor(s->ctx, CGSizeMake(0, 0), 0, NULL);
    return info.Env().Undefined();
  }
  double dx = info[2].As<Napi::Number>().DoubleValue();
  double dy = info[3].As<Napi::Number>().DoubleValue();
  CGColorRef color = CGColorCreateSRGB(
      info[4].As<Napi::Number>().DoubleValue(),
      info[5].As<Napi::Number>().DoubleValue(),
      info[6].As<Napi::Number>().DoubleValue(),
      info[7].As<Napi::Number>().DoubleValue());
  // the base CTM is y-flipped, so a downward canvas offset is a negative
  // CG one
  CGContextSetShadowWithColor(s->ctx, CGSizeMake(dx, -dy), blur, color);
  CGColorRelease(color);
  return info.Env().Undefined();
}

// layoutIndexAt(layoutHandle, x, y) -> UTF-16 index
static Napi::Value LayoutIndexAt(const Napi::CallbackInfo& info) {
  CALLayout* layout = LayoutFrom(info[0]);
  double x = info[1].As<Napi::Number>().DoubleValue();
  double y = info[2].As<Napi::Number>().DoubleValue();
  if (layout->lines.empty()) return Napi::Number::New(info.Env(), 0);
  const CALLine* pick = &layout->lines.back();
  for (const CALLine& L : layout->lines) {
    if (y < L.y + L.height) {
      pick = &L;
      break;
    }
  }
  CFIndex idx =
      CTLineGetStringIndexForPosition(pick->line, CGPointMake(x - pick->x, 0));
  if (idx == kCFNotFound) idx = pick->end;
  // Trailing-newline aware, ntk's contract: a hit at or past the right edge
  // of a hard-wrapped line answers the end of its VISIBLE content. The index
  // after the newline is the next line's start, and a caret sent there has
  // visually not moved — vertical arrow movement then sticks on the
  // boundary instead of climbing.
  if (pick->hardBreak && idx >= pick->end) idx = pick->end - 1;
  return Napi::Number::New(info.Env(), (double)idx);
}

// layoutCaret(layoutHandle, utf16Index) -> { x, y, height, line }
// `line` is the line INDEX — the field ntk's caretPosition contract carries
// and vertical caret movement steps by (lines[pos.line + delta]); without
// it an arrow-down in a textarea indexes lines[NaN].
static Napi::Value LayoutCaret(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALLayout* layout = LayoutFrom(info[0]);
  long idx = info[1].As<Napi::Number>().Int64Value();
  Napi::Object r = Napi::Object::New(env);
  if (layout->lines.empty()) {
    r.Set("x", 0);
    r.Set("y", 0);
    r.Set("height", 0);
    r.Set("line", 0);
    return r;
  }
  size_t li = layout->lines.size() - 1;
  for (size_t i = 0; i < layout->lines.size(); i++) {
    const CALLine& L = layout->lines[i];
    // an index at a line's end belongs to that line, not the next one's start
    if (idx < L.end || (idx == L.end && i == layout->lines.size() - 1)) {
      li = i;
      break;
    }
  }
  const CALLine* pick = &layout->lines[li];
  double x = CTLineGetOffsetForStringIndex(pick->line, idx, NULL);
  r.Set("x", pick->x + x);
  r.Set("y", pick->y);
  r.Set("height", pick->height);
  r.Set("line", (double)li);
  return r;
}

// ---------------------------------------------------------------------------
// pasteboard
// ---------------------------------------------------------------------------

static Napi::Value PbWriteTextFn(const Napi::CallbackInfo& info) {
  NSPasteboard* pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:BToNSString(info[0]) forType:NSPasteboardTypeString];
  return info.Env().Undefined();
}

static Napi::Value PbReadTextFn(const Napi::CallbackInfo& info) {
  NSString* s =
      [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  return s ? Napi::Value(Napi::String::New(info.Env(), s.UTF8String))
           : Napi::Value(info.Env().Null());
}

static Napi::Value PbClearFn(const Napi::CallbackInfo& info) {
  [NSPasteboard.generalPasteboard clearContents];
  return info.Env().Undefined();
}

static Napi::Value PbChangeCountFn(const Napi::CallbackInfo& info) {
  return Napi::Number::New(info.Env(),
                           (double)NSPasteboard.generalPasteboard.changeCount);
}

// ---------------------------------------------------------------------------
// screens + cursors + appearance
// ---------------------------------------------------------------------------

static Napi::Value ListScreens(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  BEnsureApp();
  CGFloat top = PrimaryScreenTop();
  NSArray<NSScreen*>* screens = NSScreen.screens;
  Napi::Array out = Napi::Array::New(env, screens.count);
  for (NSUInteger i = 0; i < screens.count; i++) {
    NSScreen* s = screens[i];
    Napi::Object o = Napi::Object::New(env);
    NSRect f = s.frame, v = s.visibleFrame;
    o.Set("x", f.origin.x);
    o.Set("y", top - (f.origin.y + f.size.height));
    o.Set("width", f.size.width);
    o.Set("height", f.size.height);
    Napi::Object work = Napi::Object::New(env);
    work.Set("x", v.origin.x);
    work.Set("y", top - (v.origin.y + v.size.height));
    work.Set("width", v.size.width);
    work.Set("height", v.size.height);
    o.Set("visible", work);
    o.Set("scale", s.backingScaleFactor);
    o.Set("primary", i == 0);
    out.Set((uint32_t)i, o);
  }
  return out;
}

static Napi::Value SetCursorFn(const Napi::CallbackInfo& info) {
  std::string name = info[0].As<Napi::String>().Utf8Value();
  NSCursor* c = nil;
  if (name == "text") c = NSCursor.IBeamCursor;
  else if (name == "pointer") c = NSCursor.pointingHandCursor;
  else if (name == "crosshair") c = NSCursor.crosshairCursor;
  else if (name == "grab") c = NSCursor.openHandCursor;
  else if (name == "grabbing") c = NSCursor.closedHandCursor;
  else if (name == "ew-resize" || name == "col-resize")
    c = NSCursor.resizeLeftRightCursor;
  else if (name == "ns-resize" || name == "row-resize")
    c = NSCursor.resizeUpDownCursor;
  else if (name == "not-allowed") c = NSCursor.operationNotAllowedCursor;
  else c = NSCursor.arrowCursor;
  [c set];
  return info.Env().Undefined();
}

// postKeyEvent(win, down, keyCode, chars, modifiers) — synthetic keys for
// tests, through the real pump like postMouseEvent.
static Napi::Value PostKeyEvent(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  bool down = info[1].ToBoolean().Value();
  unsigned short keyCode = (unsigned short)info[2].As<Napi::Number>().Uint32Value();
  NSString* chars = info.Length() > 3 && info[3].IsString()
                        ? BToNSString(info[3])
                        : @"";
  NSEventModifierFlags flags = 0;
  if (info.Length() > 4 && info[4].IsObject()) {
    Napi::Object m = info[4].As<Napi::Object>();
    if (BBoolOr(m, "shift", false)) flags |= NSEventModifierFlagShift;
    if (BBoolOr(m, "control", false)) flags |= NSEventModifierFlagControl;
    if (BBoolOr(m, "option", false)) flags |= NSEventModifierFlagOption;
    if (BBoolOr(m, "command", false)) flags |= NSEventModifierFlagCommand;
  }
  NSEvent* e = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp
                                location:NSMakePoint(0, 0)
                           modifierFlags:flags
                               timestamp:NSProcessInfo.processInfo.systemUptime
                            windowNumber:win.windowNumber
                                 context:nil
                              characters:chars
             charactersIgnoringModifiers:chars
                               isARepeat:NO
                                 keyCode:keyCode];
  [NSApp postEvent:e atStart:NO];
  return info.Env().Undefined();
}


// invalidateWindowShadow(win) — a transparent window's shadow is computed
// by AppKit from the content's opaque shape; repaints do not recompute it
// automatically, so a popup presented after its map keeps whatever shape
// AppKit guessed first (a full-frame dark square). Call after presenting.
static Napi::Value InvalidateWindowShadow(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  [win invalidateShadow];
  return info.Env().Undefined();
}

// ---------------------------------------------------------------------------
// registration (called from addon.mm's Init)
// ---------------------------------------------------------------------------

void InitBackend(Napi::Env env, Napi::Object exports) {
#define BFN(js, fn) exports.Set(js, Napi::Function::New(env, fn))
  BFN("createWindow2", CreateWindow2);
  BFN("showWindow", ShowWindowFn);
  BFN("hideWindow", HideWindowFn);
  BFN("setWindowTitle", SetWindowTitle);
  BFN("setWindowFrame", SetWindowFrame);
  BFN("getWindowFrame", GetWindowFrame);
  BFN("setWindowMinMax", SetWindowMinMax);
  BFN("destroyWindow2", DestroyWindow2);
  BFN("invalidateWindowShadow", InvalidateWindowShadow);
  BFN("activateApp", ActivateApp);
  BFN("setBackendEventCallback", SetBackendEventCallback);
  BFN("pump2", Pump2);
  BFN("createSurface", CreateSurface);
  BFN("surfaceSize", SurfaceSize);
  BFN("ctxSave", CtxSave);
  BFN("ctxRestore", CtxRestore);
  BFN("ctxTranslate", CtxTranslate);
  BFN("ctxScale", CtxScale);
  BFN("ctxRotate", CtxRotate);
  BFN("ctxTransform", CtxTransform);
  BFN("ctxBeginPath", CtxBeginPath);
  BFN("ctxMoveTo", CtxMoveTo);
  BFN("ctxLineTo", CtxLineTo);
  BFN("ctxRect", CtxRect);
  BFN("ctxRoundRect", CtxRoundRect);
  BFN("ctxArc", CtxArc);
  BFN("ctxEllipse", CtxEllipse);
  BFN("ctxCurveTo", CtxCurveTo);
  BFN("ctxQuadTo", CtxQuadTo);
  BFN("ctxClosePath", CtxClosePath);
  BFN("ctxSetFillColor", CtxSetFillColor);
  BFN("ctxSetStrokeColor", CtxSetStrokeColor);
  BFN("ctxSetLineWidth", CtxSetLineWidth);
  BFN("ctxSetGlobalAlpha", CtxSetGlobalAlpha);
  BFN("ctxSetLineCap", CtxSetLineCap);
  BFN("ctxSetLineJoin", CtxSetLineJoin);
  BFN("ctxSetLineDash", CtxSetLineDash);
  BFN("ctxFill", CtxFill);
  BFN("ctxStroke", CtxStroke);
  BFN("ctxClip", CtxClip);
  BFN("ctxFillRect", CtxFillRect);
  BFN("ctxStrokeRect", CtxStrokeRect);
  BFN("ctxClearRect", CtxClearRect);
  BFN("ctxFillRects", CtxFillRects);
  BFN("ctxFillLinearGradient", CtxFillLinearGradient);
  BFN("ctxDrawSurface", CtxDrawSurface);
  BFN("ctxPutImageData", CtxPutImageData);
  BFN("ctxGetImageData", CtxGetImageData);
  BFN("surfaceToLayer", SurfaceToLayer);
  BFN("scrollSurface", ScrollSurface);
  BFN("matchFont", MatchFont);
  BFN("fontMetrics", FontMetrics);
  BFN("fontHasGlyph", FontHasGlyph);
  BFN("fontFromData", FontFromData);
  BFN("cgFontWithSize", CgFontWithSize);
  BFN("fontByPostScriptName", FontByPostScriptName);
  BFN("fontApplyVariations", FontApplyVariations);
  BFN("drawLayoutGradient", DrawLayoutGradient);
  BFN("ctxSetShadow", CtxSetShadow);
  BFN("listFonts", ListFonts);
  BFN("loadFontData", LoadFontData);
  BFN("createLayout", CreateLayout);
  BFN("drawLayout", DrawLayout);
  BFN("layoutIndexAt", LayoutIndexAt);
  BFN("layoutCaret", LayoutCaret);
  BFN("pasteboardWriteText", PbWriteTextFn);
  BFN("pasteboardReadText", PbReadTextFn);
  BFN("pasteboardClear", PbClearFn);
  BFN("pasteboardChangeCount", PbChangeCountFn);
  BFN("setMainMenu", SetMainMenuFn);
  BFN("mainMenuInfo", MainMenuInfoFn);
  BFN("activateMenuItem", ActivateMenuItemFn);
  BFN("measureControl", MeasureControl);
  BFN("drawControlIntoSurface", DrawControlIntoSurface);
  BFN("listScreens", ListScreens);
  BFN("setCursor", SetCursorFn);
  BFN("postKeyEvent", PostKeyEvent);
#undef BFN
}
