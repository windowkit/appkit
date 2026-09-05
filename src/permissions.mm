// @windowkit/appkit permissions.mm — the macOS privacy (TCC) authorizations
// an app may need: the current status, the system prompt where a framework
// offers one, and the Settings pane for the grants that can only happen there.
//
// Mechanism only, policy stays in the renderer. Each kind is one framework's
// own pair of calls, and a switch over the kind is the whole bridge:
//
//   camera, microphone   AVCaptureDevice authorizationStatusForMediaType: /
//                        requestAccessForMediaType: — the completion lands on
//                        an arbitrary queue and comes back through a
//                        thread-safe function
//   screen-recording     CGPreflightScreenCaptureAccess /
//                        CGRequestScreenCaptureAccess
//   accessibility        AXIsProcessTrusted / AXIsProcessTrustedWithOptions
//                        with the prompt option
//   input-monitoring     IOHIDCheckAccess / IOHIDRequestAccess (listen)
//   automation           AEDeterminePermissionToAutomateTarget for one target
//                        bundle id; the asking form blocks while the prompt is
//                        up, so it runs off the main thread
//   location             CLLocationManager.authorizationStatus /
//                        requestWhenInUseAuthorization, answered through the
//                        delegate on the main run loop — i.e. during the pump
//
// Every status that crosses to JS is one of 'authorized' | 'denied' |
// 'restricted' | 'notDetermined'. Screen recording and accessibility only
// ever answer with a bool, so they never say notDetermined; their "request"
// posts the system's own go-to-Settings dialog and returns at once — the
// user finishes the grant in Settings, which is what openPrivacySettings is
// for. The folder grants (Desktop, Documents, Downloads) need nothing here:
// reading the directory is the prompt, and EPERM is the denial.
//
// Every request answers asynchronously, once, through the callback — never
// inside the requesting call — and a pending request holds the event loop
// open like pending I/O until the user has answered.

#include <napi.h>
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOHIDLib.h>

#include <cstring>
#include <string>

static const char* const kAuthorized = "authorized";
static const char* const kDenied = "denied";
static const char* const kRestricted = "restricted";
static const char* const kNotDetermined = "notDetermined";

enum class Kind {
  Camera,
  Microphone,
  ScreenRecording,
  Accessibility,
  InputMonitoring,
  Automation,
  Location,
};

static const char* const kKindNames =
    "camera, microphone, screen-recording, accessibility, input-monitoring, "
    "automation, location";

static bool ParseKind(const std::string& s, Kind* out) {
  if (s == "camera") *out = Kind::Camera;
  else if (s == "microphone") *out = Kind::Microphone;
  else if (s == "screen-recording") *out = Kind::ScreenRecording;
  else if (s == "accessibility") *out = Kind::Accessibility;
  else if (s == "input-monitoring") *out = Kind::InputMonitoring;
  else if (s == "automation") *out = Kind::Automation;
  else if (s == "location") *out = Kind::Location;
  else return false;
  return true;
}

// (kind, opts?) — the kind string, and for 'automation' the target bundle id
// from opts.target. Throws a TypeError and returns false on a bad shape.
static bool ParseKindArgs(const char* fn, const Napi::CallbackInfo& info,
                          Kind* kind, NSString** target) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsString()) {
    Napi::TypeError::New(env, std::string(fn) + ": expected a kind string (" +
                                  kKindNames + ")")
        .ThrowAsJavaScriptException();
    return false;
  }
  std::string name = info[0].As<Napi::String>().Utf8Value();
  if (!ParseKind(name, kind)) {
    Napi::TypeError::New(env, std::string(fn) + ": unknown kind '" + name +
                                  "' (" + kKindNames + ")")
        .ThrowAsJavaScriptException();
    return false;
  }
  *target = nil;
  if (*kind == Kind::Automation) {
    Napi::Value t;
    if (info.Length() > 1 && info[1].IsObject()) {
      t = info[1].As<Napi::Object>().Get("target");
    }
    if (t.IsEmpty() || !t.IsString()) {
      Napi::TypeError::New(env, std::string(fn) +
                                    ": 'automation' needs { target: <bundle "
                                    "id of the app to send Apple Events to> }")
          .ThrowAsJavaScriptException();
      return false;
    }
    std::string s = t.As<Napi::String>().Utf8Value();
    *target = [NSString stringWithUTF8String:s.c_str()];
  }
  return true;
}

// --- per-framework status --------------------------------------------------

static const char* AVStatus(AVMediaType type) {
  switch ([AVCaptureDevice authorizationStatusForMediaType:type]) {
    case AVAuthorizationStatusAuthorized: return kAuthorized;
    case AVAuthorizationStatusDenied: return kDenied;
    case AVAuthorizationStatusRestricted: return kRestricted;
    case AVAuthorizationStatusNotDetermined:
    default: return kNotDetermined;
  }
}

static const char* HidStatus() {
  switch (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)) {
    case kIOHIDAccessTypeGranted: return kAuthorized;
    case kIOHIDAccessTypeDenied: return kDenied;
    case kIOHIDAccessTypeUnknown:
    default: return kNotDetermined;
  }
}

static const char* LocationStatusOf(CLLocationManager* m) {
  switch (m.authorizationStatus) {
    // macOS has only the one grant (the SDK marks WhenInUse iOS-only)
    case kCLAuthorizationStatusAuthorizedAlways: return kAuthorized;
    case kCLAuthorizationStatusDenied: return kDenied;
    case kCLAuthorizationStatusRestricted: return kRestricted;
    case kCLAuthorizationStatusNotDetermined:
    default: return kNotDetermined;
  }
}

// One manager, created on the main thread, answers status queries; requests
// get their own (see CALLocationRequest) so the delegate traffic is per call.
static CLLocationManager* LocationStatusManager() {
  static CLLocationManager* m = nil;
  if (!m) m = [CLLocationManager new];
  return m;
}

// TCC's answer for sending Apple Events to `bundleId`. With `ask`, the call
// blocks while the consent dialog is up. procNotFound means the target is
// not running — TCC only answers for a running target, so the caller turns
// that into an error rather than a status.
static OSStatus AutomationPermission(NSString* bundleId, bool ask) {
  const char* s = bundleId.UTF8String;
  AEAddressDesc target;
  OSErr err = AECreateDesc(typeApplicationBundleID, s, strlen(s), &target);
  if (err != noErr) return err;
  OSStatus st = AEDeterminePermissionToAutomateTarget(&target, typeWildCard,
                                                      typeWildCard, ask);
  AEDisposeDesc(&target);
  return st;
}

static const char* AutomationStatus(OSStatus st) {
  if (st == noErr) return kAuthorized;
  if (st == errAEEventWouldRequireUserConsent) return kNotDetermined;
  return kDenied;  // errAEEventNotPermitted, or anything else TCC refused
}

static bool ThrowIfTargetNotRunning(Napi::Env env, const char* fn,
                                    NSString* target, OSStatus st) {
  if (st != procNotFound) return false;
  Napi::Error::New(env, std::string(fn) + ": automation target '" +
                            target.UTF8String +
                            "' is not running; TCC only answers for a "
                            "running target")
      .ThrowAsJavaScriptException();
  return true;
}

// --- the answer path -------------------------------------------------------

// Deliver one status to the request's callback as cb(granted, status) on the
// JS thread, from any thread, then let the thread-safe function go. The
// status strings are the static literals above, so a bare pointer travels.
static void Answer(Napi::ThreadSafeFunction tsfn, const char* status) {
  tsfn.BlockingCall(
      const_cast<char*>(status),
      [](Napi::Env env, Napi::Function cb, char* s) {
        cb.Call({Napi::Boolean::New(env, strcmp(s, kAuthorized) == 0),
                 Napi::String::New(env, s)});
      });
  tsfn.Release();
}

// A location request: its own CLLocationManager whose delegate reports the
// decision. The delegate is also told the current status right after it is
// set, which is notDetermined while the prompt is still up — that echo is
// skipped; the first determined status answers.
@interface CALLocationRequest : NSObject <CLLocationManagerDelegate> {
 @public
  CLLocationManager* mgr_;
  Napi::ThreadSafeFunction tsfn_;
  bool done_;
}
@end

static NSMutableArray<CALLocationRequest*>* gLocationRequests = nil;

@implementation CALLocationRequest
- (void)locationManagerDidChangeAuthorization:(CLLocationManager*)m {
  if (done_) return;
  const char* s = LocationStatusOf(m);
  if (s == kNotDetermined) return;
  done_ = true;
  m.delegate = nil;
  Answer(tsfn_, s);
  [gLocationRequests removeObject:self];
}
@end

static void StartLocationRequest(Napi::ThreadSafeFunction tsfn) {
  CALLocationRequest* r = [CALLocationRequest new];
  r->tsfn_ = tsfn;
  r->done_ = false;
  r->mgr_ = [CLLocationManager new];
  r->mgr_.delegate = r;
  if (!gLocationRequests) gLocationRequests = [NSMutableArray new];
  [gLocationRequests addObject:r];
  [r->mgr_ requestWhenInUseAuthorization];
}

// --- the natives -----------------------------------------------------------

// authorizationStatus(kind, opts?) -> 'authorized' | 'denied' | 'restricted'
// | 'notDetermined'. Never prompts.
static Napi::Value AuthorizationStatus(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Kind kind;
  NSString* target;
  if (!ParseKindArgs("authorizationStatus", info, &kind, &target))
    return env.Undefined();
  @autoreleasepool {
    const char* s = kNotDetermined;
    switch (kind) {
      case Kind::Camera: s = AVStatus(AVMediaTypeVideo); break;
      case Kind::Microphone: s = AVStatus(AVMediaTypeAudio); break;
      case Kind::ScreenRecording:
        s = CGPreflightScreenCaptureAccess() ? kAuthorized : kDenied;
        break;
      case Kind::Accessibility:
        s = AXIsProcessTrusted() ? kAuthorized : kDenied;
        break;
      case Kind::InputMonitoring: s = HidStatus(); break;
      case Kind::Automation: {
        OSStatus st = AutomationPermission(target, false);
        if (ThrowIfTargetNotRunning(env, "authorizationStatus", target, st))
          return env.Undefined();
        s = AutomationStatus(st);
        break;
      }
      case Kind::Location: s = LocationStatusOf(LocationStatusManager()); break;
    }
    return Napi::String::New(env, s);
  }
}

// requestAuthorization(kind, opts?, cb) — raises the system prompt where the
// framework offers one; cb(granted, status) once, asynchronously.
static Napi::Value RequestAuthorization(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Kind kind;
  NSString* target;
  if (!ParseKindArgs("requestAuthorization", info, &kind, &target))
    return env.Undefined();
  size_t cbAt = info.Length() > 1 && info[1].IsFunction() ? 1 : 2;
  if (info.Length() <= cbAt || !info[cbAt].IsFunction()) {
    Napi::TypeError::New(env, "requestAuthorization: expected a callback "
                              "(kind, opts?, cb)")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  @autoreleasepool {
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env, info[cbAt].As<Napi::Function>(), "appkit:requestAuthorization",
        0, 1);
    switch (kind) {
      case Kind::Camera:
      case Kind::Microphone: {
        AVMediaType type =
            kind == Kind::Camera ? AVMediaTypeVideo : AVMediaTypeAudio;
        [AVCaptureDevice requestAccessForMediaType:type
                                 completionHandler:^(BOOL) {
                                   Answer(tsfn, AVStatus(type));
                                 }];
        break;
      }
      case Kind::ScreenRecording:
        // prompts once (the go-to-Settings dialog) when not yet asked, and
        // returns the current grant either way
        Answer(tsfn, CGRequestScreenCaptureAccess() ? kAuthorized : kDenied);
        break;
      case Kind::Accessibility: {
        NSDictionary* opts =
            @{(__bridge NSString*)kAXTrustedCheckOptionPrompt : @YES};
        bool ok = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
        Answer(tsfn, ok ? kAuthorized : kDenied);
        break;
      }
      case Kind::InputMonitoring: {
        // the prompt is posted and the call returns; a still-open prompt
        // reads back as notDetermined
        bool ok = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        Answer(tsfn, ok ? kAuthorized : HidStatus());
        break;
      }
      case Kind::Automation: {
        OSStatus st = AutomationPermission(target, false);
        if (ThrowIfTargetNotRunning(env, "requestAuthorization", target, st)) {
          tsfn.Release();
          return env.Undefined();
        }
        if (st != errAEEventWouldRequireUserConsent) {
          Answer(tsfn, AutomationStatus(st));
          break;
        }
        // the asking form blocks until the user answers the consent dialog:
        // off the main thread so node's loop keeps turning meanwhile
        NSString* bundleId = target;
        dispatch_async(
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
              Answer(tsfn, AutomationStatus(AutomationPermission(bundleId, true)));
            });
        break;
      }
      case Kind::Location: StartLocationRequest(tsfn); break;
    }
  }
  return env.Undefined();
}

// openPrivacySettings(kind?) -> bool — best-effort deep link to the Privacy
// pane of System Settings, or its top level with no kind.
static Napi::Value OpenPrivacySettings(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  std::string kind;
  if (info.Length() > 0 && !info[0].IsUndefined() && !info[0].IsNull()) {
    if (!info[0].IsString()) {
      Napi::TypeError::New(env, "openPrivacySettings: expected a kind string")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    kind = info[0].As<Napi::String>().Utf8Value();
  }
  const char* anchor = nullptr;
  if (kind.empty()) anchor = "Privacy";
  else if (kind == "camera") anchor = "Privacy_Camera";
  else if (kind == "microphone") anchor = "Privacy_Microphone";
  else if (kind == "screen-recording") anchor = "Privacy_ScreenCapture";
  else if (kind == "accessibility") anchor = "Privacy_Accessibility";
  else if (kind == "input-monitoring") anchor = "Privacy_ListenEvent";
  else if (kind == "automation") anchor = "Privacy_Automation";
  else if (kind == "location") anchor = "Privacy_LocationServices";
  else if (kind == "files-and-folders") anchor = "Privacy_FilesAndFolders";
  else if (kind == "full-disk-access") anchor = "Privacy_AllFiles";
  if (!anchor) {
    Napi::TypeError::New(env, "openPrivacySettings: unknown kind '" + kind +
                                  "' (" + kKindNames +
                                  ", files-and-folders, full-disk-access)")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  @autoreleasepool {
    NSString* url = [NSString
        stringWithFormat:@"x-apple.systempreferences:com.apple.preference."
                         @"security?%s",
                         anchor];
    bool ok = [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
    return Napi::Boolean::New(env, ok);
  }
}

// ---------------------------------------------------------------------------
// registration (called from addon.mm's Init)
// ---------------------------------------------------------------------------

void InitPermissions(Napi::Env env, Napi::Object exports) {
  exports.Set("authorizationStatus",
              Napi::Function::New(env, AuthorizationStatus));
  exports.Set("requestAuthorization",
              Napi::Function::New(env, RequestAuthorization));
  exports.Set("openPrivacySettings",
              Napi::Function::New(env, OpenPrivacySettings));
}
