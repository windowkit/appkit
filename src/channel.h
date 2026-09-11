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

// Windows and status items alive — the objects a person can act on. The
// channel's threadsafe function holds the connected environment's loop open
// while any exist and lets it go when none do, so an app with nothing on
// screen can exit.
void CALUIObjectsChanged(int delta);
