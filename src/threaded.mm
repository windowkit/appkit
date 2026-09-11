// @windowkit/appkit threaded.mm — threaded mode's core (windowkit/appkit#50,
// part of #49): the main thread parked in a real [NSApp run], a way in
// (commands), a way out (events), and the process's exit and signals.
//
// Pump mode stays the default. In it JS runs on the process main thread,
// which is also AppKit's, and drives AppKit through pump2() from a timer;
// every modal loop AppKit runs (live resize, menu tracking, a drag, runModal)
// runs inside that call and freezes Node until it ends. Threaded mode swaps
// the roles instead: the process main thread calls runMain() and stays in
// [NSApp run] for the life of the app, and the renderer's JS runs on a
// worker_threads Worker, where no AppKit loop can reach it.
//
//   runMain()          main thread only; returns the code requestExit gave,
//                      or null when the connected environment ended without
//                      asking
//   connect(onEvents)  from the renderer's thread: onEvents(batch), an array
//   requestExit(code)  any thread
//   threaded()         runMain is running
//
// Mechanism only. What the renderer does with a batch, a close request, a
// quit request or a SIGINT is its own call; nothing here decides policy.
//
// The command queue. A version-0 CFRunLoopSource on the main run loop, added
// in kCFRunLoopCommonModes, so NSEventTrackingRunLoopMode (live resize, menu
// tracking, drag sessions) and NSModalPanelRunLoopMode (runModal) drain it
// too — in the #49 probe 72 commands applied inside a menu's tracking and 75
// inside an NSAlert, 0.02 ms p50 from post to apply. The drain swaps the
// queue out under the lock before running anything (a version-0 source can
// be re-entered by a nested run loop) and applies the batch inside one
// CATransaction with implicit actions off. A command that starts a modal
// loop is run from a callout of its own after the drain (CALOnUIModal), so
// the rest of its batch never waits behind the gesture.
//
// The event channel. Producers build plain CALEvent records (channel.h);
// with the channel open they are appended to one queue, and the first
// append after a delivery makes one napi_call_threadsafe_function. The JS
// side swaps the queue out and hands the whole batch over as one array, so
// a renderer busy for 200 ms gets the events it missed together, not 200 ms
// of backlog one callback at a time. Consecutive mousemove in one window
// folds to the latest position before it crosses. A delivery runs in a
// callback scope, so a microtask queued inside onEvents runs right after it
// (react-x11#484's frozen microtasks do not exist in this mode).
//
// Exit. Only the main thread may end the process: requestExit stops [NSApp
// run], runMain returns the code, and the main thread's JS calls
// process.exit(code), which stops the worker in order. (The probe's first
// try, exit() on the UI thread with the worker still running, raced static
// destructors: "mutex lock failed: Invalid argument".) An environment that
// ends without asking — process.exit in a Worker ends only the worker, an
// uncaught error ends it too — finalizes the threadsafe function, and the
// finalizer ends the run so runMain returns null instead of parking the
// process for ever. Before the run loop is stopped, any menu tracking is
// cancelled and an app-modal loop stopped; [NSApp stop:] ends only the
// innermost loop, so the stop itself waits for the default mode.
//
// Signals. process.on('SIGINT') is never called inside a Worker, and the
// main thread's JS is parked. While runMain runs, SIGINT, SIGTERM and SIGHUP
// are ignored as signals and read through DISPATCH_SOURCE_TYPE_SIGNAL on the
// main queue (kqueue records a signal even when it is ignored); each arrives
// as a `signal { signal: 'SIGINT' }` event for the renderer to re-emit on
// its own process. With no environment connected there is nobody to ask,
// and the run ends with the shell's code for it, 128 + the signal number.

#include "channel.h"

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <signal.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <utility>
#include <vector>

// backend.mm: the application, the pump-mode callback, the held events, and
// what the run loop needs beyond pump mode (the event monitor, the polled
// pasteboard count)
void BEnsureApp();
bool CALHasBackendCb();
void CALPumpDeliver(const CALEvent& ev);
void CALReplayHeldEvents();
void CALBeginRunMode();
void CALEndRunMode();

// ---------------------------------------------------------------------------
// the event record
// ---------------------------------------------------------------------------

CALEvent::Field& CALEvent::Add(Field::Kind kind, const char* key) {
  fields_.emplace_back();
  Field& f = fields_.back();
  f.kind = kind;
  f.key = key;
  return f;
}

CALEvent& CALEvent::Str(const char* key, const std::string& v) {
  Add(Field::kStr, key).s = v;
  return *this;
}
CALEvent& CALEvent::Str(const char* key, const char* v) {
  Add(Field::kStr, key).s = v ? v : "";
  return *this;
}
CALEvent& CALEvent::Num(const char* key, double v) {
  Add(Field::kNum, key).n = v;
  return *this;
}
CALEvent& CALEvent::Bool(const char* key, bool v) {
  Add(Field::kBool, key).b = v;
  return *this;
}
CALEvent& CALEvent::Null(const char* key) {
  Add(Field::kNull, key);
  return *this;
}
CALEvent& CALEvent::Strs(const char* key, std::vector<std::string> v) {
  Add(Field::kStrs, key).list = std::move(v);
  return *this;
}
CALEvent& CALEvent::Json(const char* key, const std::string& v) {
  Add(Field::kJson, key).s = v;
  return *this;
}
CALEvent& CALEvent::Handle(const char* key, CALValueBlock v) {
  Add(Field::kHandle, key).handle = v;
  return *this;
}

static Napi::Value ParseJson(Napi::Env env, const std::string& text) {
  Napi::String s = Napi::String::New(env, text);
  Napi::Object json = env.Global().Get("JSON").As<Napi::Object>();
  Napi::Value v = json.Get("parse").As<Napi::Function>().Call(json, {s});
  if (env.IsExceptionPending()) {
    (void)env.GetAndClearPendingException();
    return s;
  }
  return v;
}

Napi::Object CALEvent::ToObject(Napi::Env env) const {
  Napi::Object o = Napi::Object::New(env);
  for (const Field& f : fields_) {
    switch (f.kind) {
      case Field::kStr: o.Set(f.key, f.s); break;
      case Field::kNum: o.Set(f.key, f.n); break;
      case Field::kBool: o.Set(f.key, f.b); break;
      case Field::kNull: o.Set(f.key, env.Null()); break;
      case Field::kStrs: {
        Napi::Array a = Napi::Array::New(env, f.list.size());
        for (size_t i = 0; i < f.list.size(); i++) a.Set((uint32_t)i, f.list[i]);
        o.Set(f.key, a);
        break;
      }
      case Field::kJson: o.Set(f.key, ParseJson(env, f.s)); break;
      case Field::kHandle:
        o.Set(f.key, f.handle ? f.handle(env) : Napi::Value(env.Null()));
        break;
    }
  }
  return o;
}

// ---------------------------------------------------------------------------
// commands: into the main run loop
// ---------------------------------------------------------------------------

// The core's locks and queues are leaked on purpose, here and below: a
// thread that still emits or posts while the process exits (a
// UserNotifications or EventKit queue) must not find them destroyed — the
// #49 probe's "mutex lock failed: Invalid argument" abort.
static std::mutex& gCmdMu = *new std::mutex;
// A queued command. A frame batch committed with txCommit({ width, height })
// is tagged with the size it was painted at: what a window's resize
// handshake waits for (CALAwaitFrame).
struct Command {
  dispatch_block_t block = nil;
  bool sized = false;
  double width = 0, height = 0;
};
static std::vector<Command>& gCmdQ = *new std::vector<Command>;  // gCmdMu
// signalled on every post, for the handshake's bounded wait
static std::condition_variable& gCmdCv = *new std::condition_variable;
static CFRunLoopSourceRef gCmdSrc = nullptr;
static int gDrainDepth = 0;  // the UI thread only

// Set as requestExit is called, from any thread; read by the UI thread.
static std::atomic<bool> gExitAsked{false};
static std::atomic<int> gExitCode{0};
static std::atomic<bool> gRunning{false};

// An NSException escaping a block would unwind through CFRunLoop's frames
// and take the rest of the batch (and the open transaction) with it.
static void RunGuarded(dispatch_block_t b) {
  @try {
    b();
  } @catch (NSException* e) {
    fprintf(stderr, "@windowkit/appkit: a UI-thread command raised %s: %s\n",
            e.name.UTF8String, e.reason.UTF8String ?: "");
  }
}

static void DrainCommands(void*) {
  std::vector<Command> batch;
  {
    std::lock_guard<std::mutex> l(gCmdMu);
    batch.swap(gCmdQ);
  }
  if (batch.empty()) return;
  gDrainDepth++;
  @autoreleasepool {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (const Command& c : batch) RunGuarded(c.block);
    [CATransaction commit];
  }
  gDrainDepth--;
}

// Created by whichever thread needs it first; adding a source to another
// thread's run loop is allowed. Pump mode never posts, so the source sits
// idle there unless a worker does.
static void EnsureCommandSource() {
  static std::once_flag once;
  std::call_once(once, [] {
    CFRunLoopSourceContext ctx = {};
    ctx.perform = DrainCommands;
    gCmdSrc = CFRunLoopSourceCreate(nullptr, 0, &ctx);
    CFRunLoopAddSource(CFRunLoopGetMain(), gCmdSrc, kCFRunLoopCommonModes);
  });
}

static void PostCommand(Command c) {
  EnsureCommandSource();
  {
    std::lock_guard<std::mutex> l(gCmdMu);
    gCmdQ.push_back(std::move(c));
  }
  gCmdCv.notify_all();
  CFRunLoopSourceSignal(gCmdSrc);
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

static void Post(dispatch_block_t b) {
  Command c;
  c.block = b;
  PostCommand(std::move(c));
}

// A block of its own on the main run loop, in the default mode: after the
// current drain, and only once no tracking or modal loop is running.
static void Defer(dispatch_block_t b) {
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, b);
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

void CALOnUI(dispatch_block_t block) {
  if (pthread_main_np()) {
    block();
    return;
  }
  Post(block);
}

void CALOnUIModal(dispatch_block_t block) {
  // a modal loop begun after an exit was asked for would hold the exit up
  dispatch_block_t unlessExiting = ^{
    if (!gExitAsked.load()) block();
  };
  if (!pthread_main_np()) {
    Post(^{ Defer(unlessExiting); });  // through the queue, so it keeps its place
  } else if (gDrainDepth > 0) {
    Defer(unlessExiting);
  } else {
    block();
  }
}

void CALPostFrame(dispatch_block_t block, bool sized, double width, double height) {
  if (pthread_main_np()) {
    block();
    return;
  }
  Command c;
  c.block = block;
  c.sized = sized;
  c.width = width;
  c.height = height;
  PostCommand(std::move(c));
}

// ---------------------------------------------------------------------------
// events: out to the connected environment
// ---------------------------------------------------------------------------

static std::mutex& gEvMu = *new std::mutex;
static std::vector<CALEvent>& gEvQ = *new std::vector<CALEvent>;  // gEvMu
static napi_threadsafe_function gTsfn = nullptr;   // gEvMu
static bool gWakePending = false;                  // gEvMu
static int gUIObjects = 0;                         // gEvMu
static std::atomic<bool> gConnected{false};
static bool gRefed = true;  // the connected environment's thread only
static napi_env gConnectedEnv = nullptr;  // gEvMu
static pthread_t gConnectedThread;        // gEvMu, valid while gConnectedEnv is

bool CALThreaded() { return gRunning.load(); }
bool CALChannelOpen() { return gRunning.load() || gConnected.load(); }
bool CALListening() { return CALChannelOpen() || CALHasBackendCb(); }

// Called with gEvMu held, which also keeps the function alive for the call:
// the finalizer takes the same lock before the function is freed.
static void WakeLocked() {
  if (!gTsfn || gWakePending) return;
  if (napi_call_threadsafe_function(gTsfn, nullptr, napi_tsfn_nonblocking) ==
      napi_ok)
    gWakePending = true;
}

void CALEmit(CALEvent&& ev) {
  if (CALChannelOpen()) {
    std::lock_guard<std::mutex> l(gEvMu);
    if (!gEvQ.empty() && ev.FoldsOnto(gEvQ.back()))
      gEvQ.back() = std::move(ev);
    else
      gEvQ.push_back(std::move(ev));
    WakeLocked();
    return;
  }
  // pump mode calls JS inline, which only its own thread may do
  if (pthread_main_np()) CALPumpDeliver(ev);
}

void CALUIObjectsChanged(int delta) {
  std::lock_guard<std::mutex> l(gEvMu);
  bool before = gUIObjects > 0;
  gUIObjects = std::max(0, gUIObjects + delta);
  bool now = gUIObjects > 0;
  if (before == now) return;
  // On the connected environment's own thread (a worker's createWindow2 or
  // destroyWindow2) the reference is that thread's to change, now: a worker
  // whose script ends right after making a window must still be held.
  if (gTsfn && gConnectedEnv && pthread_equal(pthread_self(), gConnectedThread)) {
    if (now != gRefed) {
      if (now) napi_ref_threadsafe_function(gConnectedEnv, gTsfn);
      else napi_unref_threadsafe_function(gConnectedEnv, gTsfn);
      gRefed = now;
    }
    return;
  }
  WakeLocked();  // elsewhere the next delivery re-decides it
}

// Whether JS can still be called in `env`. A worker that is ending (an
// uncaught error, its own process.exit) can still run a threadsafe
// function's callback from its loop's last spin, and there every property
// set fails — which node-addon-api, with C++ exceptions off, turns into a
// fatal error, since it cannot throw either (Node 18 on CI: "FATAL ERROR:
// Error::ThrowAsJavaScriptException napi_throw" from DeliverBatch). Asked
// with a raw set on a scratch object, whose failure is only a status.
static bool CanCallIntoJS(napi_env env) {
  napi_value o, v;
  if (napi_create_object(env, &o) != napi_ok) return false;
  if (napi_get_boolean(env, true, &v) != napi_ok) return false;
  return napi_set_named_property(env, o, "probe", v) == napi_ok;
}

// On the connected environment's thread.
static void DeliverBatch(napi_env env, napi_value cb, void*, void*) {
  if (env == nullptr) return;  // the function is being torn down
  std::vector<CALEvent> batch;
  {
    std::lock_guard<std::mutex> l(gEvMu);
    gWakePending = false;
    batch.swap(gEvQ);
    bool want = gUIObjects > 0;
    if (gTsfn && want != gRefed) {
      if (want) napi_ref_threadsafe_function(env, gTsfn);
      else napi_unref_threadsafe_function(env, gTsfn);
      gRefed = want;
    }
  }
  // an environment on its way out gets nothing more: the batch goes with it
  if (batch.empty() || !CanCallIntoJS(env)) return;
  Napi::Env e(env);
  Napi::HandleScope scope(e);
  Napi::Array arr = Napi::Array::New(e, batch.size());
  for (uint32_t i = 0; i < batch.size(); i++) arr.Set(i, batch[i].ToObject(e));
  // Raw, so a failed call is a status rather than node-addon-api's fatal
  // error. An exception from onEvents is left pending: Node reports it as
  // that environment's uncaught exception.
  napi_value argv[1] = {arr};
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  napi_call_function(env, undefined, cb, 1, argv, nullptr);
}

static void StopRun();

// The environment the events went to is gone.
static void ChannelFinalize(napi_env, void*, void*) {
  {
    std::lock_guard<std::mutex> l(gEvMu);
    gTsfn = nullptr;
    gConnected = false;
    gWakePending = false;
    gConnectedEnv = nullptr;
  }
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
    if (gRunning.load()) StopRun();
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

// connect(onEvents) — one environment at a time; whatever was emitted before
// it (the launch's URL, input that arrived while the worker started) is
// waiting in the queue and is its first batch.
static Napi::Value Connect(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsFunction()) {
    Napi::TypeError::New(env, "connect(onEvents): a function is required")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  {
    std::lock_guard<std::mutex> l(gEvMu);
    if (gTsfn) {
      Napi::Error::New(env, "connect: an environment is already connected")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
  }
  napi_threadsafe_function tsfn = nullptr;
  napi_status st = napi_create_threadsafe_function(
      env, info[0], nullptr, Napi::String::New(env, "appkit:events"), 0, 1,
      nullptr, ChannelFinalize, nullptr, DeliverBatch, &tsfn);
  if (st != napi_ok) {
    Napi::Error::New(env, "connect: could not create the event channel")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  std::lock_guard<std::mutex> l(gEvMu);
  gTsfn = tsfn;
  gConnected = true;
  gWakePending = false;
  gRefed = true;
  gConnectedEnv = env;
  gConnectedThread = pthread_self();
  if (gUIObjects == 0) {
    napi_unref_threadsafe_function(env, tsfn);
    gRefed = false;
  }
  if (!gEvQ.empty()) WakeLocked();
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// handles allocated at the call (windowkit/appkit#51)
// ---------------------------------------------------------------------------

@implementation CALHandle
- (void)dealloc {
  // The object is the UI thread's to let go of, whichever thread drops the
  // last reference to its handle (a worker's collector, usually): an
  // NSWindow or a CALayer deallocated off the main thread is AppKit misuse.
  id o = object_;
  object_ = nil;
  if (o && !pthread_main_np()) dispatch_async(dispatch_get_main_queue(), ^{ (void)o; });
}
@end

// id -> the weak reference an event's `handle` field resolves through, in
// the environment that holds the External. Leaked like the queues above.
struct RegisteredHandle {
  napi_env env;
  napi_ref ref;
};
static std::mutex& gHandleMu = *new std::mutex;
static std::unordered_map<uint64_t, RegisteredHandle>& gHandles =
    *new std::unordered_map<uint64_t, RegisteredHandle>;
static std::atomic<uint64_t> gNextHandleId{1};

CALHandle* CALNewHandle() {
  CALHandle* h = [CALHandle new];
  h->id_ = gNextHandleId++;
  return h;
}

Napi::Value CALWrapHandle(Napi::Env env, CALHandle* h, bool registered) {
  uint64_t id = h->id_;
  Napi::External<void> ext = Napi::External<void>::New(
      env, (void*)CFBridgingRetain(h), [id, registered](Napi::Env env, void* data) {
        if (registered) {
          napi_ref ref = nullptr;
          {
            std::lock_guard<std::mutex> l(gHandleMu);
            auto it = gHandles.find(id);
            if (it != gHandles.end() && it->second.env == (napi_env)env) {
              ref = it->second.ref;
              gHandles.erase(it);
            }
          }
          if (ref) napi_delete_reference(env, ref);
        }
        CFRelease(data);
      });
  if (registered) {
    napi_ref ref = nullptr;
    if (napi_create_reference(env, ext, 0, &ref) == napi_ok) {
      std::lock_guard<std::mutex> l(gHandleMu);
      gHandles[id] = {env, ref};
    }
  }
  return ext;
}

CALEvent& CALEvent::HandleRef(const char* key, uint64_t id) {
  return Handle(key, ^Napi::Value(Napi::Env env) {
    // looked up on the delivering environment's thread, the only one that
    // registers or finalizes its handles, so the reference cannot go away
    // between the lookup and the read
    napi_ref ref = nullptr;
    {
      std::lock_guard<std::mutex> l(gHandleMu);
      auto it = gHandles.find(id);
      if (it != gHandles.end() && it->second.env == (napi_env)env) ref = it->second.ref;
    }
    napi_value v = nullptr;
    if (ref) napi_get_reference_value(env, ref, &v);
    return v ? Napi::Value(env, v) : env.Null();
  });
}

void CALPinHandle(Napi::Env env, uint64_t id, bool pin) {
  napi_ref ref = nullptr;
  {
    std::lock_guard<std::mutex> l(gHandleMu);
    auto it = gHandles.find(id);
    if (it != gHandles.end() && it->second.env == (napi_env)env) ref = it->second.ref;
  }
  if (!ref) return;
  uint32_t count = 0;
  if (pin) napi_reference_ref(env, ref, &count);
  else napi_reference_unref(env, ref, &count);
}

id CALHandleTarget(Napi::Value v) {
  if (!v.IsExternal()) return nil;
  void* d = v.As<Napi::External<void>>().Data();
  return d ? (__bridge id)d : nil;
}

id CALResolve(id target) {
  if ([target isKindOfClass:[CALHandle class]]) return ((CALHandle*)target)->object_;
  return target;
}

// --- one-shot replies ---------------------------------------------------------

struct Reply {
  CALValueBlock make;
};

Napi::ThreadSafeFunction CALReplyTo(Napi::Env env, Napi::Function cb,
                                    const char* name) {
  return Napi::ThreadSafeFunction::New(env, cb, name, 0, 1);
}

void CALReply(Napi::ThreadSafeFunction tsfn, CALValueBlock make) {
  Reply* r = new Reply{make};
  napi_status st = tsfn.BlockingCall(r, [](Napi::Env env, Napi::Function cb, Reply* r) {
    // an environment on its way out gets no answer (see DeliverBatch)
    if (!CanCallIntoJS(env)) {
      delete r;
      return;
    }
    napi_value v = r->make(env);
    delete r;
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, cb, 1, &v, nullptr);
  });
  if (st != napi_ok) delete r;
  tsfn.Release();
}

Napi::Value CALAnswer(const Napi::CallbackInfo& info, const char* name,
                      CALValueBlock (^compute)(void), bool nested) {
  Napi::Env env = info.Env();
  Napi::Value last = info.Length() ? info[info.Length() - 1] : env.Undefined();
  if (!last.IsFunction()) {
    if (!pthread_main_np()) {
      Napi::TypeError::New(env, std::string(name) +
                                    ": off the main thread it answers through a "
                                    "callback, its last argument")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    return compute()(env);
  }
  Napi::ThreadSafeFunction tsfn = CALReplyTo(env, last.As<Napi::Function>(), name);
  dispatch_block_t work = ^{ CALReply(tsfn, compute()); };
  if (nested) CALOnUIModal(work);
  else CALOnUI(work);
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// the live-resize handshake (windowkit/appkit#53)
// ---------------------------------------------------------------------------
//
// windowDidResize: asks, on the UI thread, with the new content size: is a
// frame painted at this size queued? It waits on the queue's condition
// variable, never longer than `waitMs`, and then drains the queue inline —
// not through the run-loop source, which AppKit's resize tracking would not
// fire until the resize had committed without its frame (it calls the
// delegate outside any run-loop pass: the #49 probe read a NULL mode
// there). Drained inline, the frame lands in the same transaction as the
// window's new size. JS never waits on the UI thread, so this cannot
// deadlock: the worst case is the deadline, and then the last frame shows at
// the new size, the root layer's background filling the exposed edge.

static bool QueuedFrameAt(double w, double h) {  // gCmdMu held
  for (const Command& c : gCmdQ)
    if (c.sized && std::fabs(c.width - w) < 0.5 && std::fabs(c.height - h) < 0.5)
      return true;
  return false;
}

bool CALAwaitFrame(double width, double height, double waitMs, double* waitedMs) {
  auto t0 = std::chrono::steady_clock::now();
  bool connected;
  {
    std::lock_guard<std::mutex> l(gEvMu);
    connected = gTsfn != nullptr;
  }
  bool met = false;
  if (connected && waitMs > 0) {
    // The deadline is not the condition variable's own timeout: the kernel
    // coalesces timers, and on a CI VM a 15 ms wait woke only as the worker's
    // 60 ms setTimeout fired. A strict dispatch timer (zero leeway, the flag
    // that asks the system not to coalesce it) ends the wait instead, and the
    // timed wait below is only a backstop a second later.
    auto expired = std::make_shared<std::atomic<bool>>(false);
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_source_set_timer(
        timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitMs * NSEC_PER_MSEC)),
        DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timer, ^{
      {
        std::lock_guard<std::mutex> l(gCmdMu);
        expired->store(true);
      }
      gCmdCv.notify_all();
    });
    dispatch_resume(timer);
    {
      std::unique_lock<std::mutex> l(gCmdMu);
      gCmdCv.wait_until(
          l, t0 + std::chrono::microseconds((long long)(waitMs * 1000)) + std::chrono::seconds(1),
          [&] { return QueuedFrameAt(width, height) || expired->load(); });
      met = QueuedFrameAt(width, height);
    }
    dispatch_source_cancel(timer);
  }
  *waitedMs = std::chrono::duration<double, std::milli>(
                  std::chrono::steady_clock::now() - t0)
                  .count();
  DrainCommands(nullptr);
  return met;
}

// ---------------------------------------------------------------------------
// the run: runMain, requestExit, and what ends a run cleanly
// ---------------------------------------------------------------------------

// Menus being tracked right now, so an exit can cancel them. Every NSMenu
// posts these, the menu bar's and a pop-up's alike.
static NSMutableSet<NSMenu*>* gTrackingMenus = nil;
static id gMenuBeginObserver = nil, gMenuEndObserver = nil;

static void ObserveMenuTracking() {
  gTrackingMenus = [NSMutableSet set];
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  gMenuBeginObserver =
      [nc addObserverForName:NSMenuDidBeginTrackingNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification* n) {
                    if (n.object) [gTrackingMenus addObject:n.object];
                  }];
  gMenuEndObserver =
      [nc addObserverForName:NSMenuDidEndTrackingNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification* n) {
                    if (n.object) [gTrackingMenus removeObject:n.object];
                  }];
}

static void StopObservingMenuTracking() {
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  if (gMenuBeginObserver) [nc removeObserver:gMenuBeginObserver];
  if (gMenuEndObserver) [nc removeObserver:gMenuEndObserver];
  gMenuBeginObserver = gMenuEndObserver = nil;
  gTrackingMenus = nil;
}

// An event for a loop waiting in nextEventMatchingMask: to wake on and then
// see the stop it was asked for. Dispatched, it means nothing to anyone.
static void PostWakeEvent() {
  NSEvent* e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                  location:NSZeroPoint
                             modifierFlags:0
                                 timestamp:0
                              windowNumber:0
                                   context:nil
                                   subtype:0
                                     data1:0
                                     data2:0];
  [NSApp postEvent:e atStart:YES];
}

void CALPostWakeEvent() { PostWakeEvent(); }

// On the UI thread. [NSApp stop:] ends the innermost loop only, and inside
// runModal it ends the modal session instead of the app, so any nested loop
// is ended first and the stop waits for the default mode — the main run.
// A drag session or a live resize cannot be ended from code; the stop
// waits for the button to come up.
static void StopRun() {
  for (NSMenu* m in [gTrackingMenus copy]) [m cancelTrackingWithoutAnimation];
  if (NSApp.modalWindow) [NSApp stopModalWithCode:NSModalResponseAbort];
  PostWakeEvent();
  Defer(^{
    if (!gRunning.load()) return;
    [NSApp stop:nil];
    PostWakeEvent();
  });
}

static const struct {
  int signo;
  const char* name;
} kForwardedSignals[] = {{SIGINT, "SIGINT"}, {SIGTERM, "SIGTERM"}, {SIGHUP, "SIGHUP"}};
static constexpr size_t kSignalCount = sizeof kForwardedSignals / sizeof kForwardedSignals[0];
static dispatch_source_t gSignalSources[kSignalCount];
static struct sigaction gPrevSignalAction[kSignalCount];

static void OnSignal(int signo, const char* name) {
  bool connected;
  {
    std::lock_guard<std::mutex> l(gEvMu);
    connected = gTsfn != nullptr;
  }
  if (connected) {
    CALEmit(std::move(CALEvent("signal").Str("signal", name)));
    return;
  }
  gExitCode = 128 + signo;
  gExitAsked = true;
  StopRun();
}

// Ignored as signals while the run lasts — Node's own SIGINT/SIGTERM handler
// would end the process from under the worker — and restored after. A child
// spawned meanwhile does not inherit the SIG_IGN: libuv resets every
// disposition in the child before exec.
static void ForwardSignals() {
  for (size_t i = 0; i < kSignalCount; i++) {
    int signo = kForwardedSignals[i].signo;
    const char* name = kForwardedSignals[i].name;
    struct sigaction ign = {};
    ign.sa_handler = SIG_IGN;
    sigemptyset(&ign.sa_mask);
    sigaction(signo, &ign, &gPrevSignalAction[i]);
    dispatch_source_t src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)signo, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{ OnSignal(signo, name); });
    dispatch_resume(src);
    gSignalSources[i] = src;
  }
}

static void StopForwardingSignals() {
  for (size_t i = 0; i < kSignalCount; i++) {
    if (!gSignalSources[i]) continue;
    dispatch_source_cancel(gSignalSources[i]);
    gSignalSources[i] = nil;
    sigaction(kForwardedSignals[i].signo, &gPrevSignalAction[i], nullptr);
  }
}

// runMain() — parks the process main thread in [NSApp run] until
// requestExit, a signal nobody is connected to hear, or the connected
// environment's end. -> the requested code, or null for the last.
static Napi::Value RunMain(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!pthread_main_np()) {
    Napi::Error::New(env, "runMain: only the process main thread can run AppKit")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (gRunning.load()) {
    Napi::Error::New(env, "runMain: already running").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  // asked before there was a run to end
  if (gExitAsked.exchange(false)) return Napi::Number::New(env, gExitCode.load());

  BEnsureApp();
  EnsureCommandSource();
  ObserveMenuTracking();
  ForwardSignals();
  gRunning = true;
  // what pump mode held back for a listener goes into the channel first
  CALReplayHeldEvents();
  CALBeginRunMode();
  @autoreleasepool {
    // A second finishLaunching inside -run sends applicationWillFinishLaunching:
    // again but not applicationDidFinishLaunching: (measured on 15.2); the
    // app delegate implements neither, and the launch's Apple Event was
    // dispatched by the first.
    [NSApp run];
  }
  CALEndRunMode();
  StopForwardingSignals();
  StopObservingMenuTracking();
  gRunning = false;
  if (gExitAsked.exchange(false)) return Napi::Number::New(env, gExitCode.load());
  return env.Null();
}

// requestExit(code) — any thread. Ends [NSApp run]; runMain returns `code`.
// The process itself is ended by the main thread's JS with that code. Asked
// before runMain, runMain returns it at once.
static Napi::Value RequestExit(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  int code = 0;
  if (info.Length() > 0 && !info[0].IsUndefined()) {
    if (!info[0].IsNumber()) {
      Napi::TypeError::New(env, "requestExit(code): code must be a number")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    code = info[0].As<Napi::Number>().Int32Value();
  }
  gExitCode = code;
  gExitAsked = true;
  CALOnUI(^{ StopRun(); });
  return env.Undefined();
}

static Napi::Value Threaded(const Napi::CallbackInfo& info) {
  return Napi::Boolean::New(info.Env(), gRunning.load());
}

// ---------------------------------------------------------------------------
// test hooks: a command's round trip, and the nested loops it must survive
// ---------------------------------------------------------------------------

// pingUI(tag) — a command that answers `ui-pong { tag, mode, drained }` from
// the UI thread: `mode` is the run-loop mode it was applied in (null outside
// any), `drained` whether it came through the queue rather than inline. The
// round trip is a command's latency plus an event's.
static Napi::Value PingUI(const Napi::CallbackInfo& info) {
  double tag = info.Length() > 0 && info[0].IsNumber()
                   ? info[0].As<Napi::Number>().DoubleValue()
                   : 0;
  CALOnUI(^{
    CALEvent ev("ui-pong");
    ev.Num("tag", tag);
    CFStringRef mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
    if (mode) {
      ev.Str("mode", ((__bridge NSString*)mode).UTF8String);
      CFRelease(mode);
    } else {
      ev.Null("mode");
    }
    ev.Bool("drained", gDrainDepth > 0);
    CALEmit(std::move(ev));
  });
  return info.Env().Undefined();
}

static double NowMs() { return CFAbsoluteTimeGetCurrent() * 1000.0; }

static void RunNestedLoop(bool menu, double ms) {
  const char* kind = menu ? "menu" : "modal";
  double t0 = NowMs();
  CALEmit(std::move(CALEvent("modal-loop-begin").Str("kind", kind)));
  if (menu) {
    NSMenu* m = [[NSMenu alloc] initWithTitle:@"appkit"];
    [m addItemWithTitle:@"postModalLoop" action:nil keyEquivalent:@""];
    [m addItemWithTitle:@"ends by itself" action:nil keyEquivalent:@""];
    NSTimer* t = [NSTimer timerWithTimeInterval:ms / 1000.0
                                        repeats:NO
                                          block:^(NSTimer*) {
                                            [m cancelTrackingWithoutAnimation];
                                          }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    [m popUpMenuPositioningItem:nil atLocation:NSEvent.mouseLocation inView:nil];
    [t invalidate];
  } else {
    NSAlert* a = [NSAlert new];
    a.messageText = @"@windowkit/appkit postModalLoop";
    a.informativeText = @"A test's modal loop; it ends by itself.";
    [a addButtonWithTitle:@"OK"];
    NSTimer* t = [NSTimer timerWithTimeInterval:ms / 1000.0
                                        repeats:NO
                                          block:^(NSTimer*) {
                                            [NSApp stopModalWithCode:NSModalResponseAbort];
                                            PostWakeEvent();
                                          }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    [a runModal];
    [t invalidate];
  }
  CALEmit(std::move(
      CALEvent("modal-loop-end").Str("kind", kind).Num("ms", NowMs() - t0)));
}

// postModalLoop('menu' | 'modal', ms) — for tests: one of AppKit's nested
// loops on the UI thread for `ms`, then ended from a timer: a pop-up menu's
// tracking (NSEventTrackingRunLoopMode) or an NSAlert's runModal
// (NSModalPanelRunLoopMode). Started as a modal command, so it is also the
// test of CALOnUIModal; `modal-loop-begin` / `modal-loop-end { ms }` bracket
// it. In pump mode it runs inside the call, as any modal loop does there.
static Napi::Value PostModalLoop(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  std::string kind = info.Length() > 0 && info[0].IsString()
                         ? info[0].As<Napi::String>().Utf8Value()
                         : "";
  if (kind != "menu" && kind != "modal") {
    Napi::TypeError::New(env, "postModalLoop(kind, ms): kind is 'menu' or 'modal'")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  double ms = info.Length() > 1 && info[1].IsNumber()
                  ? info[1].As<Napi::Number>().DoubleValue()
                  : 500;
  bool menu = kind == "menu";
  CALOnUIModal(^{ RunNestedLoop(menu, ms); });
  return env.Undefined();
}

void InitThreaded(Napi::Env env, Napi::Object exports) {
#define TFN(js, fn) exports.Set(js, Napi::Function::New(env, fn))
  TFN("runMain", RunMain);
  TFN("connect", Connect);
  TFN("requestExit", RequestExit);
  TFN("threaded", Threaded);
  TFN("pingUI", PingUI);
  TFN("postModalLoop", PostModalLoop);
#undef TFN
}
