// @windowkit/appkit notifications.mm — user notifications (banners, the
// Notification Center list, action buttons) through the UserNotifications
// framework, UNUserNotificationCenter. The cocoa counterpart of freedesktop's
// org.freedesktop.Notifications; NSUserNotification is the deprecated prior
// art and is not used.
//
// Mechanism only, policy stays in the renderer: what to say, when to ask for
// authorization, what to do with a refusal.
//
//   notificationSettings(cb)                     availability + authorization + per-channel settings
//   requestNotificationAuthorization(opts, cb)   the system prompt; cb(granted, error)
//   setNotificationCategories([...])             action sets a notification can name
//   postNotification(props, cb?) -> identifier   a banner; reusing an identifier replaces it
//   updateNotification(id, props, cb?)           = post with that identifier
//   removeNotification(id | [ids])               delivered and pending
//   deliveredNotifications(cb), notificationCategories(cb)   readback
//   events: notification-action { identifier, actionId, categoryId, userInfo }
//           notification-dismissed { identifier, reason, categoryId, userInfo }
//
// The bundle-identity constraint. UNUserNotificationCenter attributes every
// banner to an app the system knows — a bundle with a CFBundleIdentifier
// that Launch Services can see — and +currentNotificationCenter raises
// NSInternalInconsistencyException ("bundleProxyForCurrentProcess is nil")
// in a process that is none, i.e. a bare `node`. So the centre is probed
// once, at module load, behind the bundle-id check and a @try; the outcome
// is a capability the renderer reads (settings.available, with the reason),
// never a silent drop: every native but notificationSettings throws in an
// unbundled process.
//
// The delegate is set at module load too, before initApp()'s finishLaunching,
// which is what the framework requires for a response that launched the
// app (a click on a banner while the app was not running) to be delivered
// at all. Its methods carry no thread guarantee, so a response crosses to
// node's loop through a thread-safe function and is then emitted through
// the same backend callback every other event takes; whatever arrives
// before setBackendEventCallback() is held and replayed, in order, at the
// start of the first pump2() with a listener.
//
// Categories are handed to the system as a whole set, and the system keeps
// none for an app it has not yet authorized — notificationCategories reads
// back empty until then — so the last set is kept here and handed over
// again when a request for authorization is granted.
//
// Dismissals. UN reports an explicit dismissal to the delegate only for a
// notification whose category carries UNNotificationCategoryOptionCustomDismissAction,
// so every category registered here carries it (opt out per category with
// customDismissAction: false), and a notification posted with no categoryId
// is filed under a bridge-owned category that has it. A banner that times
// out into Notification Center, or is removed by removeNotification, is not
// reported by the system and produces no event.
//
// userInfo is opaque: it is JSON.stringify'd on the way in, carried as one
// string under a bridge key, and JSON.parse'd on the way back — so whatever
// JSON can hold round-trips exactly, and nothing else is accepted.

#include <napi.h>
#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

#include <string>
#include <vector>

// backend.mm: the one backend event callback
bool CALHasBackendCb();
void CALEmitBackendEvent(Napi::Env env, Napi::Object ev);

static NSString* const kDefaultCategory = @"appkit.default";
static NSString* const kUserInfoKey = @"appkit.userInfo";

// --- helpers (self-contained, like the other faces) ------------------------

static NSString* NToNSString(Napi::Value v) {
  std::string s = v.As<Napi::String>().Utf8Value();
  return [NSString stringWithUTF8String:s.c_str()];
}

static bool NThrowType(Napi::Env env, const std::string& msg) {
  Napi::TypeError::New(env, msg).ThrowAsJavaScriptException();
  return false;
}

// o[k] as a string into *out (nil when absent, null or undefined); a value
// of any other type is a TypeError.
static bool NOptString(Napi::Env env, Napi::Object o, const char* k,
                       const char* fn, NSString** out) {
  *out = nil;
  if (!o.Has(k)) return true;
  Napi::Value v = o.Get(k);
  if (v.IsUndefined() || v.IsNull()) return true;
  if (!v.IsString()) {
    return NThrowType(env, std::string(fn) + ": '" + k + "' must be a string");
  }
  *out = NToNSString(v);
  return true;
}

static bool NOptBool(Napi::Env env, Napi::Object o, const char* k,
                     const char* fn, bool d, bool* out) {
  *out = d;
  if (!o.Has(k)) return true;
  Napi::Value v = o.Get(k);
  if (v.IsUndefined() || v.IsNull()) return true;
  if (!v.IsBoolean()) {
    return NThrowType(env, std::string(fn) + ": '" + k + "' must be a boolean");
  }
  *out = v.As<Napi::Boolean>().Value();
  return true;
}

static Napi::Value JsonStringify(Napi::Env env, Napi::Value v) {
  Napi::Object json = env.Global().Get("JSON").As<Napi::Object>();
  return json.Get("stringify").As<Napi::Function>().Call(json, {v});
}

static Napi::Value JsonParse(Napi::Env env, NSString* s) {
  Napi::Object json = env.Global().Get("JSON").As<Napi::Object>();
  return json.Get("parse").As<Napi::Function>().Call(
      json, {Napi::String::New(env, s.UTF8String)});
}

// The JSON string filed under the bridge key, or nil.
static NSString* UserInfoJson(NSDictionary* userInfo) {
  id v = userInfo[kUserInfoKey];
  return [v isKindOfClass:NSString.class] ? (NSString*)v : nil;
}

static Napi::Value StringOrNull(Napi::Env env, NSString* s) {
  if (!s.length) return env.Null();
  return Napi::String::New(env, s.UTF8String);
}

// --- the centre, probed once -------------------------------------------------

@class CALNotificationDelegate;

static bool gProbed = false;
static UNUserNotificationCenter* gCenter = nil;
static NSString* gUnavailable = nil;               // why, when gCenter is nil
static CALNotificationDelegate* gDelegate = nil;   // the centre's delegate is weak
// The category set as last handed to the system. The system keeps no
// categories for an app it has not yet authorized (the readback is empty
// until then), so a grant re-applies this set; main thread only.
static NSSet<UNNotificationCategory*>* gCategories = nil;

// A response, copied out of the framework's objects so it can travel to the
// JS thread and wait there for a listener.
struct NotifEvent {
  std::string type;
  std::string identifier;
  std::string actionId;    // notification-action: 'default' for the body click
  std::string reason;      // notification-dismissed
  std::string categoryId;  // empty: none (the bridge's own category is hidden)
  bool hasUserInfo = false;
  std::string userInfoJson;
  bool hasUserText = false;
  std::string userText;
};

static void CallJsEvent(Napi::Env env, Napi::Function, void*, NotifEvent* ev);
using EventTsfn = Napi::TypedThreadSafeFunction<void, NotifEvent, CallJsEvent>;
static EventTsfn gEvents;
static std::vector<NotifEvent*> gHeld;

static Napi::Object EventObject(Napi::Env env, const NotifEvent& ev) {
  Napi::Object o = Napi::Object::New(env);
  o.Set("type", ev.type);
  o.Set("identifier", ev.identifier);
  if (!ev.actionId.empty()) o.Set("actionId", ev.actionId);
  if (!ev.reason.empty()) o.Set("reason", ev.reason);
  o.Set("categoryId", ev.categoryId.empty()
                          ? env.Null()
                          : Napi::String::New(env, ev.categoryId));
  if (ev.hasUserInfo) {
    Napi::Value v = JsonParse(env, [NSString stringWithUTF8String:ev.userInfoJson.c_str()]);
    if (env.IsExceptionPending()) {
      // not our own output after all; hand it over as it is rather than fail
      (void)env.GetAndClearPendingException();
      v = Napi::String::New(env, ev.userInfoJson);
    }
    o.Set("userInfo", v);
  }
  if (ev.hasUserText) o.Set("userText", ev.userText);
  return o;
}

static void EmitOrHold(Napi::Env env, NotifEvent* ev) {
  if (!CALHasBackendCb()) {
    gHeld.push_back(ev);
    return;
  }
  Napi::HandleScope scope(env);
  CALEmitBackendEvent(env, EventObject(env, *ev));
  delete ev;
}

// Called at the start of pump2 (backend.mm): what arrived before a listener
// goes out ahead of that tick's input, in arrival order.
void CALNotificationsReplayHeld(Napi::Env env) {
  if (gHeld.empty() || !CALHasBackendCb()) return;
  std::vector<NotifEvent*> held;
  held.swap(gHeld);
  for (NotifEvent* ev : held) EmitOrHold(env, ev);
}

static void CallJsEvent(Napi::Env env, Napi::Function, void*, NotifEvent* ev) {
  if ((napi_env)env == nullptr) {  // the function is being torn down
    delete ev;
    return;
  }
  CALNotificationsReplayHeld(env);  // keep order behind anything still held
  EmitOrHold(env, ev);
}

// From any thread: onto node's loop, then to the listener or the held list.
static void QueueEvent(NotifEvent* ev) {
  if (gEvents.NonBlockingCall(ev) != napi_ok) delete ev;
}

static void QueueResponse(UNNotificationResponse* r) {
  NotifEvent* ev = new NotifEvent;
  UNNotificationRequest* req = r.notification.request;
  ev->identifier = req.identifier.UTF8String;
  NSString* action = r.actionIdentifier;
  if ([action isEqualToString:UNNotificationDismissActionIdentifier]) {
    ev->type = "notification-dismissed";
    ev->reason = "dismissed";
  } else {
    ev->type = "notification-action";
    ev->actionId = [action isEqualToString:UNNotificationDefaultActionIdentifier]
                       ? "default"
                       : action.UTF8String;
  }
  NSString* cat = req.content.categoryIdentifier;
  if (cat.length && ![cat isEqualToString:kDefaultCategory]) {
    ev->categoryId = cat.UTF8String;
  }
  NSString* json = UserInfoJson(req.content.userInfo);
  if (json) {
    ev->hasUserInfo = true;
    ev->userInfoJson = json.UTF8String;
  }
  if ([r isKindOfClass:UNTextInputNotificationResponse.class]) {
    NSString* text = ((UNTextInputNotificationResponse*)r).userText;
    if (text) {
      ev->hasUserText = true;
      ev->userText = text.UTF8String;
    }
  }
  QueueEvent(ev);
}

@interface CALNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end
@implementation CALNotificationDelegate
// Also while the app is frontmost: the renderer posted it on purpose, and
// without this the system shows nothing for a foreground app.
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:
             (void (^)(UNNotificationPresentationOptions))completionHandler {
  (void)center;
  (void)notification;
  completionHandler(UNNotificationPresentationOptionBanner |
                    UNNotificationPresentationOptionList |
                    UNNotificationPresentationOptionSound |
                    UNNotificationPresentationOptionBadge);
}
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
             withCompletionHandler:(void (^)(void))completionHandler {
  (void)center;
  QueueResponse(response);
  completionHandler();
}
@end

static UNNotificationCategory* DefaultCategory() {
  return [UNNotificationCategory
      categoryWithIdentifier:kDefaultCategory
                     actions:@[]
           intentIdentifiers:@[]
                     options:UNNotificationCategoryOptionCustomDismissAction];
}

static void ProbeCenter(Napi::Env env) {
  if (gProbed) return;
  gProbed = true;
  gEvents = EventTsfn::New(env, "appkit:notifications", 0, 1);
  gEvents.Unref(env);  // events never hold the loop open by themselves
  @autoreleasepool {
    NSBundle* main = NSBundle.mainBundle;
    if (!main.bundleIdentifier) {
      gUnavailable = [NSString
          stringWithFormat:@"the process is not an app bundle: %@ has no "
                           @"CFBundleIdentifier, and UNUserNotificationCenter "
                           @"delivers only for a bundled, code-signed "
                           @"executable (see README, \"Desktop notifications\")",
                           main.bundleURL.path ?: @"the main bundle"];
      return;
    }
    UNUserNotificationCenter* c = nil;
    @try {
      c = UNUserNotificationCenter.currentNotificationCenter;
    } @catch (NSException* e) {
      gUnavailable = [NSString
          stringWithFormat:@"UNUserNotificationCenter is unreachable for %@: %@",
                           main.bundleIdentifier, e.reason ?: e.name];
      return;
    }
    if (!c) {
      gUnavailable = @"UNUserNotificationCenter.currentNotificationCenter is nil";
      return;
    }
    gCenter = c;
    gDelegate = [CALNotificationDelegate new];
    gCenter.delegate = gDelegate;
    gCategories = [NSSet setWithObject:DefaultCategory()];
    [gCenter setNotificationCategories:gCategories];
  }
}

// The centre, or a thrown Error naming why there is none.
static UNUserNotificationCenter* CenterOrThrow(Napi::Env env, const char* fn) {
  if (gCenter) return gCenter;
  Napi::Error::New(env, std::string(fn) + ": notifications are unavailable — " +
                            gUnavailable.UTF8String)
      .ThrowAsJavaScriptException();
  return nil;
}

// --- settings ----------------------------------------------------------------

static const char* AuthName(UNAuthorizationStatus s) {
  switch (s) {
    case UNAuthorizationStatusDenied: return "denied";
    case UNAuthorizationStatusAuthorized: return "authorized";
    case UNAuthorizationStatusProvisional: return "provisional";
    case UNAuthorizationStatusNotDetermined:
    default: return "notDetermined";
  }
}

static const char* SettingName(UNNotificationSetting s) {
  switch (s) {
    case UNNotificationSettingDisabled: return "disabled";
    case UNNotificationSettingEnabled: return "enabled";
    case UNNotificationSettingNotSupported:
    default: return "notSupported";
  }
}

static const char* AlertStyleName(UNAlertStyle s) {
  switch (s) {
    case UNAlertStyleBanner: return "banner";
    case UNAlertStyleAlert: return "alert";
    case UNAlertStyleNone:
    default: return "none";
  }
}

static const char* PreviewsName(UNShowPreviewsSetting s) {
  switch (s) {
    case UNShowPreviewsSettingAlways: return "always";
    case UNShowPreviewsSettingWhenAuthenticated: return "whenAuthenticated";
    case UNShowPreviewsSettingNever:
    default: return "never";
  }
}

static Napi::Object SettingsObject(Napi::Env env, UNNotificationSettings* s) {
  Napi::Object o = Napi::Object::New(env);
  o.Set("available", true);
  o.Set("bundleIdentifier", NSBundle.mainBundle.bundleIdentifier.UTF8String);
  o.Set("authorizationStatus", AuthName(s.authorizationStatus));
  o.Set("alert", SettingName(s.alertSetting));
  o.Set("sound", SettingName(s.soundSetting));
  o.Set("badge", SettingName(s.badgeSetting));
  o.Set("notificationCenter", SettingName(s.notificationCenterSetting));
  o.Set("lockScreen", SettingName(s.lockScreenSetting));
  o.Set("criticalAlert", SettingName(s.criticalAlertSetting));
  o.Set("alertStyle", AlertStyleName(s.alertStyle));
  o.Set("showPreviews", PreviewsName(s.showPreviewsSetting));
  if (@available(macOS 12.0, *)) {
    o.Set("timeSensitive", SettingName(s.timeSensitiveSetting));
  }
  return o;
}

static Napi::Object UnavailableObject(Napi::Env env) {
  Napi::Object o = Napi::Object::New(env);
  o.Set("available", false);
  o.Set("bundleIdentifier",
        StringOrNull(env, NSBundle.mainBundle.bundleIdentifier));
  o.Set("reason", gUnavailable.UTF8String);
  return o;
}

static bool CallbackArg(const Napi::CallbackInfo& info, size_t at,
                        const char* fn, const char* shape) {
  if (info.Length() > at && info[at].IsFunction()) return true;
  return NThrowType(info.Env(),
                    std::string(fn) + ": expected a callback " + shape);
}

// notificationSettings(cb) — cb({ available, bundleIdentifier, reason }) in
// an unbundled process, else cb({ available: true, bundleIdentifier,
// authorizationStatus, alert, sound, badge, notificationCenter, lockScreen,
// criticalAlert, alertStyle, showPreviews, timeSensitive }). Never throws
// for the state of the process; once, asynchronously.
static Napi::Value NotificationSettings(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!CallbackArg(info, 0, "notificationSettings", "(cb)"))
    return env.Undefined();
  Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
      env, info[0].As<Napi::Function>(), "appkit:notificationSettings", 0, 1);
  if (!gCenter) {
    tsfn.BlockingCall((void*)nullptr,
                      [](Napi::Env env, Napi::Function cb, void*) {
                        cb.Call({UnavailableObject(env)});
                      });
    tsfn.Release();
    return env.Undefined();
  }
  [gCenter getNotificationSettingsWithCompletionHandler:^(
               UNNotificationSettings* s) {
    void* p = (void*)CFBridgingRetain(s);
    tsfn.BlockingCall(p, [](Napi::Env env, Napi::Function cb, void* p) {
      UNNotificationSettings* s = CFBridgingRelease(p);
      cb.Call({SettingsObject(env, s)});
    });
    tsfn.Release();
  }];
  return env.Undefined();
}

// --- authorization -----------------------------------------------------------

static const char* const kAuthOptionNames =
    "alert, sound, badge, provisional, criticalAlert, "
    "providesAppNotificationSettings";

static bool ParseAuthOptions(Napi::Env env, Napi::Value v, const char* fn,
                             UNAuthorizationOptions* out) {
  if (!v.IsArray()) {
    return NThrowType(env, std::string(fn) + ": expected an array of options (" +
                               kAuthOptionNames + ")");
  }
  Napi::Array a = v.As<Napi::Array>();
  UNAuthorizationOptions opts = UNAuthorizationOptionNone;
  for (uint32_t i = 0; i < a.Length(); i++) {
    Napi::Value e = a.Get(i);
    std::string s = e.IsString() ? e.As<Napi::String>().Utf8Value() : "";
    if (s == "alert") opts |= UNAuthorizationOptionAlert;
    else if (s == "sound") opts |= UNAuthorizationOptionSound;
    else if (s == "badge") opts |= UNAuthorizationOptionBadge;
    else if (s == "provisional") opts |= UNAuthorizationOptionProvisional;
    else if (s == "criticalAlert") opts |= UNAuthorizationOptionCriticalAlert;
    else if (s == "providesAppNotificationSettings")
      opts |= UNAuthorizationOptionProvidesAppNotificationSettings;
    else
      return NThrowType(env, std::string(fn) + ": unknown option '" + s + "' (" +
                                 kAuthOptionNames + ")");
  }
  *out = opts;
  return true;
}

struct Outcome {
  bool ok;
  NSError* error;  // retained by the struct's owner
};

static Napi::Value ErrorValue(Napi::Env env, NSError* e) {
  if (!e) return env.Null();
  Napi::Error err = Napi::Error::New(env, e.localizedDescription.UTF8String);
  err.Set("code", (double)e.code);
  err.Set("domain", e.domain.UTF8String);
  return err.Value();
}

// requestNotificationAuthorization(options, cb) — the system prompt, once
// per app (later calls answer from the stored decision); cb(granted, error)
// once, asynchronously. options: ['alert', 'sound', 'badge'] and friends.
// A grant re-applies the category set, since the system held none for the
// app while it was unauthorized.
static Napi::Value RequestNotificationAuthorization(
    const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* fn = "requestNotificationAuthorization";
  UNAuthorizationOptions opts;
  if (info.Length() < 1 || !ParseAuthOptions(env, info[0], fn, &opts))
    return env.Undefined();
  if (!CallbackArg(info, 1, fn, "(options, cb)")) return env.Undefined();
  UNUserNotificationCenter* center = CenterOrThrow(env, fn);
  if (!center) return env.Undefined();
  Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
      env, info[1].As<Napi::Function>(), "appkit:requestNotificationAuthorization",
      0, 1);
  [center requestAuthorizationWithOptions:opts
                        completionHandler:^(BOOL granted, NSError* error) {
                          Outcome* out = new Outcome{(bool)granted, error};
                          tsfn.BlockingCall(
                              out, [](Napi::Env env, Napi::Function cb,
                                      Outcome* out) {
                                if (out->ok && gCenter && gCategories) {
                                  [gCenter setNotificationCategories:gCategories];
                                }
                                cb.Call({Napi::Boolean::New(env, out->ok),
                                         ErrorValue(env, out->error)});
                                delete out;
                              });
                          tsfn.Release();
                        }];
  return env.Undefined();
}

// --- categories --------------------------------------------------------------

static UNNotificationAction* BuildAction(Napi::Env env, Napi::Object o,
                                         const char* fn) {
  NSString* id;
  NSString* title;
  if (!NOptString(env, o, "id", fn, &id)) return nil;
  if (!NOptString(env, o, "title", fn, &title)) return nil;
  if (!id.length || !title.length) {
    NThrowType(env, std::string(fn) + ": an action needs { id, title }");
    return nil;
  }
  bool destructive, foreground, auth;
  if (!NOptBool(env, o, "destructive", fn, false, &destructive)) return nil;
  if (!NOptBool(env, o, "foreground", fn, false, &foreground)) return nil;
  if (!NOptBool(env, o, "authenticationRequired", fn, false, &auth)) return nil;
  UNNotificationActionOptions opts = UNNotificationActionOptionNone;
  if (destructive) opts |= UNNotificationActionOptionDestructive;
  if (foreground) opts |= UNNotificationActionOptionForeground;
  if (auth) opts |= UNNotificationActionOptionAuthenticationRequired;
  return [UNNotificationAction actionWithIdentifier:id title:title options:opts];
}

static UNNotificationCategory* BuildCategory(Napi::Env env, Napi::Object o,
                                             const char* fn) {
  NSString* id;
  if (!NOptString(env, o, "id", fn, &id)) return nil;
  if (!id.length) {
    NThrowType(env, std::string(fn) + ": a category needs an id");
    return nil;
  }
  NSMutableArray<UNNotificationAction*>* actions = [NSMutableArray new];
  if (o.Has("actions") && !o.Get("actions").IsUndefined() &&
      !o.Get("actions").IsNull()) {
    Napi::Value v = o.Get("actions");
    if (!v.IsArray()) {
      NThrowType(env, std::string(fn) + ": 'actions' must be an array");
      return nil;
    }
    Napi::Array a = v.As<Napi::Array>();
    for (uint32_t i = 0; i < a.Length(); i++) {
      Napi::Value e = a.Get(i);
      if (!e.IsObject()) {
        NThrowType(env, std::string(fn) + ": an action must be an object");
        return nil;
      }
      UNNotificationAction* act = BuildAction(env, e.As<Napi::Object>(), fn);
      if (!act) return nil;
      [actions addObject:act];
    }
  }
  bool dismiss;
  if (!NOptBool(env, o, "customDismissAction", fn, true, &dismiss)) return nil;
  UNNotificationCategoryOptions opts = UNNotificationCategoryOptionNone;
  if (dismiss) opts |= UNNotificationCategoryOptionCustomDismissAction;
  return [UNNotificationCategory categoryWithIdentifier:id
                                                actions:actions
                                      intentIdentifiers:@[]
                                                options:opts];
}

// setNotificationCategories([{ id, actions: [{ id, title, destructive?,
// foreground?, authenticationRequired? }], customDismissAction? }]) —
// replaces the app's whole set; the bridge's own category for uncategorised
// notifications is always part of it.
static Napi::Value SetNotificationCategories(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* fn = "setNotificationCategories";
  if (info.Length() < 1 || !info[0].IsArray()) {
    NThrowType(env, std::string(fn) + ": expected an array of categories");
    return env.Undefined();
  }
  @autoreleasepool {
    NSMutableSet<UNNotificationCategory*>* set = [NSMutableSet new];
    Napi::Array a = info[0].As<Napi::Array>();
    for (uint32_t i = 0; i < a.Length(); i++) {
      Napi::Value e = a.Get(i);
      if (!e.IsObject()) {
        NThrowType(env, std::string(fn) + ": a category must be an object");
        return env.Undefined();
      }
      UNNotificationCategory* c = BuildCategory(env, e.As<Napi::Object>(), fn);
      if (!c) return env.Undefined();
      [set addObject:c];
    }
    UNUserNotificationCenter* center = CenterOrThrow(env, fn);
    if (!center) return env.Undefined();
    [set addObject:DefaultCategory()];
    gCategories = set;
    [center setNotificationCategories:set];
  }
  return env.Undefined();
}

static Napi::Object CategoryObject(Napi::Env env, UNNotificationCategory* c) {
  Napi::Object o = Napi::Object::New(env);
  o.Set("id", c.identifier.UTF8String);
  Napi::Array actions = Napi::Array::New(env);
  uint32_t n = 0;
  for (UNNotificationAction* a in c.actions) {
    Napi::Object ao = Napi::Object::New(env);
    ao.Set("id", a.identifier.UTF8String);
    ao.Set("title", a.title.UTF8String);
    ao.Set("destructive",
           (bool)(a.options & UNNotificationActionOptionDestructive));
    ao.Set("foreground",
           (bool)(a.options & UNNotificationActionOptionForeground));
    ao.Set("authenticationRequired",
           (bool)(a.options & UNNotificationActionOptionAuthenticationRequired));
    actions.Set(n++, ao);
  }
  o.Set("actions", actions);
  o.Set("customDismissAction",
        (bool)(c.options & UNNotificationCategoryOptionCustomDismissAction));
  return o;
}

// notificationCategories(cb) — cb([{ id, actions, customDismissAction }]),
// the set as the system holds it, bridge category included.
static Napi::Value NotificationCategories(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* fn = "notificationCategories";
  if (!CallbackArg(info, 0, fn, "(cb)")) return env.Undefined();
  UNUserNotificationCenter* center = CenterOrThrow(env, fn);
  if (!center) return env.Undefined();
  Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
      env, info[0].As<Napi::Function>(), "appkit:notificationCategories", 0, 1);
  [center getNotificationCategoriesWithCompletionHandler:^(
              NSSet<UNNotificationCategory*>* cats) {
    void* p = (void*)CFBridgingRetain(cats);
    tsfn.BlockingCall(p, [](Napi::Env env, Napi::Function cb, void* p) {
      NSSet<UNNotificationCategory*>* cats = CFBridgingRelease(p);
      Napi::Array out = Napi::Array::New(env);
      uint32_t n = 0;
      for (UNNotificationCategory* c in cats) out.Set(n++, CategoryObject(env, c));
      cb.Call({out});
    });
    tsfn.Release();
  }];
  return env.Undefined();
}

// --- post / update / remove --------------------------------------------------

// { identifier?, title, subtitle?, body?, sound?: 'default' | <name> | null,
//   categoryId?, userInfo?, threadId?, badge?: number | null }
static UNNotificationRequest* BuildRequest(Napi::Env env, Napi::Object o,
                                           NSString* identifier,
                                           const char* fn) {
  NSString* title;
  NSString* subtitle;
  NSString* body;
  NSString* sound;
  NSString* categoryId;
  NSString* threadId;
  if (!NOptString(env, o, "title", fn, &title)) return nil;
  if (!title) {
    NThrowType(env, std::string(fn) + ": 'title' (a string) is required");
    return nil;
  }
  if (!NOptString(env, o, "subtitle", fn, &subtitle)) return nil;
  if (!NOptString(env, o, "body", fn, &body)) return nil;
  if (!NOptString(env, o, "sound", fn, &sound)) return nil;
  if (!NOptString(env, o, "categoryId", fn, &categoryId)) return nil;
  if (!NOptString(env, o, "threadId", fn, &threadId)) return nil;
  if (!identifier) {
    if (!NOptString(env, o, "identifier", fn, &identifier)) return nil;
    if (!identifier.length) identifier = NSUUID.UUID.UUIDString;
  }

  UNMutableNotificationContent* c = [UNMutableNotificationContent new];
  c.title = title;
  if (subtitle) c.subtitle = subtitle;
  if (body) c.body = body;
  if (sound) {
    c.sound = [sound isEqualToString:@"default"]
                  ? UNNotificationSound.defaultSound
                  : [UNNotificationSound soundNamed:sound];
  }
  c.categoryIdentifier = categoryId.length ? categoryId : kDefaultCategory;
  if (threadId) c.threadIdentifier = threadId;
  if (o.Has("badge")) {
    Napi::Value v = o.Get("badge");
    if (v.IsNumber()) {
      c.badge = @((NSInteger)v.As<Napi::Number>().Int64Value());
    } else if (!v.IsUndefined() && !v.IsNull()) {
      NThrowType(env, std::string(fn) + ": 'badge' must be a number or null");
      return nil;
    }
  }
  if (o.Has("userInfo")) {
    Napi::Value v = o.Get("userInfo");
    if (!v.IsUndefined() && !v.IsNull()) {
      Napi::Value json = JsonStringify(env, v);
      if (env.IsExceptionPending()) return nil;
      if (!json.IsString()) {
        NThrowType(env, std::string(fn) + ": 'userInfo' must be JSON-serialisable");
        return nil;
      }
      c.userInfo = @{kUserInfoKey : NToNSString(json)};
    }
  }
  return [UNNotificationRequest requestWithIdentifier:identifier
                                              content:c
                                              trigger:nil];
}

static Napi::Value Post(const Napi::CallbackInfo& info, size_t propsAt,
                        NSString* identifier, const char* fn) {
  Napi::Env env = info.Env();
  if (info.Length() <= propsAt || !info[propsAt].IsObject()) {
    NThrowType(env, std::string(fn) + ": expected a props object { title, ... }");
    return env.Undefined();
  }
  size_t cbAt = propsAt + 1;
  bool hasCb = info.Length() > cbAt && info[cbAt].IsFunction();
  if (info.Length() > cbAt && !hasCb && !info[cbAt].IsUndefined() &&
      !info[cbAt].IsNull()) {
    NThrowType(env, std::string(fn) + ": the callback must be a function");
    return env.Undefined();
  }
  @autoreleasepool {
    UNNotificationRequest* req =
        BuildRequest(env, info[propsAt].As<Napi::Object>(), identifier, fn);
    if (!req) return env.Undefined();
    UNUserNotificationCenter* center = CenterOrThrow(env, fn);
    if (!center) return env.Undefined();
    if (!hasCb) {
      [center addNotificationRequest:req withCompletionHandler:nil];
    } else {
      Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
          env, info[cbAt].As<Napi::Function>(), "appkit:postNotification", 0,
          1);
      [center addNotificationRequest:req
               withCompletionHandler:^(NSError* error) {
                 Outcome* out = new Outcome{error == nil, error};
                 tsfn.BlockingCall(
                     out, [](Napi::Env env, Napi::Function cb, Outcome* out) {
                       cb.Call({ErrorValue(env, out->error)});
                       delete out;
                     });
                 tsfn.Release();
               }];
    }
    return Napi::String::New(env, req.identifier.UTF8String);
  }
}

// postNotification(props, cb?) -> identifier. cb(error | null) once the
// system has accepted or refused the request — refused, for one, while the
// app is not authorized (UNErrorCodeNotificationsNotAllowed, code 1).
static Napi::Value PostNotification(const Napi::CallbackInfo& info) {
  return Post(info, 0, nil, "postNotification");
}

// updateNotification(identifier, props, cb?) -> identifier: the same request
// under the same identifier replaces the banner in place.
static Napi::Value UpdateNotification(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsString() ||
      info[0].As<Napi::String>().Utf8Value().empty()) {
    NThrowType(env, "updateNotification: expected (identifier, props, cb?)");
    return env.Undefined();
  }
  return Post(info, 1, NToNSString(info[0]), "updateNotification");
}

// removeNotification(identifier | [identifiers]) — out of Notification
// Center, and off the queue if not yet delivered.
static Napi::Value RemoveNotification(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* fn = "removeNotification";
  NSMutableArray<NSString*>* ids = [NSMutableArray new];
  if (info.Length() >= 1 && info[0].IsString()) {
    [ids addObject:NToNSString(info[0])];
  } else if (info.Length() >= 1 && info[0].IsArray()) {
    Napi::Array a = info[0].As<Napi::Array>();
    for (uint32_t i = 0; i < a.Length(); i++) {
      Napi::Value e = a.Get(i);
      if (!e.IsString()) {
        NThrowType(env, std::string(fn) + ": identifiers must be strings");
        return env.Undefined();
      }
      [ids addObject:NToNSString(e)];
    }
  } else {
    NThrowType(env, std::string(fn) + ": expected an identifier or an array of them");
    return env.Undefined();
  }
  UNUserNotificationCenter* center = CenterOrThrow(env, fn);
  if (!center) return env.Undefined();
  [center removePendingNotificationRequestsWithIdentifiers:ids];
  [center removeDeliveredNotificationsWithIdentifiers:ids];
  return env.Undefined();
}

// deliveredNotifications(cb) — cb([{ identifier, title, subtitle, body,
// categoryId, threadId, userInfo, date }]): what is in Notification Center
// for this app right now, newest last as the system lists them.
static Napi::Value DeliveredNotifications(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* fn = "deliveredNotifications";
  if (!CallbackArg(info, 0, fn, "(cb)")) return env.Undefined();
  UNUserNotificationCenter* center = CenterOrThrow(env, fn);
  if (!center) return env.Undefined();
  Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
      env, info[0].As<Napi::Function>(), "appkit:deliveredNotifications", 0, 1);
  [center getDeliveredNotificationsWithCompletionHandler:^(
              NSArray<UNNotification*>* list) {
    void* p = (void*)CFBridgingRetain(list);
    tsfn.BlockingCall(p, [](Napi::Env env, Napi::Function cb, void* p) {
      NSArray<UNNotification*>* list = CFBridgingRelease(p);
      Napi::Array out = Napi::Array::New(env);
      uint32_t n = 0;
      for (UNNotification* note in list) {
        UNNotificationRequest* req = note.request;
        UNNotificationContent* c = req.content;
        Napi::Object o = Napi::Object::New(env);
        o.Set("identifier", req.identifier.UTF8String);
        o.Set("title", c.title.UTF8String);
        o.Set("subtitle", c.subtitle.UTF8String);
        o.Set("body", c.body.UTF8String);
        NSString* cat = c.categoryIdentifier;
        o.Set("categoryId",
              (cat.length && ![cat isEqualToString:kDefaultCategory])
                  ? Napi::String::New(env, cat.UTF8String)
                  : env.Null());
        o.Set("threadId", StringOrNull(env, c.threadIdentifier));
        NSString* json = UserInfoJson(c.userInfo);
        if (json) {
          Napi::Value v = JsonParse(env, json);
          if (env.IsExceptionPending()) {
            (void)env.GetAndClearPendingException();
            v = Napi::String::New(env, json.UTF8String);
          }
          o.Set("userInfo", v);
        }
        o.Set("date", note.date.timeIntervalSince1970 * 1000.0);
        out.Set(n++, o);
      }
      cb.Call({out});
    });
    tsfn.Release();
  }];
  return env.Undefined();
}

// --- test seam ---------------------------------------------------------------

// postNotificationResponse({ identifier, actionId?, dismissed?, categoryId?,
// userInfo?, userText? }) — a response as the delegate would queue it, minus
// the delegate: the same hand-off to node's loop, the same hold-and-replay,
// the same event shape. Test-only, like postMouseEvent and postKeyEvent; it
// needs no bundle, since nothing here touches the centre.
static Napi::Value PostNotificationResponse(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* fn = "postNotificationResponse";
  if (info.Length() < 1 || !info[0].IsObject()) {
    NThrowType(env, std::string(fn) + ": expected { identifier, actionId?, "
                                      "dismissed?, categoryId?, userInfo?, "
                                      "userText? }");
    return env.Undefined();
  }
  Napi::Object o = info[0].As<Napi::Object>();
  NSString* identifier;
  NSString* actionId;
  NSString* categoryId;
  NSString* userText;
  bool dismissed;
  if (!NOptString(env, o, "identifier", fn, &identifier)) return env.Undefined();
  if (!identifier.length) {
    NThrowType(env, std::string(fn) + ": 'identifier' (a string) is required");
    return env.Undefined();
  }
  if (!NOptString(env, o, "actionId", fn, &actionId)) return env.Undefined();
  if (!NOptString(env, o, "categoryId", fn, &categoryId)) return env.Undefined();
  if (!NOptString(env, o, "userText", fn, &userText)) return env.Undefined();
  if (!NOptBool(env, o, "dismissed", fn, false, &dismissed)) return env.Undefined();
  NotifEvent* ev = new NotifEvent;
  ev->identifier = identifier.UTF8String;
  if (dismissed) {
    ev->type = "notification-dismissed";
    ev->reason = "dismissed";
  } else {
    ev->type = "notification-action";
    ev->actionId = actionId.length ? actionId.UTF8String : "default";
  }
  if (categoryId.length && ![categoryId isEqualToString:kDefaultCategory]) {
    ev->categoryId = categoryId.UTF8String;
  }
  if (o.Has("userInfo") && !o.Get("userInfo").IsUndefined() &&
      !o.Get("userInfo").IsNull()) {
    Napi::Value json = JsonStringify(env, o.Get("userInfo"));
    if (env.IsExceptionPending()) {
      delete ev;
      return env.Undefined();
    }
    if (json.IsString()) {
      ev->hasUserInfo = true;
      ev->userInfoJson = json.As<Napi::String>().Utf8Value();
    }
  }
  if (userText) {
    ev->hasUserText = true;
    ev->userText = userText.UTF8String;
  }
  QueueEvent(ev);
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// registration (called from addon.mm's Init, i.e. at require time — before
// initApp() finishes launching, which is when the delegate has to be in place)
// ---------------------------------------------------------------------------

void InitNotifications(Napi::Env env, Napi::Object exports) {
  ProbeCenter(env);
  exports.Set("notificationSettings",
              Napi::Function::New(env, NotificationSettings));
  exports.Set("requestNotificationAuthorization",
              Napi::Function::New(env, RequestNotificationAuthorization));
  exports.Set("setNotificationCategories",
              Napi::Function::New(env, SetNotificationCategories));
  exports.Set("notificationCategories",
              Napi::Function::New(env, NotificationCategories));
  exports.Set("postNotification", Napi::Function::New(env, PostNotification));
  exports.Set("updateNotification",
              Napi::Function::New(env, UpdateNotification));
  exports.Set("removeNotification",
              Napi::Function::New(env, RemoveNotification));
  exports.Set("deliveredNotifications",
              Napi::Function::New(env, DeliveredNotifications));
  exports.Set("postNotificationResponse",
              Napi::Function::New(env, PostNotificationResponse));
}
