// @windowkit/appkit backend.mm — the surface the react-x11 Cocoa backend consumes.
//
// Everything here is mechanism, no policy: windows with delegates and
// per-window event routing, an enriched event pump, CoreGraphics bitmap
// surfaces with a canvas-shaped drawing API, a CoreText layout engine
// (measure + draw + caret/hit geometry) with glyph-level natives beside it
// (ids, advances, fallback faces, glyph-run drawing), pasteboard text,
// drag and drop, screen lists and cursors. The retained-layer API stays in
// addon.mm; this file is what a renderer paints and listens through.
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
#import <IOSurface/IOSurface.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
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
    // A react-x11 window has no tab semantics. Left on, AppKit persists
    // "show tab bar" per process name (under bun the key lives in the `bun`
    // defaults domain) and grows a 28pt bar into the titlebar of every
    // window we create (windowkit/appkit#12).
    NSWindow.allowsAutomaticWindowTabbing = NO;
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

// The content view's rect in screen coordinates, Cocoa (bottom-left) space.
// The renderer draws into the content view, so this — not the rect the style
// mask implies — is what getWindowFrame and the geometry events report. The
// two differ while the titlebar holds an accessory (a tab bar, most often):
// the accessory takes its height out of the content view without moving the
// window frame, and no windowDidResize fires for it (windowkit/appkit#12).
static NSRect ContentViewScreenRect(NSWindow* win) {
  NSView* cv = win.contentView;
  if (!cv) return [win contentRectForFrameRect:win.frame];
  return [win convertRectToScreen:[cv convertRect:cv.bounds toView:nil]];
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

// The same callback, for the faces in other files: notifications.mm hands
// the UNUserNotificationCenter delegate's responses through here.
bool CALHasBackendCb() { return HasBackendCb(); }
void CALEmitBackendEvent(Napi::Env env, Napi::Object ev) { EmitToJS(env, ev); }

// Window bookkeeping: delegate + view need to reach the JS callback with the
// window's number attached, and windowShouldClose needs to answer NO while
// telling JS. One delegate class serves every window.

@interface CALBackendDelegate : NSObject <NSWindowDelegate> {
 @public
  napi_env env_;
}
@end

static bool WindowOnGlass(NSWindow* win) {
  return (win.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

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
  NSRect content = ContentViewScreenRect(win);
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
// A window entirely behind another application's window is still visible
// by isVisible's measure and still costs every frame its tree produces.
// AppKit knows the difference; `visible: false` here means no pixel of the
// window is on glass, so a renderer can hold its frames until one is.
- (void)windowDidChangeOcclusionState:(NSNotification*)n {
  NSWindow* win = n.object;
  Napi::Env env(env_);
  Napi::HandleScope scope(env);
  Napi::Object ev = WindowEvent(env, win, "window-occlusion");
  ev.Set("visible", WindowOnGlass(win));
  EmitToJS(env, ev);
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
  // drag and drop (its own section below): the env the callbacks run in,
  // the destination's standing answer, the source's masks and provider,
  // and the press a session is begun from
  napi_env env_;
  bool dropAccept_;
  NSString* dropOp_;  // nil: the conventional operation for the source's mask
  NSDragOperation sourceMask_, sourceMaskOutside_;
  BOOL ignoreModifiers_;
  NSEvent* lastPress_;
  id dragProvider_;
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
    // Never a tab bar, whatever an earlier process left in the defaults
    // domain (see BEnsureApp).
    win.tabbingMode = NSWindowTabbingModeDisallowed;
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
    view->env_ = (napi_env)env;
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
  NSRect content = ContentViewScreenRect(win);
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

// -> { x, y, width, height, scale, visible, occluded, key } — content rect, top-left
// global coordinates, points.
static Napi::Value GetWindowFrame(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  NSRect content = ContentViewScreenRect(win);
  Napi::Object r = Napi::Object::New(env);
  r.Set("x", content.origin.x);
  r.Set("y", PrimaryScreenTop() - (content.origin.y + content.size.height));
  r.Set("width", content.size.width);
  r.Set("height", content.size.height);
  r.Set("scale", win.backingScaleFactor);
  r.Set("visible", (bool)win.isVisible);
  // visible but with no pixel on glass: fully behind another app's window
  r.Set("occluded", win.isVisible && !WindowOnGlass(win));
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

static void CancelPanelSheetsOn(NSWindow* win);

static Napi::Value DestroyWindow2(const Napi::CallbackInfo& info) {
  NSWindow* win = BDeref<NSWindow*>(info[0]);
  // A sheet whose owner goes away ends without telling its completion
  // handler; answer it as a cancel first so no callback is left waiting.
  CancelPanelSheetsOn(win);
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
  // The press a drag session is begun from (beginDrag): the latest
  // left-button down or drag in the window, recorded before JS sees it so a
  // beginDrag from inside this very callback has it.
  if ((e.type == NSEventTypeLeftMouseDown ||
       e.type == NSEventTypeLeftMouseDragged) &&
      [e.window.contentView isKindOfClass:[CALBackendView class]]) {
    ((CALBackendView*)e.window.contentView)->lastPress_ = e;
  }

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

// notifications.mm: responses that arrived before a listener was installed
void CALNotificationsReplayHeld(Napi::Env env);

static Napi::Value Pump2(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  BEnsureApp();
  // a notification acted on before the callback existed (one that launched
  // the app, say) goes out ahead of this tick's input
  CALNotificationsReplayHeld(env);
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
  CGContextRef ctx = nullptr;  // nullptr once released
  size_t width = 0, height = 0;  // pixels
  double scale = 1;
  // when the bitmap lives in an IOSurface (zero-copy presentation), the
  // surface owns a reference and the layer scans out of the same memory
  IOSurfaceRef iosurface = nullptr;
  // bytes of bitmap this handle keeps alive, reported to V8 as external
  // memory: a handle is a few dozen bytes of heap to the collector, the
  // 10MB behind it is invisible, and a live resize retiring two of them a
  // tick piles up RSS until the heap happens to grow into a collection
  int64_t bytes = 0;
};

// Free the bitmap now and hand the bytes back to V8's account. The struct
// outlives its bitmap: the External's finalizer deletes it, and ctx == nullptr
// marks it released to every verb in between.
static void SurfaceFree(Napi::Env env, CALSurface* s) {
  if (!s->ctx) return;
  CGContextRelease(s->ctx);
  s->ctx = nullptr;
  if (s->iosurface) {
    CFRelease(s->iosurface);
    s->iosurface = nullptr;
  }
  if (s->bytes) {
    Napi::MemoryManagement::AdjustExternalMemory(env, -s->bytes);
    s->bytes = 0;
  }
}

static void SurfaceFinalize(Napi::Env env, void* d) {
  auto* s = (CALSurface*)d;
  SurfaceFree(env, s);
  delete s;
}

static Napi::Value WrapSurface(Napi::Env env, CALSurface* s, int64_t bytes) {
  s->bytes = bytes;
  if (bytes) Napi::MemoryManagement::AdjustExternalMemory(env, bytes);
  return Napi::External<void>::New(env, s, SurfaceFinalize);
}

// The surface behind a handle, or nullptr with a JS error pending when the
// handle was released: a use after releaseSurface is an error, not a crash.
// Callers return on nullptr.
static CALSurface* SurfaceFrom(Napi::Value v) {
  if (!v.IsExternal()) {
    Napi::TypeError::New(v.Env(), "expected a surface handle")
        .ThrowAsJavaScriptException();
    return nullptr;
  }
  auto* s = (CALSurface*)v.As<Napi::External<void>>().Data();
  if (!s->ctx) {
    Napi::Error::New(v.Env(), "surface was released")
        .ThrowAsJavaScriptException();
    return nullptr;
  }
  return s;
}

// For the fire-and-forget drawing verbs: the context to draw into, or a
// scratch bitmap when the surface is released (the error is already
// pending; the stroke lands nowhere anyone looks).
static CGContextRef CtxOf(Napi::Value v) {
  CALSurface* s = SurfaceFrom(v);
  if (s) return s->ctx;
  static CGContextRef scratch = nullptr;
  if (!scratch) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    scratch = CGBitmapContextCreate(
        NULL, 1, 1, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
  }
  return scratch;
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
  return WrapSurface(env, s, (int64_t)(CGBitmapContextGetBytesPerRow(ctx) * h));
}

// createSurfaceIOSurface(widthPx, heightPx, scale)
//   -> { handle, iosurfaceId }
// The zero-copy presentation surface: the CG bitmap is laid directly over
// an IOSurface's memory, so presenting is `layer.contents = iosurface` —
// the WindowServer composites out of the buffer the painters drew into,
// and the window-sized CGImage copy the plain surface pays per frame
// never happens. Same top-left CTM contract as createSurface.
static Napi::Value CreateSurfaceIOSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  size_t w = (size_t)info[0].As<Napi::Number>().Int64Value();
  size_t h = (size_t)info[1].As<Napi::Number>().Int64Value();
  double scale = info.Length() > 2 ? info[2].As<Napi::Number>().DoubleValue() : 1;
  if (w < 1) w = 1;
  if (h < 1) h = 1;

  bool shared = info.Length() > 3 && info[3].ToBoolean().Value();
  NSMutableDictionary* props = [@{
    (id)kIOSurfaceWidth : @(w),
    (id)kIOSurfaceHeight : @(h),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
  } mutableCopy];
  // kIOSurfaceIsGlobal is the v1 cross-process route: a pane process
  // creates its buffers with it and the host looks them up by plain id.
  // Deprecated but stable; the clean upgrade is a mach-port handshake. Set
  // ONLY when sharing — an explicit @NO disables the global registry entry
  // that same-process IOSurfaceLookup (the window's own present) relies on.
  if (shared) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    props[(id)kIOSurfaceIsGlobal] = @YES;
#pragma clang diagnostic pop
  }
  IOSurfaceRef ios = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (!ios) {
    Napi::Error::New(env, "IOSurfaceCreate failed").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreateWithData(
      IOSurfaceGetBaseAddress(ios), w, h, 8, IOSurfaceGetBytesPerRow(ios), cs,
      kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host,
      NULL, NULL);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    CFRelease(ios);
    Napi::Error::New(env, "CGBitmapContextCreateWithData over IOSurface failed")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CGContextTranslateCTM(ctx, 0, (CGFloat)h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
  auto* s = new CALSurface{ctx, w, h, scale, ios};
  Napi::Object out = Napi::Object::New(env);
  out.Set("handle", WrapSurface(env, s, (int64_t)IOSurfaceGetAllocSize(ios)));
  out.Set("iosurfaceId", (double)IOSurfaceGetID(ios));
  return out;
}

// surfaceFromIOSurfaceID(id, scale) -> { handle, width, height }
// The consumer end of a shared pane buffer: look the surface up by its
// process-global id and lay a CG bitmap over its memory, so a child
// process paints into the very bytes the host's layer scans out of.
static Napi::Value SurfaceFromIOSurfaceID(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  uint32_t sid = info[0].As<Napi::Number>().Uint32Value();
  double scale = info.Length() > 1 ? info[1].As<Napi::Number>().DoubleValue() : 1;
  IOSurfaceRef ios = IOSurfaceLookup(sid);
  if (!ios) {
    Napi::Error::New(env, "IOSurfaceLookup: no surface with that id")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  size_t w = IOSurfaceGetWidth(ios);
  size_t h = IOSurfaceGetHeight(ios);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreateWithData(
      IOSurfaceGetBaseAddress(ios), w, h, 8, IOSurfaceGetBytesPerRow(ios), cs,
      kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host,
      NULL, NULL);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    CFRelease(ios);
    Napi::Error::New(env, "CGBitmapContextCreateWithData over looked-up IOSurface failed")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CGContextTranslateCTM(ctx, 0, (CGFloat)h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
  auto* s = new CALSurface{ctx, w, h, scale, ios};
  Napi::Object out = Napi::Object::New(env);
  out.Set("handle", WrapSurface(env, s, (int64_t)IOSurfaceGetAllocSize(ios)));
  out.Set("width", (double)w);
  out.Set("height", (double)h);
  return out;
}

// releaseSurface(handle) — free the bitmap now, not when V8 gets around to
// the handle. A swapchain retires a pair per resize tick, 20MB at
// 900x700@2x; released on the flip that retires them, they never pile up.
// The finalizer stays as the safety net. Idempotent; every other verb on a
// released handle throws.
static Napi::Value ReleaseSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsExternal()) {
    Napi::TypeError::New(env, "releaseSurface: expected a surface handle")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  SurfaceFree(env, (CALSurface*)info[0].As<Napi::External<void>>().Data());
  return env.Undefined();
}

// CPU access bracketing for an IOSurface-backed surface: lock before the
// frame's first draw, unlock before handing the buffer to the layer. No-op
// on a plain surface, so callers need not care which kind they hold.
static Napi::Value SurfaceLock(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  if (s->iosurface) IOSurfaceLock(s->iosurface, 0, NULL);
  return info.Env().Undefined();
}
static Napi::Value SurfaceUnlock(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  if (s->iosurface) IOSurfaceUnlock(s->iosurface, 0, NULL);
  return info.Env().Undefined();
}

// copySurfaceRegion(src, dst, [x, y, w, h, ...]) — bring a swapchain's new
// back buffer current: memcpy the named device-px rects. Same-size
// surfaces only; rects are clamped. Null/empty rects list copies all.
static Napi::Value CopySurfaceRegion(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALSurface* src = SurfaceFrom(info[0]);
  if (!src) return info.Env().Undefined();
  CALSurface* dst = SurfaceFrom(info[1]);
  if (!dst) return info.Env().Undefined();
  if (src->width != dst->width || src->height != dst->height) {
    Napi::Error::New(env, "copySurfaceRegion: size mismatch")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  const uint8_t* sbase = (const uint8_t*)CGBitmapContextGetData(src->ctx);
  uint8_t* dbase = (uint8_t*)CGBitmapContextGetData(dst->ctx);
  size_t srow = CGBitmapContextGetBytesPerRow(src->ctx);
  size_t drow = CGBitmapContextGetBytesPerRow(dst->ctx);
  if (!sbase || !dbase) return env.Undefined();
  auto copyRect = [&](long x, long y, long w, long h) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > (long)src->width) w = (long)src->width - x;
    if (y + h > (long)src->height) h = (long)src->height - y;
    if (w <= 0 || h <= 0) return;
    for (long r = 0; r < h; r++) {
      memcpy(dbase + (size_t)(y + r) * drow + (size_t)x * 4,
             sbase + (size_t)(y + r) * srow + (size_t)x * 4, (size_t)w * 4);
    }
  };
  if (info.Length() < 3 || info[2].IsNull() || info[2].IsUndefined()) {
    copyRect(0, 0, (long)src->width, (long)src->height);
    return env.Undefined();
  }
  Napi::Array rects = info[2].As<Napi::Array>();
  if (rects.Length() == 0) {
    copyRect(0, 0, (long)src->width, (long)src->height);
    return env.Undefined();
  }
  for (uint32_t i = 0; i + 3 < rects.Length(); i += 4) {
    copyRect((long)rects.Get(i).As<Napi::Number>().Int64Value(),
             (long)rects.Get(i + 1).As<Napi::Number>().Int64Value(),
             (long)rects.Get(i + 2).As<Napi::Number>().Int64Value(),
             (long)rects.Get(i + 3).As<Napi::Number>().Int64Value());
  }
  return env.Undefined();
}

static Napi::Value SurfaceSize(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
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
  // Icons, the serialisable pair from the dbusmenu vocabulary. `iconName`
  // is read in the platform's own icon theme — SF Symbols — which renders
  // as a template and follows the menu's appearance for free; a name the
  // symbol catalogue does not know simply misses (a freedesktop name on
  // its way to a Linux panel does the same in reverse). `iconData` is
  // literal pixels (PNG bytes on the bus) and is the fallback.
  NSString* iconName = BStrOr(o, "iconName", @"");
  NSImage* icon = nil;
  if (iconName.length) {
    icon = [NSImage imageWithSystemSymbolName:iconName
                     accessibilityDescription:nil];
  }
  if (!icon && o.Has("iconData")) {
    Napi::Value v = o.Get("iconData");
    if (v.IsBuffer()) {
      Napi::Buffer<uint8_t> buf = v.As<Napi::Buffer<uint8_t>>();
      NSData* bytes = [NSData dataWithBytes:buf.Data() length:buf.Length()];
      icon = [[NSImage alloc] initWithData:bytes];
      if (icon) icon.size = NSMakeSize(16, 16);
    }
  }
  if (icon) it.image = icon;
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
    io.Set("hasImage", it.image != nil);
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
// file panels — NSOpenPanel / NSSavePanel, the real thing rather than an
// osascript process: owned by our NSApplication, a sheet on the window that
// asked, a cancel that reads as a cancel. Two presentations: with a window
// handle the panel is a sheet (beginSheetModalForWindow:), the pump keeps
// running and the answer arrives through the completion handler on a later
// tick; with no window it is app-modal (runModal), which parks this thread
// in AppKit's modal loop until the panel is dismissed, so the callback runs
// before the call returns. Both end in cb(result), null meaning cancel.
// Filters are UTType identifiers — extension/MIME resolution is the
// renderer's policy; contentTypeFor() asks the OS's own type database on its
// behalf so nothing is dropped the way AppleScript's `of type` dropped MIME.
// ---------------------------------------------------------------------------

// What a presented panel owes JS: the callback and the env to call it with.
// Hung on the panel itself so cancelPanel can tell an open panel from one
// that has already answered.
@interface CALPanelPending : NSObject {
 @public
  napi_env env_;
  Napi::FunctionReference cb_;
  bool open_;  // NSOpenPanel answers paths[], NSSavePanel answers a path
}
@end
@implementation CALPanelPending
@end

static char kPanelPendingKey;

static Napi::Value PanelResult(Napi::Env env, NSSavePanel* panel, bool open,
                               NSModalResponse r) {
  if (r != NSModalResponseOK) return env.Null();
  if (open) {
    NSArray<NSURL*>* urls = ((NSOpenPanel*)panel).URLs;
    Napi::Array a = Napi::Array::New(env, urls.count);
    for (NSUInteger i = 0; i < urls.count; i++)
      a.Set((uint32_t)i, Napi::String::New(env, urls[i].path.UTF8String));
    return a;
  }
  NSURL* u = panel.URL;
  return u ? Napi::Value(Napi::String::New(env, u.path.UTF8String))
           : Napi::Value(env.Null());
}

// The one place a panel answers. The pending record comes off first, so a
// second answer (or a cancelPanel from inside the callback) finds nothing.
static void FinishPanel(NSSavePanel* panel, NSModalResponse r) {
  CALPanelPending* p = objc_getAssociatedObject(panel, &kPanelPendingKey);
  if (!p) return;
  objc_setAssociatedObject(panel, &kPanelPendingKey, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  Napi::Env env(p->env_);
  Napi::HandleScope scope(env);
  Napi::Value result = PanelResult(env, panel, p->open_, r);
  Napi::FunctionReference cb = std::move(p->cb_);
  cb.Call({result});
}

// A path, or a file: URL for callers that already hold one.
static NSURL* PanelURLArg(Napi::Value v) {
  if (!v.IsString()) return nil;
  NSString* s = BToNSString(v);
  if ([s hasPrefix:@"file:"]) return [NSURL URLWithString:s];
  return s.length ? [NSURL fileURLWithPath:s] : nil;
}

// The spec keys both panels share.
static void ConfigurePanel(NSSavePanel* panel, Napi::Object o) {
  if (o.Has("title") && o.Get("title").IsString())
    panel.title = BToNSString(o.Get("title"));
  if (o.Has("message") && o.Get("message").IsString())
    panel.message = BToNSString(o.Get("message"));
  if (o.Has("prompt") && o.Get("prompt").IsString())
    panel.prompt = BToNSString(o.Get("prompt"));
  if (o.Has("directoryURL")) {
    NSURL* u = PanelURLArg(o.Get("directoryURL"));
    if (u) panel.directoryURL = u;
  }
  if (o.Has("canCreateDirectories"))
    panel.canCreateDirectories =
        BBoolOr(o, "canCreateDirectories", panel.canCreateDirectories);
  if (o.Has("allowedContentTypes") && o.Get("allowedContentTypes").IsArray()) {
    Napi::Array ids = o.Get("allowedContentTypes").As<Napi::Array>();
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    for (uint32_t i = 0; i < ids.Length(); i++) {
      Napi::Value v = ids.Get(i);
      if (!v.IsString()) continue;
      UTType* t = [UTType typeWithIdentifier:BToNSString(v)];
      if (t) [types addObject:t];
    }
    // A list the OS recognises nothing of is no filter at all, the same as
    // passing none: a panel that admits nothing helps nobody.
    if (types.count) panel.allowedContentTypes = types;
  }
}

// openPanel(spec, cb) / savePanel(spec, cb) -> panel handle
//   spec: { window?,               // handle: sheet on it; absent: app-modal
//           title?, message?, prompt?,          // prompt = confirm button label
//           directoryURL?,                      // path or file: URL, where it opens
//           allowedContentTypes?: [UTType id],  // absent/empty: any
//           canCreateDirectories?,
//           directory?, multiple?,              // open: folders not files; several
//           nameFieldStringValue? }             // save: the proposed name
//   cb(paths | null) for open, cb(path | null) for save; null is cancel.
static Napi::Value PresentPanel(const Napi::CallbackInfo& info, bool open) {
  Napi::Env env = info.Env();
  if (!info[0].IsObject() || !info[1].IsFunction()) {
    Napi::TypeError::New(env, open ? "openPanel(spec, cb): spec object and callback required"
                                   : "savePanel(spec, cb): spec object and callback required")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  Napi::Object o = info[0].As<Napi::Object>();
  NSWindow* owner = nil;
  if (o.Has("window")) {
    Napi::Value w = o.Get("window");
    if (w.IsExternal()) {
      owner = BDeref<NSWindow*>(w);
    } else if (!w.IsNull() && !w.IsUndefined()) {
      Napi::TypeError::New(env, "window must be a window handle")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
  }
  BEnsureApp();

  NSSavePanel* panel;
  if (open) {
    NSOpenPanel* op = [NSOpenPanel openPanel];
    bool dirs = BBoolOr(o, "directory", false);
    op.canChooseDirectories = dirs;
    op.canChooseFiles = !dirs;
    op.allowsMultipleSelection = BBoolOr(o, "multiple", false);
    panel = op;
  } else {
    panel = [NSSavePanel savePanel];
    if (o.Has("nameFieldStringValue") &&
        o.Get("nameFieldStringValue").IsString())
      panel.nameFieldStringValue = BToNSString(o.Get("nameFieldStringValue"));
  }
  ConfigurePanel(panel, o);

  CALPanelPending* p = [CALPanelPending new];
  p->env_ = (napi_env)env;
  p->cb_ = Napi::Persistent(info[1].As<Napi::Function>());
  p->open_ = open;
  objc_setAssociatedObject(panel, &kPanelPendingKey, p,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  Napi::Value handle = BWrapRetained(env, panel);

  if (owner) {
    [panel beginSheetModalForWindow:owner
                  completionHandler:^(NSModalResponse r) {
                    FinishPanel(panel, r);
                  }];
  } else {
    NSModalResponse r = [panel runModal];
    FinishPanel(panel, r);
  }
  return handle;
}

static Napi::Value OpenPanelFn(const Napi::CallbackInfo& info) {
  return PresentPanel(info, true);
}

static Napi::Value SavePanelFn(const Napi::CallbackInfo& info) {
  return PresentPanel(info, false);
}

// cancelPanel(panel) -> bool — dismiss a sheet that is still up; its
// callback then gets null. False when the panel has already answered.
// (An app-modal panel cannot be reached from here: the thread that would
// call this is inside runModal.)
static Napi::Value CancelPanelFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsExternal()) {
    Napi::TypeError::New(env, "cancelPanel: panel handle required")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  NSSavePanel* panel = BDeref<NSSavePanel*>(info[0]);
  if (!objc_getAssociatedObject(panel, &kPanelPendingKey))
    return Napi::Boolean::New(env, false);
  [panel cancel:nil];
  return Napi::Boolean::New(env, true);
}

// Every panel sheet still up on `win`, answered null. Called before the
// window is torn down.
static void CancelPanelSheetsOn(NSWindow* win) {
  for (NSWindow* sheet in [win.sheets copy]) {
    if (objc_getAssociatedObject(sheet, &kPanelPendingKey))
      [(NSSavePanel*)sheet cancel:nil];
  }
}

// contentTypeFor({ extension } | { mime }) -> UTType identifier, or null.
// The OS's own database: 'png' -> 'public.png', 'application/json' ->
// 'public.json'; an extension nothing has declared still yields a dynamic
// type ('dyn.…') that matches exactly that extension in a panel.
static Napi::Value ContentTypeForFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsObject()) {
    Napi::TypeError::New(env, "contentTypeFor({ extension } | { mime })")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  Napi::Object o = info[0].As<Napi::Object>();
  UTType* t = nil;
  if (o.Has("extension") && o.Get("extension").IsString()) {
    NSString* ext = BToNSString(o.Get("extension"));
    if ([ext hasPrefix:@"."]) ext = [ext substringFromIndex:1];
    if (ext.length) t = [UTType typeWithFilenameExtension:ext];
  } else if (o.Has("mime") && o.Get("mime").IsString()) {
    t = [UTType typeWithMIMEType:BToNSString(o.Get("mime"))];
  }
  return t ? Napi::Value(Napi::String::New(env, t.identifier.UTF8String))
           : Napi::Value(env.Null());
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
  if (!s) return info.Env().Undefined();
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
  CGContextSaveGState(CtxOf(info[0]));
  return info.Env().Undefined();
}
static Napi::Value CtxRestore(const Napi::CallbackInfo& info) {
  CGContextRestoreGState(CtxOf(info[0]));
  return info.Env().Undefined();
}
static Napi::Value CtxTranslate(const Napi::CallbackInfo& info) {
  CGContextTranslateCTM(CtxOf(info[0]),
                        info[1].As<Napi::Number>().DoubleValue(),
                        info[2].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxScale(const Napi::CallbackInfo& info) {
  CGContextScaleCTM(CtxOf(info[0]),
                    info[1].As<Napi::Number>().DoubleValue(),
                    info[2].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxTransform(const Napi::CallbackInfo& info) {
  CGContextConcatCTM(CtxOf(info[0]),
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
  CGContextRotateCTM(CtxOf(info[0]),
                     info[1].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxBeginPath(const Napi::CallbackInfo& info) {
  CGContextBeginPath(CtxOf(info[0]));
  return info.Env().Undefined();
}
static Napi::Value CtxMoveTo(const Napi::CallbackInfo& info) {
  CGContextMoveToPoint(CtxOf(info[0]),
                       info[1].As<Napi::Number>().DoubleValue(),
                       info[2].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxLineTo(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  double x = info[1].As<Napi::Number>().DoubleValue();
  double y = info[2].As<Napi::Number>().DoubleValue();
  if (CGContextIsPathEmpty(s->ctx)) CGContextMoveToPoint(s->ctx, x, y);
  else CGContextAddLineToPoint(s->ctx, x, y);
  return info.Env().Undefined();
}
static Napi::Value CtxRect(const Napi::CallbackInfo& info) {
  CGContextAddRect(CtxOf(info[0]),
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
  if (!s) return info.Env().Undefined();
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
  // arc(surface, x, y, r, a0, a1, anticlockwise). Angles live in user
  // space, where canvas's y-down "clockwise" sweep is the INCREASING-angle
  // direction — which is what CG calls counterclockwise (clockwise = 0).
  // The flag therefore maps straight across, not inverted: getting this
  // backwards leaves full circles (donuts) looking right and every partial
  // arc sweeping the long way round — the raster-gate gauges caught it.
  CGContextAddArc(CtxOf(info[0]),
                  info[1].As<Napi::Number>().DoubleValue(),
                  info[2].As<Napi::Number>().DoubleValue(),
                  info[3].As<Napi::Number>().DoubleValue(),
                  info[4].As<Napi::Number>().DoubleValue(),
                  info[5].As<Napi::Number>().DoubleValue(),
                  info[6].ToBoolean().Value() ? 1 : 0);
  return info.Env().Undefined();
}
static Napi::Value CtxEllipse(const Napi::CallbackInfo& info) {
  CGContextAddEllipseInRect(
      CtxOf(info[0]),
      CGRectMake(info[1].As<Napi::Number>().DoubleValue() -
                     info[3].As<Napi::Number>().DoubleValue(),
                 info[2].As<Napi::Number>().DoubleValue() -
                     info[4].As<Napi::Number>().DoubleValue(),
                 info[3].As<Napi::Number>().DoubleValue() * 2,
                 info[4].As<Napi::Number>().DoubleValue() * 2));
  return info.Env().Undefined();
}
static Napi::Value CtxCurveTo(const Napi::CallbackInfo& info) {
  CGContextAddCurveToPoint(CtxOf(info[0]),
                           info[1].As<Napi::Number>().DoubleValue(),
                           info[2].As<Napi::Number>().DoubleValue(),
                           info[3].As<Napi::Number>().DoubleValue(),
                           info[4].As<Napi::Number>().DoubleValue(),
                           info[5].As<Napi::Number>().DoubleValue(),
                           info[6].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxQuadTo(const Napi::CallbackInfo& info) {
  CGContextAddQuadCurveToPoint(CtxOf(info[0]),
                               info[1].As<Napi::Number>().DoubleValue(),
                               info[2].As<Napi::Number>().DoubleValue(),
                               info[3].As<Napi::Number>().DoubleValue(),
                               info[4].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxClosePath(const Napi::CallbackInfo& info) {
  CGContextClosePath(CtxOf(info[0]));
  return info.Env().Undefined();
}

static Napi::Value CtxSetFillColor(const Napi::CallbackInfo& info) {
  CGContextSetRGBFillColor(CtxOf(info[0]),
                           info[1].As<Napi::Number>().DoubleValue(),
                           info[2].As<Napi::Number>().DoubleValue(),
                           info[3].As<Napi::Number>().DoubleValue(),
                           info[4].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxSetStrokeColor(const Napi::CallbackInfo& info) {
  CGContextSetRGBStrokeColor(CtxOf(info[0]),
                             info[1].As<Napi::Number>().DoubleValue(),
                             info[2].As<Napi::Number>().DoubleValue(),
                             info[3].As<Napi::Number>().DoubleValue(),
                             info[4].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxSetLineWidth(const Napi::CallbackInfo& info) {
  CGContextSetLineWidth(CtxOf(info[0]),
                        info[1].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxSetGlobalAlpha(const Napi::CallbackInfo& info) {
  CGContextSetAlpha(CtxOf(info[0]),
                    info[1].As<Napi::Number>().DoubleValue());
  return info.Env().Undefined();
}
static Napi::Value CtxSetLineCap(const Napi::CallbackInfo& info) {
  std::string cap = info[1].As<Napi::String>().Utf8Value();
  CGContextSetLineCap(CtxOf(info[0]),
                      cap == "round"    ? kCGLineCapRound
                      : cap == "square" ? kCGLineCapSquare
                                        : kCGLineCapButt);
  return info.Env().Undefined();
}
static Napi::Value CtxSetLineJoin(const Napi::CallbackInfo& info) {
  std::string join = info[1].As<Napi::String>().Utf8Value();
  CGContextSetLineJoin(CtxOf(info[0]),
                       join == "round"   ? kCGLineJoinRound
                       : join == "bevel" ? kCGLineJoinBevel
                                         : kCGLineJoinMiter);
  return info.Env().Undefined();
}
static Napi::Value CtxSetLineDash(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
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
  if (!s) return info.Env().Undefined();
  bool evenOdd = info.Length() > 1 && info[1].ToBoolean().Value();
  KeepPathAround(s->ctx, ^{
    if (evenOdd) CGContextEOFillPath(s->ctx);
    else CGContextFillPath(s->ctx);
  });
  return info.Env().Undefined();
}
static Napi::Value CtxStroke(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  KeepPathAround(s->ctx, ^{ CGContextStrokePath(s->ctx); });
  return info.Env().Undefined();
}
static Napi::Value CtxClip(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  KeepPathAround(s->ctx, ^{ CGContextClip(s->ctx); });
  return info.Env().Undefined();
}

static Napi::Value CtxFillRect(const Napi::CallbackInfo& info) {
  CGContextFillRect(CtxOf(info[0]),
                    CGRectMake(info[1].As<Napi::Number>().DoubleValue(),
                               info[2].As<Napi::Number>().DoubleValue(),
                               info[3].As<Napi::Number>().DoubleValue(),
                               info[4].As<Napi::Number>().DoubleValue()));
  return info.Env().Undefined();
}
static Napi::Value CtxStrokeRect(const Napi::CallbackInfo& info) {
  CGContextStrokeRect(CtxOf(info[0]),
                      CGRectMake(info[1].As<Napi::Number>().DoubleValue(),
                                 info[2].As<Napi::Number>().DoubleValue(),
                                 info[3].As<Napi::Number>().DoubleValue(),
                                 info[4].As<Napi::Number>().DoubleValue()));
  return info.Env().Undefined();
}
static Napi::Value CtxClearRect(const Napi::CallbackInfo& info) {
  CGContextClearRect(CtxOf(info[0]),
                     CGRectMake(info[1].As<Napi::Number>().DoubleValue(),
                                info[2].As<Napi::Number>().DoubleValue(),
                                info[3].As<Napi::Number>().DoubleValue(),
                                info[4].As<Napi::Number>().DoubleValue()));
  return info.Env().Undefined();
}
// fillRects(surface, flat [x,y,w,h,...]) — one call for a batch of fills.
static Napi::Value CtxFillRects(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
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
  if (!s) return info.Env().Undefined();
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
  if (!dst) return info.Env().Undefined();
  CALSurface* src = SurfaceFrom(info[1]);
  if (!src) return info.Env().Undefined();
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
  if (!s) return info.Env().Undefined();
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
  if (!s) return info.Env().Undefined();
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
  if (!s) return info.Env().Undefined();
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
  if (!s) return info.Env().Undefined();
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

// --- glyph-level natives ---------------------------------------------------
//
// createLayout/drawLayout shape text at the line level. A renderer that
// positions glyphs itself — a terminal grid, a tabular column — needs the
// glyph, its advance, a face that covers what the base face does not, and
// a way to draw a run of ids at positions of its own choosing without a
// typesetter in the middle (ctxDrawGlyphs, beside drawLayout below).
// Shaping — ligatures, kerning, bidi — stays the typesetter's job; a grid
// renderer bypasses it on purpose.

// A font handle is an External over an NSFont (matchFont) or a CTFont
// (cgFontWithSize and friends); the two are toll-free bridged, so one
// accessor serves both.
static CTFontRef BFontFrom(Napi::Value v) {
  return (CTFontRef)v.As<Napi::External<void>>().Data();
}

static bool BCheckFontArg(const Napi::CallbackInfo& info, const char* fn) {
  if (info[0].IsExternal()) return true;
  Napi::TypeError::New(info.Env(), std::string(fn) + ": expected a font handle")
      .ThrowAsJavaScriptException();
  return false;
}

// One code point -> its UTF-16 form. False for a surrogate or an
// out-of-range value.
static bool BUtf16ForCodepoint(uint32_t cp, unichar out[2], CFIndex* len) {
  if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
  if (cp < 0x10000) {
    out[0] = (unichar)cp;
    *len = 1;
    return true;
  }
  cp -= 0x10000;
  out[0] = (unichar)(0xD800 + (cp >> 10));
  out[1] = (unichar)(0xDC00 + (cp & 0x3FF));
  *len = 2;
  return true;
}

// A code point argument: a number, or a string read for its first code
// point. False when there is none.
static bool BCodepointArg(Napi::Value v, uint32_t* cp) {
  if (v.IsNumber()) {
    double d = v.As<Napi::Number>().DoubleValue();
    if (!(d >= 0 && d <= 0x10FFFF)) return false;  // NaN fails too
    *cp = (uint32_t)d;
    return true;
  }
  if (v.IsString()) {
    std::u16string s = v.As<Napi::String>().Utf16Value();
    if (s.empty()) return false;
    uint32_t hi = s[0];
    if (hi >= 0xD800 && hi <= 0xDBFF && s.size() > 1 && s[1] >= 0xDC00 &&
        s[1] <= 0xDFFF) {
      *cp = 0x10000 + ((hi - 0xD800) << 10) + ((uint32_t)s[1] - 0xDC00);
    } else {
      *cp = hi;
    }
    return true;
  }
  return false;
}

// The glyph a face maps one code point to, 0 when it does not: glyph 0 is
// .notdef in every sfnt and what CTFontGetGlyphsForCharacters answers for
// an unmapped character. A non-BMP character is sparse — its glyph sits in
// the high surrogate's slot and the low surrogate's slot is 0 by design,
// which is not a failure.
static CGGlyph BGlyphForCodepoint(CTFontRef font, uint32_t cp) {
  unichar buf[2];
  CFIndex len = 0;
  if (!BUtf16ForCodepoint(cp, buf, &len)) return 0;
  CGGlyph glyphs[2] = {0, 0};
  CTFontGetGlyphsForCharacters(font, buf, glyphs, len);
  return glyphs[0];
}

// Glyph ids for a run. A Uint16Array is used in place (CGGlyph is a
// uint16); any other array of numbers is copied into `store`.
static const CGGlyph* BGlyphsArg(Napi::Value v, std::vector<CGGlyph>* store,
                                 size_t* count) {
  if (v.IsTypedArray() &&
      v.As<Napi::TypedArray>().TypedArrayType() == napi_uint16_array) {
    Napi::Uint16Array a = v.As<Napi::Uint16Array>();
    *count = a.ElementLength();
    return a.Data();
  }
  store->clear();
  size_t n = v.IsTypedArray() ? v.As<Napi::TypedArray>().ElementLength()
             : v.IsArray()    ? v.As<Napi::Array>().Length()
                              : 0;
  if (n > 0) {
    Napi::Object o = v.As<Napi::Object>();
    store->reserve(n);
    for (uint32_t i = 0; i < n; i++) {
      Napi::Value e = o.Get(i);
      store->push_back(
          e.IsNumber() ? (CGGlyph)e.As<Napi::Number>().Uint32Value() : 0);
    }
  }
  *count = store->size();
  return store->data();
}

// Glyph origins for a run, x0,y0,x1,y1,… in canvas space, converted into
// the frame CTFontDrawGlyphs reads: its positions are in TEXT space — the
// text matrix applies to them, not only to the outlines (the trap WebKit's
// fillVectorWithHorizontalGlyphPositions documents) — and the text matrix
// here is the y-flip, so each origin's y is negated on the way in. A
// Float64Array is read directly; any other array of numbers is accepted.
static void BGlyphOriginsArg(Napi::Value v, std::vector<CGPoint>* out) {
  out->clear();
  if (v.IsTypedArray() &&
      v.As<Napi::TypedArray>().TypedArrayType() == napi_float64_array) {
    Napi::Float64Array a = v.As<Napi::Float64Array>();
    const double* d = a.Data();
    size_t n = a.ElementLength() / 2;
    out->reserve(n);
    for (size_t i = 0; i < n; i++)
      out->push_back(CGPointMake(d[2 * i], -d[2 * i + 1]));
    return;
  }
  size_t n = v.IsTypedArray() ? v.As<Napi::TypedArray>().ElementLength()
             : v.IsArray()    ? v.As<Napi::Array>().Length()
                              : 0;
  if (n < 2) return;
  Napi::Object o = v.As<Napi::Object>();
  out->reserve(n / 2);
  for (uint32_t i = 0; i + 1 < n; i += 2) {
    Napi::Value x = o.Get(i), y = o.Get(i + 1);
    out->push_back(
        CGPointMake(x.IsNumber() ? x.As<Napi::Number>().DoubleValue() : 0,
                    -(y.IsNumber() ? y.As<Napi::Number>().DoubleValue() : 0)));
  }
}

// fontGlyphForCodepoint(font, codepoint) -> glyph id | null
// The answer fontHasGlyph throws away. null when the face does not map the
// code point — the caller wants "not covered" as a branch (pick a fallback
// face), not glyph 0 discovered on screen. `codepoint` is a number; a
// string is read for its first code point.
static Napi::Value FontGlyphForCodepoint(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!BCheckFontArg(info, "fontGlyphForCodepoint")) return env.Undefined();
  uint32_t cp = 0;
  if (!BCodepointArg(info[1], &cp)) return env.Null();
  CGGlyph g = BGlyphForCodepoint(BFontFrom(info[0]), cp);
  if (g == 0) return env.Null();
  return Napi::Number::New(env, (double)g);
}

// fontGlyphAdvances(font, glyphs: Uint16Array) -> Float64Array
// Horizontal advances, in points at the handle's size — what a monospace
// grid reads its cell width from (the advance of "0").
static Napi::Value FontGlyphAdvances(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!BCheckFontArg(info, "fontGlyphAdvances")) return env.Undefined();
  std::vector<CGGlyph> store;
  size_t count = 0;
  const CGGlyph* glyphs = BGlyphsArg(info[1], &store, &count);
  Napi::Float64Array out = Napi::Float64Array::New(env, count);
  if (count == 0) return out;
  std::vector<CGSize> advances(count);
  CTFontGetAdvancesForGlyphs(BFontFrom(info[0]), kCTFontOrientationHorizontal,
                             glyphs, advances.data(), (CFIndex)count);
  for (size_t i = 0; i < count; i++) out[i] = advances[i].width;
  return out;
}

// Code points a cmap rarely lists and the typesetter never draws: C0/C1
// controls and Unicode's default ignorables (soft hyphen, joiners, bidi
// controls, variation selectors, tags). Coverage checks skip them.
static bool BIgnorableForCoverage(uint32_t cp) {
  if (cp < 0x20 || (cp >= 0x7F && cp <= 0x9F)) return true;
  switch (cp >> 16) {
    case 0x00:
      return cp == 0x00AD || cp == 0x034F || cp == 0x061C ||
             (cp >= 0x115F && cp <= 0x1160) ||
             (cp >= 0x17B4 && cp <= 0x17B5) ||
             (cp >= 0x180B && cp <= 0x180F) ||
             (cp >= 0x200B && cp <= 0x200F) ||
             (cp >= 0x202A && cp <= 0x202E) ||
             (cp >= 0x2060 && cp <= 0x206F) || cp == 0x3164 ||
             (cp >= 0xFE00 && cp <= 0xFE0F) || cp == 0xFEFF ||
             cp == 0xFFA0 || (cp >= 0xFFF0 && cp <= 0xFFF8);
    case 0x01:
      return (cp >= 0x1BCA0 && cp <= 0x1BCA3) ||
             (cp >= 0x1D173 && cp <= 0x1D17A);
    case 0x0E:
      return true;
    default:
      return false;
  }
}

// Does the face's cmap map every code point of `s` that would be drawn?
static bool BFontCovers(CTFontRef font, NSString* s) {
  NSUInteger n = s.length;
  if (n == 0) return true;
  std::vector<unichar> chars(n);
  [s getCharacters:chars.data() range:NSMakeRange(0, n)];
  std::vector<CGGlyph> glyphs(n, 0);
  CTFontGetGlyphsForCharacters(font, chars.data(), glyphs.data(), (CFIndex)n);
  for (NSUInteger i = 0; i < n; i++) {
    uint32_t cp = chars[i];
    bool pair = cp >= 0xD800 && cp <= 0xDBFF && i + 1 < n &&
                chars[i + 1] >= 0xDC00 && chars[i + 1] <= 0xDFFF;
    if (pair) cp = 0x10000 + ((cp - 0xD800) << 10) + (chars[i + 1] - 0xDC00);
    if (glyphs[i] == 0 && !BIgnorableForCoverage(cp)) return false;
    if (pair) i++;  // the low surrogate's slot is 0 by design
  }
  return true;
}

// fontFallbackFor(font, text) -> font handle | null
// CTFontCreateForString over the font's cascade list: the face CoreText
// would substitute for `text`, at the same size — box drawing in a font
// that has none, CJK, emoji. Answers the handle itself when the face
// already covers the text (`fallback === font` reads as "no substitution
// needed") and null when nothing covers it. `text` may also be a code
// point number.
static Napi::Value FontFallbackFor(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!BCheckFontArg(info, "fontFallbackFor")) return env.Undefined();
  CTFontRef font = BFontFrom(info[0]);
  NSString* text = nil;
  if (info[1].IsString()) {
    text = BToNSString(info[1]);
  } else {
    uint32_t cp = 0;
    unichar buf[2];
    CFIndex len = 0;
    if (BCodepointArg(info[1], &cp) && BUtf16ForCodepoint(cp, buf, &len))
      text = [NSString stringWithCharacters:buf length:(NSUInteger)len];
  }
  if (!text) return env.Null();
  if (text.length == 0) return info[0];
  CTFontRef sub = CTFontCreateForString(font, (__bridge CFStringRef)text,
                                        CFRangeMake(0, (CFIndex)text.length));
  if (!sub) return env.Null();
  if (CFEqual(sub, font)) {
    // CoreText hands the font itself back both when it covers the text
    // and when nothing in the cascade does; the cmap tells the two apart.
    CFRelease(sub);
    return BFontCovers(font, text) ? info[0] : env.Null();
  }
  // LastResort is CoreText's own "nothing covers it": a box with the
  // block's name in it. The caller asked for that as a branch, not a glyph.
  CFStringRef ps = CTFontCopyPostScriptName(sub);
  bool lastResort =
      ps && CFStringCompare(ps, CFSTR("LastResort"), 0) == kCFCompareEqualTo;
  if (ps) CFRelease(ps);
  if (lastResort) {
    CFRelease(sub);
    return env.Null();
  }
  return Napi::External<void>::New(env, (void*)sub, [](Napi::Env, void* d) {
    CFRelease(d);
  });
}

// fontWithSize(font, size) -> font handle | null
// The same face at another size (CTFontCreateCopyWithAttributes). A matched
// family re-resolves per size through matchFont; a face that arrived by
// substitution — fontFallbackFor's answer, a fontShapeText run's font — has
// no family to re-match by, and asking the cascade again at the new size is
// a different question with a possibly different answer. This is how such a
// face answers metrics and advances at every size, as itself.
static Napi::Value FontWithSize(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!BCheckFontArg(info, "fontWithSize")) return env.Undefined();
  double size = info[1].IsNumber() ? info[1].As<Napi::Number>().DoubleValue() : 0;
  if (!(size > 0)) {
    Napi::TypeError::New(env, "fontWithSize: expected a size > 0")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CTFontRef sized = CTFontCreateCopyWithAttributes(BFontFrom(info[0]),
                                                   (CGFloat)size, NULL, NULL);
  if (!sized) return env.Null();
  return Napi::External<void>::New(env, (void*)sized, [](Napi::Env, void* d) {
    CFRelease(d);
  });
}

// fontShapeText(font, text)
//   -> { width, runs: [{ font: handle | null, glyphs: Uint16Array,
//                        positions: Float64Array x0,y0,x1,y1,…,
//                        advances: Float64Array }] }
// One CTLine over `text` in this font, read back run by run: glyph ids,
// each glyph's origin relative to the line origin in CoreText's text space
// (y up), and its advance. A run's `font` is null when it is the font asked
// for, and a new handle when CoreText substituted a face for characters
// this one lacks — the ids in that run are the substitute's, and drawing
// them with the base font would draw its glyphs at those indices instead.
// Runs come in visual order, so a right-to-left cluster reads back left to
// right. The typesetter's whole answer for a cluster — a base with its
// marks positioned, an emoji sequence joined, a variation selector honoured
// — as ids a caller can hand to ctxDrawGlyphs beside the ids it looked up
// itself; nothing here decides where a cluster goes.
static Napi::Value FontShapeText(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!BCheckFontArg(info, "fontShapeText")) return env.Undefined();
  CTFontRef font = BFontFrom(info[0]);
  NSString* text = info[1].IsString() ? BToNSString(info[1]) : @"";
  Napi::Object out = Napi::Object::New(env);
  Napi::Array runsOut = Napi::Array::New(env);
  double width = 0;
  if (text.length > 0) {
    NSDictionary* attrs =
        @{(__bridge id)kCTFontAttributeName : (__bridge id)font};
    NSAttributedString* as =
        [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line =
        CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    uint32_t written = 0;
    for (CFIndex ri = 0; ri < CFArrayGetCount(runs); ri++) {
      CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, ri);
      CFIndex count = CTRunGetGlyphCount(run);
      if (count <= 0) continue;
      std::vector<CGGlyph> glyphs((size_t)count);
      std::vector<CGPoint> positions((size_t)count);
      std::vector<CGSize> advances((size_t)count);
      CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs.data());
      CTRunGetPositions(run, CFRangeMake(0, 0), positions.data());
      CTRunGetAdvances(run, CFRangeMake(0, 0), advances.data());
      CFDictionaryRef rattrs = CTRunGetAttributes(run);
      CTFontRef rfont =
          (CTFontRef)CFDictionaryGetValue(rattrs, kCTFontAttributeName);
      Napi::Object ro = Napi::Object::New(env);
      if (rfont && !CFEqual(rfont, font)) {
        CFRetain(rfont);
        ro.Set("font", Napi::External<void>::New(
                           env, (void*)rfont,
                           [](Napi::Env, void* d) { CFRelease(d); }));
      } else {
        ro.Set("font", env.Null());
      }
      Napi::Uint16Array g = Napi::Uint16Array::New(env, (size_t)count);
      Napi::Float64Array p = Napi::Float64Array::New(env, (size_t)count * 2);
      Napi::Float64Array a = Napi::Float64Array::New(env, (size_t)count);
      for (size_t i = 0; i < (size_t)count; i++) {
        g[i] = glyphs[i];
        p[i * 2] = positions[i].x;
        p[i * 2 + 1] = positions[i].y;
        a[i] = advances[i].width;
      }
      ro.Set("glyphs", g);
      ro.Set("positions", p);
      ro.Set("advances", a);
      runsOut.Set(written++, ro);
    }
    CFRelease(line);
  }
  out.Set("width", width);
  out.Set("runs", runsOut);
  return out;
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
  if (!s) return info.Env().Undefined();
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

// ctxDrawGlyphs(surface, runs) — CTFontDrawGlyphs per run, no typesetter
// in the middle.
//   runs: [{ font, glyphs: Uint16Array, positions: Float64Array x0,y0,… }]
// Positions are canvas space (y down), one baseline origin per glyph; a
// run draws min(glyphs, positions) of them. Honours the surface CTM and
// clip like every other ctx verb and paints with the current fill colour,
// so one call covers every run of one colour — the batch a terminal
// renderer produces (one call per foreground colour per frame). The base
// CTM is y-flipped for canvas semantics and glyph outlines are y-up, so
// the text matrix flips them back, as in drawLayout; the positions ride
// through that same matrix, hence the y negation in BGlyphOriginsArg.
static Napi::Value CtxDrawGlyphs(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  if (!info[1].IsArray()) return info.Env().Undefined();
  Napi::Array runs = info[1].As<Napi::Array>();
  CGContextRef ctx = s->ctx;
  CGContextSaveGState(ctx);
  CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
  CGContextSetTextDrawingMode(ctx, kCGTextFill);
  std::vector<CGGlyph> glyphStore;
  std::vector<CGPoint> positionStore;
  for (uint32_t i = 0; i < runs.Length(); i++) {
    Napi::Value rv = runs.Get(i);
    if (!rv.IsObject()) continue;
    Napi::Object run = rv.As<Napi::Object>();
    Napi::Value fv = run.Get("font");
    if (!fv.IsExternal()) continue;
    size_t nGlyphs = 0;
    const CGGlyph* glyphs =
        BGlyphsArg(run.Get("glyphs"), &glyphStore, &nGlyphs);
    BGlyphOriginsArg(run.Get("positions"), &positionStore);
    size_t count = std::min(nGlyphs, positionStore.size());
    if (count == 0) continue;
    CTFontDrawGlyphs(BFontFrom(fv), glyphs, positionStore.data(),
                     (CFIndex)count, ctx);
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
  if (!s) return info.Env().Undefined();
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
  if (!s) return info.Env().Undefined();
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
    // the panel's own refresh rate, so a renderer paces frames on the
    // display's period instead of assuming 60Hz on a 120Hz ProMotion
    // panel; 0 where the OS cannot say (before macOS 12)
    double fps = 0;
    if (@available(macOS 12.0, *)) fps = (double)s.maximumFramesPerSecond;
    o.Set("fps", fps);
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
// drag and drop — NSDraggingDestination on the hosting view, NSDraggingSource
// from it (windowkit/appkit#16). Mechanism only. AppKit asks its questions
// synchronously — may this drop land, and with which operation? — and the
// view answers them from a response JS sets during the callback for that
// very question (the callback runs inside draggingEntered:/draggingUpdated:,
// so a setDropResponse in a drag-enter handler is the answer to that
// draggingEntered:). Every phase is reported through the backend callback
// with the window's number attached, like every other window event. Type
// names cross this boundary as pasteboard types — UTIs such as
// public.utf8-plain-text, public.file-url, public.png, and the legacy
// NSPasteboardType strings AppKit still hands out — and the MIME vocabulary
// stays the renderer's; pasteboardTypeForMIME is the OS's own table for it.
// ---------------------------------------------------------------------------

static const struct {
  const char* name;
  NSDragOperation op;
} kDragOps[] = {
    {"copy", NSDragOperationCopy},       {"link", NSDragOperationLink},
    {"generic", NSDragOperationGeneric}, {"private", NSDragOperationPrivate},
    {"move", NSDragOperationMove},       {"delete", NSDragOperationDelete},
};

static NSDragOperation DragOpFromName(const std::string& name) {
  for (const auto& d : kDragOps)
    if (name == d.name) return d.op;
  return NSDragOperationNone;
}

static const char* DragOpName(NSDragOperation op) {
  for (const auto& d : kDragOps)
    if (op == d.op) return d.name;
  return op == NSDragOperationNone ? "none" : "generic";
}

// ['copy', 'move'] or a raw NSDragOperation mask; absent means copy.
static NSDragOperation DragMaskFrom(Napi::Value v) {
  if (v.IsNumber()) return (NSDragOperation)v.As<Napi::Number>().Uint32Value();
  if (!v.IsArray()) return NSDragOperationCopy;
  Napi::Array a = v.As<Napi::Array>();
  NSDragOperation mask = NSDragOperationNone;
  for (uint32_t i = 0; i < a.Length(); i++) {
    Napi::Value e = a.Get(i);
    if (e.IsString()) mask |= DragOpFromName(e.As<Napi::String>().Utf8Value());
  }
  return mask;
}

static Napi::Array DragOpsOfMask(Napi::Env env, NSDragOperation mask) {
  Napi::Array out = Napi::Array::New(env);
  uint32_t n = 0;
  for (const auto& d : kDragOps)
    if (mask & d.op) out.Set(n++, d.name);
  return out;
}

// The operation a destination answers when JS accepted without naming one:
// the conventional order over what the source allows. An explicit
// `operation` is returned as given, whether or not the source offered it.
static NSDragOperation DragDefaultOp(NSDragOperation mask) {
  static const NSDragOperation prefer[] = {
      NSDragOperationCopy,    NSDragOperationMove,    NSDragOperationLink,
      NSDragOperationGeneric, NSDragOperationPrivate, NSDragOperationDelete};
  for (NSDragOperation op : prefer)
    if (mask & op) return op;
  return NSDragOperationGeneric;
}

// The pasteboard of the drag most recently over one of our windows — what
// dragItems / dragItemData read. AppKit hands each destination method its
// own NSDraggingInfo and forbids keeping it; the pasteboard underneath is
// the drag pasteboard, which outlives the call.
static NSPasteboard* gDragPasteboard = nil;
// postDragEvent's private pasteboard; released when the next one replaces it.
static NSPasteboard* gPostedPasteboard = nil;

// The hosting view of a createWindow2 window, or nil with a TypeError
// pending: these verbs belong to the backend surface, and addon.mm's windows
// host a CALHostView that has none of this.
static CALBackendView* BackendViewArg(Napi::Value v, const char* fn) {
  if (v.IsExternal()) {
    NSWindow* win = BDeref<NSWindow*>(v);
    if ([win.contentView isKindOfClass:[CALBackendView class]])
      return (CALBackendView*)win.contentView;
  }
  Napi::TypeError::New(v.Env(),
                       std::string(fn) + ": expected a createWindow2 window")
      .ThrowAsJavaScriptException();
  return nil;
}

// A JS value onto a pasteboard item: a string as a string (AppKit encodes
// it for the type — UTF-8 for public.utf8-plain-text, the URL string for
// public.file-url), bytes as bytes, anything else stringified. null writes
// nothing.
static void WritePasteboardValue(NSPasteboardItem* item, NSString* type,
                                 Napi::Value v) {
  if (v.IsNull() || v.IsUndefined()) return;
  if (v.IsString()) {
    [item setString:BToNSString(v) forType:type];
    return;
  }
  const void* bytes = nullptr;
  size_t len = 0;
  if (v.IsBuffer()) {
    Napi::Buffer<uint8_t> b = v.As<Napi::Buffer<uint8_t>>();
    bytes = b.Data();
    len = b.Length();
  } else if (v.IsTypedArray()) {
    Napi::TypedArray a = v.As<Napi::TypedArray>();
    bytes = (const uint8_t*)a.ArrayBuffer().Data() + a.ByteOffset();
    len = a.ByteLength();
  } else if (v.IsArrayBuffer()) {
    Napi::ArrayBuffer a = v.As<Napi::ArrayBuffer>();
    bytes = a.Data();
    len = a.ByteLength();
  } else {
    [item setString:BToNSString(v.ToString()) forType:type];
    return;
  }
  [item setData:[NSData dataWithBytes:bytes length:len] forType:type];
}

// The source side's lazy payloads: a representation whose value was null is
// promised, and AppKit asks for it here — on this thread, inside the pump or
// the session's own tracking — when a consumer actually reads it. The
// answer is `provide(type, itemIndex)`'s return value, written like any
// other.
@interface CALDragProvider : NSObject <NSPasteboardItemDataProvider> {
 @public
  napi_env env_;
  Napi::FunctionReference fn_;
  NSArray<NSPasteboardItem*>* items_;
}
@end
@implementation CALDragProvider
- (void)pasteboard:(NSPasteboard*)pb
                  item:(NSPasteboardItem*)item
    provideDataForType:(NSPasteboardType)type {
  (void)pb;
  if (fn_.IsEmpty()) return;
  Napi::Env env(env_);
  Napi::HandleScope scope(env);
  NSUInteger idx = [items_ indexOfObjectIdenticalTo:item];
  Napi::Value v = fn_.Call(
      {Napi::String::New(env, type.UTF8String),
       Napi::Number::New(env, idx == NSNotFound ? -1 : (double)idx)});
  if (env.IsExceptionPending()) return;
  WritePasteboardValue(item, type, v);
}
- (void)pasteboardFinishedWithDataProvider:(NSPasteboard*)pb {
  (void)pb;
  fn_.Reset();
  items_ = nil;
}
@end

// items: [{ [type]: string | bytes | null }, ...] — one entry per dragging
// item, its keys the representations that item offers (react-x11's dragData
// shape; a drag of three files is three entries of one public.file-url
// each, which is how Finder reads them). A bare object is one item. null
// promises the representation through `provide`; without a provider it is
// dropped.
static NSArray<NSPasteboardItem*>* BuildPasteboardItems(
    Napi::Env env, Napi::Value spec, CALDragProvider* provider) {
  NSMutableArray<NSPasteboardItem*>* items = [NSMutableArray array];
  Napi::Array arr;
  if (spec.IsArray()) {
    arr = spec.As<Napi::Array>();
  } else {
    arr = Napi::Array::New(env, 1);
    arr.Set(0u, spec);
  }
  for (uint32_t i = 0; i < arr.Length(); i++) {
    Napi::Value v = arr.Get(i);
    if (!v.IsObject()) continue;
    Napi::Object o = v.As<Napi::Object>();
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    NSMutableArray<NSString*>* lazy = [NSMutableArray array];
    Napi::Array keys = o.GetPropertyNames();
    for (uint32_t k = 0; k < keys.Length(); k++) {
      Napi::Value key = keys.Get(k);
      if (!key.IsString()) continue;
      NSString* type = BToNSString(key);
      Napi::Value val = o.Get(key);
      if (val.IsNull() || val.IsUndefined()) {
        if (provider) [lazy addObject:type];
      } else {
        WritePasteboardValue(item, type, val);
      }
    }
    if (lazy.count) [item setDataProvider:provider forTypes:lazy];
    [items addObject:item];
  }
  return items;
}

// The drag image, from either bitmap this addon deals in: `surface`, a
// surface handle (the renderer's own paint, its scale known), or `image`, a
// CGImage External — or the {image, width, height, scale} object
// text.render / controls.render answer, taken whole.
static NSImage* DragImageFrom(Napi::Object o, double* w, double* h) {
  Napi::Value sv = o.Get("surface");
  if (sv.IsExternal()) {
    CALSurface* s = SurfaceFrom(sv);  // a released handle throws, as everywhere
    if (!s) return nil;
    double scale = s->scale > 0 ? s->scale : 1;
    CGImageRef cg = CGBitmapContextCreateImage(s->ctx);
    if (!cg) return nil;
    *w = s->width / scale;
    *h = s->height / scale;
    NSImage* img = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(*w, *h)];
    CGImageRelease(cg);
    return img;
  }
  Napi::Value iv = o.Get("image");
  double scale = BNumOr(o, "imageScale", 1);
  if (iv.IsObject() && !iv.IsExternal()) {
    Napi::Object r = iv.As<Napi::Object>();
    scale = BNumOr(r, "scale", scale);
    iv = r.Get("image");
  }
  if (!iv.IsExternal()) return nil;
  CGImageRef cg = (CGImageRef)iv.As<Napi::External<void>>().Data();
  *w = CGImageGetWidth(cg) / scale;
  *h = CGImageGetHeight(cg) / scale;
  return [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(*w, *h)];
}

// The shared payload of the destination events: where (content view,
// top-left; and global top-left as gx/gy, like a mouse event), what the
// pasteboard carries, and what the source allows. `types` is the union over
// the pasteboard's items; `itemCount` says how many items carry them —
// a Finder drag of three files is three items of one public.file-url each,
// read per item through dragItemString. `local` is a drag begun by one of
// our own windows (beginDrag), whose number then follows.
static void EmitDragInfo(Napi::Env env, CALBackendView* view,
                         const char* type, id<NSDraggingInfo> info) {
  if (!HasBackendCb()) return;
  Napi::HandleScope scope(env);
  NSWindow* win = view.window;
  Napi::Object ev = WindowEvent(env, win, type);
  if (info) {
    NSPoint loc = info.draggingLocation;
    NSPoint p = [view convertPoint:loc fromView:nil];  // the view is flipped
    ev.Set("x", p.x);
    ev.Set("y", p.y);
    NSRect r = [win convertRectToScreen:NSMakeRect(loc.x, loc.y, 0, 0)];
    ev.Set("gx", r.origin.x);
    ev.Set("gy", PrimaryScreenTop() - r.origin.y);
    NSPasteboard* pb = info.draggingPasteboard;
    Napi::Array types = Napi::Array::New(env);
    uint32_t n = 0;
    for (NSString* t in pb.types) types.Set(n++, t.UTF8String);
    ev.Set("types", types);
    ev.Set("itemCount", (double)pb.pasteboardItems.count);
    NSDragOperation mask = info.draggingSourceOperationMask;
    ev.Set("sourceMask", (double)mask);
    ev.Set("operations", DragOpsOfMask(env, mask));
    id src = info.draggingSource;
    bool local = [src isKindOfClass:[CALBackendView class]];
    ev.Set("local", local);
    if (local)
      ev.Set("sourceWindowNumber",
             (double)((CALBackendView*)src).window.windowNumber);
    ev.Set("sequence", (double)info.draggingSequenceNumber);
  }
  EmitToJS(env, ev);
}

// The source side's events: the pointer in global top-left coordinates,
// and for the end, the operation the destination performed ('none' when
// nothing took the drop) with `dropped` as its boolean.
static void EmitDragSession(Napi::Env env, CALBackendView* view,
                            const char* type, NSPoint screenPoint,
                            const char* operation) {
  if (!HasBackendCb()) return;
  Napi::HandleScope scope(env);
  Napi::Object ev = WindowEvent(env, view.window, type);
  ev.Set("x", screenPoint.x);
  ev.Set("y", PrimaryScreenTop() - screenPoint.y);
  if (operation) {
    ev.Set("operation", operation);
    ev.Set("dropped", strcmp(operation, "none") != 0);
  }
  EmitToJS(env, ev);
}

@interface CALBackendView (DragAndDrop) <NSDraggingSource>
@end
@implementation CALBackendView (DragAndDrop)

// --- destination ----------------------------------------------------------

- (NSDragOperation)dropAnswer:(id<NSDraggingInfo>)info {
  if (!dropAccept_) return NSDragOperationNone;
  if (dropOp_) return DragOpFromName(dropOp_.UTF8String);
  return DragDefaultOp(info.draggingSourceOperationMask);
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  gDragPasteboard = sender.draggingPasteboard;
  // a yes left over from the previous drag must not answer this one
  dropAccept_ = false;
  dropOp_ = nil;
  EmitDragInfo(Napi::Env(env_), self, "drag-enter", sender);
  return [self dropAnswer:sender];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  gDragPasteboard = sender.draggingPasteboard;
  EmitDragInfo(Napi::Env(env_), self, "drag-over", sender);
  return [self dropAnswer:sender];
}
- (void)draggingExited:(nullable id<NSDraggingInfo>)sender {
  EmitDragInfo(Napi::Env(env_), self, "drag-exit", sender);
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
  (void)sender;
  return dropAccept_;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  gDragPasteboard = sender.draggingPasteboard;
  EmitDragInfo(Napi::Env(env_), self, "drag-perform", sender);
  return dropAccept_;  // JS may withdraw it, having looked at the payload
}
// One drag-over per pointer position, not a timer's worth.
- (BOOL)wantsPeriodicDraggingUpdates { return NO; }

// --- source ---------------------------------------------------------------

- (NSDragOperation)draggingSession:(NSDraggingSession*)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  (void)session;
  return context == NSDraggingContextOutsideApplication ? sourceMaskOutside_
                                                        : sourceMask_;
}
- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession*)session {
  (void)session;
  return ignoreModifiers_;
}
- (void)draggingSession:(NSDraggingSession*)session
       willBeginAtPoint:(NSPoint)screenPoint {
  (void)session;
  EmitDragSession(Napi::Env(env_), self, "drag-session-began", screenPoint,
                  nullptr);
}
- (void)draggingSession:(NSDraggingSession*)session
           movedToPoint:(NSPoint)screenPoint {
  (void)session;
  EmitDragSession(Napi::Env(env_), self, "drag-session-moved", screenPoint,
                  nullptr);
}
- (void)draggingSession:(NSDraggingSession*)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
  (void)session;
  EmitDragSession(Napi::Env(env_), self, "drag-session-ended", screenPoint,
                  DragOpName(operation));
}
@end

// registerDropTypes(win, types) — registerForDraggedTypes: on the hosting
// view; an empty list unregisters. Until this is called a window takes no
// drops and sees no drag events: AppKit routes a drag only to views
// registered for a type it carries.
static Napi::Value RegisterDropTypes(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALBackendView* view = BackendViewArg(info[0], "registerDropTypes");
  if (!view) return env.Undefined();
  view->env_ = env;
  NSMutableArray<NSString*>* types = [NSMutableArray array];
  if (info[1].IsArray()) {
    Napi::Array a = info[1].As<Napi::Array>();
    for (uint32_t i = 0; i < a.Length(); i++)
      if (a.Get(i).IsString()) [types addObject:BToNSString(a.Get(i))];
  }
  [view unregisterDraggedTypes];  // replace, never accumulate
  if (types.count) [view registerForDraggedTypes:types];
  return env.Undefined();
}

// setDropResponse(win, { accept, operation? }) — the view's answer for the
// drag in flight. Set during a drag-enter or drag-over callback it answers
// that question; it stays in force for the drag-over events that follow
// until changed, and resets to a refusal when a new drag enters. Set during
// drag-perform, `accept: false` withdraws the drop. `operation` is one of
// copy | move | link | generic | private | delete; absent, the conventional
// choice among what the source allows.
static Napi::Value SetDropResponse(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALBackendView* view = BackendViewArg(info[0], "setDropResponse");
  if (!view) return env.Undefined();
  Napi::Object o = info[1].IsObject() ? info[1].As<Napi::Object>()
                                      : Napi::Object::New(env);
  view->dropAccept_ = BBoolOr(o, "accept", false);
  NSString* op = BStrOr(o, "operation", nil);
  view->dropOp_ = op.length ? op : nil;
  return env.Undefined();
}

static NSPasteboard* CurrentDragPasteboard() {
  return gDragPasteboard
             ?: [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
}

// dragItems() -> [{ types: [...] }] — the items of the drag over (or just
// dropped on) one of our windows, each with the representations it offers.
// dragItemData(index, type) -> Buffer | null and dragItemString(index,
// type) -> string | null read one. Read during the drag-perform callback:
// the payload is the source's promise, and a source is free to withdraw it
// once its session has ended.
static Napi::Value DragItems(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Array out = Napi::Array::New(env);
  uint32_t n = 0;
  for (NSPasteboardItem* item in CurrentDragPasteboard().pasteboardItems) {
    Napi::Object o = Napi::Object::New(env);
    Napi::Array types = Napi::Array::New(env);
    uint32_t k = 0;
    for (NSString* t in item.types) types.Set(k++, t.UTF8String);
    o.Set("types", types);
    out.Set(n++, o);
  }
  return out;
}

static NSPasteboardItem* DragItemArg(Napi::Value v) {
  NSArray<NSPasteboardItem*>* items = CurrentDragPasteboard().pasteboardItems;
  if (!v.IsNumber()) return nil;
  double i = v.As<Napi::Number>().DoubleValue();
  if (!(i >= 0 && i < (double)items.count)) return nil;
  return items[(NSUInteger)i];
}

static Napi::Value DragItemData(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSPasteboardItem* item = DragItemArg(info[0]);
  if (!item || !info[1].IsString()) return env.Null();
  NSData* d = [item dataForType:BToNSString(info[1])];
  if (!d) return env.Null();
  return Napi::Buffer<uint8_t>::Copy(env, (const uint8_t*)d.bytes, d.length);
}

static Napi::Value DragItemString(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSPasteboardItem* item = DragItemArg(info[0]);
  if (!item || !info[1].IsString()) return env.Null();
  NSString* s = [item stringForType:BToNSString(info[1])];
  if (!s) return env.Null();
  return Napi::String::New(env, s.UTF8String);
}

// beginDrag(win, { x, y, items, provide?, operations?, operationsOutside?,
//                  ignoreModifiers?, slideBack?,
//                  surface | image, imageScale?, imageX?, imageY?,
//                  imageWidth?, imageHeight? }) -> bool
// Begin a dragging session from the press in flight. x/y is the press in
// the window's content coordinates; the session is begun from the real
// mouse-down (or drag) event when the pointer is still down in this window,
// which is what a renderer's threshold logic calls from, and from an event
// synthesised at x/y otherwise. `operations` is what the source allows
// (['copy'] default), `operationsOutside` the same for other applications
// when it differs; `ignoreModifiers` stops AppKit turning Option/Command
// into copy/link; `slideBack` (default true) animates a refused drop home.
// The image sits at imageX/imageY (content coordinates, top-left), centred
// on the press by default, at its own size unless imageWidth/imageHeight
// say otherwise; with no image the drag shows nothing. Returns whether a
// session began. The session runs on AppKit's own tracking from here; JS
// hears drag-session-began / -moved / -ended, and the pointer's own
// mousemove/mouseup do not arrive while it runs — the ended event is the
// release.
static Napi::Value BeginDrag(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALBackendView* view = BackendViewArg(info[0], "beginDrag");
  if (!view) return env.Undefined();
  if (!info[1].IsObject()) {
    Napi::TypeError::New(env, "beginDrag: expected an options object")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  Napi::Object o = info[1].As<Napi::Object>();
  view->env_ = env;

  NSEvent* press = view->lastPress_;
  if (press && press.window != view.window) press = nil;
  double x = BNumOr(o, "x", NAN), y = BNumOr(o, "y", NAN);
  if (std::isnan(x) || std::isnan(y)) {
    if (!press) {
      Napi::TypeError::New(env, "beginDrag: x and y are required without a press in flight")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    NSPoint p = [view convertPoint:press.locationInWindow fromView:nil];
    x = p.x;
    y = p.y;
  }
  if (!press) {
    NSPoint wp = [view convertPoint:NSMakePoint(x, y) toView:nil];
    press = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                               location:wp
                          modifierFlags:0
                              timestamp:NSProcessInfo.processInfo.systemUptime
                           windowNumber:view.window.windowNumber
                                context:nil
                            eventNumber:0
                             clickCount:1
                               pressure:1];
  }

  CALDragProvider* provider = nil;
  Napi::Value provide = o.Get("provide");
  if (provide.IsFunction()) {
    provider = [[CALDragProvider alloc] init];
    provider->env_ = env;
    provider->fn_ = Napi::Persistent(provide.As<Napi::Function>());
  }
  NSArray<NSPasteboardItem*>* pbItems =
      BuildPasteboardItems(env, o.Get("items"), provider);
  if (provider) provider->items_ = pbItems;
  if (pbItems.count == 0) {
    Napi::TypeError::New(env, "beginDrag: items must name at least one item")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }

  double w = 0, h = 0;
  NSImage* img = DragImageFrom(o, &w, &h);
  if (env.IsExceptionPending()) return env.Undefined();
  if (o.Has("imageWidth")) w = BNumOr(o, "imageWidth", w);
  if (o.Has("imageHeight")) h = BNumOr(o, "imageHeight", h);
  double ix = BNumOr(o, "imageX", x - w / 2), iy = BNumOr(o, "imageY", y - h / 2);
  if (!img) {
    img = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    w = h = 1;
    ix = x;
    iy = y;
  }
  // the view is flipped, so a top-left frame is what setDraggingFrame: takes
  NSRect frame = NSMakeRect(ix, iy, w, h);
  NSMutableArray<NSDraggingItem*>* dragItems = [NSMutableArray array];
  for (NSPasteboardItem* item in pbItems) {
    NSDraggingItem* di = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
    [di setDraggingFrame:frame contents:img];
    [dragItems addObject:di];
  }

  view->sourceMask_ = DragMaskFrom(o.Get("operations"));
  view->sourceMaskOutside_ = o.Has("operationsOutside")
                                 ? DragMaskFrom(o.Get("operationsOutside"))
                                 : view->sourceMask_;
  view->ignoreModifiers_ = BBoolOr(o, "ignoreModifiers", false);
  view->dragProvider_ = provider;  // alive for as long as the pasteboard may ask

  NSDraggingSession* session = [view beginDraggingSessionWithItems:dragItems
                                                             event:press
                                                            source:view];
  if (!session) return Napi::Boolean::New(env, false);
  session.animatesToStartingPositionsOnCancelOrFail =
      BBoolOr(o, "slideBack", true);
  return Napi::Boolean::New(env, true);
}

// A dragging info of our own, for postDragEvent: what AppKit would build
// for a drag from another application, over a private pasteboard.
@interface CALPostedDragInfo : NSObject <NSDraggingInfo> {
 @public
  NSWindow* window_;
  NSPasteboard* pasteboard_;
  NSPoint location_;
  NSDragOperation mask_;
  id source_;
  NSInteger sequence_;
  NSDraggingFormation formation_;
  BOOL animates_;
  NSInteger valid_;
}
@end
@implementation CALPostedDragInfo
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (NSWindow*)draggingDestinationWindow { return window_; }
- (NSDragOperation)draggingSourceOperationMask { return mask_; }
- (NSPoint)draggingLocation { return location_; }
- (NSPoint)draggedImageLocation { return location_; }
- (NSImage*)draggedImage { return nil; }
- (NSPasteboard*)draggingPasteboard { return pasteboard_; }
- (id)draggingSource { return source_; }
- (NSInteger)draggingSequenceNumber { return sequence_; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint { (void)screenPoint; }
- (NSArray<NSString*>*)namesOfPromisedFilesDroppedAtDestination:(NSURL*)url {
  (void)url;
  return nil;
}
#pragma clang diagnostic pop
- (NSDraggingFormation)draggingFormation { return formation_; }
- (void)setDraggingFormation:(NSDraggingFormation)f { formation_ = f; }
- (BOOL)animatesToDestination { return animates_; }
- (void)setAnimatesToDestination:(BOOL)a { animates_ = a; }
- (NSInteger)numberOfValidItemsForDrop { return valid_; }
- (void)setNumberOfValidItemsForDrop:(NSInteger)n { valid_ = n; }
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)opts
                                  forView:(NSView*)view
                                  classes:(NSArray<Class>*)classes
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id>*)options
                               usingBlock:(void (^)(NSDraggingItem*, NSInteger, BOOL*))block {
  (void)opts;
  (void)view;
  (void)classes;
  (void)options;
  (void)block;
}
- (NSSpringLoadingHighlight)springLoadingHighlight {
  return NSSpringLoadingHighlightNone;
}
- (void)resetSpringLoading {}
@end

// postDragEvent(win, phase, { x, y, items, operations?, local? })
// Drive the view's NSDraggingDestination methods with a dragging info of
// our own, the way AppKit does for a drag from another application — the
// drag-and-drop counterpart of postMouseEvent, for tests. phase 'enter' and
// 'over' answer the operation the view returned ('none' when it refused);
// 'exit' answers nothing; 'drop' runs prepare + perform + conclude as
// AppKit sequences them and answers whether the drop was taken. x/y are
// content coordinates, `items` has beginDrag's shape (read on enter, and
// again on any later phase that names it), `operations` is the pretend
// source's mask (copy default), and `local: true` names this window's own
// view as the source.
static Napi::Value PostDragEvent(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALBackendView* view = BackendViewArg(info[0], "postDragEvent");
  if (!view) return env.Undefined();
  view->env_ = env;
  std::string phase = info[1].IsString() ? info[1].As<Napi::String>().Utf8Value() : "";
  Napi::Object o = info.Length() > 2 && info[2].IsObject()
                       ? info[2].As<Napi::Object>()
                       : Napi::Object::New(env);

  // one pasteboard per drag: a new one on enter, its contents whatever
  // `items` the latest phase named (a drag's payload is fixed in AppKit,
  // but a test may want to say it once, at the drop)
  static NSInteger sequence = 0;
  if (phase == "enter" || !gPostedPasteboard) {
    if (gPostedPasteboard) [gPostedPasteboard releaseGlobally];
    gPostedPasteboard = [NSPasteboard pasteboardWithUniqueName];
    sequence++;
  }
  if (phase == "enter" || o.Has("items")) {
    [gPostedPasteboard clearContents];
    [gPostedPasteboard writeObjects:BuildPasteboardItems(env, o.Get("items"), nil)];
  }
  CALPostedDragInfo* di = [[CALPostedDragInfo alloc] init];
  di->window_ = view.window;
  di->pasteboard_ = gPostedPasteboard;
  di->location_ = [view convertPoint:NSMakePoint(BNumOr(o, "x", 0), BNumOr(o, "y", 0)) toView:nil];
  di->mask_ = DragMaskFrom(o.Get("operations"));
  di->source_ = BBoolOr(o, "local", false) ? view : nil;
  di->sequence_ = sequence;
  di->formation_ = NSDraggingFormationDefault;
  di->valid_ = (NSInteger)gPostedPasteboard.pasteboardItems.count;

  if (phase == "enter")
    return Napi::String::New(env, DragOpName([view draggingEntered:di]));
  if (phase == "over")
    return Napi::String::New(env, DragOpName([view draggingUpdated:di]));
  if (phase == "exit") {
    [view draggingExited:di];
    return env.Undefined();
  }
  if (phase == "drop") {
    bool taken = [view prepareForDragOperation:di] && [view performDragOperation:di];
    if (taken && [view respondsToSelector:@selector(concludeDragOperation:)])
      [view concludeDragOperation:di];
    return Napi::Boolean::New(env, taken);
  }
  Napi::TypeError::New(env, "postDragEvent: phase must be enter | over | exit | drop")
      .ThrowAsJavaScriptException();
  return env.Undefined();
}

// pasteboardTypeForMIME(mime) -> UTI — the OS's own MIME <-> UTI table
// (UniformTypeIdentifiers), so a renderer's transfer vocabulary maps
// through the table Finder and Mail read rather than a copy kept in JS. A
// MIME type no declared type claims gets a dynamic identifier (dyn.a…),
// which is still a working pasteboard type: it encodes the MIME type, so
// any process asking the same question gets the same string.
// pasteboardTypeInfo(uti) -> { identifier, mime, extension, description,
// dynamic, declared } | null reads the table the other way.
static Napi::Value PasteboardTypeForMIME(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsString()) return env.Null();
  UTType* t = [UTType typeWithMIMEType:BToNSString(info[0])];
  if (!t) return env.Null();
  return Napi::String::New(env, t.identifier.UTF8String);
}

static Napi::Value PasteboardTypeInfo(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsString()) return env.Null();
  UTType* t = [UTType typeWithIdentifier:BToNSString(info[0])];
  if (!t) return env.Null();
  Napi::Object r = Napi::Object::New(env);
  r.Set("identifier", t.identifier.UTF8String);
  r.Set("mime", t.preferredMIMEType
                    ? Napi::Value(Napi::String::New(env, t.preferredMIMEType.UTF8String))
                    : Napi::Value(env.Null()));
  r.Set("extension",
        t.preferredFilenameExtension
            ? Napi::Value(Napi::String::New(env, t.preferredFilenameExtension.UTF8String))
            : Napi::Value(env.Null()));
  r.Set("description",
        t.localizedDescription
            ? Napi::Value(Napi::String::New(env, t.localizedDescription.UTF8String))
            : Napi::Value(env.Null()));
  r.Set("dynamic", (bool)t.isDynamic);
  r.Set("declared", (bool)t.isDeclared);
  return r;
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
  BFN("createSurfaceIOSurface", CreateSurfaceIOSurface);
  BFN("surfaceFromIOSurfaceID", SurfaceFromIOSurfaceID);
  BFN("releaseSurface", ReleaseSurface);
  BFN("surfaceLock", SurfaceLock);
  BFN("surfaceUnlock", SurfaceUnlock);
  BFN("copySurfaceRegion", CopySurfaceRegion);
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
  BFN("fontGlyphForCodepoint", FontGlyphForCodepoint);
  BFN("fontGlyphAdvances", FontGlyphAdvances);
  BFN("fontFallbackFor", FontFallbackFor);
  BFN("fontWithSize", FontWithSize);
  BFN("fontShapeText", FontShapeText);
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
  BFN("ctxDrawGlyphs", CtxDrawGlyphs);
  BFN("layoutIndexAt", LayoutIndexAt);
  BFN("layoutCaret", LayoutCaret);
  BFN("pasteboardWriteText", PbWriteTextFn);
  BFN("pasteboardReadText", PbReadTextFn);
  BFN("pasteboardClear", PbClearFn);
  BFN("pasteboardChangeCount", PbChangeCountFn);
  BFN("setMainMenu", SetMainMenuFn);
  BFN("mainMenuInfo", MainMenuInfoFn);
  BFN("activateMenuItem", ActivateMenuItemFn);
  BFN("openPanel", OpenPanelFn);
  BFN("savePanel", SavePanelFn);
  BFN("cancelPanel", CancelPanelFn);
  BFN("contentTypeFor", ContentTypeForFn);
  BFN("measureControl", MeasureControl);
  BFN("drawControlIntoSurface", DrawControlIntoSurface);
  BFN("listScreens", ListScreens);
  BFN("setCursor", SetCursorFn);
  BFN("postKeyEvent", PostKeyEvent);
  BFN("registerDropTypes", RegisterDropTypes);
  BFN("setDropResponse", SetDropResponse);
  BFN("dragItems", DragItems);
  BFN("dragItemData", DragItemData);
  BFN("dragItemString", DragItemString);
  BFN("beginDrag", BeginDrag);
  BFN("postDragEvent", PostDragEvent);
  BFN("pasteboardTypeForMIME", PasteboardTypeForMIME);
  BFN("pasteboardTypeInfo", PasteboardTypeInfo);
#undef BFN
}
