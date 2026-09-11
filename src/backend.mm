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
#include <dlfcn.h>
#include <pthread.h>

#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "channel.h"

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

// ---------------------------------------------------------------------------
// the application: one bootstrap for both faces of the addon. addon.mm's
// EnsureApp calls BEnsureApp (not static for that reason), so NSApplication
// is set up exactly once, whichever entry point (initApp, createWindow,
// createWindow2, a control bezel) comes first, and the app delegate it
// dispatches to is in place for finishLaunching.
//
// The activation policy has to be decided before finishLaunching: a Regular
// launch registers a Dock tile, and an agent app that flips to Accessory
// afterwards has already flashed its icon. `initApp({ activationPolicy })`
// and setActivationPolicy therefore feed gActivationPolicy when the app is
// not launched yet, and go through -[NSApplication setActivationPolicy:]
// once it is (any policy may be set at runtime since 10.9).
// ---------------------------------------------------------------------------

static NSApplicationActivationPolicy gActivationPolicy =
    NSApplicationActivationPolicyRegular;
static bool gAppLaunched = false;
static NSMenu* gDockMenu = nil;  // applicationDockMenu: answer; setDockMenu

static void BInstallAppDelegate();  // the app lifecycle section, below
static void BInstallAccessibilityObserver();  // the accessibility section, below
static void BPublishAppState();  // the published state section, below
static bool PolicyFromName(const std::string& s,
                           NSApplicationActivationPolicy* out);  // app presence
static void PublishPolicy(NSApplicationActivationPolicy p);  // published state

// Said before launch by initApp({ activationPolicy }), setActivationPolicy
// or runMain({ activationPolicy }): then the environment is not consulted.
static bool gPolicyChosen = false;

// APPKIT_ACTIVATION_POLICY=regular|accessory|prohibited — the policy to
// launch with when the code that would say so has not run yet
// (windowkit/appkit#64): a launcher's initApp() or runMain() launches the
// app before a worker has imported the app's entry, and a policy set after
// finishLaunching is too late for an agent app, whose Dock tile has
// already appeared. A bundled app says the same with LSUIElement. A name
// nobody knows is reported and the default kept.
static void PolicyFromEnvironment() {
  const char* v = getenv("APPKIT_ACTIVATION_POLICY");
  if (!v || !*v) return;
  NSApplicationActivationPolicy p;
  if (PolicyFromName(v, &p)) {
    gActivationPolicy = p;
  } else {
    fprintf(stderr,
            "@windowkit/appkit: APPKIT_ACTIVATION_POLICY=%s is not regular, "
            "accessory or prohibited; launching as regular\n",
            v);
  }
}

void BEnsureApp() {
  if (gAppLaunched) return;
  if (!gPolicyChosen) PolicyFromEnvironment();
  // published as it is decided, not after finishLaunching: a launch can
  // take longer than a worker takes to start and read it
  PublishPolicy(gActivationPolicy);
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:gActivationPolicy];
    // A react-x11 window has no tab semantics. Left on, AppKit persists
    // "show tab bar" per process name (under bun the key lives in the `bun`
    // defaults domain) and grows a 28pt bar into the titlebar of every
    // window we create (windowkit/appkit#12).
    NSWindow.allowsAutomaticWindowTabbing = NO;
    // Before finishLaunching, never after: the Apple Event this process was
    // launched for (a URL, a document) is dispatched inside that call, and
    // a delegate installed a line later would never hear of it.
    BInstallAppDelegate();
    BInstallAccessibilityObserver();
    [NSApp finishLaunching];
  }
  gAppLaunched = true;
  BPublishAppState();
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

// Pump mode's delivery, which threaded.mm's CALEmit calls while the channel
// is closed: the record materialized in the callback's own environment and
// handed over inline, as every event always was. Producers everywhere build
// a CALEvent and call CALEmit (channel.h); nothing calls the callback
// directly any more. The call is raw, so a failed call is a status rather
// than node-addon-api's fatal error; an exception the callback throws is
// left pending. Inside pump2 (a JS call frame) it rethrows to pump2's
// caller, as it always has; the notification and calendar-change hops,
// which reach here from a threadsafe function's callback, make it the
// uncaught exception themselves (CALRaiseUncaughtIfPending).
void CALPumpDeliver(const CALEvent& ev) {
  if (!HasBackendCb()) return;
  Napi::Env env = gBackendCb.Env();
  Napi::HandleScope scope(env);
  napi_value undefined, arg = ev.ToObject(env);
  if (napi_get_undefined(env, &undefined) != napi_ok) return;
  napi_call_function(env, undefined, gBackendCb.Value(), 1, &arg, nullptr);
}

bool CALHasBackendCb() { return HasBackendCb(); }

// ---------------------------------------------------------------------------
// published state: what JS on a worker reads without a hop
// ---------------------------------------------------------------------------
//
// In threaded mode (threaded.mm) the renderer's JS never waits on the UI
// thread, so what it reads back synchronously is a copy the UI thread keeps
// as things change, under one lock: each window's content rect, visibility,
// occlusion, key state and scale; the screen list; the accessibility display
// options; the activation policy; the pasteboard's change count (polled, as
// nothing announces another app's write). listScreens,
// accessibilityDisplayOptions and pasteboardChangeCount answer from it when
// called off the main thread while runMain runs, and windowState and
// activationPolicy read it in either mode. The copies are kept in pump mode
// too — a few doubles per change — but every query pump mode already makes
// still asks AppKit, live, on the main thread.

struct PubWindow {
  double x = 0, y = 0, width = 0, height = 0, scale = 1;
  bool visible = false, occluded = false, key = false, ignoresMouseEvents = false;
  bool liveResize = false;  // inside a live resize (windowkit/appkit#63)
};

struct PubScreen {
  double x, y, width, height;           // the whole screen
  double vx, vy, vwidth, vheight;       // less the menu bar and the Dock
  double scale, fps;
  bool primary;
};

struct A11yOptions {
  bool reduceMotion, reduceTransparency, increaseContrast,
      differentiateWithoutColor, invertColors;
};

// leaked, like threaded.mm's queues: a worker may still read while the
// process exits, after static destructors have begun
static std::mutex& gPubMu = *new std::mutex;
static std::unordered_map<long, PubWindow>& gPubWindows =
    *new std::unordered_map<long, PubWindow>;  // by windowNumber
static std::vector<PubScreen>& gPubScreens = *new std::vector<PubScreen>;
static A11yOptions gPubA11y = {};
static std::atomic<int> gPubPolicy{(int)NSApplicationActivationPolicyRegular};
static std::atomic<long> gPubPasteboardCount{0};

static void PublishPolicy(NSApplicationActivationPolicy p) { gPubPolicy = (int)p; }

// A call off the main thread — a worker's, threaded mode's — answers from
// the copy: AppKit's state is not that thread's to read.
static bool ReadPublished() { return !pthread_main_np(); }

// appInfo's part of the copy: the name LaunchServices has for the process,
// the Dock badge, whether the app is active.
static NSString* gPubName = nil;   // gPubMu
static NSString* gPubBadge = nil;  // gPubMu
static std::atomic<bool> gPubActive{false};

static void PublishName() {
  NSString* name = NSRunningApplication.currentApplication.localizedName;
  std::lock_guard<std::mutex> l(gPubMu);
  gPubName = [name copy];
}

static void PublishBadge() {
  NSString* badge = NSApp.dockTile.badgeLabel;
  std::lock_guard<std::mutex> l(gPubMu);
  gPubBadge = [badge copy];
}

static bool WindowOnGlass(NSWindow* win) {
  return (win.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

// The content rect, top-left global coordinates, points.
static PubWindow WindowStateOf(NSWindow* win) {
  NSRect content = ContentViewScreenRect(win);
  PubWindow s;
  s.x = content.origin.x;
  s.y = PrimaryScreenTop() - (content.origin.y + content.size.height);
  s.width = content.size.width;
  s.height = content.size.height;
  s.scale = win.backingScaleFactor;
  s.visible = win.isVisible;
  // visible but with no pixel on glass: fully behind another app's window
  s.occluded = win.isVisible && !WindowOnGlass(win);
  s.key = win.isKeyWindow;
  s.ignoresMouseEvents = win.ignoresMouseEvents;
  s.liveResize = win.inLiveResize;
  return s;
}

// getWindowFrame's shape.
static Napi::Object WindowStateObject(Napi::Env env, const PubWindow& s) {
  Napi::Object r = Napi::Object::New(env);
  r.Set("x", s.x);
  r.Set("y", s.y);
  r.Set("width", s.width);
  r.Set("height", s.height);
  r.Set("scale", s.scale);
  r.Set("visible", s.visible);
  r.Set("occluded", s.occluded);
  r.Set("key", s.key);
  r.Set("ignoresMouseEvents", s.ignoresMouseEvents);
  r.Set("liveResize", s.liveResize);
  return r;
}

static void PublishWindow(NSWindow* win) {
  PubWindow s = WindowStateOf(win);
  long number = (long)win.windowNumber;
  std::lock_guard<std::mutex> l(gPubMu);
  gPubWindows[number] = s;
}

// At a live resize's two ends, where the flag is said rather than read back:
// the notifications bracket the resize, and inLiveResize at exactly those
// instants is AppKit's to decide.
static void PublishWindowLiveResize(NSWindow* win, bool live) {
  PubWindow s = WindowStateOf(win);
  s.liveResize = live;
  long number = (long)win.windowNumber;
  std::lock_guard<std::mutex> l(gPubMu);
  gPubWindows[number] = s;
}

static void ForgetWindow(long number) {
  std::lock_guard<std::mutex> l(gPubMu);
  gPubWindows.erase(number);
}

static bool PublishedWindow(long number, PubWindow* out) {
  if (!number) return false;
  std::lock_guard<std::mutex> l(gPubMu);
  auto it = gPubWindows.find(number);
  if (it == gPubWindows.end()) return false;
  *out = it->second;
  return true;
}

// For addon.mm's windowIsVisible on a worker's window.
bool CALWindowVisible(long number, bool* visible) {
  PubWindow s;
  if (!PublishedWindow(number, &s)) return false;
  *visible = s.visible;
  return true;
}

// A worker's window handle, or nil for anything else (pump mode's window
// itself included).
static CALHandle* WindowHandleOf(id target) {
  return [target isKindOfClass:[CALHandle class]] ? (CALHandle*)target : nil;
}

static std::vector<PubScreen> ScreensNow() {
  CGFloat top = PrimaryScreenTop();
  std::vector<PubScreen> out;
  NSArray<NSScreen*>* screens = NSScreen.screens;
  for (NSUInteger i = 0; i < screens.count; i++) {
    NSScreen* s = screens[i];
    NSRect f = s.frame, v = s.visibleFrame;
    // the panel's own refresh rate, so a renderer paces frames on the
    // display's period instead of assuming 60Hz on a 120Hz ProMotion
    // panel; 0 where the OS cannot say (before macOS 12)
    double fps = 0;
    if (@available(macOS 12.0, *)) fps = (double)s.maximumFramesPerSecond;
    out.push_back({f.origin.x, top - (f.origin.y + f.size.height), f.size.width,
                   f.size.height, v.origin.x, top - (v.origin.y + v.size.height),
                   v.size.width, v.size.height, s.backingScaleFactor, fps, i == 0});
  }
  return out;
}

// listScreens' shape.
static Napi::Array ScreensArray(Napi::Env env, const std::vector<PubScreen>& screens) {
  Napi::Array out = Napi::Array::New(env, screens.size());
  for (size_t i = 0; i < screens.size(); i++) {
    const PubScreen& s = screens[i];
    Napi::Object o = Napi::Object::New(env);
    o.Set("x", s.x);
    o.Set("y", s.y);
    o.Set("width", s.width);
    o.Set("height", s.height);
    Napi::Object work = Napi::Object::New(env);
    work.Set("x", s.vx);
    work.Set("y", s.vy);
    work.Set("width", s.vwidth);
    work.Set("height", s.vheight);
    o.Set("visible", work);
    o.Set("scale", s.scale);
    o.Set("fps", s.fps);
    o.Set("primary", s.primary);
    out.Set((uint32_t)i, o);
  }
  return out;
}

static void PublishScreens() {
  std::vector<PubScreen> screens = ScreensNow();
  std::lock_guard<std::mutex> l(gPubMu);
  gPubScreens = std::move(screens);
}

static A11yOptions A11yOptionsNow() {
  NSWorkspace* ws = NSWorkspace.sharedWorkspace;
  return {(bool)ws.accessibilityDisplayShouldReduceMotion,
          (bool)ws.accessibilityDisplayShouldReduceTransparency,
          (bool)ws.accessibilityDisplayShouldIncreaseContrast,
          (bool)ws.accessibilityDisplayShouldDifferentiateWithoutColor,
          (bool)ws.accessibilityDisplayShouldInvertColors};
}

static void A11yFields(CALEvent& r, const A11yOptions& a) {
  r.Bool("reduceMotion", a.reduceMotion);
  r.Bool("reduceTransparency", a.reduceTransparency);
  r.Bool("increaseContrast", a.increaseContrast);
  r.Bool("differentiateWithoutColor", a.differentiateWithoutColor);
  r.Bool("invertColors", a.invertColors);
}

static void PublishA11y(const A11yOptions& a) {
  std::lock_guard<std::mutex> l(gPubMu);
  gPubA11y = a;
}

static void PublishPasteboardCount() {
  gPubPasteboardCount = (long)NSPasteboard.generalPasteboard.changeCount;
}

// Everything the app as a whole publishes, once it is launched (BEnsureApp);
// the screen list again whenever the arrangement or a resolution changes.
static id gScreensObserver = nil;

static id gActiveObserver = nil, gInactiveObserver = nil;

static void BPublishAppState() {
  PublishScreens();
  PublishA11y(A11yOptionsNow());
  gPubPolicy = (int)NSApp.activationPolicy;
  PublishPasteboardCount();
  PublishName();
  PublishBadge();
  gPubActive = NSApp.isActive;
  if (gScreensObserver) return;
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  gScreensObserver =
      [nc addObserverForName:NSApplicationDidChangeScreenParametersNotification
                      object:NSApp
                       queue:nil
                  usingBlock:^(NSNotification*) { PublishScreens(); }];
  gActiveObserver =
      [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                      object:NSApp
                       queue:nil
                  usingBlock:^(NSNotification*) { gPubActive = true; }];
  gInactiveObserver =
      [nc addObserverForName:NSApplicationDidResignActiveNotification
                      object:NSApp
                       queue:nil
                  usingBlock:^(NSNotification*) { gPubActive = false; }];
}

// windowState(windowNumber) -> { x, y, width, height, scale, visible,
// occluded, key, ignoresMouseEvents } — getWindowFrame's answer for a
// createWindow2 window, as the UI thread last published it; null for a
// number this bridge has no window for. Any thread.
static Napi::Value WindowStateFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "windowState(windowNumber): a number is required")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  long number = (long)info[0].As<Napi::Number>().Int64Value();
  PubWindow s;
  if (!PublishedWindow(number, &s)) return env.Null();
  return WindowStateObject(env, s);
}

// ---------------------------------------------------------------------------
// app lifecycle: what the OS asks the application as a whole
// ---------------------------------------------------------------------------
//
// A URL for a scheme the bundle registers (kInternetEventClass/kAEGetURL),
// a document handed over by the Finder (kCoreEventClass/kAEOpenDocuments),
// a second launch of a running app (kAEReopenApplication) and Quit from the
// Dock, the app menu or a logout (kAEQuitApplication) all reach the process
// as Apple Events, which AppKit turns into NSApplicationDelegate calls. The
// delegate forwards them as backend events and decides nothing itself, the
// same rule windowShouldClose follows:
//
//   app-open-urls     { urls: [string] }     scheme URLs as sent, documents
//                                            as file:// URLs
//   app-reopen        { hasVisibleWindows }  the Dock tile clicked again
//   app-quit-request  {}                     terminate: was asked for; the
//                                            renderer exits or vetoes
//
// Two timing facts shape the code. Launch Services delivers the launching
// event inside finishLaunching, so the delegate goes in before that call
// (BEnsureApp). And initApp() runs before setBackendEventCallback(), so
// whatever arrives with nobody listening is held here and replayed on the
// first pump that has a listener — or as runMain opens the channel — in
// arrival order, ahead of that pump's NSEvents. Registering the scheme itself (CFBundleURLTypes) is an
// Info.plist matter for the app bundle, not runtime code.

enum class AppEventKind { OpenURLs, Reopen, QuitRequest };

struct PendingAppEvent {
  explicit PendingAppEvent(AppEventKind k) : kind(k) {}
  AppEventKind kind;
  std::vector<std::string> urls;   // OpenURLs
  bool hasVisibleWindows = false;  // Reopen
};
static std::vector<PendingAppEvent> gPendingAppEvents;

static CALEvent AppEventRecord(const PendingAppEvent& p) {
  switch (p.kind) {
    case AppEventKind::OpenURLs: {
      CALEvent ev("app-open-urls");
      ev.Strs("urls", p.urls);
      return ev;
    }
    case AppEventKind::Reopen: {
      CALEvent ev("app-reopen");
      ev.Bool("hasVisibleWindows", p.hasVisibleWindows);
      return ev;
    }
    case AppEventKind::QuitRequest:
      break;
  }
  return CALEvent("app-quit-request");
}

// Now if anyone is listening, else held for the pump (or the run) that
// finds a listener.
static void EmitAppEvent(PendingAppEvent&& p) {
  if (!CALListening()) {
    gPendingAppEvents.push_back(std::move(p));
    return;
  }
  CALEmit(AppEventRecord(p));
}

static void FlushPendingAppEvents() {
  if (gPendingAppEvents.empty() || !CALListening()) return;
  // moved out first: a handler may pump, and pumping may hold more
  std::vector<PendingAppEvent> held = std::move(gPendingAppEvents);
  gPendingAppEvents.clear();
  for (const PendingAppEvent& p : held) CALEmit(AppEventRecord(p));
}

@interface CALAppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation CALAppDelegate
// One entry point for both Apple Events since 10.13 (NSApplication.h: every
// CFBundleURLTypes URL and every document type without an NSDocument class
// comes here, and application:openFiles: is then never called). No
// replyToOpenOrPrint: is owed on this path; that is openFiles:' contract.
- (void)application:(NSApplication*)app openURLs:(NSArray<NSURL*>*)urls {
  (void)app;
  PendingAppEvent p(AppEventKind::OpenURLs);
  for (NSURL* u in urls) {
    NSString* s = u.absoluteString;
    if (s) p.urls.push_back(s.UTF8String);
  }
  if (!p.urls.empty()) EmitAppEvent(std::move(p));
}
- (BOOL)applicationShouldHandleReopen:(NSApplication*)app
                    hasVisibleWindows:(BOOL)flag {
  (void)app;
  PendingAppEvent p(AppEventKind::Reopen);
  p.hasVisibleWindows = flag;
  EmitAppEvent(std::move(p));
  return NO;  // what a second launch means is the renderer's call
}
// With nobody listening the OS default stands and the process ends here,
// as it always has. With a listener the request is theirs to act on, and
// quitting is a process.exit on their side (in threaded mode, requestExit
// and the main thread's process.exit). Never NSTerminateLater: AppKit would
// spin its own run loop waiting for the reply, and in pump mode this
// process is pumped from JS, not run by AppKit.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)app {
  (void)app;
  if (!CALListening()) return NSTerminateNow;
  EmitAppEvent(PendingAppEvent(AppEventKind::QuitRequest));
  return NSTerminateCancel;
}
// The Dock tile's menu (right-click or press-and-hold), asked for on every
// open; the spec behind it comes from setDockMenu in the menu section.
- (NSMenu*)applicationDockMenu:(NSApplication*)app {
  (void)app;
  return gDockMenu;
}
@end

// NSApp.delegate is unretained; this is the retain.
static CALAppDelegate* gAppDelegate = nil;

static void BInstallAppDelegate() {
  if (!gAppDelegate) gAppDelegate = [CALAppDelegate new];
  NSApp.delegate = gAppDelegate;
}

// ---------------------------------------------------------------------------
// accessibility display options: reduce motion and its siblings
// ---------------------------------------------------------------------------
//
// System Settings › Accessibility › Display, as NSWorkspace reports it
// (windowkit/appkit#31). The query answers synchronously; a change arrives as
// a backend event from NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification,
// which AppKit posts on the main thread as the pump runs the run loop. Nothing
// is held for a listener that is not there yet: a setting is a fact rather
// than a message, so a renderer reads it when it installs its callback and
// hears of changes from then on. Mechanism only — what a renderer does with
// reduceMotion (react-x11: loops never start, transitions still run) is its
// own call.

// accessibilityDisplayOptions() -> { reduceMotion, reduceTransparency,
// increaseContrast, differentiateWithoutColor, invertColors }
static Napi::Value AccessibilityDisplayOptionsFn(const Napi::CallbackInfo& info) {
  A11yOptions a;
  if (ReadPublished()) {
    std::lock_guard<std::mutex> l(gPubMu);
    a = gPubA11y;
  } else {
    a = A11yOptionsNow();
  }
  CALEvent r;
  A11yFields(r, a);
  return r.ToObject(info.Env());
}

// The observer is installed once, with the app (BEnsureApp), so it is in
// place before any callback could be. Its block runs on the main queue,
// which the main run loop drains inside a pump — where a call into JS is
// legal, the same place a window delegate's methods fire.
static id gAccessibilityObserver = nil;

static void BInstallAccessibilityObserver() {
  if (gAccessibilityObserver) return;
  gAccessibilityObserver = [NSWorkspace.sharedWorkspace.notificationCenter
      addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* n) {
                (void)n;
                A11yOptions a = A11yOptionsNow();
                PublishA11y(a);
                if (!CALListening()) return;
                CALEvent ev;
                A11yFields(ev, a);
                ev.Str("type", "accessibility-display-changed");
                CALEmit(std::move(ev));
              }];
}

// postAccessibilityDisplayChange() — the notification the system would post,
// posted from here through the same centre, so the observer path can be
// exercised without touching the user's settings. Test-only, like
// postAppleEvent; the values it carries are whatever the settings are.
// A command: the centre calls its observers on the posting thread, and
// AppKit's own (the menu bar's) rebuilds the main menu there — from a
// worker that is an NSInternalInconsistencyException abort.
static Napi::Value PostAccessibilityDisplayChange(const Napi::CallbackInfo& info) {
  CALOnUI(^{
    BEnsureApp();
    [NSWorkspace.sharedWorkspace.notificationCenter
        postNotificationName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                      object:NSWorkspace.sharedWorkspace];
  });
  return info.Env().Undefined();
}

// Window bookkeeping: delegate + view need to reach the JS callback with the
// window's number attached, and windowShouldClose needs to answer NO while
// telling JS. One delegate class serves every window.

@interface CALBackendDelegate : NSObject <NSWindowDelegate> {
 @public
  double handshakeMs_;  // setResizeHandshake's budget; 0 is off
}
@end

// A worker's window carries its handle's id (createWindow2 off the main
// thread), and every event about it names the handle JS holds, so a
// renderer can key its windows on the handle. Pump mode's windows have
// none, and their events are what they always were.
static char kWindowHandleKey;

static void AddWindowHandle(CALEvent& ev, NSWindow* win) {
  NSNumber* id = objc_getAssociatedObject(win, &kWindowHandleKey);
  if (id) ev.HandleRef("handle", id.unsignedLongLongValue);
}

static CALEvent WindowEvent(NSWindow* win, const char* type) {
  CALEvent ev(type);
  ev.Num("windowNumber", (double)win.windowNumber);
  AddWindowHandle(ev, win);
  return ev;
}

static void EmitWindowGeometry(NSWindow* win, const char* type, bool live) {
  PublishWindow(win);
  if (!CALListening()) return;
  CALEvent ev = WindowEvent(win, type);
  NSRect content = ContentViewScreenRect(win);
  ev.Num("width", content.size.width);
  ev.Num("height", content.size.height);
  ev.Num("x", content.origin.x);
  ev.Num("y", PrimaryScreenTop() - (content.origin.y + content.size.height));
  ev.Bool("live", live);
  CALEmit(std::move(ev));
}

// The live-resize handshake (windowkit/appkit#53), after window-resize has
// gone out: wait, bounded, for the renderer's frame at the new size and
// apply it before AppKit commits the resize, then say how it went —
// resize-handshake { windowNumber, handle?, width, height, live, waited
// (ms), met } — which is the renderer's measure of whether its frames keep
// up with the edge.
static void AwaitFrameForResize(NSWindow* win, double waitMs) {
  NSSize size = ContentViewScreenRect(win).size;
  double waited = 0;
  bool met = CALAwaitFrame(size.width, size.height, waitMs, &waited);
  CALEvent ev = WindowEvent(win, "resize-handshake");
  ev.Num("width", size.width).Num("height", size.height);
  ev.Bool("live", win.inLiveResize).Num("waited", waited).Bool("met", met);
  CALEmit(std::move(ev));
}

@implementation CALBackendDelegate
- (void)windowDidResize:(NSNotification*)n {
  NSWindow* win = n.object;
  EmitWindowGeometry(win, "window-resize", win.inLiveResize);
  // threaded mode's: in pump mode the event above ran the renderer inside
  // this very call, and its frame is already in this transaction
  if (handshakeMs_ > 0 && CALThreaded()) AwaitFrameForResize(win, handshakeMs_);
}
- (void)windowDidMove:(NSNotification*)n {
  EmitWindowGeometry((NSWindow*)n.object, "window-move", false);
}
// A live resize's two ends (windowkit/appkit#63). AppKit's tracking loop
// calls windowDidResize: once per pointer move and nothing when the pointer
// stops or lifts, so a renderer that defers its measured layout until the
// drag is over has to be told when it is: window-live-resize { phase:
// 'begin' | 'end' }, in both modes, and liveResize in the published state.
- (void)windowWillStartLiveResize:(NSNotification*)n {
  NSWindow* win = n.object;
  PublishWindowLiveResize(win, true);
  CALEvent ev = WindowEvent(win, "window-live-resize");
  ev.Str("phase", "begin");
  CALEmit(std::move(ev));
}
- (void)windowDidEndLiveResize:(NSNotification*)n {
  NSWindow* win = n.object;
  PublishWindowLiveResize(win, false);
  CALEvent ev = WindowEvent(win, "window-live-resize");
  ev.Str("phase", "end");
  CALEmit(std::move(ev));
}
- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (CALListening()) CALEmit(WindowEvent(sender, "window-close-request"));
  return NO;  // closing is the renderer's decision, never AppKit's
}
- (void)windowDidBecomeKey:(NSNotification*)n {
  NSWindow* win = n.object;
  PublishWindow(win);
  CALEmit(WindowEvent(win, "window-focus"));
}
- (void)windowDidResignKey:(NSNotification*)n {
  NSWindow* win = n.object;
  PublishWindow(win);
  CALEmit(WindowEvent(win, "window-blur"));
}
// A window entirely behind another application's window is still visible
// by isVisible's measure and still costs every frame its tree produces.
// AppKit knows the difference; `visible: false` here means no pixel of the
// window is on glass, so a renderer can hold its frames until one is.
- (void)windowDidChangeOcclusionState:(NSNotification*)n {
  NSWindow* win = n.object;
  PublishWindow(win);
  CALEvent ev = WindowEvent(win, "window-occlusion");
  ev.Bool("visible", WindowOnGlass(win));
  CALEmit(std::move(ev));
}
- (void)windowDidChangeBackingProperties:(NSNotification*)n {
  NSWindow* win = n.object;
  PublishWindow(win);
  CALEvent ev = WindowEvent(win, "window-scale");
  ev.Num("scale", win.backingScaleFactor);
  CALEmit(std::move(ev));
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
  // drag and drop (its own section below): the destination's standing
  // answer, the source's masks and provider, and the press a session is
  // begun from
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
//                 ignoresMouseEvents,     // the pointer passes through (below)
//                 backgroundColor })      // [r,g,b,a] or absent
//
// On the main thread (pump mode) the window is made in the call and the
// window itself is the handle, as always. Off it (a worker, threaded mode)
// the options are read here, a handle is answered at once, and the window is
// made by a command; `window-created { handle, windowNumber }` follows, and
// every event about the window carries `handle`.

// createWindow2's options, read on the calling thread.
struct WindowSpec {
  double w = 640, h = 480;
  std::string kind = "normal", level;
  bool resizable = true;
  NSString* title = nil;
  int hasShadow = -1, opaque = -1, ignoresMouseEvents = -1;  // -1: not given
  bool hasBackground = false;
  double background[4] = {0, 0, 0, 1};
  bool placed = false;
  double x = 0, y = 0;
};

static int BTriOr(Napi::Object o, const char* k, bool d) {
  return o.Has(k) ? (int)BBoolOr(o, k, d) : -1;
}

static WindowSpec ParseWindowSpec(Napi::Object o) {
  WindowSpec s;
  s.w = BNumOr(o, "width", 640);
  s.h = BNumOr(o, "height", 480);
  if (o.Has("kind") && o.Get("kind").IsString())
    s.kind = o.Get("kind").As<Napi::String>().Utf8Value();
  s.resizable = BBoolOr(o, "resizable", true);
  if (o.Has("title") && o.Get("title").IsString())
    s.title = BToNSString(o.Get("title"));
  if (o.Has("level") && o.Get("level").IsString())
    s.level = o.Get("level").As<Napi::String>().Utf8Value();
  s.hasShadow = BTriOr(o, "hasShadow", true);
  s.opaque = BTriOr(o, "opaque", true);
  s.ignoresMouseEvents = BTriOr(o, "ignoresMouseEvents", false);
  if (o.Has("backgroundColor") && o.Get("backgroundColor").IsArray()) {
    Napi::Array a = o.Get("backgroundColor").As<Napi::Array>();
    s.hasBackground = true;
    for (uint32_t i = 0; i < 4 && i < a.Length(); i++)
      s.background[i] = a.Get(i).As<Napi::Number>().DoubleValue();
  }
  if (o.Has("x") && o.Get("x").IsNumber() && o.Has("y") && o.Get("y").IsNumber()) {
    s.placed = true;
    s.x = BNumOr(o, "x", 0);
    s.y = BNumOr(o, "y", 0);
  }
  return s;
}

// On the UI thread, the app launched.
static NSWindow* BuildWindow(const WindowSpec& spec) {
  double w = spec.w, h = spec.h;
  const std::string& kind = spec.kind;
  bool resizable = spec.resizable;

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
    if (spec.title) win.title = spec.title;
    if (spec.level == "popup") win.level = NSPopUpMenuWindowLevel;
    else if (spec.level == "floating") win.level = NSFloatingWindowLevel;
    if (spec.hasShadow >= 0) win.hasShadow = spec.hasShadow;
    if (spec.opaque >= 0) {
      win.opaque = spec.opaque;
      if (!win.opaque) win.backgroundColor = NSColor.clearColor;
    }
    // A window the pointer passes through. The window server hit-tests
    // past it, so a click or a drag reaches whatever is beneath — what a
    // drag preview following the pointer needs. Registering no dragged
    // types is not that: the window under the pointer is found first, an
    // unregistered one is still the one found, and the drag then has no
    // destination at all. Transparent pixels do not pass a hit either.
    if (spec.ignoresMouseEvents >= 0) win.ignoresMouseEvents = spec.ignoresMouseEvents;

    CALBackendView* view = [[CALBackendView alloc] initWithFrame:rect];
    CALayer* root = [CALayer layer];
    root.geometryFlipped = YES;
    [view setLayer:root];
    [view setWantsLayer:YES];
    win.contentView = view;
    root.contentsScale = win.backingScaleFactor;
    if (spec.hasBackground) {
      CGColorRef c = CGColorCreateSRGB(spec.background[0], spec.background[1],
                                       spec.background[2], spec.background[3]);
      root.backgroundColor = c;
      CGColorRelease(c);
    }

    // Placement: explicit top-left global coordinates, or centered.
    if (spec.placed) {
      // y is the CONTENT's top edge in top-left global coordinates.
      [win setFrameOrigin:NSMakePoint(spec.x, PrimaryScreenTop() - spec.y - h)];
    } else {
      [win center];
    }

    CALBackendDelegate* delegate = [[CALBackendDelegate alloc] init];
    win.delegate = delegate;
    objc_setAssociatedObject(win, &kDelegateKey, delegate,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [win makeFirstResponder:view];
    PublishWindow(win);
  }
  return win;
}

static Napi::Value CreateWindow2(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  WindowSpec spec = ParseWindowSpec(info[0].IsObject() ? info[0].As<Napi::Object>()
                                                       : Napi::Object::New(env));
  if (pthread_main_np()) {
    BEnsureApp();
    NSWindow* win = BuildWindow(spec);
    CALUIObjectsChanged(+1);
    return BWrapRetained(env, win);
  }
  CALHandle* h = CALNewHandle();
  h->part_ = CALNewHandle();  // windowRootLayer's, bound with the window
  Napi::Value handle = CALWrapHandle(env, h, true);
  CALUIObjectsChanged(+1);  // counted at the call: this thread's loop is held now
  CALOnUI(^{
    BEnsureApp();
    NSWindow* win = BuildWindow(spec);
    h->object_ = win;
    h->part_->object_ = win.contentView.layer;
    h->number_ = (long)win.windowNumber;
    objc_setAssociatedObject(win, &kWindowHandleKey, @(h->id_),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CALEvent ev("window-created");
    ev.HandleRef("handle", h->id_);
    ev.Num("windowNumber", (double)win.windowNumber);
    CALEmit(std::move(ev));
  });
  return handle;
}

// Runs `body` on the UI thread with the window a verb's first argument
// names: inline for pump mode's window on the main thread, as a command for
// a worker's handle — resolved there, and a no-op before the window is made
// or for anything that is not a window handle.
static void OnWindow(Napi::Value v, void (^body)(NSWindow* win)) {
  id target = CALHandleTarget(v);
  if (!target) return;
  CALOnUI(^{
    NSWindow* win = CALResolve(target);
    if (win) body(win);
  });
}

static double BNumArg(const Napi::CallbackInfo& info, size_t i) {
  return info.Length() > i && info[i].IsNumber()
             ? info[i].As<Napi::Number>().DoubleValue()
             : NAN;
}

// showWindow(win, activate) — map. Popups order front without activating.
static Napi::Value ShowWindowFn(const Napi::CallbackInfo& info) {
  bool activate = info.Length() > 1 && info[1].ToBoolean().Value();
  OnWindow(info[0], ^(NSWindow* win) {
    if (activate) {
      [win makeKeyAndOrderFront:nil];
      [NSApp activateIgnoringOtherApps:YES];
    } else {
      [win orderFrontRegardless];
    }
    PublishWindow(win);
  });
  return info.Env().Undefined();
}

static Napi::Value HideWindowFn(const Napi::CallbackInfo& info) {
  OnWindow(info[0], ^(NSWindow* win) {
    [win orderOut:nil];
    PublishWindow(win);
  });
  return info.Env().Undefined();
}

static Napi::Value SetWindowTitle(const Napi::CallbackInfo& info) {
  NSString* title = BToNSString(info[1]);
  OnWindow(info[0], ^(NSWindow* win) { win.title = title; });
  return info.Env().Undefined();
}

// setWindowIgnoresMouseEvents(win, flag) — createWindow2's option of the
// same name, changed on a live window; the next hit the window server
// resolves honours it.
static Napi::Value SetWindowIgnoresMouseEvents(const Napi::CallbackInfo& info) {
  bool flag = info.Length() > 1 && info[1].ToBoolean().Value();
  OnWindow(info[0], ^(NSWindow* win) {
    win.ignoresMouseEvents = flag;
    PublishWindow(win);
  });
  return info.Env().Undefined();
}

// setWindowFrame(win, x, y, w, h) — any argument may be null to keep it.
// x/y are the content's top-left in global top-left coordinates, points.
static Napi::Value SetWindowFrame(const Napi::CallbackInfo& info) {
  double ax = BNumArg(info, 1), ay = BNumArg(info, 2);
  double aw = BNumArg(info, 3), ah = BNumArg(info, 4);
  OnWindow(info[0], ^(NSWindow* win) {
    NSRect content = ContentViewScreenRect(win);
    double topY = PrimaryScreenTop() - (content.origin.y + content.size.height);
    double x = std::isnan(ax) ? content.origin.x : ax;
    double y = std::isnan(ay) ? topY : ay;
    double w = std::isnan(aw) ? content.size.width : aw;
    double h = std::isnan(ah) ? content.size.height : ah;
    NSRect newContent = NSMakeRect(x, PrimaryScreenTop() - y - h, w, h);
    [win setFrame:[win frameRectForContentRect:newContent] display:YES];
    PublishWindow(win);
  });
  return info.Env().Undefined();
}

// -> { x, y, width, height, scale, visible, occluded, key, ignoresMouseEvents }
// — content rect, top-left global coordinates, points. (windowState reads
// the same shape from the published copy, by window number.) From a worker
// it is that copy: null until the window is made.
static Napi::Value GetWindowFrame(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  id target = CALHandleTarget(info[0]);
  if (!pthread_main_np()) {
    CALHandle* h = WindowHandleOf(target);
    PubWindow s;
    if (!h || !PublishedWindow(h->number_.load(), &s)) return env.Null();
    return WindowStateObject(env, s);
  }
  return WindowStateObject(env, WindowStateOf(CALResolve(target)));
}

// windowNumberAtPoint(x, y, belowWindowNumber?) -> number — the window the
// window server would hand a mouse-down at a global top-left point, any
// application's, or 0 for none. It is the question `ignoresMouseEvents`
// changes the answer to, and where a drag's destination lookup starts. A
// window number in `belowWindowNumber` starts the search beneath that
// window, so walking the answers back in finds what sits under another
// application's window — a lock screen, a floating panel.
// Off the main thread: windowNumberAtPoint(x, y, below?, cb).
static Napi::Value WindowNumberAtPoint(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber() || !info[1].IsNumber()) {
    Napi::TypeError::New(env, "windowNumberAtPoint: x and y must be numbers")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  double x = info[0].As<Napi::Number>().DoubleValue();
  double y = info[1].As<Napi::Number>().DoubleValue();
  NSInteger below = info.Length() > 2 && info[2].IsNumber()
                        ? (NSInteger)info[2].As<Napi::Number>().Int64Value()
                        : 0;
  return CALAnswer(info, "windowNumberAtPoint", ^CALValueBlock {
    BEnsureApp();
    NSInteger hit =
        [NSWindow windowNumberAtPoint:NSMakePoint(x, PrimaryScreenTop() - y)
            belowWindowWithWindowNumber:below];
    return ^Napi::Value(Napi::Env e) { return Napi::Number::New(e, (double)hit); };
  });
}

static Napi::Value SetWindowMinMax(const Napi::CallbackInfo& info) {
  Napi::Object o = info[1].As<Napi::Object>();
  bool setMin = o.Has("minWidth") || o.Has("minHeight");
  bool setMax = o.Has("maxWidth") || o.Has("maxHeight");
  NSSize min = NSMakeSize(BNumOr(o, "minWidth", 0), BNumOr(o, "minHeight", 0));
  NSSize max = NSMakeSize(BNumOr(o, "maxWidth", 100000), BNumOr(o, "maxHeight", 100000));
  OnWindow(info[0], ^(NSWindow* win) {
    if (setMin) win.contentMinSize = min;
    if (setMax) win.contentMaxSize = max;
  });
  return info.Env().Undefined();
}

// setResizeHandshake(win, { waitMs }) — the live-resize handshake
// (windowkit/appkit#53). When the window's size changes, by a live resize or
// a setWindowFrame, the UI thread sends window-resize and then waits, never
// longer than waitMs, for a frame batch committed with that size
// (txCommit({ width, height })), applying it in the same transaction as the
// new size; resize-handshake reports each wait. 0 turns it off, the
// default. Pump mode needs none — its window-resize runs the renderer inside
// windowDidResize: itself — so it acts only while runMain runs.
static Napi::Value SetResizeHandshake(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value v = info[1].IsObject() ? info[1].As<Napi::Object>().Get("waitMs")
                                     : env.Undefined();
  double ms = v.IsNumber() ? v.As<Napi::Number>().DoubleValue() : NAN;
  if (!(ms >= 0) || !std::isfinite(ms)) {
    Napi::TypeError::New(env, "setResizeHandshake(win, { waitMs }): waitMs is a "
                              "number of milliseconds, 0 for off")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  OnWindow(info[0], ^(NSWindow* win) {
    CALBackendDelegate* d = objc_getAssociatedObject(win, &kDelegateKey);
    if (d) d->handshakeMs_ = ms;
  });
  return env.Undefined();
}

static void CancelPanelSheetsOn(NSWindow* win);

static Napi::Value DestroyWindow2(const Napi::CallbackInfo& info) {
  id target = CALHandleTarget(info[0]);
  CALHandle* h = WindowHandleOf(target);
  if (h) {
    // a worker's window is counted out at the call, once
    if (h->released_.exchange(true)) return info.Env().Undefined();
    CALUIObjectsChanged(-1);
  }
  OnWindow(info[0], ^(NSWindow* win) {
    long number = (long)win.windowNumber;
    // a second destroy of the same window counts nothing
    bool live = objc_getAssociatedObject(win, &kDelegateKey) != nil;
    // A sheet whose owner goes away ends without telling its completion
    // handler; answer it as a cancel first so no callback is left waiting.
    CancelPanelSheetsOn(win);
    win.delegate = nil;
    objc_setAssociatedObject(win, &kDelegateKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [win orderOut:nil];
    [win close];
    ForgetWindow(number);
    if (live && !h) CALUIObjectsChanged(-1);
  });
  return info.Env().Undefined();
}

// initApp lives in the app presence section: it takes { activationPolicy }.

static Napi::Value ActivateApp(const Napi::CallbackInfo& info) {
  CALOnUI(^{
    BEnsureApp();
    [NSApp activateIgnoringOtherApps:YES];
  });
  return info.Env().Undefined();
}

// postAppleEvent('open-url', 'scheme://…')
// postAppleEvent('open-documents', ['/path', …])
// postAppleEvent('reopen')
// postAppleEvent('quit')
// The Apple Event Launch Services would send, built here and dispatched
// through NSAppleEventManager as if it had just been dequeued, so AppKit's
// own handler and then the app delegate run on it exactly as for a real
// one. For tests, like postMouseEvent and postKeyEvent. (An AESendMessage
// to the sending process is short-circuited to this same dispatch by the
// Apple Event Manager, minus a spurious errAETimeout on kAEOpenDocuments,
// whose AppKit handler suspends the event to reply later.) No Automation
// permission is involved: nothing leaves the process.
// A command from a worker, whose dispatch failure then goes unreported.
static Napi::Value PostAppleEvent(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsString()) {
    Napi::TypeError::New(env, "postAppleEvent: kind must be a string")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  std::string kind = info[0].As<Napi::String>().Utf8Value();
  NSString* url = nil;
  NSMutableArray<NSString*>* paths = nil;
  if (kind == "open-url") {
    if (!info[1].IsString()) {
      Napi::TypeError::New(env, "postAppleEvent('open-url', url): url must be a string")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    url = BToNSString(info[1]);
  } else if (kind == "open-documents") {
    if (!info[1].IsArray()) {
      Napi::TypeError::New(env, "postAppleEvent('open-documents', paths): paths must be an array")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    paths = [NSMutableArray array];
    Napi::Array a = info[1].As<Napi::Array>();
    for (uint32_t i = 0; i < a.Length(); i++) [paths addObject:BToNSString(a.Get(i))];
  } else if (kind != "reopen" && kind != "quit") {
    Napi::TypeError::New(env, "postAppleEvent: unknown kind '" + kind + "'")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  __block OSErr err = noErr;
  CALOnUI(^{
    BEnsureApp();
    @autoreleasepool {
      NSAppleEventDescriptor* target =
          [NSAppleEventDescriptor currentProcessDescriptor];
      AEEventClass cls = kCoreEventClass;
      AEEventID id = kAEQuitApplication;
      NSAppleEventDescriptor* direct = nil;
      if (url) {
        cls = kInternetEventClass;
        id = kAEGetURL;
        direct = [NSAppleEventDescriptor descriptorWithString:url];
      } else if (paths) {
        id = kAEOpenDocuments;
        direct = [NSAppleEventDescriptor listDescriptor];
        for (NSString* p in paths) {
          NSURL* u = [NSURL fileURLWithPath:p];
          [direct insertDescriptor:[NSAppleEventDescriptor descriptorWithFileURL:u]
                           atIndex:0];  // 0 appends
        }
      } else if (kind == "reopen") {
        id = kAEReopenApplication;
      }
      NSAppleEventDescriptor* ev =
          [NSAppleEventDescriptor appleEventWithEventClass:cls
                                                   eventID:id
                                          targetDescriptor:target
                                                  returnID:kAutoGenerateReturnID
                                             transactionID:kAnyTransactionID];
      if (direct) [ev setParamDescriptor:direct forKeyword:keyDirectObject];
      AppleEvent reply = {typeNull, NULL};
      // the refCon reaches raw C handlers only; AppKit's are Objective-C
      // methods looked up by class and id, but the parameter is non-null
      static char refCon;
      err = [[NSAppleEventManager sharedAppleEventManager]
          dispatchRawAppleEvent:ev.aeDesc
                   withRawReply:&reply
                  handlerRefCon:(SRefCon)&refCon];
      AEDisposeDesc(&reply);
    }
  });
  if (pthread_main_np() && err != noErr) {
    Napi::Error::New(env, "postAppleEvent: dispatch failed (" +
                              std::to_string((int)err) + ")")
        .ThrowAsJavaScriptException();
  }
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// pump2: the enriched event stream
// ---------------------------------------------------------------------------

static bool StatusWindowEvent(NSEvent* e);

// One NSEvent as a backend event. In pump mode pump2 calls this for each
// event it dequeues, before [NSApp sendEvent:]; in threaded mode [NSApp run]
// dequeues, and a local event monitor calls it from the top of that same
// sendEvent: (measured: a monitor fires inside sendEvent:, not at dequeue).
// So both modes see the events AppKit dispatches, and neither sees what a
// nested tracking loop dequeues for itself.
static void DispatchEvent2(NSEvent* e) {
  if (!CALListening()) return;
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
  if ((mouse || crossing) && (!e.window || StatusWindowEvent(e))) return;
  // The press a drag session is begun from (beginDrag): the latest
  // left-button down or drag in the window, recorded before JS sees it so a
  // beginDrag from inside this very callback has it.
  if ((e.type == NSEventTypeLeftMouseDown ||
       e.type == NSEventTypeLeftMouseDragged) &&
      [e.window.contentView isKindOfClass:[CALBackendView class]]) {
    ((CALBackendView*)e.window.contentView)->lastPress_ = e;
  }

  CALEvent ev(type);
  if (e.window) ev.Num("windowNumber", (double)e.window.windowNumber);
  if (e.window) AddWindowHandle(ev, e.window);
  ev.Num("time", e.timestamp * 1000.0);
  // queued behind another move in the same window, it replaces it
  if (strcmp(type, "mousemove") == 0) ev.FoldBy((double)e.window.windowNumber);

  NSEventModifierFlags f = e.modifierFlags;
  ev.Bool("shift", (bool)(f & NSEventModifierFlagShift));
  ev.Bool("control", (bool)(f & NSEventModifierFlagControl));
  ev.Bool("option", (bool)(f & NSEventModifierFlagOption));
  ev.Bool("command", (bool)(f & NSEventModifierFlagCommand));
  ev.Bool("capsLock", (bool)(f & NSEventModifierFlagCapsLock));

  if ((mouse || crossing) && e.window) {
    NSView* v = e.window.contentView;
    NSPoint p = [v convertPoint:e.locationInWindow fromView:nil];
    ev.Num("x", p.x);
    ev.Num("y", v.isFlipped ? p.y : v.bounds.size.height - p.y);
    // and the same point in global top-left coordinates, for popups
    NSRect r = [e.window
        convertRectToScreen:NSMakeRect(e.locationInWindow.x,
                                       e.locationInWindow.y, 0, 0)];
    ev.Num("gx", r.origin.x);
    ev.Num("gy", PrimaryScreenTop() - r.origin.y);
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
    ev.Num("button", (double)xbutton);
    if (e.type == NSEventTypeLeftMouseDown ||
        e.type == NSEventTypeRightMouseDown ||
        e.type == NSEventTypeOtherMouseDown ||
        e.type == NSEventTypeLeftMouseUp ||
        e.type == NSEventTypeRightMouseUp ||
        e.type == NSEventTypeOtherMouseUp) {
      ev.Num("clickCount", (double)e.clickCount);
    }
  }
  if (wheel) {
    ev.Num("dx", e.scrollingDeltaX);
    ev.Num("dy", e.scrollingDeltaY);
    ev.Bool("precise", (bool)e.hasPreciseScrollingDeltas);
    ev.Bool("momentum", e.momentumPhase != NSEventPhaseNone);
  }
  if (key && e.type != NSEventTypeFlagsChanged) {
    ev.Num("keyCode", (double)e.keyCode);
    NSString* chars = e.characters;
    NSString* ignoring = e.charactersIgnoringModifiers;
    if (chars) ev.Str("chars", chars.UTF8String);
    if (ignoring) ev.Str("charsShifted", ignoring.UTF8String);
    if (@available(macOS 10.15, *)) {
      NSString* base = [e charactersByApplyingModifiers:0];
      if (base) ev.Str("charsBase", base.UTF8String);
    }
    ev.Bool("repeat", (bool)e.isARepeat);
  }
  CALEmit(std::move(ev));
}

static Napi::Value SetBackendEventCallback(const Napi::CallbackInfo& info) {
  if (info[0].IsFunction()) {
    gBackendCb = Napi::Persistent(info[0].As<Napi::Function>());
    // A static reference is destructed after the Node environment is gone;
    // deleting it then is a segfault at exit on Node 18. Replacing or
    // clearing it (Reset, above and in the move-assign) still frees the old
    // reference while the environment is alive.
    gBackendCb.SuppressDestruct();
  } else {
    gBackendCb.Reset();
  }
  return info.Env().Undefined();
}

// notifications.mm: responses that arrived before a listener was installed
void CALNotificationsReplayHeld();
// calendars.mm: an EventKit store change from before there was a listener
void CALCalendarsReplayHeld();

// What came before anyone listened, ahead of the input that follows so the
// renderer hears of it first: the launch's URL (or a Dock click), then a
// notification acted on before the callback existed (one that launched the
// app, say), then a calendar store that changed under it. pump2 calls this
// at the top of every tick; runMain as it opens the channel.
void CALReplayHeldEvents() {
  FlushPendingAppEvents();
  CALNotificationsReplayHeld();
  CALCalendarsReplayHeld();
}

static Napi::Value Pump2(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!pthread_main_np()) {
    Napi::Error::New(env, "pump2: the main thread's — in threaded mode [NSApp run] "
                          "dispatches, and a worker listens through connect()")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  BEnsureApp();
  CALReplayHeldEvents();
  @autoreleasepool {
    while (true) {
      NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                      untilDate:[NSDate distantPast]
                                         inMode:NSDefaultRunLoopMode
                                        dequeue:YES];
      if (!e) break;
      DispatchEvent2(e);
      [NSApp sendEvent:e];
    }
    [CATransaction flush];
  }
  return env.Undefined();
}

// Threaded mode's side of the same stream (threaded.mm's runMain brackets
// [NSApp run] with these): the local monitor that hands each dispatched
// event to DispatchEvent2, and the pasteboard's change count polled into the
// published state, since nothing announces another app's write. Neither is
// installed in pump mode, where pump2's own loop dispatches.
static id gEventMonitor = nil;
static NSTimer* gPasteboardPoll = nil;

void CALBeginRunMode() {
  gEventMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskAny
                                            handler:^NSEvent*(NSEvent* e) {
                                              DispatchEvent2(e);
                                              return e;
                                            }];
  gPasteboardPoll = [NSTimer timerWithTimeInterval:0.25
                                           repeats:YES
                                             block:^(NSTimer*) {
                                               PublishPasteboardCount();
                                             }];
  gPasteboardPoll.tolerance = 0.1;
  [NSRunLoop.mainRunLoop addTimer:gPasteboardPoll forMode:NSRunLoopCommonModes];
}

void CALEndRunMode() {
  if (gEventMonitor) [NSEvent removeMonitor:gEventMonitor];
  gEventMonitor = nil;
  [gPasteboardPoll invalidate];
  gPasteboardPoll = nil;
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

// blitSurface(src, sx, sy, w, h, dst, dx, dy, clip?) -> [x, y, w, h] | null
// A row memcpy of a rect of one surface into another, at surfaces of any
// two sizes. copySurfaceRegion is the same-size special case a swapchain
// wants; this is the general one, for a caller compositing an offscreen
// surface into a window at a translate — a terminal's grid, an element's
// retained scene — where drawSurface builds a CGImage of the whole source
// and blends it. On an M1 Pro, a 2000x1620 grid into a window-sized
// surface: 1.2ms that way, 0.42ms this way.
//
// Straight copy, no blending, alpha included: this is the `copy` op, and a
// caller reaches it by setting that blend mode and drawing at 1:1 under a
// translate-only transform. Coordinates are device pixels with a top-left
// origin — the convention createSurface's CTM gives user space, and the one
// copySurfaceRegion's rects already use. Neither the destination's CTM nor
// its clip is visible to a memcpy, so `clip`, when given, is [x, y, w, h] in
// the DESTINATION's pixels and the caller passes the clip it is drawing
// under; a damage region of several rects is several calls. The rect copied
// is the destination rect intersected with that clip and with both surfaces'
// bounds, the source origin moving with it — returned, or null when the
// intersection is empty and nothing moved.
//
// When either surface is IOSurface-backed the caller owes the usual
// surfaceLock bracketing. Two handles onto one bitmap are refused:
// overlapping memcpy rows have no defined result, and the check is on the
// backing store, not the handle, so the two ends of a shared IOSurface do
// not slip through as different handles.
static Napi::Value BlitSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALSurface* src = SurfaceFrom(info[0]);
  if (!src) return env.Null();
  CALSurface* dst = SurfaceFrom(info[5]);
  if (!dst) return env.Null();

  const uint8_t* sbase = (const uint8_t*)CGBitmapContextGetData(src->ctx);
  uint8_t* dbase = (uint8_t*)CGBitmapContextGetData(dst->ctx);
  if (!sbase || !dbase) return env.Null();
  if (sbase == dbase) {
    Napi::Error::New(env, "blitSurface: source and destination are one bitmap")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  long sx = (long)info[1].As<Napi::Number>().Int64Value();
  long sy = (long)info[2].As<Napi::Number>().Int64Value();
  long w = (long)info[3].As<Napi::Number>().Int64Value();
  long h = (long)info[4].As<Napi::Number>().Int64Value();
  long dx = (long)info[6].As<Napi::Number>().Int64Value();
  long dy = (long)info[7].As<Napi::Number>().Int64Value();

  // the destination rect trimmed to the clip, the source origin moving by
  // whatever each edge takes off
  if (info.Length() > 8 && !info[8].IsNull() && !info[8].IsUndefined()) {
    if (!info[8].IsArray() || info[8].As<Napi::Array>().Length() < 4) {
      Napi::TypeError::New(env, "blitSurface: clip must be [x, y, w, h]")
          .ThrowAsJavaScriptException();
      return env.Null();
    }
    Napi::Array clip = info[8].As<Napi::Array>();
    long cx = (long)clip.Get((uint32_t)0).As<Napi::Number>().Int64Value();
    long cy = (long)clip.Get((uint32_t)1).As<Napi::Number>().Int64Value();
    long cw = (long)clip.Get((uint32_t)2).As<Napi::Number>().Int64Value();
    long ch = (long)clip.Get((uint32_t)3).As<Napi::Number>().Int64Value();
    if (dx < cx) { long over = cx - dx; sx += over; dx += over; w -= over; }
    if (dy < cy) { long over = cy - dy; sy += over; dy += over; h -= over; }
    if (dx + w > cx + cw) w = cx + cw - dx;
    if (dy + h > cy + ch) h = cy + ch - dy;
  }
  // and to both surfaces
  if (sx < 0) { dx -= sx; w += sx; sx = 0; }
  if (sy < 0) { dy -= sy; h += sy; sy = 0; }
  if (dx < 0) { sx -= dx; w += dx; dx = 0; }
  if (dy < 0) { sy -= dy; h += dy; dy = 0; }
  if (sx + w > (long)src->width) w = (long)src->width - sx;
  if (sy + h > (long)src->height) h = (long)src->height - sy;
  if (dx + w > (long)dst->width) w = (long)dst->width - dx;
  if (dy + h > (long)dst->height) h = (long)dst->height - dy;
  if (w <= 0 || h <= 0) return env.Null();

  size_t srow = CGBitmapContextGetBytesPerRow(src->ctx);
  size_t drow = CGBitmapContextGetBytesPerRow(dst->ctx);
  for (long r = 0; r < h; r++) {
    memcpy(dbase + (size_t)(dy + r) * drow + (size_t)dx * 4,
           sbase + (size_t)(sy + r) * srow + (size_t)sx * 4, (size_t)w * 4);
  }
  Napi::Array out = Napi::Array::New(env, 4);
  out.Set((uint32_t)0, (double)dx);
  out.Set((uint32_t)1, (double)dy);
  out.Set((uint32_t)2, (double)w);
  out.Set((uint32_t)3, (double)h);
  return out;
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
  const char* source_;  // "main" | "dock" | "status": which menu tree the item is in
}
- (void)activate:(NSMenuItem*)sender;
@end
@implementation CALMenuTarget
- (void)activate:(NSMenuItem*)sender {
  CALEvent ev("menu-activate");
  ev.Num("id", (double)sender.tag);
  // ids are the caller's; the trees may allocate them independently
  ev.Str("menu", source_);
  CALEmit(std::move(ev));
}
@end

// One target per menu tree, so an activation says which tree it came from.
static CALMenuTarget* gMenuTarget = nil;      // NSApp.mainMenu
static CALMenuTarget* gDockMenuTarget = nil;  // the Dock menu
static CALMenuTarget* gStatusMenuTarget = nil;  // status-item (tray) menus

static CALMenuTarget* MenuTargetFor(CALMenuTarget* __strong* slot,
                                    const char* source) {
  if (!*slot) *slot = [CALMenuTarget new];
  (*slot)->source_ = source;
  return *slot;
}

// A menu spec, read on the calling thread and built into NSMenus on the UI
// thread — in the call in pump mode, by a command from a worker — since an
// NSMenu touched off the main thread (the main menu's above all) is an
// NSInternalInconsistencyException.
struct MenuItemSpec {
  bool separator = false;
  NSString* title = @"";
  NSInteger tag = 0;
  bool enabled = true, hidden = false, checked = false;
  NSString* key = @"";
  NSUInteger modifiers = NSEventModifierFlagCommand;
  NSString* iconName = @"";
  NSData* iconData = nil;
  bool hasItems = false;  // a non-empty `items`: a submenu, not an action
  std::vector<MenuItemSpec> items;
};

static std::vector<MenuItemSpec> ParseMenuItems(Napi::Array items);

static MenuItemSpec ParseMenuItem(Napi::Object o) {
  MenuItemSpec s;
  s.separator = BBoolOr(o, "separator", false);
  if (s.separator) return s;
  s.title = BStrOr(o, "title", @"");
  s.tag = (NSInteger)BNumOr(o, "id", 0);
  s.enabled = BBoolOr(o, "enabled", true);
  s.hidden = BBoolOr(o, "hidden", false);
  s.checked = BBoolOr(o, "checked", false);
  s.key = BStrOr(o, "key", @"");
  s.modifiers = (NSUInteger)BNumOr(o, "modifiers", NSEventModifierFlagCommand);
  s.iconName = BStrOr(o, "iconName", @"");
  if (o.Has("iconData")) {
    Napi::Value v = o.Get("iconData");
    if (v.IsBuffer()) {
      Napi::Buffer<uint8_t> buf = v.As<Napi::Buffer<uint8_t>>();
      s.iconData = [NSData dataWithBytes:buf.Data() length:buf.Length()];
    }
  }
  if (o.Has("items")) {
    Napi::Value v = o.Get("items");
    if (v.IsArray() && v.As<Napi::Array>().Length() > 0) {
      s.hasItems = true;
      s.items = ParseMenuItems(v.As<Napi::Array>());
    }
  }
  return s;
}

static std::vector<MenuItemSpec> ParseMenuItems(Napi::Array items) {
  std::vector<MenuItemSpec> out;
  for (uint32_t i = 0; i < items.Length(); i++) {
    Napi::Value v = items.Get(i);
    if (v.IsObject()) out.push_back(ParseMenuItem(v.As<Napi::Object>()));
  }
  return out;
}

static NSMenu* BuildMenu(const std::vector<MenuItemSpec>& items,
                         CALMenuTarget* target);

static NSMenuItem* BuildMenuItem(const MenuItemSpec& s, CALMenuTarget* target) {
  if (s.separator) return [NSMenuItem separatorItem];
  NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:s.title
                                              action:nil
                                       keyEquivalent:@""];
  it.tag = s.tag;
  it.enabled = s.enabled;
  it.hidden = s.hidden;
  it.state = s.checked ? NSControlStateValueOn : NSControlStateValueOff;
  if (s.key.length) {
    it.keyEquivalent = s.key;
    it.keyEquivalentModifierMask = s.modifiers;
  }
  // Icons, the serialisable pair from the dbusmenu vocabulary. `iconName`
  // is read in the platform's own icon theme — SF Symbols — which renders
  // as a template and follows the menu's appearance for free; a name the
  // symbol catalogue does not know simply misses (a freedesktop name on
  // its way to a Linux panel does the same in reverse). `iconData` is
  // literal pixels (PNG bytes on the bus) and is the fallback.
  NSImage* icon = nil;
  if (s.iconName.length) {
    icon = [NSImage imageWithSystemSymbolName:s.iconName
                     accessibilityDescription:nil];
  }
  if (!icon && s.iconData) {
    icon = [[NSImage alloc] initWithData:s.iconData];
    if (icon) icon.size = NSMakeSize(16, 16);
  }
  if (icon) it.image = icon;
  if (s.hasItems) {
    NSMenu* sub = BuildMenu(s.items, target);
    sub.title = it.title;
    it.submenu = sub;
  } else {
    it.target = target;
    it.action = @selector(activate:);
  }
  return it;
}

static NSMenu* BuildMenu(const std::vector<MenuItemSpec>& items,
                         CALMenuTarget* target) {
  NSMenu* m = [[NSMenu alloc] initWithTitle:@""];
  // we own enabled/hidden; AppKit's validation would grey everything whose
  // target it cannot interrogate
  m.autoenablesItems = NO;
  for (const MenuItemSpec& s : items) [m addItem:BuildMenuItem(s, target)];
  return m;
}

// setMainMenu(spec) — spec: [{title, items: [...]}, ...]. Entry 0 is the
// app menu (macOS shows the process name for its title regardless).
static Napi::Value SetMainMenuFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Array spec = info[0].As<Napi::Array>();
  std::vector<std::pair<NSString*, std::vector<MenuItemSpec>>> menus;
  for (uint32_t i = 0; i < spec.Length(); i++) {
    Napi::Value v = spec.Get(i);
    if (!v.IsObject()) continue;
    Napi::Object m = v.As<Napi::Object>();
    Napi::Value items = m.Get("items");
    menus.emplace_back(BStrOr(m, "title", @""),
                       items.IsArray() ? ParseMenuItems(items.As<Napi::Array>())
                                       : std::vector<MenuItemSpec>());
  }
  CALOnUI(^{
    BEnsureApp();
    CALMenuTarget* target = MenuTargetFor(&gMenuTarget, "main");
    NSMenu* main = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    main.autoenablesItems = NO;
    for (const auto& m : menus) {
      NSMenuItem* holder = [[NSMenuItem alloc] initWithTitle:m.first
                                                      action:nil
                                               keyEquivalent:@""];
      NSMenu* sub = BuildMenu(m.second, target);
      sub.autoenablesItems = NO;
      sub.title = m.first;
      holder.submenu = sub;
      [main addItem:holder];
    }
    [NSApp setMainMenu:main];
  });
  return env.Undefined();
}

// A menu tree as plain data, read on the UI thread and made into JS on the
// caller's: mainMenuInfo's shape.
struct MenuInfoData {
  struct Item {
    std::string title, key;
    double id;
    bool enabled, hidden, separator, checked, hasImage;
    std::shared_ptr<MenuInfoData> submenu;
  };
  std::string title;
  std::vector<Item> items;
};

static std::shared_ptr<MenuInfoData> MenuInfoOf(NSMenu* menu) {
  auto out = std::make_shared<MenuInfoData>();
  out->title = menu.title.UTF8String ?: "";
  for (NSInteger i = 0; i < menu.numberOfItems; i++) {
    NSMenuItem* it = [menu itemAtIndex:i];
    MenuInfoData::Item io;
    io.title = it.title.UTF8String ?: "";
    io.id = (double)it.tag;
    io.enabled = it.enabled;
    io.hidden = it.hidden;
    io.separator = it.separatorItem;
    io.checked = it.state == NSControlStateValueOn;
    io.hasImage = it.image != nil;
    io.key = it.keyEquivalent.UTF8String ?: "";
    if (it.submenu) io.submenu = MenuInfoOf(it.submenu);
    out->items.push_back(std::move(io));
  }
  return out;
}

static Napi::Object MenuInfoValue(Napi::Env env, const MenuInfoData& m) {
  Napi::Object out = Napi::Object::New(env);
  out.Set("title", m.title);
  Napi::Array arr = Napi::Array::New(env, m.items.size());
  for (size_t i = 0; i < m.items.size(); i++) {
    const MenuInfoData::Item& it = m.items[i];
    Napi::Object io = Napi::Object::New(env);
    io.Set("title", it.title);
    io.Set("id", it.id);
    io.Set("enabled", it.enabled);
    io.Set("hidden", it.hidden);
    io.Set("separator", it.separator);
    io.Set("checked", it.checked);
    io.Set("hasImage", it.hasImage);
    io.Set("key", it.key);
    if (it.submenu) io.Set("submenu", MenuInfoValue(env, *it.submenu));
    arr.Set((uint32_t)i, io);
  }
  out.Set("items", arr);
  return out;
}

// What a menu read answers: the tree as data, or null for no menu.
static CALValueBlock MenuInfoAnswer(NSMenu* menu) {
  std::shared_ptr<MenuInfoData> data = menu ? MenuInfoOf(menu) : nullptr;
  return ^Napi::Value(Napi::Env e) {
    return data ? Napi::Value(MenuInfoValue(e, *data)) : Napi::Value(e.Null());
  };
}

// mainMenuInfo(cb?) — the installed menu bar as data, for tests.
static Napi::Value MainMenuInfoFn(const Napi::CallbackInfo& info) {
  return CALAnswer(info, "mainMenuInfo", ^CALValueBlock {
    return MenuInfoAnswer([NSApp mainMenu]);
  });
}

// An index path into a menu tree, read on the calling thread.
static std::vector<NSInteger> MenuPathArg(Napi::Value v) {
  std::vector<NSInteger> path;
  if (!v.IsArray()) return path;
  Napi::Array a = v.As<Napi::Array>();
  for (uint32_t i = 0; i < a.Length(); i++)
    path.push_back((NSInteger)a.Get(i).As<Napi::Number>().Int64Value());
  return path;
}

// Walk a menu tree by index and fire the leaf's action the way tracking
// would (shared by the main menu and status item test hooks).
static bool ActivateInMenu(NSMenu* menu, const std::vector<NSInteger>& path) {
  if (!menu || path.empty()) return false;
  for (size_t d = 0; d + 1 < path.size(); d++) {
    NSInteger i = path[d];
    if (i < 0 || i >= menu.numberOfItems) return false;
    menu = [menu itemAtIndex:i].submenu;
    if (!menu) return false;
  }
  NSInteger leaf = path.back();
  if (leaf < 0 || leaf >= menu.numberOfItems) return false;
  [menu performActionForItemAtIndex:leaf];
  return true;
}

static CALValueBlock BoolAnswer(bool ok) {
  return ^Napi::Value(Napi::Env e) { return Napi::Boolean::New(e, ok); };
}

// activateMenuItem([i, j, ...], cb?) -> bool — walk the installed bar by
// index and fire the leaf's action, the way tracking would. For tests.
static Napi::Value ActivateMenuItemFn(const Napi::CallbackInfo& info) {
  std::vector<NSInteger> path = MenuPathArg(info[0]);
  return CALAnswer(info, "activateMenuItem", ^CALValueBlock {
    return BoolAnswer(ActivateInMenu([NSApp mainMenu], path));
  });
}

// ---------------------------------------------------------------------------
// status items — NSStatusItem, the menu-bar extra (the "tray"). The cocoa
// counterpart of the freedesktop StatusNotifierItem: an icon or a title in
// the system status bar, a tooltip, and either a menu or clicks. The menu
// is the same item spec setMainMenu takes, so the tray, the menu bar and a
// Linux panel share one authoring model; activations arrive as the same
// `menu-activate` events. Without a menu a click is the renderer's to
// answer: it arrives as `status-item-click` with the button's screen rect,
// which is the anchor a custom popup wants.
//
// Lifetime is explicit. The handle retains the NSStatusItem, and the item's
// target keeps the handle alive until removeStatusItem, so an item stays in
// the bar exactly as long as JS says — AppKit would otherwise drop it the
// moment the last reference went.
// ---------------------------------------------------------------------------

@interface CALStatusItemTarget : NSObject {
 @public
  // the JS handle: events carry this very object, so `ev.statusItem ===
  // item` holds and a renderer can key a Map on it
  Napi::Reference<Napi::Value> handle_;
  uint64_t handleId_;  // a worker's item: its CALHandle's id instead (0: none)
  NSStatusItem* __weak item_;
}
- (void)click:(id)sender;
@end

static char kStatusTargetKey;
static NSMapTable<NSNumber*, NSStatusItem*>* gStatusWindows = nil;  // number -> item (weak)

static CALStatusItemTarget* StatusTargetOf(NSStatusItem* item) {
  return objc_getAssociatedObject(item, &kStatusTargetKey);
}

// The status bar hosts each item in a window of its own. Its raw mouse
// events are noise to a renderer (a foreign windowNumber with no tree
// behind it); remember the windows so the pump can skip them — and so it
// can answer the one click AppKit's button ignores (below).
static void RememberStatusWindow(NSWindow* win, NSStatusItem* item) {
  if (!win) return;
  if (!gStatusWindows) gStatusWindows = [NSMapTable strongToWeakObjectsMapTable];
  [gStatusWindows setObject:item forKey:@(win.windowNumber)];
}

// The button's rect in global top-left coordinates, points: x, y, width,
// height. False while the button has no window.
static bool StatusButtonFrame(NSStatusBarButton* btn, double out[4]) {
  if (!btn.window) return false;
  NSRect r = [btn.window convertRectToScreen:[btn convertRect:btn.bounds
                                                        toView:nil]];
  out[0] = r.origin.x;
  out[1] = PrimaryScreenTop() - (r.origin.y + r.size.height);
  out[2] = r.size.width;
  out[3] = r.size.height;
  return true;
}

static void EmitStatusItemClick(CALStatusItemTarget* t, const char* kind,
                                NSEvent* e) {
  NSStatusItem* item = t->item_;
  if (!item || !CALListening()) return;
  CALEvent ev("status-item-click");
  // The item's own handle, looked up as the event is materialized, so
  // `ev.statusItem === item` holds in the environment that created it.
  // Weak: an event still in flight never keeps a removed item's target.
  __weak CALStatusItemTarget* weak = t;
  if (t->handleId_) ev.HandleRef("statusItem", t->handleId_);
  else ev.Handle("statusItem", ^Napi::Value(Napi::Env env) {
    CALStatusItemTarget* target = weak;
    if (!target || target->handle_.IsEmpty() ||
        (napi_env)target->handle_.Env() != (napi_env)env)
      return env.Null();
    return target->handle_.Value();
  });
  ev.Str("kind", kind);
  NSEventModifierFlags f = e ? e.modifierFlags : NSEvent.modifierFlags;
  ev.Bool("shift", (bool)(f & NSEventModifierFlagShift));
  ev.Bool("control", (bool)(f & NSEventModifierFlagControl));
  ev.Bool("option", (bool)(f & NSEventModifierFlagOption));
  ev.Bool("command", (bool)(f & NSEventModifierFlagCommand));
  ev.Num("clickCount", (double)(e ? e.clickCount : 1));
  double r[4];
  if (StatusButtonFrame(item.button, r))
    ev.Num("x", r[0]).Num("y", r[1]).Num("width", r[2]).Num("height", r[3]);
  CALEmit(std::move(ev));
}

// Called by the pump for every mouse event that has a window: true when
// the window is a status item's (the event is then not for JS). NSButton
// tracks the left button, NSStatusBarButton adds the right; neither looks
// at the middle one, so a middle mouse-up over the button is answered
// here — with or without a menu, since AppKit opens the menu for neither.
static bool StatusWindowEvent(NSEvent* e) {
  if (!gStatusWindows) return false;
  NSStatusItem* item = [gStatusWindows objectForKey:@(e.window.windowNumber)];
  if (!item) return false;
  if (e.type == NSEventTypeOtherMouseUp && e.buttonNumber == 2) {
    NSStatusBarButton* btn = item.button;
    NSRect r = [btn convertRect:btn.bounds toView:nil];
    CALStatusItemTarget* t = StatusTargetOf(item);
    if (t && NSPointInRect(e.locationInWindow, r))
      EmitStatusItemClick(t, "middle", e);
  }
  return true;
}

@implementation CALStatusItemTarget
- (void)click:(id)sender {
  (void)sender;
  // the button sends on left and right mouse-up; the event says which
  NSEvent* e = NSApp.currentEvent;
  bool right = e && (e.type == NSEventTypeRightMouseUp ||
                     e.type == NSEventTypeRightMouseDown);
  EmitStatusItemClick(self, right ? "right" : "left", e);
}
@end

// A length: points, 'square' or 'variable'; NAN for anything else (the
// caller keeps what it had).
static double StatusLengthFrom(Napi::Value v) {
  if (v.IsNumber()) return v.As<Napi::Number>().DoubleValue();
  if (v.IsString()) {
    std::string s = v.As<Napi::String>().Utf8Value();
    if (s == "square") return NSSquareStatusItemLength;
    if (s == "variable") return NSVariableStatusItemLength;
  }
  return NAN;
}

// A status item's props, read on the calling thread and applied on the UI
// thread; only the keys present are touched, so setStatusItem's patch is a
// create with fewer keys. `image`: an SF Symbol name (a template by nature —
// it follows the bar's light/dark), a surface handle (its bitmap at its
// scale, copied as it is at the call), or encoded image bytes (PNG and
// friends). Template by default so a bitmap icon adapts the way a symbol
// does; `imageTemplate: false` keeps its colours. `imageSize: [w, h]` sets
// the size in points.
struct StatusItemSpec {
  bool hasImage = false;
  NSString* symbol = nil;
  NSData* bytes = nil;
  id bitmap = nil;  // a CGImage, owned by ARC through the bridge
  double bitmapW = 0, bitmapH = 0;
  bool hasImageSize = false;
  double imageW = 0, imageH = 0;
  bool imageTemplate = true;
  bool hasTitle = false, hasTooltip = false, hasLength = false;
  NSString* title = @"";
  NSString* tooltip = @"";
  double length = NAN;
  int visible = -1;  // -1: not given
};

// False with a TypeError pending (a released surface as the image).
static bool ParseStatusItemSpec(Napi::Object o, StatusItemSpec* s) {
  if (o.Has("image")) {
    s->hasImage = true;
    Napi::Value v = o.Get("image");
    if (v.IsString()) {
      s->symbol = BToNSString(v);
    } else if (v.IsBuffer()) {
      Napi::Buffer<uint8_t> buf = v.As<Napi::Buffer<uint8_t>>();
      s->bytes = [NSData dataWithBytes:buf.Data() length:buf.Length()];
    } else if (v.IsExternal()) {
      CALSurface* surf = SurfaceFrom(v);
      if (!surf) return false;  // released: the error is pending
      s->bitmap = (__bridge_transfer id)CGBitmapContextCreateImage(surf->ctx);
      s->bitmapW = surf->width / surf->scale;
      s->bitmapH = surf->height / surf->scale;
    }
    if (o.Has("imageSize") && o.Get("imageSize").IsArray()) {
      Napi::Array sz = o.Get("imageSize").As<Napi::Array>();
      if (sz.Length() >= 2) {
        s->hasImageSize = true;
        s->imageW = sz.Get(0u).As<Napi::Number>().DoubleValue();
        s->imageH = sz.Get(1u).As<Napi::Number>().DoubleValue();
      }
    }
    s->imageTemplate = BBoolOr(o, "imageTemplate", true);
  }
  if (o.Has("title")) {
    s->hasTitle = true;
    s->title = BStrOr(o, "title", @"");
  }
  if (o.Has("tooltip")) {
    s->hasTooltip = true;
    s->tooltip = BStrOr(o, "tooltip", @"");
  }
  if (o.Has("length")) {
    s->hasLength = true;
    s->length = StatusLengthFrom(o.Get("length"));
  }
  if (o.Has("visible")) s->visible = BBoolOr(o, "visible", true);
  return true;
}

static NSImage* StatusImageOf(const StatusItemSpec& s) {
  NSImage* img = nil;
  if (s.symbol) {
    img = [NSImage imageWithSystemSymbolName:s.symbol accessibilityDescription:nil];
  } else if (s.bytes) {
    img = [[NSImage alloc] initWithData:s.bytes];
  } else if (s.bitmap) {
    img = [[NSImage alloc] initWithCGImage:(__bridge CGImageRef)s.bitmap
                                      size:NSMakeSize(s.bitmapW, s.bitmapH)];
  }
  if (!img) return nil;
  if (s.hasImageSize) img.size = NSMakeSize(s.imageW, s.imageH);
  [img setTemplate:s.imageTemplate];
  return img;
}

static void ApplyStatusItemSpec(NSStatusItem* item, const StatusItemSpec& s) {
  NSStatusBarButton* btn = item.button;
  if (s.hasImage) btn.image = StatusImageOf(s);
  if (s.hasTitle) btn.title = s.title;
  if (s.hasTooltip) btn.toolTip = s.tooltip.length ? s.tooltip : nil;
  if (s.hasLength && !std::isnan(s.length)) item.length = s.length;
  if (s.visible >= 0) item.visible = s.visible;
  // image alone, title alone, or the image leading the title
  bool hasImage = btn.image != nil, hasTitle = btn.title.length > 0;
  btn.imagePosition = hasImage && hasTitle ? NSImageLeft
                      : hasImage           ? NSImageOnly
                                           : NSNoImage;
}

// On the UI thread, the app launched: the item, its target, and its props.
static NSStatusItem* MakeStatusItem(const StatusItemSpec& spec) {
  CGFloat len = spec.hasLength && !std::isnan(spec.length)
                    ? spec.length
                    : NSVariableStatusItemLength;
  NSStatusItem* item = [[NSStatusBar systemStatusBar] statusItemWithLength:len];
  CALStatusItemTarget* target = [CALStatusItemTarget new];
  target->item_ = item;
  objc_setAssociatedObject(item, &kStatusTargetKey, target,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  NSStatusBarButton* btn = item.button;
  btn.target = target;
  btn.action = @selector(click:);
  [btn sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];
  RememberStatusWindow(btn.window, item);
  // AppKit remembers an item's visibility across launches in user defaults
  // under an autosave name it generates by creation order ("Item-0"), so
  // an item hidden when the last process ended would come back hidden.
  // Visibility is the renderer's to decide: assert it at creation.
  item.visible = spec.visible != 0;
  ApplyStatusItemSpec(item, spec);
  return item;
}

// createStatusItem({ image, title, tooltip, length, visible,
//                    imageTemplate, imageSize }) -> handle
// length: 'variable' (default) | 'square' | points. From a worker the
// handle is answered at the call and the item made by a command; its clicks
// carry that handle, and it is held until removeStatusItem.
static Napi::Value CreateStatusItem(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Object o = info.Length() > 0 && info[0].IsObject()
                       ? info[0].As<Napi::Object>()
                       : Napi::Object::New(env);
  StatusItemSpec spec;
  if (!ParseStatusItemSpec(o, &spec)) return env.Undefined();
  if (pthread_main_np()) {
    BEnsureApp();
    Napi::Value handle;
    @autoreleasepool {
      NSStatusItem* item = MakeStatusItem(spec);
      handle = BWrapRetained(env, item);
      StatusTargetOf(item)->handle_ = Napi::Reference<Napi::Value>::New(handle, 1);
    }
    CALUIObjectsChanged(+1);
    return handle;
  }
  CALHandle* h = CALNewHandle();
  Napi::Value handle = CALWrapHandle(env, h, true);
  CALPinHandle(env, h->id_, true);
  CALUIObjectsChanged(+1);
  CALOnUI(^{
    BEnsureApp();
    NSStatusItem* item = MakeStatusItem(spec);
    StatusTargetOf(item)->handleId_ = h->id_;
    h->object_ = item;
  });
  return handle;
}

// A status item verb's first argument, captured for its command (a
// TypeError, and nil, for anything that is not a handle).
static id StatusTargetArg(Napi::Value v) {
  if (!v.IsExternal()) {
    Napi::TypeError::New(v.Env(), "expected a status item handle")
        .ThrowAsJavaScriptException();
    return nil;
  }
  return CALHandleTarget(v);
}

// On the UI thread: the item a captured target names, or nil when it was
// removed (or not made yet) — every verb after removeStatusItem is a no-op,
// never a crash.
static NSStatusItem* ResolveStatusItem(id target) {
  NSStatusItem* item = CALResolve(target);
  return item && StatusTargetOf(item) ? item : nil;
}

// setStatusItem(item, { image, title, tooltip, length, visible, ... })
static Napi::Value SetStatusItem(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  id target = StatusTargetArg(info[0]);
  if (!target || !info[1].IsObject()) return env.Undefined();
  StatusItemSpec spec;
  if (!ParseStatusItemSpec(info[1].As<Napi::Object>(), &spec)) return env.Undefined();
  CALOnUI(^{
    NSStatusItem* item = ResolveStatusItem(target);
    if (!item) return;
    @autoreleasepool {
      ApplyStatusItemSpec(item, spec);
      RememberStatusWindow(item.button.window, item);
    }
  });
  return env.Undefined();
}

// setStatusItemMenu(item, items | null) — items in setMainMenu's item
// vocabulary (title, id, enabled, checked, key, iconName, items, ...);
// activations arrive as `menu-activate` with `menu: 'status'`. With a
// menu, a click tracks it and the button's action stays silent; null
// returns the item to click events.
static Napi::Value SetStatusItemMenu(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  id target = StatusTargetArg(info[0]);
  if (!target) return env.Undefined();
  Napi::Value spec = info.Length() > 1 ? info[1] : env.Null();
  bool hasMenu = spec.IsArray();
  std::vector<MenuItemSpec> items;
  if (hasMenu) items = ParseMenuItems(spec.As<Napi::Array>());
  CALOnUI(^{
    NSStatusItem* item = ResolveStatusItem(target);
    if (!item) return;
    @autoreleasepool {
      item.menu = hasMenu ? BuildMenu(items, MenuTargetFor(&gStatusMenuTarget, "status"))
                          : nil;
    }
  });
  return env.Undefined();
}

static Napi::Value RemoveStatusItem(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  id target = StatusTargetArg(info[0]);
  if (!target) return env.Undefined();
  CALHandle* h = WindowHandleOf(target);  // any handle: a worker's item
  if (h) {
    // counted out and let go at the call, once
    if (h->released_.exchange(true)) return env.Undefined();
    CALUIObjectsChanged(-1);
    CALPinHandle(env, h->id_, false);
  }
  CALOnUI(^{
    NSStatusItem* item = ResolveStatusItem(target);
    if (!item) return;
    @autoreleasepool {
      CALStatusItemTarget* t = StatusTargetOf(item);
      item.button.target = nil;
      item.button.action = nil;
      item.menu = nil;
      [[NSStatusBar systemStatusBar] removeStatusItem:item];
      objc_setAssociatedObject(item, &kStatusTargetKey, nil,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      t->item_ = nil;
      t->handle_.Reset();  // pump mode's handle may now be collected
    }
    if (!h) CALUIObjectsChanged(-1);
  });
  return env.Undefined();
}

// statusItemInfo(item, cb?) — the item as data, for tests: what the bar
// shows, its menu in mainMenuInfo's shape, and the button's screen rect.
// Null once removed.
static Napi::Value StatusItemInfo(const Napi::CallbackInfo& info) {
  id target = StatusTargetArg(info[0]);
  if (!target) return info.Env().Undefined();
  return CALAnswer(info, "statusItemInfo", ^CALValueBlock {
    NSStatusItem* item = ResolveStatusItem(target);
    if (!item) return ^Napi::Value(Napi::Env e) { return e.Null(); };
    NSStatusBarButton* btn = item.button;
    CALEvent r;
    r.Str("title", btn.title.UTF8String);
    r.Str("tooltip", btn.toolTip ? btn.toolTip.UTF8String : "");
    r.Bool("visible", item.visible);
    r.Bool("hasImage", btn.image != nil);
    r.Bool("imageTemplate", btn.image != nil && [btn.image isTemplate]);
    if (btn.image) {
      r.Num("imageWidth", btn.image.size.width);
      r.Num("imageHeight", btn.image.size.height);
    }
    if (item.length == NSVariableStatusItemLength) r.Str("length", "variable");
    else if (item.length == NSSquareStatusItemLength) r.Str("length", "square");
    else r.Num("length", item.length);
    r.Handle("menu", MenuInfoAnswer(item.menu));
    if (btn.window) r.Num("windowNumber", (double)btn.window.windowNumber);
    double f[4];
    if (StatusButtonFrame(btn, f))
      r.Num("x", f[0]).Num("y", f[1]).Num("width", f[2]).Num("height", f[3]);
    return ^Napi::Value(Napi::Env e) { return r.ToObject(e); };
  });
}

// activateStatusItemMenuItem(item, [i, j, ...], cb?) — for tests; a real
// click would track the menu in a modal loop nobody can dismiss from a
// script.
static Napi::Value ActivateStatusItemMenuItem(const Napi::CallbackInfo& info) {
  id target = StatusTargetArg(info[0]);
  if (!target) return info.Env().Undefined();
  std::vector<NSInteger> path = MenuPathArg(info[1]);
  return CALAnswer(info, "activateStatusItemMenuItem", ^CALValueBlock {
    NSStatusItem* item = ResolveStatusItem(target);
    return BoolAnswer(item && ActivateInMenu(item.menu, path));
  });
}

// Two things have to happen before a mouse event posted into an item's
// window is delivered rather than dropped: AppKit's first pass through
// nextEventMatchingMask: (whatever it sets up there, an event queued
// before it is lost), and the status bar server's reply that places the
// window and orders it in — on a hosted CI VM the latter takes longer
// than one pass. The test hooks take at least one pass here and then wait
// for the window to be on glass, for at most `timeout` seconds; nothing
// is dequeued or dispatched.
static bool WaitForStatusWindow(NSWindow* win, NSTimeInterval timeout) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  NSDate* until = [NSDate distantPast];
  while (true) {
    [NSApp nextEventMatchingMask:0
                       untilDate:until
                          inMode:NSDefaultRunLoopMode
                         dequeue:NO];
    if (win.isVisible && WindowOnGlass(win)) return true;
    if (deadline.timeIntervalSinceNow <= 0) return false;
    until = [NSDate dateWithTimeIntervalSinceNow:0.01];
  }
}

// clickStatusItem(item, 'left' | 'right' | 'middle') — for tests: a real
// press-and-release posted into the item's own window, so the button's
// tracking and sendActionOn: path (or the pump's middle-click path) is
// what fires. Declines a left or right click while a menu is set: that
// click would open the menu and never return. Pump afterwards; the event
// arrives through the backend callback like a user's click.
// Off the main thread: clickStatusItem(item, kind, cb). It waits for the
// status window in a run loop of its own, so a queued one is a callout of
// its own too (CALAnswer's `nested`).
static Napi::Value ClickStatusItem(const Napi::CallbackInfo& info) {
  id target = StatusTargetArg(info[0]);
  if (!target) return info.Env().Undefined();
  std::string kind = info.Length() > 1 && info[1].IsString()
                         ? info[1].As<Napi::String>().Utf8Value()
                         : "left";
  return CALAnswer(info, "clickStatusItem", ^CALValueBlock {
    NSStatusItem* item = ResolveStatusItem(target);
    if (!item) return BoolAnswer(false);
    if (item.menu && kind != "middle") return BoolAnswer(false);
    NSStatusBarButton* btn = item.button;
    NSWindow* win = btn.window;
    if (!win) return BoolAnswer(false);
    WaitForStatusWindow(win, 2.0);
    RememberStatusWindow(win, item);
    NSEventType down = NSEventTypeLeftMouseDown, up = NSEventTypeLeftMouseUp;
    if (kind == "right") {
      down = NSEventTypeRightMouseDown; up = NSEventTypeRightMouseUp;
    } else if (kind == "middle") {
      down = NSEventTypeOtherMouseDown; up = NSEventTypeOtherMouseUp;
    }
    NSRect r = [btn convertRect:btn.bounds toView:nil];
    NSPoint p = NSMakePoint(NSMidX(r), NSMidY(r));
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    for (NSEventType t : {down, up}) {
      NSEvent* e = [NSEvent mouseEventWithType:t
                                      location:p
                                 modifierFlags:0
                                     timestamp:now
                                  windowNumber:win.windowNumber
                                       context:nil
                                   eventNumber:0
                                    clickCount:1
                                      pressure:t == down ? 1 : 0];
      if (kind == "middle") {
        // mouseEventWithType: leaves the button number at 0 for the "other"
        // types; the middle button is number 2, which only the CGEvent
        // underneath can say
        CGEventRef cg = CGEventCreateCopy(e.CGEvent);
        CGEventSetIntegerValueField(cg, kCGMouseEventButtonNumber, 2);
        NSEvent* e2 = [NSEvent eventWithCGEvent:cg];
        CFRelease(cg);
        if (e2) e = e2;
      }
      [NSApp postEvent:e atStart:NO];
    }
    return BoolAnswer(true);
  }, true);
}

// snapshotStatusItem(item, file, cb?) — the item's window as the
// WindowServer composited it, to PNG (our own window: no screen-recording
// permission needed, unlike `screencapture -l` from another process). For
// tests.
static Napi::Value SnapshotStatusItem(const Napi::CallbackInfo& info) {
  id target = StatusTargetArg(info[0]);
  if (!target) return info.Env().Undefined();
  NSString* path = info[1].IsString() ? BToNSString(info[1]) : nil;
  return CALAnswer(info, "snapshotStatusItem", ^CALValueBlock {
    NSStatusItem* item = ResolveStatusItem(target);
    NSWindow* win = item ? item.button.window : nil;
    if (!win || !path) return BoolAnswer(false);
    WaitForStatusWindow(win, 2.0);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CGImageRef img = CGWindowListCreateImage(
        CGRectNull, kCGWindowListOptionIncludingWindow,
        (CGWindowID)win.windowNumber,
        (CGWindowImageOption)(kCGWindowImageBoundsIgnoreFraming |
                              kCGWindowImageBestResolution));
#pragma clang diagnostic pop
    if (!img) return BoolAnswer(false);
    NSURL* url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    bool ok = false;
    if (dst) {
      CGImageDestinationAddImage(dst, img, NULL);
      ok = CGImageDestinationFinalize(dst);
      CFRelease(dst);
    }
    CGImageRelease(img);
    return BoolAnswer(ok);
  }, true);
}

// setDockMenu(items | null) — the menu behind a right-click (or a press-
// and-hold) on the Dock tile. `items` is one menu's worth of the item
// vocabulary setMainMenu takes: {id, title, enabled, hidden, checked,
// separator, iconName, iconData, items}. Activations arrive as
// `menu-activate` with `menu: 'dock'`. The Dock asks the delegate for the
// menu every time it opens it, so a new spec shows on the next click; null
// removes the menu (the Dock then shows only its own entries).
static Napi::Value SetDockMenuFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value v = info[0];
  bool clear = v.IsNull() || v.IsUndefined();
  if (!clear && !v.IsArray()) {
    Napi::TypeError::New(env, "setDockMenu: expected an array of items or null")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  std::vector<MenuItemSpec> items;
  if (!clear) items = ParseMenuItems(v.As<Napi::Array>());
  CALOnUI(^{
    BEnsureApp();
    gDockMenu = clear ? nil : BuildMenu(items, MenuTargetFor(&gDockMenuTarget, "dock"));
  });
  return env.Undefined();
}

// The menu the Dock would get: through the delegate, so the test exercises
// the wiring the Dock uses, not the variable behind it.
static NSMenu* DockMenuViaDelegate() {
  id<NSApplicationDelegate> d = NSApp.delegate;
  if (![d respondsToSelector:@selector(applicationDockMenu:)]) return nil;
  return [d applicationDockMenu:NSApp];
}

// dockMenuInfo() — the installed Dock menu as data (null when none). Tests.
static Napi::Value DockMenuInfoFn(const Napi::CallbackInfo& info) {
  return CALAnswer(info, "dockMenuInfo", ^CALValueBlock {
    BEnsureApp();
    return MenuInfoAnswer(DockMenuViaDelegate());
  });
}

// activateDockMenuItem([i, j, ...], cb?) — through the Dock menu.
static Napi::Value ActivateDockMenuItemFn(const Napi::CallbackInfo& info) {
  std::vector<NSInteger> path = MenuPathArg(info[0]);
  return CALAnswer(info, "activateDockMenuItem", ^CALValueBlock {
    BEnsureApp();
    return BoolAnswer(ActivateInMenu(DockMenuViaDelegate(), path));
  });
}

// ---------------------------------------------------------------------------
// app presence: what the user sees of the process outside its windows — the
// Dock tile (badge, bounce, menu, whether there is one) and the name the
// Dock, the ⌘-Tab switcher and the menu bar print for it. Mechanism only:
// the counts, the reasons and the timing are the renderer's.
// ---------------------------------------------------------------------------

static bool PolicyFromName(const std::string& s,
                           NSApplicationActivationPolicy* out) {
  if (s == "regular") *out = NSApplicationActivationPolicyRegular;
  else if (s == "accessory") *out = NSApplicationActivationPolicyAccessory;
  else if (s == "prohibited") *out = NSApplicationActivationPolicyProhibited;
  else return false;
  return true;
}

static const char* PolicyName(NSApplicationActivationPolicy p) {
  switch (p) {
    case NSApplicationActivationPolicyRegular: return "regular";
    case NSApplicationActivationPolicyAccessory: return "accessory";
    case NSApplicationActivationPolicyProhibited: return "prohibited";
  }
  return "regular";
}

// Before launch the policy is what the app launches with (no Dock tile ever
// registers for an agent); after launch it is a live switch.
static bool ApplyActivationPolicy(NSApplicationActivationPolicy p) {
  if (!gAppLaunched) {
    gActivationPolicy = p;
    gPolicyChosen = true;  // over APPKIT_ACTIVATION_POLICY
    BEnsureApp();  // publishes it
    return true;
  }
  bool ok = [NSApp setActivationPolicy:p];
  gPubPolicy = (int)NSApp.activationPolicy;
  return ok;
}

// Reads `activationPolicy` off an options object on the calling thread;
// throws on an unknown name. Returns false when it threw; *has says whether
// there was one to apply.
static bool ParsePolicyOption(Napi::Env env, Napi::Value v, bool* has,
                              NSApplicationActivationPolicy* p) {
  *has = false;
  if (v.IsUndefined() || v.IsNull()) return true;
  if (!v.IsString() || !PolicyFromName(v.As<Napi::String>().Utf8Value(), p)) {
    Napi::RangeError::New(
        env, "activationPolicy: expected 'regular' | 'accessory' | 'prohibited'")
        .ThrowAsJavaScriptException();
    return false;
  }
  *has = true;
  return true;
}

// runMain({ activationPolicy }) (threaded.mm, windowkit/appkit#64), on the
// main thread: before launch it is the policy the app launches with; after,
// a live switch, as setActivationPolicy is. False with a RangeError pending
// for a name nobody knows.
bool CALApplyActivationPolicyOption(Napi::Env env, Napi::Value v) {
  bool has = false;
  NSApplicationActivationPolicy p = NSApplicationActivationPolicyRegular;
  if (!ParsePolicyOption(env, v, &has, &p)) return false;
  if (has) ApplyActivationPolicy(p);
  return true;
}

// A command's answer, for the verbs that return what AppKit said: the
// answer in pump mode, where the block ran in the call; undefined from a
// worker, whose command has not run yet (JS never waits on the UI thread).
static Napi::Value BCommandAnswer(Napi::Env env, bool ok) {
  return pthread_main_np() ? Napi::Value(Napi::Boolean::New(env, ok))
                           : env.Undefined();
}

// initApp({ activationPolicy? }) — the NSApplication, its activation policy
// and the app delegate (open-URL / open-file, reopen, quit and Dock-menu
// routing; see the app lifecycle section). Idempotent; every other entry
// point calls it implicitly, but a renderer that wants the launching URL
// calls it first thing and installs its callback next, before the first
// pump. The policy option is honoured on any call: before launch it decides
// how the app launches, afterwards it switches live.
static Napi::Value InitAppFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  bool has = false;
  NSApplicationActivationPolicy p = NSApplicationActivationPolicyRegular;
  if (info.Length() > 0 && info[0].IsObject()) {
    Napi::Object o = info[0].As<Napi::Object>();
    if (!ParsePolicyOption(env, o.Get("activationPolicy"), &has, &p))
      return env.Undefined();
  }
  CALOnUI(^{
    if (has) ApplyActivationPolicy(p);
    BEnsureApp();
  });
  return env.Undefined();
}

// setActivationPolicy('regular' | 'accessory' | 'prohibited') -> bool
// 'regular': Dock tile, menu bar, ⌘-Tab entry. 'accessory': none of those,
// windows still work (LSUIElement — menu-bar and agent apps). 'prohibited':
// no UI at all. Returns what AppKit answers (true on every supported macOS).
static Napi::Value SetActivationPolicyFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSApplicationActivationPolicy p;
  if (!info[0].IsString() ||
      !PolicyFromName(info[0].As<Napi::String>().Utf8Value(), &p)) {
    Napi::RangeError::New(
        env, "setActivationPolicy: expected 'regular' | 'accessory' | 'prohibited'")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  __block bool ok = false;
  CALOnUI(^{ ok = ApplyActivationPolicy(p); });
  return BCommandAnswer(env, ok);
}

// activationPolicy() -> 'regular' | 'accessory' | 'prohibited' — as the UI
// thread last published it (the published state section). Any thread.
static Napi::Value ActivationPolicyFn(const Napi::CallbackInfo& info) {
  return Napi::String::New(
      info.Env(), PolicyName((NSApplicationActivationPolicy)gPubPolicy.load()));
}

// setDockBadge(label | null) — NSDockTile.badgeLabel: the red pill on the
// Dock tile (an unread count, usually). A number is stringified; null or
// undefined clears. Shows only while the tile exists (policy 'regular').
static Napi::Value SetDockBadgeFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value v = info[0];
  NSString* label = nil;
  if (v.IsString() || v.IsNumber()) {
    label = BToNSString(v.ToString());
  } else if (!v.IsNull() && !v.IsUndefined()) {
    Napi::TypeError::New(env, "setDockBadge: expected a string, a number or null")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CALOnUI(^{
    BEnsureApp();
    NSApp.dockTile.badgeLabel = label;
    PublishBadge();
  });
  return env.Undefined();
}

// requestUserAttention('informational' | 'critical') -> requestId
// The Dock bounce, _NET_WM_STATE_DEMANDS_ATTENTION's counterpart:
// 'informational' bounces once, 'critical' keeps bouncing until the app is
// activated. AppKit ignores the request while the app is active (the id it
// returns then is still safe to cancel; appInfo().active says which case a
// caller is in). Anything else as the type is a RangeError.
//
// From a worker the id is the bridge's own, allocated at the call from a
// range AppKit's never reaches (2^40 up) and mapped to AppKit's when the
// command runs; cancelUserAttention takes either kind.
static std::atomic<int64_t> gNextAttentionId{(int64_t)1 << 40};
static NSMutableDictionary<NSNumber*, NSNumber*>* gAttention = nil;  // UI thread

static Napi::Value RequestUserAttentionFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSRequestUserAttentionType type;
  std::string s = info[0].IsString() ? info[0].As<Napi::String>().Utf8Value() : "";
  if (s == "informational") type = NSInformationalRequest;
  else if (s == "critical") type = NSCriticalRequest;
  else {
    Napi::RangeError::New(
        env, "requestUserAttention: expected 'informational' | 'critical'")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (pthread_main_np()) {
    BEnsureApp();
    return Napi::Number::New(env, (double)[NSApp requestUserAttention:type]);
  }
  int64_t id = gNextAttentionId++;
  CALOnUI(^{
    BEnsureApp();
    if (!gAttention) gAttention = [NSMutableDictionary dictionary];
    gAttention[@(id)] = @([NSApp requestUserAttention:type]);
  });
  return Napi::Number::New(env, (double)id);
}

// cancelUserAttention(requestId) — stop a bounce early (the message was
// read some other way); a request that already ended is a no-op.
static Napi::Value CancelUserAttentionFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "cancelUserAttention: expected the request id")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  int64_t id = info[0].As<Napi::Number>().Int64Value();
  CALOnUI(^{
    BEnsureApp();
    NSNumber* mapped = gAttention[@(id)];
    if (mapped) [gAttention removeObjectForKey:@(id)];
    [NSApp cancelUserAttentionRequest:mapped ? mapped.integerValue : (NSInteger)id];
  });
  return env.Undefined();
}

// setAppName(name) -> bool — the name the Dock tile, the ⌘-Tab switcher,
// Force Quit and the application menu print for this process.
//
// A bundled app gets that name from its Info.plist and keeps it: when the
// main bundle declares CFBundleName or CFBundleDisplayName this is a no-op
// answering false. An unbundled process (`node`, `bun`) is registered with
// LaunchServices under its executable name, and the only way to change that
// record from inside is the private LaunchServices call WebKit, Chromium
// and the JDK's -Xdock:name use: _LSSetApplicationInformationItem with
// _kLSDisplayNameKey on the process's own ASN. It is looked up at runtime,
// so a macOS that drops it makes this answer false rather than fail to
// load. NSRunningApplication.localizedName reads the same record back
// (appInfo().name).
typedef CFTypeRef (*CALLSGetCurrentApplicationASN)(void);
typedef OSStatus (*CALLSSetApplicationInformationItem)(int, CFTypeRef,
                                                       CFStringRef, CFStringRef,
                                                       CFDictionaryRef*);

static bool BundleDeclaresName() {
  NSBundle* b = [NSBundle mainBundle];
  return [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] != nil ||
         [b objectForInfoDictionaryKey:@"CFBundleName"] != nil;
}

static bool SetLaunchServicesDisplayName(NSString* name) {
  void* h = dlopen(
      "/System/Library/Frameworks/CoreServices.framework/CoreServices",
      RTLD_LAZY);
  if (!h) return false;
  auto getASN = (CALLSGetCurrentApplicationASN)dlsym(
      h, "_LSGetCurrentApplicationASN");
  auto setItem = (CALLSSetApplicationInformationItem)dlsym(
      h, "_LSSetApplicationInformationItem");
  auto key = (CFStringRef*)dlsym(h, "_kLSDisplayNameKey");
  if (!getASN || !setItem || !key || !*key) return false;
  CFTypeRef asn = getASN();
  if (!asn) return false;
  // -2: the "current session" LSSessionID WebKit passes here
  return setItem(-2, asn, *key, (__bridge CFStringRef)name, NULL) == noErr;
}

static Napi::Value SetAppNameFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsString()) {
    Napi::TypeError::New(env, "setAppName: expected a string")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  NSString* name = BToNSString(info[0]);
  __block bool ok = false;
  CALOnUI(^{
    BEnsureApp();
    ok = !BundleDeclaresName() && SetLaunchServicesDisplayName(name);
    PublishName();
  });
  return BCommandAnswer(env, ok);
}

// appInfo() -> { activationPolicy, name, dockBadge, active } — the presence
// state read back from AppKit and LaunchServices, for tests and for a
// renderer deciding whether a bounce would even be seen. From a worker it is
// the published copy.
static Napi::Value AppInfoFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (ReadPublished()) {
    NSString *name, *badge;
    {
      std::lock_guard<std::mutex> l(gPubMu);
      name = gPubName;
      badge = gPubBadge;
    }
    Napi::Object r = Napi::Object::New(env);
    r.Set("activationPolicy",
          PolicyName((NSApplicationActivationPolicy)gPubPolicy.load()));
    if (name) r.Set("name", name.UTF8String);
    else r.Set("name", env.Null());
    if (badge.length) r.Set("dockBadge", badge.UTF8String);
    else r.Set("dockBadge", env.Null());
    r.Set("active", gPubActive.load());
    return r;
  }
  BEnsureApp();
  Napi::Object r = Napi::Object::New(env);
  r.Set("activationPolicy", PolicyName(NSApp.activationPolicy));
  NSString* name = NSRunningApplication.currentApplication.localizedName;
  if (name) r.Set("name", name.UTF8String);
  else r.Set("name", env.Null());
  NSString* badge = NSApp.dockTile.badgeLabel;
  if (badge.length) r.Set("dockBadge", badge.UTF8String);
  else r.Set("dockBadge", env.Null());
  r.Set("active", (bool)NSApp.isActive);
  return r;
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

// What a presented panel owes JS: pump mode's callback and the env to call
// it with, or a worker's threadsafe function. Hung on the panel itself so
// cancelPanel can tell an open panel from one that has already answered.
@interface CALPanelPending : NSObject {
 @public
  napi_env env_;
  Napi::FunctionReference cb_;
  bool threaded_;
  Napi::ThreadSafeFunction tsfn_;
  bool open_;   // NSOpenPanel answers paths[], NSSavePanel answers a path
  bool modal_;  // app-modal (runModal) rather than a sheet
}
@end
@implementation CALPanelPending
@end

static char kPanelPendingKey;

// The answer, read off the panel on the UI thread: paths[] for an open
// panel, a path for a save panel, null for a cancel.
static CALValueBlock PanelAnswer(NSSavePanel* panel, bool open, NSModalResponse r) {
  if (r != NSModalResponseOK) return ^Napi::Value(Napi::Env e) { return e.Null(); };
  if (open) {
    std::vector<std::string> paths;
    for (NSURL* u in ((NSOpenPanel*)panel).URLs) paths.push_back(u.path.UTF8String);
    return ^Napi::Value(Napi::Env e) {
      Napi::Array a = Napi::Array::New(e, paths.size());
      for (size_t i = 0; i < paths.size(); i++)
        a.Set((uint32_t)i, Napi::String::New(e, paths[i]));
      return a;
    };
  }
  NSURL* u = panel.URL;
  bool has = u != nil;
  std::string path = has ? u.path.UTF8String : "";
  return ^Napi::Value(Napi::Env e) {
    return has ? Napi::Value(Napi::String::New(e, path)) : Napi::Value(e.Null());
  };
}

// The one place a panel answers. The pending record comes off first, so a
// second answer (or a cancelPanel from inside the callback) finds nothing.
static void FinishPanel(NSSavePanel* panel, NSModalResponse r) {
  CALPanelPending* p = objc_getAssociatedObject(panel, &kPanelPendingKey);
  if (!p) return;
  objc_setAssociatedObject(panel, &kPanelPendingKey, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  CALValueBlock answer = PanelAnswer(panel, p->open_, r);
  if (p->threaded_) {
    CALReply(p->tsfn_, answer);
    return;
  }
  Napi::Env env(p->env_);
  Napi::HandleScope scope(env);
  Napi::Value result = answer(env);
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

// A panel's spec, read on the calling thread; the panel itself is made on
// the UI thread (MakePanel).
struct PanelSpec {
  NSString *title = nil, *message = nil, *prompt = nil, *name = nil;
  NSURL* directoryURL = nil;
  int canCreateDirectories = -1;  // -1: AppKit's default
  NSArray<NSString*>* typeIds = nil;
  bool directory = false, multiple = false;
};

static PanelSpec ParsePanelSpec(Napi::Object o, bool open) {
  PanelSpec s;
  if (o.Has("title") && o.Get("title").IsString())
    s.title = BToNSString(o.Get("title"));
  if (o.Has("message") && o.Get("message").IsString())
    s.message = BToNSString(o.Get("message"));
  if (o.Has("prompt") && o.Get("prompt").IsString())
    s.prompt = BToNSString(o.Get("prompt"));
  if (o.Has("directoryURL")) s.directoryURL = PanelURLArg(o.Get("directoryURL"));
  if (o.Has("canCreateDirectories") && o.Get("canCreateDirectories").IsBoolean())
    s.canCreateDirectories = o.Get("canCreateDirectories").As<Napi::Boolean>().Value();
  if (o.Has("allowedContentTypes") && o.Get("allowedContentTypes").IsArray()) {
    Napi::Array ids = o.Get("allowedContentTypes").As<Napi::Array>();
    NSMutableArray<NSString*>* strs = [NSMutableArray array];
    for (uint32_t i = 0; i < ids.Length(); i++) {
      Napi::Value v = ids.Get(i);
      if (v.IsString()) [strs addObject:BToNSString(v)];
    }
    s.typeIds = strs;
  }
  if (open) {
    s.directory = BBoolOr(o, "directory", false);
    s.multiple = BBoolOr(o, "multiple", false);
  } else if (o.Has("nameFieldStringValue") && o.Get("nameFieldStringValue").IsString()) {
    s.name = BToNSString(o.Get("nameFieldStringValue"));
  }
  return s;
}

// On the UI thread.
static NSSavePanel* MakePanel(const PanelSpec& s, bool open) {
  NSSavePanel* panel;
  if (open) {
    NSOpenPanel* op = [NSOpenPanel openPanel];
    op.canChooseDirectories = s.directory;
    op.canChooseFiles = !s.directory;
    op.allowsMultipleSelection = s.multiple;
    panel = op;
  } else {
    panel = [NSSavePanel savePanel];
    if (s.name) panel.nameFieldStringValue = s.name;
  }
  if (s.title) panel.title = s.title;
  if (s.message) panel.message = s.message;
  if (s.prompt) panel.prompt = s.prompt;
  if (s.directoryURL) panel.directoryURL = s.directoryURL;
  if (s.canCreateDirectories >= 0) panel.canCreateDirectories = s.canCreateDirectories;
  if (s.typeIds) {
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    for (NSString* id in s.typeIds) {
      UTType* t = [UTType typeWithIdentifier:id];
      if (t) [types addObject:t];
    }
    // A list the OS recognises nothing of is no filter at all, the same as
    // passing none: a panel that admits nothing helps nobody.
    if (types.count) panel.allowedContentTypes = types;
  }
  return panel;
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
  id owner = nil;
  if (o.Has("window")) {
    Napi::Value w = o.Get("window");
    if (w.IsExternal()) {
      owner = CALHandleTarget(w);
    } else if (!w.IsNull() && !w.IsUndefined()) {
      Napi::TypeError::New(env, "window must be a window handle")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
  }
  PanelSpec spec = ParsePanelSpec(o, open);

  if (pthread_main_np()) {
    BEnsureApp();
    NSSavePanel* panel = MakePanel(spec, open);
    CALPanelPending* p = [CALPanelPending new];
    p->env_ = (napi_env)env;
    p->cb_ = Napi::Persistent(info[1].As<Napi::Function>());
    p->threaded_ = false;
    p->open_ = open;
    objc_setAssociatedObject(panel, &kPanelPendingKey, p,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Napi::Value handle = BWrapRetained(env, panel);
    NSWindow* ownerWin = owner ? CALResolve(owner) : nil;
    p->modal_ = !ownerWin;
    if (ownerWin) {
      [panel beginSheetModalForWindow:ownerWin
                    completionHandler:^(NSModalResponse r) {
                      FinishPanel(panel, r);
                    }];
    } else {
      NSModalResponse r = [panel runModal];
      FinishPanel(panel, r);
    }
    return handle;
  }

  // From a worker: the handle now, the panel from a command — an app-modal
  // one from a callout of its own, runModal being a nested loop — and the
  // answer through a threadsafe function in this environment.
  CALHandle* h = CALNewHandle();
  Napi::Value handle = CALWrapHandle(env, h, false);
  Napi::ThreadSafeFunction tsfn = CALReplyTo(
      env, info[1].As<Napi::Function>(), open ? "appkit:openPanel" : "appkit:savePanel");
  dispatch_block_t present = ^{
    BEnsureApp();
    NSSavePanel* panel = MakePanel(spec, open);
    CALPanelPending* p = [CALPanelPending new];
    p->threaded_ = true;
    p->tsfn_ = tsfn;
    p->open_ = open;
    objc_setAssociatedObject(panel, &kPanelPendingKey, p,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    h->object_ = panel;
    p->modal_ = !owner;
    if (!owner) {
      FinishPanel(panel, [panel runModal]);
      return;
    }
    NSWindow* ownerWin = CALResolve(owner);
    if (!ownerWin) {  // the window it was to sit on is gone
      FinishPanel(panel, NSModalResponseCancel);
      return;
    }
    [panel beginSheetModalForWindow:ownerWin
                  completionHandler:^(NSModalResponse r) {
                    FinishPanel(panel, r);
                  }];
  };
  if (owner) CALOnUI(present);
  else CALOnUIModal(present);
  return handle;
}

static Napi::Value OpenPanelFn(const Napi::CallbackInfo& info) {
  return PresentPanel(info, true);
}

static Napi::Value SavePanelFn(const Napi::CallbackInfo& info) {
  return PresentPanel(info, false);
}

// cancelPanel(panel) -> bool — dismiss a panel that is still up; its
// callback then gets null. False when the panel has already answered. In
// pump mode only a sheet can be reached (the thread that would call this
// for an app-modal panel is inside runModal); from a worker either can, the
// command queue draining inside runModal too — and there the answer is
// undefined, the command not having run yet.
static Napi::Value CancelPanelFn(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsExternal()) {
    Napi::TypeError::New(env, "cancelPanel: panel handle required")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  id target = CALHandleTarget(info[0]);
  __block bool ok = false;
  CALOnUI(^{
    NSSavePanel* panel = CALResolve(target);
    CALPanelPending* p = panel ? objc_getAssociatedObject(panel, &kPanelPendingKey) : nil;
    if (!p) return;
    if (p->modal_) {
      // the panel is hosted out of process, and its cancel: ends a sheet but
      // not the modal session runModal is in: that is ended as its Cancel
      // button would, and runModal answers the cancel
      [NSApp stopModalWithCode:NSModalResponseCancel];
      CALPostWakeEvent();
    } else {
      [panel cancel:nil];
    }
    ok = true;
  });
  return BCommandAnswer(env, ok);
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

// A bezel's parameters, read on the calling thread. The cell or control is
// made on the UI thread (windowkit/appkit#54): an NSView or NSControl made
// on a worker drew correct pixels and then crashed the process at exit.
struct BezelSpec {
  NSString* kind = @"push";
  NSString* title = @"";
  bool pressed = false, enabled = true, isDefault = false;
  int state = 0;  // 0 off, 1 on
  double value = 0.5;
  NSString* controlSize = @"regular";
  NSString* appearance = @"system";
};

// False with an error pending: not an object, or a kind nobody draws.
static bool ParseBezelSpec(Napi::Env env, Napi::Value v, BezelSpec* s) {
  if (!v.IsObject()) {
    Napi::TypeError::New(env, "expected the control's parameters, an object")
        .ThrowAsJavaScriptException();
    return false;
  }
  Napi::Object o = v.As<Napi::Object>();
  s->kind = BStrOr(o, "kind", @"push");
  if (![@[ @"push", @"checkbox", @"radio", @"popup", @"slider", @"switch" ]
          containsObject:s->kind]) {
    Napi::Error::New(env, "unknown control kind").ThrowAsJavaScriptException();
    return false;
  }
  s->title = BStrOr(o, "title", @"");
  s->pressed = BBoolOr(o, "pressed", false);
  s->enabled = BBoolOr(o, "enabled", true);
  s->isDefault = BBoolOr(o, "isDefault", false);
  s->state = (int)BNumOr(o, "state", 0);
  s->value = BNumOr(o, "value", 0.5);
  s->controlSize = BStrOr(o, "controlSize", @"regular");
  s->appearance = BStrOr(o, "appearance", @"system");
  return true;
}

// On the UI thread.
static BezelControl BuildBezel(const BezelSpec& s) {
  BezelControl out;
  NSString* kind = s.kind;
  if ([kind isEqualToString:@"checkbox"] || [kind isEqualToString:@"radio"] ||
      [kind isEqualToString:@"push"]) {
    NSButtonCell* c = [[NSButtonCell alloc] initTextCell:s.title];
    if ([kind isEqualToString:@"checkbox"]) {
      c.buttonType = NSButtonTypeSwitch;
    } else if ([kind isEqualToString:@"radio"]) {
      c.buttonType = NSButtonTypeRadio;
    } else {
      c.buttonType = NSButtonTypeMomentaryPushIn;
      c.bezelStyle = NSBezelStylePush;
      // the Return key equivalent is what makes AppKit fill it with the
      // user's accent — the "default button" look
      if (s.isDefault) c.keyEquivalent = @"\r";
    }
    c.state = s.state == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    out.cell = c;
  } else if ([kind isEqualToString:@"popup"]) {
    NSPopUpButtonCell* c = [[NSPopUpButtonCell alloc] initTextCell:@"" pullsDown:NO];
    [c addItemWithTitle:s.title];
    out.cell = c;
  } else if ([kind isEqualToString:@"slider"]) {
    NSSlider* sl = [[NSSlider alloc] init];
    sl.minValue = 0;
    sl.maxValue = 1;
    sl.doubleValue = s.value;
    out.view = sl;
  } else {  // switch: ParseBezelSpec admits nothing else
    NSSwitch* sw = [[NSSwitch alloc] init];
    sw.state = s.state == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    out.view = sw;
  }

  NSString* sz = s.controlSize;
  NSControlSize csize = NSControlSizeRegular;
  if ([sz isEqualToString:@"small"]) csize = NSControlSizeSmall;
  else if ([sz isEqualToString:@"mini"]) csize = NSControlSizeMini;
  else if ([sz isEqualToString:@"large"]) csize = NSControlSizeLarge;

  if (out.cell) {
    out.cell.controlSize = csize;
    out.cell.font =
        [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:csize]];
    out.cell.enabled = s.enabled;
    out.cell.highlighted = s.pressed;
  } else if (out.view) {
    out.view.controlSize = csize;
    out.view.enabled = s.enabled;
  }
  return out;
}

static NSAppearance* BezelAppearance(NSString* name) {
  if ([name isEqualToString:@"dark"])
    return [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  if ([name isEqualToString:@"light"])
    return [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  return NSApp.effectiveAppearance;
}

// measureControl({kind, controlSize, title?}, cb?) -> {width, height} in
// points — the control's natural size, which is the size the bezel is
// *designed* at: stretching a checkbox distorts it, so layout adopts these.
// On the main thread without a callback it answers in the call, as always;
// with one — the only way off the main thread — the cell is measured on the
// UI thread and cb({ width, height }) follows.
static Napi::Value MeasureControl(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  BezelSpec spec;
  if (!ParseBezelSpec(env, info[0], &spec)) return env.Undefined();
  return CALAnswer(info, "measureControl", ^CALValueBlock {
    BEnsureApp();
    BezelControl c = BuildBezel(spec);
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
    return ^Napi::Value(Napi::Env e) {
      Napi::Object r = Napi::Object::New(e);
      r.Set("width", w);
      r.Set("height", h);
      return r;
    };
  });
}

// drawControlIntoSurface(surface, params, cb?) — render the bezel to fill
// the whole surface (surface px / scale = the frame in points). Clears
// first: bezels are alpha-composited art, not opaque tiles. With a callback
// (the only way off the main thread) AppKit draws on the UI thread straight
// into the caller's bitmap, nothing copied, and cb() says it is done: until
// then the renderer must leave the surface alone.
static Napi::Value DrawControlIntoSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  BezelSpec spec;
  if (!ParseBezelSpec(env, info[1], &spec)) return env.Undefined();
  // held until the bezel is drawn: a release in the meantime must not free
  // the bitmap under AppKit
  id ctxKeep = (__bridge id)s->ctx;
  id ioKeep = s->iosurface ? (__bridge id)s->iosurface : nil;
  size_t pw = s->width, ph = s->height;
  double scale = s->scale > 0 ? s->scale : 1;

  return CALAnswer(info, "drawControlIntoSurface", ^CALValueBlock {
    (void)ioKeep;
    BEnsureApp();
    CGContextRef ctx = (__bridge CGContextRef)ctxKeep;
    BezelControl c = BuildBezel(spec);
    double w = pw / scale, h = ph / scale;

    CGContextSaveGState(ctx);
    // the surface's base CTM is already top-left-origin device pixels;
    // clear in that space, then move to points for AppKit
    CGContextClearRect(ctx, CGRectMake(0, 0, (CGFloat)pw, (CGFloat)ph));
    CGContextScaleCTM(ctx, scale, scale);

    NSGraphicsContext* g =
        [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:g];

    NSAppearance* ap = BezelAppearance(spec.appearance);
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
    CGContextRestoreGState(ctx);
    return ^Napi::Value(Napi::Env e) { return e.Undefined(); };
  });
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
// ctxSetBlendMode(surface, mode) -> boolean — canvas's
// globalCompositeOperation, in CoreGraphics' spelling. Every one of the
// canvas names has an exact CGBlendMode: the Porter-Duff dozen a 2d context
// composites with, and the separable and non-separable blend modes below
// them. `copy` is the one the compositing paths care about — it is what
// makes a paint a replacement rather than a blend, and what lets a
// translate-only 1:1 drawSurface take blitSurface's memcpy instead.
//
// A name the list does not have leaves the context's blend mode alone and
// answers false, which is canvas's rule for an unknown value (it is
// ignored, not reset) and lets a caller keep its own property in step. The
// mode is gstate, so ctxSave/ctxRestore bracket it like any other.
static Napi::Value CtxSetBlendMode(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  std::string mode = info[1].As<Napi::String>().Utf8Value();
  CGBlendMode blend;
  if (mode == "source-over") blend = kCGBlendModeNormal;
  else if (mode == "copy") blend = kCGBlendModeCopy;
  else if (mode == "source-in") blend = kCGBlendModeSourceIn;
  else if (mode == "source-out") blend = kCGBlendModeSourceOut;
  else if (mode == "source-atop") blend = kCGBlendModeSourceAtop;
  else if (mode == "destination-over") blend = kCGBlendModeDestinationOver;
  else if (mode == "destination-in") blend = kCGBlendModeDestinationIn;
  else if (mode == "destination-out") blend = kCGBlendModeDestinationOut;
  else if (mode == "destination-atop") blend = kCGBlendModeDestinationAtop;
  else if (mode == "xor") blend = kCGBlendModeXOR;
  else if (mode == "lighter") blend = kCGBlendModePlusLighter;
  else if (mode == "multiply") blend = kCGBlendModeMultiply;
  else if (mode == "screen") blend = kCGBlendModeScreen;
  else if (mode == "overlay") blend = kCGBlendModeOverlay;
  else if (mode == "darken") blend = kCGBlendModeDarken;
  else if (mode == "lighten") blend = kCGBlendModeLighten;
  else if (mode == "color-dodge") blend = kCGBlendModeColorDodge;
  else if (mode == "color-burn") blend = kCGBlendModeColorBurn;
  else if (mode == "hard-light") blend = kCGBlendModeHardLight;
  else if (mode == "soft-light") blend = kCGBlendModeSoftLight;
  else if (mode == "difference") blend = kCGBlendModeDifference;
  else if (mode == "exclusion") blend = kCGBlendModeExclusion;
  else if (mode == "hue") blend = kCGBlendModeHue;
  else if (mode == "saturation") blend = kCGBlendModeSaturation;
  else if (mode == "color") blend = kCGBlendModeColor;
  else if (mode == "luminosity") blend = kCGBlendModeLuminosity;
  // not canvas's, but CoreGraphics' own and the CSS spelling of two of them
  else if (mode == "clear") blend = kCGBlendModeClear;
  else if (mode == "plus-lighter") blend = kCGBlendModePlusLighter;
  else if (mode == "plus-darker") blend = kCGBlendModePlusDarker;
  else return Napi::Boolean::New(env, false);
  CGContextSetBlendMode(CtxOf(info[0]), blend);
  return Napi::Boolean::New(env, true);
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
// The image is taken in the call, on the thread that paints the surface, so
// what a worker's frame shows is the bitmap as it was then, whatever is
// drawn into it before the frame applies.
static Napi::Value SurfaceToLayer(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  id target = CALHandleTarget(info[1]);
  id img = CFBridgingRelease(CGBitmapContextCreateImage(s->ctx));
  double scale = s->scale;
  CALOnLayers(^{
    CALayer* L = CALResolve(target);
    if (!L) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALNoteContentsReplaced(L, img);
    L.contents = img;
    L.contentsScale = scale;
    [CATransaction commit];
  });
  return info.Env().Undefined();
}

// surfaceIsInUse(surface) -> bool — whether anything (the render server
// scanning it out, most often) still reads an IOSurface-backed surface:
// IOSurfaceIsInUse, which is thread-safe, so a worker's renderer can poll
// it before drawing into a buffer it handed a layer. False for a surface
// that is not IOSurface-backed.
static Napi::Value SurfaceIsInUse(const Napi::CallbackInfo& info) {
  CALSurface* s = SurfaceFrom(info[0]);
  if (!s) return info.Env().Undefined();
  return Napi::Boolean::New(info.Env(), s->iosurface && IOSurfaceIsInUse(s->iosurface));
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

// The general pasteboard is the UI thread's: writes are commands, and a
// read off the main thread answers through a callback.
static Napi::Value PbWriteTextFn(const Napi::CallbackInfo& info) {
  NSString* text = BToNSString(info[0]);
  CALOnUI(^{
    NSPasteboard* pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    PublishPasteboardCount();
  });
  return info.Env().Undefined();
}

// pasteboardReadText(cb?) -> string | null
static Napi::Value PbReadTextFn(const Napi::CallbackInfo& info) {
  return CALAnswer(info, "pasteboardReadText", ^CALValueBlock {
    NSString* s =
        [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    std::string text = s ? s.UTF8String : "";
    bool has = s != nil;
    return ^Napi::Value(Napi::Env e) {
      return has ? Napi::Value(Napi::String::New(e, text)) : Napi::Value(e.Null());
    };
  });
}

static Napi::Value PbClearFn(const Napi::CallbackInfo& info) {
  CALOnUI(^{
    [NSPasteboard.generalPasteboard clearContents];
    PublishPasteboardCount();
  });
  return info.Env().Undefined();
}

static Napi::Value PbChangeCountFn(const Napi::CallbackInfo& info) {
  if (ReadPublished())
    return Napi::Number::New(info.Env(), (double)gPubPasteboardCount.load());
  return Napi::Number::New(info.Env(),
                           (double)NSPasteboard.generalPasteboard.changeCount);
}

// ---------------------------------------------------------------------------
// screens + cursors + appearance
// ---------------------------------------------------------------------------

static Napi::Value ListScreens(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (ReadPublished()) {
    std::vector<PubScreen> screens;
    {
      std::lock_guard<std::mutex> l(gPubMu);
      screens = gPubScreens;
    }
    return ScreensArray(env, screens);
  }
  BEnsureApp();
  return ScreensArray(env, ScreensNow());
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
  CALOnUI(^{ [c set]; });
  return info.Env().Undefined();
}

// postKeyEvent(win, down, keyCode, chars, modifiers) — synthetic keys for
// tests, through the real pump like postMouseEvent.
static Napi::Value PostKeyEvent(const Napi::CallbackInfo& info) {
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
  OnWindow(info[0], ^(NSWindow* win) {
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
  });
  return info.Env().Undefined();
}


// invalidateWindowShadow(win) — a transparent window's shadow is computed
// by AppKit from the content's opaque shape; repaints do not recompute it
// automatically, so a popup presented after its map keeps whatever shape
// AppKit guessed first (a full-frame dark square). Call after presenting.
static Napi::Value InvalidateWindowShadow(const Napi::CallbackInfo& info) {
  OnWindow(info[0], ^(NSWindow* win) { [win invalidateShadow]; });
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

static std::vector<std::string> DragOpsOfMask(NSDragOperation mask) {
  std::vector<std::string> out;
  for (const auto& d : kDragOps)
    if (mask & d.op) out.push_back(d.name);
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
// dropped. Read on the calling thread into plain data; the NSPasteboardItems
// are made on the UI thread.
struct PbRep {
  NSString* type = nil;
  NSString* string = nil;
  NSData* data = nil;
  bool lazy = false;
};
typedef std::vector<std::vector<PbRep>> PbItemsSpec;

// WritePasteboardValue's reading half: false for null / undefined.
static bool ParsePbValue(Napi::Value v, PbRep* r) {
  if (v.IsNull() || v.IsUndefined()) return false;
  if (v.IsString()) {
    r->string = BToNSString(v);
    return true;
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
    r->string = BToNSString(v.ToString());
    return true;
  }
  r->data = [NSData dataWithBytes:bytes length:len];
  return true;
}

static PbItemsSpec ParsePasteboardItems(Napi::Env env, Napi::Value spec,
                                        bool lazyAllowed) {
  PbItemsSpec out;
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
    std::vector<PbRep> reps;
    Napi::Array keys = o.GetPropertyNames();
    for (uint32_t k = 0; k < keys.Length(); k++) {
      Napi::Value key = keys.Get(k);
      if (!key.IsString()) continue;
      PbRep r;
      r.type = BToNSString(key);
      if (!ParsePbValue(o.Get(key), &r)) {
        if (!lazyAllowed) continue;
        r.lazy = true;
      }
      reps.push_back(r);
    }
    out.push_back(std::move(reps));
  }
  return out;
}

// On the UI thread.
static NSArray<NSPasteboardItem*>* BuildPasteboardItems(const PbItemsSpec& spec,
                                                        CALDragProvider* provider) {
  NSMutableArray<NSPasteboardItem*>* items = [NSMutableArray array];
  for (const std::vector<PbRep>& reps : spec) {
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    NSMutableArray<NSString*>* lazy = [NSMutableArray array];
    for (const PbRep& r : reps) {
      if (r.lazy) {
        if (provider) [lazy addObject:r.type];
      } else if (r.string) {
        [item setString:r.string forType:r.type];
      } else if (r.data) {
        [item setData:r.data forType:r.type];
      }
    }
    if (lazy.count) [item setDataProvider:provider forTypes:lazy];
    [items addObject:item];
  }
  return items;
}

// The drag image, from either bitmap this addon deals in: `surface`, a
// surface handle (the renderer's own paint, its scale known, its pixels
// copied as they are at the call), or `image`, a CGImage External — or the
// {image, width, height, scale} object text.render / controls.render
// answer, taken whole. False with an error pending.
struct DragImageSpec {
  id image = nil;  // a CGImage, owned by ARC through the bridge
  double w = 0, h = 0;
};

static bool ParseDragImage(Napi::Object o, DragImageSpec* d) {
  Napi::Value sv = o.Get("surface");
  if (sv.IsExternal()) {
    CALSurface* s = SurfaceFrom(sv);  // a released handle throws, as everywhere
    if (!s) return false;
    double scale = s->scale > 0 ? s->scale : 1;
    CGImageRef cg = CGBitmapContextCreateImage(s->ctx);
    if (!cg) return true;
    d->image = (__bridge_transfer id)cg;
    d->w = s->width / scale;
    d->h = s->height / scale;
    return true;
  }
  Napi::Value iv = o.Get("image");
  double scale = BNumOr(o, "imageScale", 1);
  if (iv.IsObject() && !iv.IsExternal()) {
    Napi::Object r = iv.As<Napi::Object>();
    scale = BNumOr(r, "scale", scale);
    iv = r.Get("image");
  }
  if (!iv.IsExternal()) return true;
  CGImageRef cg = (CGImageRef)iv.As<Napi::External<void>>().Data();
  d->image = (__bridge id)cg;
  d->w = CGImageGetWidth(cg) / scale;
  d->h = CGImageGetHeight(cg) / scale;
  return true;
}

// With threaded mode's channel open, the drop carries the cheap forms of
// its payload itself — each item's types, and the strings of its text and
// URL types — since a worker cannot read the drag pasteboard back inside
// the destination callback, and after it the source may withdraw it.
static std::string DragItemsJson(NSPasteboard* pb) {
  NSMutableArray* out = [NSMutableArray array];
  for (NSPasteboardItem* item in pb.pasteboardItems) {
    NSMutableDictionary* strings = [NSMutableDictionary dictionary];
    for (NSString* t in item.types) {
      UTType* ut = [UTType typeWithIdentifier:t];
      if (!ut || !([ut conformsToType:UTTypeText] || [ut conformsToType:UTTypeURL]))
        continue;
      NSString* s = [item stringForType:t];
      if (s) strings[t] = s;
    }
    [out addObject:@{@"types" : item.types ?: @[], @"strings" : strings}];
  }
  NSData* d = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
  return d ? std::string((const char*)d.bytes, d.length) : "[]";
}

// The shared payload of the destination events: where (content view,
// top-left; and global top-left as gx/gy, like a mouse event), what the
// pasteboard carries, and what the source allows. `types` is the union over
// the pasteboard's items; `itemCount` says how many items carry them —
// a Finder drag of three files is three items of one public.file-url each,
// read per item through dragItemString. `local` is a drag begun by one of
// our own windows (beginDrag), whose number then follows.
static void EmitDragInfo(CALBackendView* view, const char* type,
                         id<NSDraggingInfo> info) {
  if (!CALListening()) return;
  NSWindow* win = view.window;
  CALEvent ev = WindowEvent(win, type);
  if (info) {
    NSPoint loc = info.draggingLocation;
    NSPoint p = [view convertPoint:loc fromView:nil];  // the view is flipped
    ev.Num("x", p.x);
    ev.Num("y", p.y);
    NSRect r = [win convertRectToScreen:NSMakeRect(loc.x, loc.y, 0, 0)];
    ev.Num("gx", r.origin.x);
    ev.Num("gy", PrimaryScreenTop() - r.origin.y);
    NSPasteboard* pb = info.draggingPasteboard;
    std::vector<std::string> types;
    for (NSString* t in pb.types) types.push_back(t.UTF8String);
    ev.Strs("types", std::move(types));
    ev.Num("itemCount", (double)pb.pasteboardItems.count);
    NSDragOperation mask = info.draggingSourceOperationMask;
    ev.Num("sourceMask", (double)mask);
    ev.Strs("operations", DragOpsOfMask(mask));
    id src = info.draggingSource;
    bool local = [src isKindOfClass:[CALBackendView class]];
    ev.Bool("local", local);
    if (local)
      ev.Num("sourceWindowNumber",
             (double)((CALBackendView*)src).window.windowNumber);
    ev.Num("sequence", (double)info.draggingSequenceNumber);
    if (CALChannelOpen() && strcmp(type, "drag-perform") == 0)
      ev.Json("items", DragItemsJson(pb));
  }
  CALEmit(std::move(ev));
}

// The source side's events: the pointer in global top-left coordinates,
// and for the end, the operation the destination performed ('none' when
// nothing took the drop) with `dropped` as its boolean.
static void EmitDragSession(CALBackendView* view, const char* type,
                            NSPoint screenPoint, const char* operation) {
  if (!CALListening()) return;
  CALEvent ev = WindowEvent(view.window, type);
  ev.Num("x", screenPoint.x);
  ev.Num("y", PrimaryScreenTop() - screenPoint.y);
  if (operation) {
    ev.Str("operation", operation);
    ev.Bool("dropped", strcmp(operation, "none") != 0);
  }
  CALEmit(std::move(ev));
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
  EmitDragInfo(self, "drag-enter", sender);
  return [self dropAnswer:sender];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  gDragPasteboard = sender.draggingPasteboard;
  EmitDragInfo(self, "drag-over", sender);
  return [self dropAnswer:sender];
}
- (void)draggingExited:(nullable id<NSDraggingInfo>)sender {
  EmitDragInfo(self, "drag-exit", sender);
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
  (void)sender;
  return dropAccept_;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  gDragPasteboard = sender.draggingPasteboard;
  EmitDragInfo(self, "drag-perform", sender);
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
  EmitDragSession(self, "drag-session-began", screenPoint, nullptr);
}
- (void)draggingSession:(NSDraggingSession*)session
           movedToPoint:(NSPoint)screenPoint {
  (void)session;
  EmitDragSession(self, "drag-session-moved", screenPoint, nullptr);
}
- (void)draggingSession:(NSDraggingSession*)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
  (void)session;
  EmitDragSession(self, "drag-session-ended", screenPoint,
                  DragOpName(operation));
}
@end

// registerDropTypes(win, types) — registerForDraggedTypes: on the hosting
// view; an empty list unregisters. Until this is called a window takes no
// drops and sees no drag events: AppKit routes a drag only to views
// registered for a type it carries.
// The hosting view of a verb's window, for a command: pump mode's checked
// in the call (a TypeError for anything else, as always), a worker's when
// its command runs (skipped then if it is not a createWindow2 window).
static bool OnBackendView(Napi::Value v, const char* fn,
                          void (^body)(CALBackendView* view)) {
  if (pthread_main_np()) {
    CALBackendView* view = BackendViewArg(v, fn);
    if (!view) return false;
    body(view);
    return true;
  }
  if (!v.IsExternal()) {
    Napi::TypeError::New(v.Env(), std::string(fn) + ": expected a createWindow2 window")
        .ThrowAsJavaScriptException();
    return false;
  }
  id target = CALHandleTarget(v);
  CALOnUI(^{
    NSWindow* win = CALResolve(target);
    if ([win.contentView isKindOfClass:[CALBackendView class]])
      body((CALBackendView*)win.contentView);
  });
  return true;
}

// The same resolution inside a command already on the UI thread.
static CALBackendView* BackendViewOf(id target) {
  NSWindow* win = CALResolve(target);
  return [win.contentView isKindOfClass:[CALBackendView class]]
             ? (CALBackendView*)win.contentView
             : nil;
}

static Napi::Value RegisterDropTypes(const Napi::CallbackInfo& info) {
  NSMutableArray<NSString*>* types = [NSMutableArray array];
  if (info[1].IsArray()) {
    Napi::Array a = info[1].As<Napi::Array>();
    for (uint32_t i = 0; i < a.Length(); i++)
      if (a.Get(i).IsString()) [types addObject:BToNSString(a.Get(i))];
  }
  OnBackendView(info[0], "registerDropTypes", ^(CALBackendView* view) {
    [view unregisterDraggedTypes];  // replace, never accumulate
    if (types.count) [view registerForDraggedTypes:types];
  });
  return info.Env().Undefined();
}

// setDropResponse(win, { accept, operation? }) — the view's answer for the
// drag in flight. Set during a drag-enter or drag-over callback it answers
// that question; it stays in force for the drag-over events that follow
// until changed, and resets to a refusal when a new drag enters. Set during
// drag-perform, `accept: false` withdraws the drop. `operation` is one of
// copy | move | link | generic | private | delete; absent, the conventional
// choice among what the source allows.
// From a worker it is a command, so it cannot answer the draggingEntered:
// that is running as the event crosses: it is the standing answer for the
// drag-over questions that follow (the rule for what AppKit asks
// synchronously: push it ahead).
static Napi::Value SetDropResponse(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Object o = info[1].IsObject() ? info[1].As<Napi::Object>()
                                      : Napi::Object::New(env);
  bool accept = BBoolOr(o, "accept", false);
  NSString* op = BStrOr(o, "operation", nil);
  OnBackendView(info[0], "setDropResponse", ^(CALBackendView* view) {
    view->dropAccept_ = accept;
    view->dropOp_ = op.length ? op : nil;
  });
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
// Off the main thread each takes a callback (its last argument); in
// threaded mode the drop's own `items` usually makes the call unnecessary.
static Napi::Value DragItems(const Napi::CallbackInfo& info) {
  return CALAnswer(info, "dragItems", ^CALValueBlock {
    std::vector<std::vector<std::string>> all;
    for (NSPasteboardItem* item in CurrentDragPasteboard().pasteboardItems) {
      std::vector<std::string> types;
      for (NSString* t in item.types) types.push_back(t.UTF8String);
      all.push_back(std::move(types));
    }
    return ^Napi::Value(Napi::Env e) {
      Napi::Array out = Napi::Array::New(e);
      uint32_t n = 0;
      for (const std::vector<std::string>& types : all) {
        Napi::Object o = Napi::Object::New(e);
        Napi::Array ta = Napi::Array::New(e);
        uint32_t k = 0;
        for (const std::string& t : types) ta.Set(k++, t);
        o.Set("types", ta);
        out.Set(n++, o);
      }
      return out;
    };
  });
}

// On the UI thread: the item at an index read on the calling thread.
static NSPasteboardItem* DragItemAt(double i) {
  NSArray<NSPasteboardItem*>* items = CurrentDragPasteboard().pasteboardItems;
  if (!(i >= 0 && i < (double)items.count)) return nil;
  return items[(NSUInteger)i];
}

static double DragIndexArg(Napi::Value v) {
  return v.IsNumber() ? v.As<Napi::Number>().DoubleValue() : -1;
}

static Napi::Value DragItemData(const Napi::CallbackInfo& info) {
  double index = DragIndexArg(info[0]);
  NSString* type = info[1].IsString() ? BToNSString(info[1]) : nil;
  return CALAnswer(info, "dragItemData", ^CALValueBlock {
    NSPasteboardItem* item = DragItemAt(index);
    NSData* d = item && type ? [item dataForType:type] : nil;
    return ^Napi::Value(Napi::Env e) {
      return d ? Napi::Value(Napi::Buffer<uint8_t>::Copy(e, (const uint8_t*)d.bytes, d.length))
               : Napi::Value(e.Null());
    };
  });
}

static Napi::Value DragItemString(const Napi::CallbackInfo& info) {
  double index = DragIndexArg(info[0]);
  NSString* type = info[1].IsString() ? BToNSString(info[1]) : nil;
  return CALAnswer(info, "dragItemString", ^CALValueBlock {
    NSPasteboardItem* item = DragItemAt(index);
    NSString* s = item && type ? [item stringForType:type] : nil;
    bool has = s != nil;
    std::string text = has ? s.UTF8String : "";
    return ^Napi::Value(Napi::Env e) {
      return has ? Napi::Value(Napi::String::New(e, text)) : Napi::Value(e.Null());
    };
  });
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
//
// From a worker the session is begun by a modal command and the call
// answers undefined: the answer is the drag-session-began event, or a
// drag-session-ended with nothing dropped when no session began (no press
// in flight and no x/y given included). `provide` answers AppKit
// synchronously, which a worker cannot: there it is a TypeError, and every
// representation's value is given up front.
static Napi::Value BeginDrag(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  bool main = pthread_main_np();
  if (main) {
    if (!BackendViewArg(info[0], "beginDrag")) return env.Undefined();
  } else if (!info[0].IsExternal()) {
    Napi::TypeError::New(env, "beginDrag: expected a createWindow2 window")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (!info[1].IsObject()) {
    Napi::TypeError::New(env, "beginDrag: expected an options object")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  Napi::Object o = info[1].As<Napi::Object>();
  double x = BNumOr(o, "x", NAN), y = BNumOr(o, "y", NAN);

  CALDragProvider* provider = nil;
  Napi::Value provide = o.Get("provide");
  if (provide.IsFunction()) {
    if (!main) {
      Napi::TypeError::New(env, "beginDrag: `provide` answers AppKit synchronously, "
                                "which a worker cannot — give every value up front")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    provider = [[CALDragProvider alloc] init];
    provider->env_ = env;
    provider->fn_ = Napi::Persistent(provide.As<Napi::Function>());
  }
  PbItemsSpec items = ParsePasteboardItems(env, o.Get("items"), provider != nil);
  if (items.empty()) {
    Napi::TypeError::New(env, "beginDrag: items must name at least one item")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  DragImageSpec image;
  if (!ParseDragImage(o, &image)) return env.Undefined();
  double imageW = o.Has("imageWidth") ? BNumOr(o, "imageWidth", NAN) : NAN;
  double imageH = o.Has("imageHeight") ? BNumOr(o, "imageHeight", NAN) : NAN;
  double imageX = BNumOr(o, "imageX", NAN), imageY = BNumOr(o, "imageY", NAN);
  NSDragOperation mask = DragMaskFrom(o.Get("operations"));
  NSDragOperation maskOutside =
      o.Has("operationsOutside") ? DragMaskFrom(o.Get("operationsOutside")) : mask;
  bool ignoreModifiers = BBoolOr(o, "ignoreModifiers", false);
  bool slideBack = BBoolOr(o, "slideBack", true);
  id target = CALHandleTarget(info[0]);

  __block bool began = false, needXY = false;
  CALOnUIModal(^{
    CALBackendView* view = BackendViewOf(target);
    if (!view) return;
    NSEvent* press = view->lastPress_;
    if (press && press.window != view.window) press = nil;
    double px = x, py = y;
    if (std::isnan(px) || std::isnan(py)) {
      if (!press) {
        needXY = true;
        if (!main)
          EmitDragSession(view, "drag-session-ended", NSEvent.mouseLocation, "none");
        return;
      }
      NSPoint p = [view convertPoint:press.locationInWindow fromView:nil];
      px = p.x;
      py = p.y;
    }
    if (!press) {
      NSPoint wp = [view convertPoint:NSMakePoint(px, py) toView:nil];
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
    NSArray<NSPasteboardItem*>* pbItems = BuildPasteboardItems(items, provider);
    if (provider) provider->items_ = pbItems;

    double w = image.w, h = image.h;
    NSImage* img = image.image ? [[NSImage alloc] initWithCGImage:(__bridge CGImageRef)image.image
                                                             size:NSMakeSize(w, h)]
                               : nil;
    if (!std::isnan(imageW)) w = imageW;
    if (!std::isnan(imageH)) h = imageH;
    double ix = std::isnan(imageX) ? px - w / 2 : imageX;
    double iy = std::isnan(imageY) ? py - h / 2 : imageY;
    if (!img) {
      img = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
      w = h = 1;
      ix = px;
      iy = py;
    }
    // the view is flipped, so a top-left frame is what setDraggingFrame: takes
    NSRect frame = NSMakeRect(ix, iy, w, h);
    NSMutableArray<NSDraggingItem*>* dragItems = [NSMutableArray array];
    for (NSPasteboardItem* item in pbItems) {
      NSDraggingItem* di = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
      [di setDraggingFrame:frame contents:img];
      [dragItems addObject:di];
    }

    view->sourceMask_ = mask;
    view->sourceMaskOutside_ = maskOutside;
    view->ignoreModifiers_ = ignoreModifiers;
    view->dragProvider_ = provider;  // alive for as long as the pasteboard may ask

    NSDraggingSession* session = [view beginDraggingSessionWithItems:dragItems
                                                               event:press
                                                              source:view];
    if (!session) {
      if (!main)
        EmitDragSession(view, "drag-session-ended", NSEvent.mouseLocation, "none");
      return;
    }
    session.animatesToStartingPositionsOnCancelOrFail = slideBack;
    began = true;
  });
  if (!main) return env.Undefined();
  if (needXY) {
    Napi::TypeError::New(env, "beginDrag: x and y are required without a press in flight")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  return Napi::Boolean::New(env, began);
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
// Off the main thread: postDragEvent(win, phase, opts, cb), the answer
// through cb.
static NSInteger gPostedDragSequence = 0;  // the UI thread's

static Napi::Value PostDragEvent(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (pthread_main_np()) {
    if (!BackendViewArg(info[0], "postDragEvent")) return env.Undefined();
  } else if (!info[0].IsExternal()) {
    Napi::TypeError::New(env, "postDragEvent: expected a createWindow2 window")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  std::string phase = info[1].IsString() ? info[1].As<Napi::String>().Utf8Value() : "";
  if (phase != "enter" && phase != "over" && phase != "exit" && phase != "drop") {
    Napi::TypeError::New(env, "postDragEvent: phase must be enter | over | exit | drop")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  Napi::Object o = info.Length() > 2 && info[2].IsObject()
                       ? info[2].As<Napi::Object>()
                       : Napi::Object::New(env);
  bool hasItems = o.Has("items");
  PbItemsSpec items = ParsePasteboardItems(env, o.Get("items"), false);
  double x = BNumOr(o, "x", 0), y = BNumOr(o, "y", 0);
  NSDragOperation mask = DragMaskFrom(o.Get("operations"));
  bool local = BBoolOr(o, "local", false);
  id target = CALHandleTarget(info[0]);

  return CALAnswer(info, "postDragEvent", ^CALValueBlock {
    CALBackendView* view = BackendViewOf(target);
    if (!view) return ^Napi::Value(Napi::Env e) { return e.Undefined(); };
    // one pasteboard per drag: a new one on enter, its contents whatever
    // `items` the latest phase named (a drag's payload is fixed in AppKit,
    // but a test may want to say it once, at the drop)
    if (phase == "enter" || !gPostedPasteboard) {
      if (gPostedPasteboard) [gPostedPasteboard releaseGlobally];
      gPostedPasteboard = [NSPasteboard pasteboardWithUniqueName];
      gPostedDragSequence++;
    }
    if (phase == "enter" || hasItems) {
      [gPostedPasteboard clearContents];
      [gPostedPasteboard writeObjects:BuildPasteboardItems(items, nil)];
    }
    CALPostedDragInfo* di = [[CALPostedDragInfo alloc] init];
    di->window_ = view.window;
    di->pasteboard_ = gPostedPasteboard;
    di->location_ = [view convertPoint:NSMakePoint(x, y) toView:nil];
    di->mask_ = mask;
    di->source_ = local ? view : nil;
    di->sequence_ = gPostedDragSequence;
    di->formation_ = NSDraggingFormationDefault;
    di->valid_ = (NSInteger)gPostedPasteboard.pasteboardItems.count;

    if (phase == "enter" || phase == "over") {
      std::string op = DragOpName(phase == "enter" ? [view draggingEntered:di]
                                                   : [view draggingUpdated:di]);
      return ^Napi::Value(Napi::Env e) { return Napi::String::New(e, op); };
    }
    if (phase == "exit") {
      [view draggingExited:di];
      return ^Napi::Value(Napi::Env e) { return e.Undefined(); };
    }
    bool taken = [view prepareForDragOperation:di] && [view performDragOperation:di];
    if (taken && [view respondsToSelector:@selector(concludeDragOperation:)])
      [view concludeDragOperation:di];
    return BoolAnswer(taken);
  });
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
  BFN("setWindowIgnoresMouseEvents", SetWindowIgnoresMouseEvents);
  BFN("windowNumberAtPoint", WindowNumberAtPoint);
  BFN("setWindowFrame", SetWindowFrame);
  BFN("getWindowFrame", GetWindowFrame);
  BFN("windowState", WindowStateFn);
  BFN("setWindowMinMax", SetWindowMinMax);
  BFN("setResizeHandshake", SetResizeHandshake);
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
  BFN("blitSurface", BlitSurface);
  BFN("surfaceSize", SurfaceSize);
  BFN("surfaceIsInUse", SurfaceIsInUse);
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
  BFN("ctxSetBlendMode", CtxSetBlendMode);
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
  BFN("createStatusItem", CreateStatusItem);
  BFN("setStatusItem", SetStatusItem);
  BFN("setStatusItemMenu", SetStatusItemMenu);
  BFN("removeStatusItem", RemoveStatusItem);
  BFN("statusItemInfo", StatusItemInfo);
  BFN("activateStatusItemMenuItem", ActivateStatusItemMenuItem);
  BFN("clickStatusItem", ClickStatusItem);
  BFN("snapshotStatusItem", SnapshotStatusItem);
  BFN("openPanel", OpenPanelFn);
  BFN("savePanel", SavePanelFn);
  BFN("cancelPanel", CancelPanelFn);
  BFN("contentTypeFor", ContentTypeForFn);
  BFN("setDockMenu", SetDockMenuFn);
  BFN("dockMenuInfo", DockMenuInfoFn);
  BFN("activateDockMenuItem", ActivateDockMenuItemFn);
  BFN("initApp", InitAppFn);
  BFN("setActivationPolicy", SetActivationPolicyFn);
  BFN("setDockBadge", SetDockBadgeFn);
  BFN("requestUserAttention", RequestUserAttentionFn);
  BFN("cancelUserAttention", CancelUserAttentionFn);
  BFN("setAppName", SetAppNameFn);
  BFN("appInfo", AppInfoFn);
  BFN("activationPolicy", ActivationPolicyFn);
  BFN("measureControl", MeasureControl);
  BFN("drawControlIntoSurface", DrawControlIntoSurface);
  BFN("listScreens", ListScreens);
  BFN("accessibilityDisplayOptions", AccessibilityDisplayOptionsFn);
  BFN("postAccessibilityDisplayChange", PostAccessibilityDisplayChange);
  BFN("setCursor", SetCursorFn);
  BFN("postKeyEvent", PostKeyEvent);
  BFN("postAppleEvent", PostAppleEvent);
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
