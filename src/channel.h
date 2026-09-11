// @windowkit/appkit channel.h — what every face of the addon shares with the
// threading core in threaded.mm (windowkit/appkit#50): the event record, the
// one way an event leaves the UI thread, and the one way a command reaches it.
//
// Two modes, one set of producers. In pump mode (today's, the default) JS
// runs on the process main thread and pumps AppKit through pump2(); an event
// is materialized and handed to the backend callback inline, exactly as it
// always was. In threaded mode the main thread is parked in [NSApp run]
// (runMain) and the renderer's JS runs on a Worker; an event is appended to
// a queue and crosses to the connected environment in batches. A producer
// cannot tell the two apart: it builds a CALEvent and calls CALEmit.

#pragma once

#include <napi.h>
#import <Foundation/Foundation.h>

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

// A JS value the producer's environment already holds (a status item's own
// handle), looked up when the event is materialized. Gets the environment
// the event is being delivered to and answers null when the value is not
// that environment's.
typedef Napi::Value (^CALValueBlock)(Napi::Env env);

// A backend event as plain data. Built on whatever thread AppKit calls in
// on, never as a Napi::Object, since no JS value may be made off its
// environment's thread; materialized there, key order as added.
class CALEvent {
 public:
  CALEvent() = default;
  explicit CALEvent(const char* type) : type_(type) { Str("type", type); }

  CALEvent& Str(const char* key, const std::string& v);
  CALEvent& Str(const char* key, const char* v);  // nullptr reads as ""
  CALEvent& Num(const char* key, double v);
  CALEvent& Bool(const char* key, bool v);
  CALEvent& Null(const char* key);
  CALEvent& Strs(const char* key, std::vector<std::string> v);
  // JSON text, parsed as it crosses; the text itself if it does not parse
  CALEvent& Json(const char* key, const std::string& v);
  CALEvent& Handle(const char* key, CALValueBlock v);
  // the JS handle CALWrapHandle registered for this id, or null when the
  // delivering environment is not the one holding it (or it was collected)
  CALEvent& HandleRef(const char* key, uint64_t id);
  // In threaded mode an event of the same type and key queued right behind
  // this one replaces it: consecutive motion crosses as its latest position.
  CALEvent& FoldBy(double key) {
    foldable_ = true;
    foldKey_ = key;
    return *this;
  }

  Napi::Object ToObject(Napi::Env env) const;
  bool FoldsOnto(const CALEvent& prev) const {
    return foldable_ && prev.foldable_ && foldKey_ == prev.foldKey_ &&
           type_ == prev.type_;
  }

 private:
  struct Field {
    enum Kind { kStr, kNum, kBool, kNull, kStrs, kJson, kHandle } kind;
    std::string key;
    std::string s;
    double n = 0;
    bool b = false;
    std::vector<std::string> list;
    CALValueBlock handle = nil;
  };
  Field& Add(Field::Kind kind, const char* key);

  std::string type_;
  std::vector<Field> fields_;
  bool foldable_ = false;
  double foldKey_ = 0;
};

// The event goes out: into the channel's queue in threaded mode (from any
// thread), to the backend callback inline in pump mode (the JS main thread
// only; dropped when no callback is installed, as before).
void CALEmit(CALEvent&& ev);

// Somebody will receive an event: the channel is open (runMain entered or an
// environment connected), or a pump-mode callback is installed. The test
// producers use before doing work, and the test for holding one back.
bool CALListening();

// The channel is open: CALEmit queues, from any thread. A producer that
// runs off the main thread (a UNUserNotificationCenter delegate, EventKit's
// change notification) emits directly when this holds, and takes its own
// hop to the JS main thread for pump mode when it does not.
bool CALChannelOpen();

// runMain has been entered and not returned: the main thread is AppKit's.
bool CALThreaded();

// Runs `block` on the UI thread: inline when called there (pump mode, as
// every verb does today), queued to the command source otherwise. Arguments
// are parsed on the calling thread and captured by value; no napi_value may
// cross. Queued blocks apply in order, a whole drain inside one
// CATransaction with implicit actions disabled.
void CALOnUI(void (^block)(void));

// The same for a block that starts a modal loop — a pop-up menu, an
// app-modal panel, a drag session. Queued, it runs from a run-loop callout
// of its own in the default mode once the drain it arrived in is done, so
// the rest of that batch never waits behind the gesture; called on the UI
// thread outside a drain it runs inline, as today.
void CALOnUIModal(void (^block)(void));

// On the UI thread: an application-defined event for a loop waiting in
// nextEventMatchingMask: to wake on — after a stopModal from a command, say,
// which the modal loop only notices on its next event.
void CALPostWakeEvent();

// Windows and status items alive — the objects a person can act on. The
// channel's threadsafe function holds the connected environment's loop open
// while any exist and lets it go when none do, so an app with nothing on
// screen can exit. Called on the connected environment's own thread (a
// worker's createWindow2) the reference changes at once, so a worker whose
// script ends right after making a window is still held.
void CALUIObjectsChanged(int delta);

// ---------------------------------------------------------------------------
// handles allocated at the call (windowkit/appkit#51)
// ---------------------------------------------------------------------------
//
// JS never waits on the UI thread, so in threaded mode a verb that makes an
// AppKit object answers before the object exists: it allocates a CALHandle
// on the calling thread, hands JS an External over it, and queues the
// making; the UI thread binds the object into the handle as it makes it.
// Every later verb captures the handle and resolves it inside its own
// command, which runs after the making because commands apply in order.
// Pump mode still hands out the object itself, as it always has; the two
// helpers below take either.

@interface CALHandle : NSObject {
 @public
  uint64_t id_;                  // what an event's `handle` field names
  id object_;                    // the UI thread's: nil until made, nil once gone
  CALHandle* part_;              // a window's root layer, allocated with it
  std::atomic<long> number_;     // a window's number once made (0 before); any thread
  std::atomic<bool> released_;   // destroyed / removed through a verb (counted once)
}
@end

CALHandle* CALNewHandle();  // any thread

// The External JS holds. `registered`: events may name it (a window, a
// status item), so a weak reference is kept for CALEvent::HandleRef; the
// External's finalizer drops it. The object is let go on the UI thread
// whichever thread the handle dies on.
Napi::Value CALWrapHandle(Napi::Env env, CALHandle* h, bool registered);

// Hold a registered handle's External strongly (pin) or let it go again,
// on the environment's own thread: a worker's status item stays in the bar
// until removeStatusItem even when JS drops its handle, as pump mode's does.
void CALPinHandle(Napi::Env env, uint64_t id, bool pin);

// What a verb captures for its command: the handle, or pump mode's object
// itself; nil for anything that is neither.
id CALHandleTarget(Napi::Value v);

// On the UI thread: the object a captured target names — nil before it is
// made and after it is gone.
id CALResolve(id target);

// A layer verb's work (windowkit/appkit#52): run in the call on the main
// thread; from any other, recorded into that thread's open frame batch
// (txBegin … txCommit) or, outside one, queued as a command of its own.
void CALOnLayers(void (^op)(void));

// On the UI thread, before a layer's contents are replaced: while a worker's
// frame applies, an IOSurface taken off the layer is reported afterwards as
// `surface-released { id }`.
void CALNoteContentsReplaced(id layer, id next);

// A one-shot callback in the calling environment, answered from any thread:
// `make` runs there and builds the one argument cb gets. A pending reply
// holds that environment's loop open, like I/O in flight.
Napi::ThreadSafeFunction CALReplyTo(Napi::Env env, Napi::Function cb,
                                    const char* name);
void CALReply(Napi::ThreadSafeFunction tsfn, CALValueBlock make);

// A read of AppKit state, in either mode. Without a callback (the last
// argument, when it is a function) it answers synchronously — on the main
// thread only, as every read always has; off it that is a TypeError. With
// one, `compute` runs on the UI thread and what it returns builds cb's one
// argument in the caller's environment, a later tick even on the main
// thread. `compute` never returns nil. `nested`: compute spins a run loop of
// its own (a test hook waiting for a window), so a queued one runs through
// CALOnUIModal rather than inside a drain.
Napi::Value CALAnswer(const Napi::CallbackInfo& info, const char* name,
                      CALValueBlock (^compute)(void), bool nested = false);
