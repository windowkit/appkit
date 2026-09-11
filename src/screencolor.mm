// @windowkit/appkit screencolor.mm — one colour off the screen, through
// NSColorSampler: the eyedropper a colour picker's dropper button calls.
//
// The system draws the loupe out of process and hands back the one colour the
// user clicked, so nothing here reads the screen and the app needs no Screen
// Recording grant of its own. That is why this is the rung that belongs on
// top of react-x11's ladder rather than a fallback under the desktop
// portal's PickColor (windowkit/appkit#46): it is the same shape — the
// desktop samples, the app is told the answer — and the rung below it, a
// pointer grab and a 1×1 GetImage on the root window, has neither a pointer
// to grab nor a root window to read on Cocoa.
//
// One verb, mechanism only:
//
//   sampleScreenColor(cb)   cb(null, { r, g, b }) — sRGB, 0–1 floats, the
//                           portal's (ddd) shape — or cb(null, null) when the
//                           user dismissed the sampler without picking. A
//                           cancel is an ordinary outcome, not an error.
//
// What the colour means past that — the hex string a component paints with,
// whether a cancel resolves null or rejects — stays in the renderer.
//
// One at a time, the way NSColorSampler is: a show "begins or attaches to an
// existing color sampling session", its header says, so a second call while a
// loupe is up must not stack a second one. The bridge keeps that promise
// itself rather than leaving it to the framework — one session, and every
// caller waiting on it answered once with the same colour — because a
// callback that never fired would hold node's loop open forever.
//
// The answer is asynchronous, always: AppKit calls the handler on the main
// thread when the session ends, which is during the pump (the location grant
// in permissions.mm arrives the same way), and it crosses to JS through a
// thread-safe function, so a sampler still up holds the event loop open like
// pending I/O. Nothing dismisses it from code — AppKit offers no such call —
// so the session ends when the user picks a colour or presses Escape.

#include <napi.h>
#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>

#include "channel.h"  // CALOnUI: the session is the UI thread's; CALCallJS

// src/backend.mm — NSApplication set up exactly once, whichever verb comes
// first. The sampler is AppKit UI like a panel, so it wants an app.
void BEnsureApp();

// What one finished session owes every caller waiting on it.
struct ColorAnswer {
  bool cancelled = false;      // dismissed without picking
  double r = 0, g = 0, b = 0;  // sRGB, 0–1
  std::string error;           // set instead when the colour could not be read
};

// The callers of the session that is up, in the order they asked; empty when
// none is. Touched on the UI thread only: the verb's own part runs there
// (inline in pump mode, a command from a worker), and so does AppKit's
// handler, inside the pump or the run.
static std::vector<Napi::ThreadSafeFunction> gWaiting;

// cb(err) | cb(null, null) | cb(null, { r, g, b }) on the JS thread, then the
// thread-safe function goes — which is what held the loop open meanwhile.
static void Deliver(Napi::ThreadSafeFunction tsfn, const ColorAnswer& answer) {
  ColorAnswer* a = new ColorAnswer(answer);
  napi_status st = tsfn.BlockingCall(
      a, [](Napi::Env env, Napi::Function cb, ColorAnswer* a) {
        // an environment on its way out gets no answer (channel.h)
        if (!CALCanCallIntoJS(env)) {
          delete a;
          return;
        }
        if (!a->error.empty()) {
          CALCallJS(env, cb, {Napi::Error::New(env, a->error).Value()});
        } else if (a->cancelled) {
          CALCallJS(env, cb, {env.Null(), env.Null()});
        } else {
          Napi::Object c = Napi::Object::New(env);
          c.Set("r", Napi::Number::New(env, a->r));
          c.Set("g", Napi::Number::New(env, a->g));
          c.Set("b", Napi::Number::New(env, a->b));
          CALCallJS(env, cb, {env.Null(), c});
        }
        delete a;
      });
  if (st != napi_ok) delete a;
  tsfn.Release();
}

// The one place a session answers. The waiting list comes off first, so a
// sampleScreenColor called from inside a callback opens a fresh session
// rather than joining the one that has just ended (the file panels' rule).
static void FinishSession(NSColor* picked) {
  ColorAnswer a;
  if (!picked) {
    a.cancelled = true;
  } else {
    // Whatever space the sampler read the pixel in — a display's, wide-gamut
    // on most Macs now — in the one every colour crosses this bridge in (the
    // 0.5.1 rule). ColorSync gamut-maps on the way, so a Display P3 red
    // arrives as sRGB (1, 0, 0) rather than as components outside 0–1.
    NSColor* srgb = [picked colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (srgb) {
      a.r = srgb.redComponent;
      a.g = srgb.greenComponent;
      a.b = srgb.blueComponent;
    } else {
      // Nothing the sampler can hand back should land here (a pattern colour
      // is the shape with no sRGB form), but a colour that cannot be read is
      // not a cancel, so it is said rather than answered as one.
      a.error =
          "sampleScreenColor: the sampler answered a colour with no sRGB form";
    }
  }
  std::vector<Napi::ThreadSafeFunction> waiting;
  waiting.swap(gWaiting);
  for (Napi::ThreadSafeFunction& tsfn : waiting) Deliver(tsfn, a);
}

// sampleScreenColor(cb) — show the system sampler and answer once,
// asynchronously: cb(null, { r, g, b }) in sRGB, or cb(null, null) when the
// user dismissed it. A second call while a sampler is up joins that session
// instead of showing another, and both callbacks get the same answer.
static Napi::Value SampleScreenColor(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsFunction()) {
    Napi::TypeError::New(env, "sampleScreenColor: expected a callback (cb)")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  // made in the caller's environment, which is the one answered
  Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
      env, info[0].As<Napi::Function>(), "appkit:sampleScreenColor", 0, 1);
  CALOnUI(^{
    @autoreleasepool {
      BEnsureApp();
      bool sessionUp = !gWaiting.empty();
      gWaiting.push_back(tsfn);
      if (sessionUp) return;
      // Nothing here keeps the sampler alive: AppKit retains it for as long
      // as the session lasts, which its header promises in as many words.
      [[NSColorSampler new] showSamplerWithSelectionHandler:^(NSColor* c) {
        FinishSession(c);
      }];
    }
  });
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// registration (called from addon.mm's Init)
// ---------------------------------------------------------------------------

void InitScreenColor(Napi::Env env, Napi::Object exports) {
  exports.Set("sampleScreenColor",
              Napi::Function::New(env, SampleScreenColor));
}
