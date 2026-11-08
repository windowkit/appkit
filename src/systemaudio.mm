// @windowkit/appkit systemaudio.mm — the sound other applications play, for a
// renderer's media capture (react-x11's design/architecture/media-capture.md):
// CoreAudio's process taps (macOS 14.2), of every process but this one or of
// one application, delivered the way a microphone's sound is.
//
// The processes — nothing asked of the user, nothing prompts:
//
// - audioProcesses() -> [{ pid, bundleId, name, playing, app? }], or the same
//   through audioProcesses(cb) from a queue of its own: CoreAudio's process
//   objects, every process connected to the audio server and not only those
//   playing. `playing` is whether it has output running now; `app` is the
//   outermost application bundle its executable sits in, `{ bundleId, name,
//   regular }`, `regular` for an app with a Dock icon. A browser's renderers
//   and an Electron app's helpers play under helper bundle ids of their own
//   (com.google.Chrome.helper), and `app` is what a person would call them.
// - event `audio-processes` whenever a process connects or goes, or starts or
//   stops playing. Watched from the first audioProcesses() on.
//
// A tap:
//
// - openSystemAudio({ pid?, bundleId?, exclude?, sampleRate, channels }) ->
//   { id, sampleRate, channels }: a private tap of every process but this one
//   and the pids in `exclude`; with `pid`, of that process; with `bundleId`,
//   of every process whose own bundle id or `app` is that one. A bundle id's
//   tap follows the application: a helper that starts later joins it, and an
//   application that is not running is silence until it is. The audio is
//   resampled and mixed to the rate and count asked, as a microphone's is.
//   `system-audio-started { id, sampleRate, channels, latency }` or
//   `system-audio-error { id, name, message }` answers the open, `name` Media
//   Capture's (NotFoundError for a pid with no audio, NotAllowedError, and
//   NotReadableError for CoreAudio saying no); then `audio-input { id,
//   sampleRate, channels: [Float32Array], frames, time, dropped? }` every
//   10 ms — a microphone's event — silence included while nothing plays, and
//   nothing dropped short of two seconds waiting. `system-audio-ended { id }`
//   when the one process tapped has gone. closeSystemAudio(id).
//
// These verbs are exported on macOS 14.2 and later only, which is how a
// renderer tells whether there is a tap to open.
//
// The permission is TCC's System Audio Recording (kTCCServiceAudioCapture;
// NSAudioCaptureUsageDescription is the bundle's key), which permissions.mm
// reads and asks for as `system-audio-recording`. A tap without it is not an
// error — it delivers silence, for as long as anybody reads it — so an open
// reads the status first: a refusal is a NotAllowedError, and an undecided one
// is asked before the tap is made.
//
// Each tap is an aggregate device of its own holding the tap and nothing else:
// no output device beside it, whose input streams would be opened with it (a
// headset's microphone, and a Bluetooth headset switched into its call
// profile by that) and come first in the buffers. The IO block runs on a
// queue of the tap's own; everything else — making, following, closing — on
// one queue for all of them, where CoreAudio's listeners call too.
//
// APPKIT_DEBUG_AUDIO=1 — capture.mm's switch — says on stderr what each tap
// did: the grant read, each CoreAudio call's status, the first buffers'
// layout, and once a second the frames in, the chunks out and the loudest
// sample. A peak of 0 with something playing is a refused grant: macOS feeds
// such a tap silence.

#include <napi.h>
#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <atomic>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "channel.h"

// capture.mm: the count every capture's id comes from, so an event's id names
// one thing, and the one way a queue of CoreAudio's reaches JS
double CALNextCaptureId();
bool CALCaptureDeliver(dispatch_block_t block);

// permissions.mm: TCC's System Audio Recording, read and asked
const char* CALAudioCaptureStatus();
void CALAudioCaptureRequest(void (^done)(void));

static const bool gDebugAudio = [] {
  const char* v = getenv("APPKIT_DEBUG_AUDIO");
  return v && *v && strcmp(v, "0") != 0;
}();
#define TAP_LOG(...)                                                   \
  do {                                                                 \
    if (gDebugAudio) {                                                 \
      fprintf(stderr, "@windowkit/appkit system audio: " __VA_ARGS__); \
      fputc('\n', stderr);                                             \
    }                                                                  \
  } while (0)

static double Seconds() {
  static mach_timebase_info_data_t base = [] {
    mach_timebase_info_data_t b;
    mach_timebase_info(&b);
    return b;
  }();
  return (double)mach_absolute_time() * base.numer / base.denom / 1e9;
}

static void Send(CALEvent ev) {
  auto held = std::make_shared<CALEvent>(std::move(ev));
  CALCaptureDeliver(^{
    if (CALListening()) CALEmit(std::move(*held));
  });
}

static NSString* Str(Napi::Value v) {
  if (!v.IsString()) return nil;
  return [NSString stringWithUTF8String:v.As<Napi::String>().Utf8Value().c_str()];
}

static bool OptNum(Napi::Value obj, const char* k, double* out) {
  if (!obj.IsObject()) return false;
  Napi::Value v = obj.As<Napi::Object>().Get(k);
  if (!v.IsNumber()) return false;
  double d = v.As<Napi::Number>().DoubleValue();
  if (!std::isfinite(d)) return false;
  *out = d;
  return true;
}

static AudioObjectPropertyAddress Global(AudioObjectPropertySelector sel) {
  return {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

// One queue for making, following and closing taps, and for CoreAudio's
// listeners: everything below that is not the IO itself.
static dispatch_queue_t Control() {
  static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ q = dispatch_queue_create("appkit.systemaudio", DISPATCH_QUEUE_SERIAL); });
  return q;
}

// ---------------------------------------------------------------------------
// processes
// ---------------------------------------------------------------------------

static std::vector<AudioObjectID> ProcessObjects() {
  AudioObjectPropertyAddress a = Global(kAudioHardwarePropertyProcessObjectList);
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr) return {};
  std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
  if (ids.empty() || AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data()) != noErr) {
    return {};
  }
  ids.resize(size / sizeof(AudioObjectID));
  return ids;
}

static pid_t PidOf(AudioObjectID p) {
  pid_t pid = -1;
  UInt32 size = sizeof(pid);
  AudioObjectPropertyAddress a = Global(kAudioProcessPropertyPID);
  if (AudioObjectGetPropertyData(p, &a, 0, nullptr, &size, &pid) != noErr) return -1;
  return pid;
}

static NSString* BundleIdOf(AudioObjectID p) {
  CFStringRef s = nullptr;
  UInt32 size = sizeof(s);
  AudioObjectPropertyAddress a = Global(kAudioProcessPropertyBundleID);
  if (AudioObjectGetPropertyData(p, &a, 0, nullptr, &size, &s) != noErr || !s) return @"";
  return (__bridge_transfer NSString*)s;
}

static bool PlayingOf(AudioObjectID p) {
  UInt32 on = 0, size = sizeof(on);
  AudioObjectPropertyAddress a = Global(kAudioProcessPropertyIsRunningOutput);
  return AudioObjectGetPropertyData(p, &a, 0, nullptr, &size, &on) == noErr && on;
}

static NSString* ExecutableOf(pid_t pid) {
  char path[PROC_PIDPATHINFO_MAXSIZE];
  if (pid <= 0 || proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
  return [NSString stringWithUTF8String:path];
}

// The outermost application bundle `path` is inside: the browser a renderer
// belongs to, the app an Electron helper is a part of. Nil for a tool that is
// in no bundle.
static NSBundle* OutermostApp(NSString* path) {
  NSString* found = nil;
  for (NSString* p = path; p.length > 1; p = p.stringByDeletingLastPathComponent) {
    if ([p.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame) found = p;
  }
  return found ? [NSBundle bundleWithPath:found] : nil;
}

static NSString* BundleName(NSBundle* b) {
  NSString* name = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"];
  if (!name.length) name = [b objectForInfoDictionaryKey:@"CFBundleName"];
  return name.length ? name : b.bundlePath.lastPathComponent.stringByDeletingPathExtension;
}

// The bundle id a tap of one application matches a process by: the
// application it runs from, or its own where it runs from none.
static NSString* AppIdOf(AudioObjectID p, pid_t pid) {
  NSString* app = OutermostApp(ExecutableOf(pid)).bundleIdentifier;
  return app.length ? app : BundleIdOf(p);
}

struct Proc {
  pid_t pid = -1;
  std::string bundleId, name;
  bool playing = false;
  bool hasApp = false;
  std::string appBundleId, appName;
  bool regular = false;
};

// The processes there are, as plain data: on any thread.
static std::vector<Proc> ListProcesses() {
  std::vector<Proc> list;
  for (AudioObjectID object : ProcessObjects()) {
    @autoreleasepool {
      Proc p;
      p.pid = PidOf(object);
      if (p.pid <= 0) continue;
      p.bundleId = BundleIdOf(object).UTF8String ?: "";
      p.playing = PlayingOf(object);
      NSString* exe = ExecutableOf(p.pid);
      NSString* name = [NSRunningApplication runningApplicationWithProcessIdentifier:p.pid].localizedName;
      if (!name.length) name = exe.lastPathComponent;
      if (!name.length) {
        char n[2 * MAXCOMLEN + 1] = {0};
        if (proc_name(p.pid, n, sizeof(n)) > 0) name = [NSString stringWithUTF8String:n];
      }
      p.name = name.UTF8String ?: "";
      NSBundle* app = exe ? OutermostApp(exe) : nil;
      if (app.bundleIdentifier.length) {
        p.hasApp = true;
        p.appBundleId = app.bundleIdentifier.UTF8String;
        // the running application's name is in the user's language; the
        // bundle's own, read from here, is in this process's
        NSString* appName = nil;
        for (NSRunningApplication* r in [NSRunningApplication runningApplicationsWithBundleIdentifier:app.bundleIdentifier]) {
          if (r.activationPolicy == NSApplicationActivationPolicyRegular) p.regular = true;
          if (!appName.length) appName = r.localizedName;
        }
        p.appName = (appName.length ? appName : BundleName(app)).UTF8String ?: "";
      }
      list.push_back(std::move(p));
    }
  }
  return list;
}

static Napi::Value ProcessesValue(Napi::Env env, const std::vector<Proc>& list) {
  Napi::Array out = Napi::Array::New(env, list.size());
  for (size_t i = 0; i < list.size(); i++) {
    const Proc& p = list[i];
    Napi::Object o = Napi::Object::New(env);
    o.Set("pid", (double)p.pid);
    o.Set("bundleId", p.bundleId);
    o.Set("name", p.name);
    o.Set("playing", p.playing);
    if (p.hasApp) {
      Napi::Object app = Napi::Object::New(env);
      app.Set("bundleId", p.appBundleId);
      app.Set("name", p.appName);
      app.Set("regular", p.regular);
      o.Set("app", app);
    }
    out.Set((uint32_t)i, o);
  }
  return out;
}

// What a listing shows that changes: who is connected and who is playing.
// CoreAudio reuses a process object's id for a later process, so the pid is
// part of it.
static NSString* Signature() {
  NSMutableArray<NSString*>* parts = [NSMutableArray array];
  for (AudioObjectID o : ProcessObjects()) {
    [parts addObject:[NSString stringWithFormat:@"%d|%@|%d", PidOf(o), BundleIdOf(o), PlayingOf(o)]];
  }
  [parts sortUsingSelector:@selector(compare:)];
  return [parts componentsJoinedByString:@"\n"];
}

// ---------------------------------------------------------------------------
// taps
// ---------------------------------------------------------------------------

API_AVAILABLE(macos(14.2))
@interface CALTap : NSObject
@property(nonatomic) double tid;
@property(nonatomic) pid_t pid;                     // one process, or 0
@property(nonatomic, copy) NSString* bundleId;      // one application, or nil
@property(nonatomic, copy) NSArray<NSNumber*>* excludePids;
@property(nonatomic) double sampleRate;
@property(nonatomic) AVAudioChannelCount channels;
@property(nonatomic, strong) CATapDescription* desc;
@property(nonatomic, copy) NSSet<NSNumber*>* objects;  // the process objects in it (out of it, for everything)
@property(nonatomic, strong) dispatch_queue_t io;
@property(nonatomic, copy) AudioObjectPropertyListenerBlock formatListener;
@property(nonatomic) BOOL started, ended;
// the IO queue's
@property(nonatomic, strong) AVAudioFormat* format;  // what was asked
@property(nonatomic, strong) AVAudioFormat* source;  // what the tap's buffers hold
@property(nonatomic, strong) AVAudioConverter* converter;
@end

@implementation CALTap {
 @public
  AudioObjectID tap, aggregate;
  AudioDeviceIOProcID proc;
  double tapRate;  // the IO queue's once the IO runs
  std::atomic<bool> closed;
  std::vector<std::vector<float>> pending;  // converted, not yet a 10 ms chunk
  double sent;                              // frames sent, for `time`
  std::shared_ptr<std::atomic<int>> inflight;
  std::atomic<int> dropped;
  // APPKIT_DEBUG_AUDIO's, the IO queue's
  bool described;
  uint64_t framesIn, chunksOut;
  float peak;
  double lastReport;
}

// The process objects the tap is of now — or for everything, the ones it
// leaves out: this process and what the caller excluded.
- (NSSet<NSNumber*>*)wanted {
  NSMutableSet<NSNumber*>* out = [NSMutableSet set];
  pid_t me = getpid();
  for (AudioObjectID o : ProcessObjects()) {
    pid_t pid = PidOf(o);
    if (self.pid > 0) {
      if (pid == self.pid) [out addObject:@(o)];
    } else if (self.bundleId) {
      if ([self.bundleId isEqualToString:AppIdOf(o, pid)] || [self.bundleId isEqualToString:BundleIdOf(o)]) {
        [out addObject:@(o)];
      }
    } else if (pid == me || [self.excludePids containsObject:@(pid)]) {
      [out addObject:@(o)];
    }
  }
  return out;
}

// On the IO queue: what the tap gave, converted, out in 10 ms chunks.
- (void)took:(const AudioBufferList*)in {
  if (closed.load() || !in || in->mNumberBuffers == 0 || !(tapRate > 0)) return;
  const AudioBuffer& first = in->mBuffers[0];
  UInt32 perFrame = first.mNumberChannels ?: 1;
  bool interleaved = in->mNumberBuffers == 1 && perFrame > 1;
  AVAudioChannelCount count = interleaved ? perFrame : in->mNumberBuffers;
  AVAudioFrameCount frames = (AVAudioFrameCount)(first.mDataByteSize / (sizeof(float) * perFrame));
  if (gDebugAudio) {
    if (!described) {
      described = true;
      TAP_LOG("tap %g: first buffers — %u buffer(s), %u channel(s) in the first, %u bytes, %u frames at %g Hz",
              self.tid, (unsigned)in->mNumberBuffers, (unsigned)first.mNumberChannels,
              (unsigned)first.mDataByteSize, (unsigned)frames, tapRate);
    }
    framesIn += frames;
    for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
      const float* p = (const float*)in->mBuffers[b].mData;
      size_t n = p ? in->mBuffers[b].mDataByteSize / sizeof(float) : 0;
      for (size_t i = 0; i < n; i++) peak = fmaxf(peak, fabsf(p[i]));
    }
    double now = Seconds();
    if (now - lastReport >= 1) {
      TAP_LOG("tap %g: last second %llu frame(s) in, %llu chunk(s) out, peak %.4f%s", self.tid,
              (unsigned long long)framesIn, (unsigned long long)chunksOut, peak,
              peak == 0 ? " — silence: nothing playing, or the grant refused" : "");
      framesIn = chunksOut = 0;
      peak = 0;
      lastReport = now;
    }
  }
  if (frames == 0) return;
  if (!self.source || self.source.channelCount != count || self.source.isInterleaved != interleaved ||
      self.source.sampleRate != tapRate) {
    self.source = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                   sampleRate:tapRate
                                                     channels:count
                                                  interleaved:interleaved];
    self.converter = nil;
  }
  if (!self.converter) {
    self.converter = [[AVAudioConverter alloc] initFromFormat:self.source toFormat:self.format];
    if (self.format.channelCount < count) self.converter.downmix = YES;
  }
  AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.source bufferListNoCopy:in deallocator:nil];
  if (!buf || !self.converter) return;
  buf.frameLength = frames;
  AVAudioFrameCount cap = (AVAudioFrameCount)ceil(frames * self.format.sampleRate / tapRate) + 64;
  AVAudioPCMBuffer* out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.format frameCapacity:cap];
  __block bool given = false;
  NSError* err = nil;
  [self.converter convertToBuffer:out
                            error:&err
               withInputFromBlock:^AVAudioBuffer*(AVAudioPacketCount, AVAudioConverterInputStatus* status) {
                 if (given) {
                   *status = AVAudioConverterInputStatus_NoDataNow;
                   return nil;
                 }
                 given = true;
                 *status = AVAudioConverterInputStatus_HaveData;
                 return buf;
               }];
  AVAudioChannelCount n = self.format.channelCount;
  if (pending.size() != n) pending.assign(n, {});
  for (AVAudioChannelCount c = 0; c < n; c++) {
    float* src = out.floatChannelData[c];
    pending[c].insert(pending[c].end(), src, src + out.frameLength);
  }
  size_t chunk = (size_t)llround(self.format.sampleRate / 100);
  while (pending[0].size() >= chunk) {
    auto planes = std::make_shared<std::vector<std::vector<float>>>();
    for (auto& p : pending) {
      planes->emplace_back(p.begin(), p.begin() + chunk);
      p.erase(p.begin(), p.begin() + chunk);
    }
    double time = sent / self.format.sampleRate;
    sent += chunk;
    // two seconds waiting is as far as it goes: past that, the oldest wait
    // and this one is counted instead
    if (inflight->load() > 200) {
      dropped++;
      continue;
    }
    int lost = dropped.exchange(0);
    chunksOut++;
    auto waiting = inflight;
    waiting->fetch_add(1);
    double tid = self.tid, rate = self.format.sampleRate;
    if (!CALCaptureDeliver(^{
          waiting->fetch_sub(1);
          if (!CALListening()) return;
          CALEvent ev("audio-input");
          ev.Num("id", tid).Num("sampleRate", rate).Num("frames", (double)chunk).Num("time", time);
          if (lost) ev.Num("dropped", lost);
          ev.Handle("channels", ^Napi::Value(Napi::Env env) {
            Napi::Array a = Napi::Array::New(env, planes->size());
            for (size_t c = 0; c < planes->size(); c++) {
              auto& p = (*planes)[c];
              Napi::ArrayBuffer ab = Napi::ArrayBuffer::New(env, p.size() * sizeof(float));
              memcpy(ab.Data(), p.data(), p.size() * sizeof(float));
              a.Set((uint32_t)c, Napi::Float32Array::New(env, p.size(), ab, 0));
            }
            return a;
          });
          CALEmit(std::move(ev));
        })) {
      waiting->fetch_sub(1);
    }
  }
}

@end

// JS's and the control queue's alike, only under @synchronized(gTapsLock).
static NSMutableDictionary<NSNumber*, id>* gTaps;
static NSObject* gTapsLock;

static NSArray* TapsNow() {
  @synchronized(gTapsLock) {
    return gTaps.allValues ?: @[];
  }
}

static void TapError(double tid, const char* name, NSString* message) {
  Send(std::move(
      CALEvent("system-audio-error").Num("id", tid).Str("name", name).Str("message", message.UTF8String)));
}

// The aggregate device's input latency in seconds: what its streams and its
// buffer add, as CoreAudio reports them.
static double LatencyOf(AudioObjectID device, double rate) {
  if (!(rate > 0)) return 0;
  UInt32 frames = 0, safety = 0, buffer = 0, size = sizeof(UInt32);
  AudioObjectPropertyAddress a = {kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput,
                                  kAudioObjectPropertyElementMain};
  AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, &frames);
  a.mSelector = kAudioDevicePropertySafetyOffset;
  size = sizeof(UInt32);
  AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, &safety);
  a = Global(kAudioDevicePropertyBufferFrameSize);
  size = sizeof(UInt32);
  AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, &buffer);
  return (double)(frames + safety + buffer) / rate;
}

// The rate the IO block's buffers are at: the aggregate device's, which runs
// them, and the tap's own format where the device does not say.
static double TapRate(AudioObjectID tap, AudioObjectID aggregate) {
  Float64 rate = 0;
  UInt32 size = sizeof(rate);
  AudioObjectPropertyAddress a = Global(kAudioDevicePropertyNominalSampleRate);
  if (AudioObjectGetPropertyData(aggregate, &a, 0, nullptr, &size, &rate) == noErr && rate > 0) return rate;
  AudioStreamBasicDescription asbd = {};
  size = sizeof(asbd);
  a = Global(kAudioTapPropertyFormat);
  if (AudioObjectGetPropertyData(tap, &a, 0, nullptr, &size, &asbd) == noErr) return asbd.mSampleRate;
  return 0;
}

// On the control queue: everything the tap holds let go, in the reverse of
// the order it was made.
API_AVAILABLE(macos(14.2))
static void StopTap(CALTap* t) {
  TAP_LOG("tap %g: closed", t.tid);
  if (t->proc) {
    AudioDeviceStop(t->aggregate, t->proc);
    AudioDeviceDestroyIOProcID(t->aggregate, t->proc);
    t->proc = nullptr;
  }
  if (t->aggregate != kAudioObjectUnknown) {
    AudioHardwareDestroyAggregateDevice(t->aggregate);
    t->aggregate = kAudioObjectUnknown;
  }
  if (t->tap != kAudioObjectUnknown) {
    if (t.formatListener) {
      AudioObjectPropertyAddress a = Global(kAudioTapPropertyFormat);
      AudioObjectRemovePropertyListenerBlock(t->tap, &a, Control(), t.formatListener);
      t.formatListener = nil;
    }
    AudioHardwareDestroyProcessTap(t->tap);
    t->tap = kAudioObjectUnknown;
  }
}

API_AVAILABLE(macos(14.2))
static CATapDescription* DescriptionFor(CALTap* t, NSSet<NSNumber*>* objects) {
  NSArray<NSNumber*>* list = objects.allObjects;
  bool everything = t.pid <= 0 && !t.bundleId;
  bool mono = t.channels == 1;
  CATapDescription* d;
  if (everything) {
    d = mono ? [[CATapDescription alloc] initMonoGlobalTapButExcludeProcesses:list]
             : [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:list];
  } else {
    d = mono ? [[CATapDescription alloc] initMonoMixdownOfProcesses:list]
             : [[CATapDescription alloc] initStereoMixdownOfProcesses:list];
  }
  d.name = @"appkit system audio";
  d.UUID = [NSUUID UUID];
  d.privateTap = YES;
  d.muteBehavior = CATapUnmuted;
  return d;
}

// On the control queue, with the permission settled: the tap, the aggregate
// device holding it, the IO on it, started.
API_AVAILABLE(macos(14.2))
static void StartTap(CALTap* t) {
  double tid = t.tid;
  if (t->closed.load()) return;
  t.objects = [t wanted];
  if (t.pid > 0 && t.objects.count == 0) {
    TapError(tid, "NotFoundError", [NSString stringWithFormat:@"process %d has no audio to tap", t.pid]);
    return;
  }
  t.desc = DescriptionFor(t, t.objects);
  OSStatus st = AudioHardwareCreateProcessTap(t.desc, &t->tap);
  TAP_LOG("tap %g: %s%s, %lu process(es) %s, %u channel(s): AudioHardwareCreateProcessTap %d", tid,
          t.pid > 0 ? "one process" : t.bundleId ? "one application" : "everything",
          t.bundleId ? [@" " stringByAppendingString:t.bundleId].UTF8String : "",
          (unsigned long)t.objects.count, t.pid > 0 || t.bundleId ? "in it" : "left out", (unsigned)t.channels,
          (int)st);
  if (st != noErr) {
    t->tap = kAudioObjectUnknown;
    TapError(tid, "NotReadableError", [NSString stringWithFormat:@"CoreAudio made no tap (%d)", (int)st]);
    return;
  }
  NSDictionary* composition = @{
    @kAudioAggregateDeviceNameKey : @"appkit system audio",
    @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
    @kAudioAggregateDeviceIsPrivateKey : @YES,
    @kAudioAggregateDeviceIsStackedKey : @NO,
    // the IO runs from the start, silence included, so `time` is the
    // recording's and not the first sound's
    @kAudioAggregateDeviceTapAutoStartKey : @NO,
    @kAudioAggregateDeviceTapListKey : @[
      @{@kAudioSubTapUIDKey : t.desc.UUID.UUIDString, @kAudioSubTapDriftCompensationKey : @YES},
    ],
  };
  st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &t->aggregate);
  TAP_LOG("tap %g: AudioHardwareCreateAggregateDevice %d", tid, (int)st);
  if (st != noErr) {
    t->aggregate = kAudioObjectUnknown;
    StopTap(t);
    TapError(tid, "NotReadableError", [NSString stringWithFormat:@"CoreAudio made no device for the tap (%d)", (int)st]);
    return;
  }
  double rate = TapRate(t->tap, t->aggregate);
  if (gDebugAudio) {
    AudioStreamBasicDescription asbd = {};
    UInt32 size = sizeof(asbd);
    AudioObjectPropertyAddress a = Global(kAudioTapPropertyFormat);
    OSStatus fs = AudioObjectGetPropertyData(t->tap, &a, 0, nullptr, &size, &asbd);
    TAP_LOG("tap %g: the device runs at %g Hz; the tap's format (%d) %g Hz, %u channel(s), %u bits, flags %#x", tid,
            rate, (int)fs, asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame, (unsigned)asbd.mBitsPerChannel,
            (unsigned)asbd.mFormatFlags);
  }
  dispatch_sync(t.io, ^{ t->tapRate = rate; });
  // the output device under the tapped processes changed rate: so does the tap
  __weak CALTap* weak = t;
  t.formatListener = ^(UInt32, const AudioObjectPropertyAddress*) {
    CALTap* tap = weak;
    if (!tap || tap->closed.load()) return;
    double now = TapRate(tap->tap, tap->aggregate);
    TAP_LOG("tap %g: the format changed, now %g Hz", tap.tid, now);
    dispatch_async(tap.io, ^{
      tap->tapRate = now;
      tap.source = nil;
      tap.converter = nil;
    });
  };
  AudioObjectPropertyAddress fa = Global(kAudioTapPropertyFormat);
  AudioObjectAddPropertyListenerBlock(t->tap, &fa, Control(), t.formatListener);
  st = AudioDeviceCreateIOProcIDWithBlock(&t->proc, t->aggregate, t.io,
                                          ^(const AudioTimeStamp*, const AudioBufferList* in, const AudioTimeStamp*,
                                            AudioBufferList*, const AudioTimeStamp*) {
                                            CALTap* tap = weak;
                                            if (tap) [tap took:in];
                                          });
  TAP_LOG("tap %g: AudioDeviceCreateIOProcIDWithBlock %d", tid, (int)st);
  if (st != noErr) {
    t->proc = nullptr;
    StopTap(t);
    TapError(tid, "NotReadableError", [NSString stringWithFormat:@"the tap's device would not run (%d)", (int)st]);
    return;
  }
  st = AudioDeviceStart(t->aggregate, t->proc);
  TAP_LOG("tap %g: AudioDeviceStart %d, latency %.1f ms", tid, (int)st, LatencyOf(t->aggregate, rate) * 1000);
  if (st != noErr) {
    StopTap(t);
    TapError(tid, "NotReadableError", [NSString stringWithFormat:@"the tap's device did not start (%d)", (int)st]);
    return;
  }
  t.started = YES;
  Send(std::move(CALEvent("system-audio-started")
                     .Num("id", tid)
                     .Num("sampleRate", t.sampleRate)
                     .Num("channels", t.channels)
                     .Num("latency", LatencyOf(t->aggregate, rate))));
}

// On the control queue, when the processes changed: an application's tap
// takes in the helpers that started and lets go of the ones that ended, the
// tap of everything leaves this process out once it has connected, and a tap
// of one process says when that process has gone.
API_AVAILABLE(macos(14.2))
static void Follow(CALTap* t) {
  if (!t.started || t.ended || t->closed.load()) return;
  NSSet<NSNumber*>* now = [t wanted];
  if (t.pid > 0 && now.count == 0) {
    t.ended = YES;
    Send(std::move(CALEvent("system-audio-ended").Num("id", t.tid)));
    return;
  }
  if ([now isEqualToSet:t.objects]) return;
  NSUInteger before = t.objects.count;
  t.objects = now;
  t.desc.processes = now.allObjects;
  CATapDescription* __unsafe_unretained desc = t.desc;
  AudioObjectPropertyAddress a = Global(kAudioTapPropertyDescription);
  OSStatus st = AudioObjectSetPropertyData(t->tap, &a, 0, nullptr, sizeof(desc), &desc);
  TAP_LOG("tap %g: followed the processes, %lu → %lu: %d", t.tid, (unsigned long)before,
          (unsigned long)now.count, (int)st);
}

// ---------------------------------------------------------------------------
// watching
// ---------------------------------------------------------------------------

static std::atomic<bool> gAnnounce{false};

// The control queue's: process objects with a listener on their output, as
// `object:pid` since CoreAudio reuses an object's id; and the last signature.
static NSMutableSet<NSString*>* gWatched;
static NSString* gSignature;

static void Changed();

static void WatchEach() {
  NSMutableSet<NSString*>* seen = [NSMutableSet set];
  for (AudioObjectID o : ProcessObjects()) {
    NSString* key = [NSString stringWithFormat:@"%u:%d", o, PidOf(o)];
    [seen addObject:key];
    if ([gWatched containsObject:key]) continue;
    AudioObjectPropertyAddress a = Global(kAudioProcessPropertyIsRunningOutput);
    AudioObjectAddPropertyListenerBlock(o, &a, Control(), ^(UInt32, const AudioObjectPropertyAddress*) {
      Changed();
    });
    [gWatched addObject:key];
  }
  [gWatched intersectSet:seen];
}

static void Changed() {
  WatchEach();
  if (@available(macOS 14.2, *)) {
    for (CALTap* t in TapsNow()) Follow(t);
  }
  NSString* now = Signature();
  if ([now isEqualToString:gSignature]) return;
  gSignature = now;
  if (gAnnounce.load()) Send(CALEvent("audio-processes"));
}

// From the first listing or the first tap on: processes connecting, going,
// starting and stopping, followed by every tap and said as `audio-processes`.
static void WatchProcesses() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_async(Control(), ^{
      gWatched = [NSMutableSet set];
      gSignature = Signature();
      AudioObjectPropertyAddress a = Global(kAudioHardwarePropertyProcessObjectList);
      AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a, Control(),
                                          ^(UInt32, const AudioObjectPropertyAddress*) { Changed(); });
      WatchEach();
    });
  });
}

// ---------------------------------------------------------------------------
// the verbs
// ---------------------------------------------------------------------------

// audioProcesses() answers at once; audioProcesses(cb) lists on a queue of its
// own and answers through cb, which is the form a worker uses.
static Napi::Value AudioProcesses(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  gAnnounce = true;
  WatchProcesses();
  if (info.Length() && info[info.Length() - 1].IsFunction()) {
    CALTsfn tsfn = CALReplyTo(env, info[info.Length() - 1].As<Napi::Function>(), "appkit:audioProcesses");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      auto list = std::make_shared<std::vector<Proc>>(ListProcesses());
      CALReply(tsfn, ^Napi::Value(Napi::Env e) { return ProcessesValue(e, *list); });
    });
    return env.Undefined();
  }
  return ProcessesValue(env, ListProcesses());
}

API_AVAILABLE(macos(14.2))
static Napi::Value OpenSystemAudio(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value opts = info.Length() ? info[0] : env.Undefined();
  if (!opts.IsUndefined() && !opts.IsNull() && !opts.IsObject()) {
    Napi::TypeError::New(env, "openSystemAudio(options): options is an object").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  double pid = 0;
  bool hasPid = OptNum(opts, "pid", &pid);
  NSString* bundleId = opts.IsObject() ? Str(opts.As<Napi::Object>().Get("bundleId")) : nil;
  if (opts.IsObject() && opts.As<Napi::Object>().Has("pid") && (!hasPid || pid < 1 || pid != floor(pid))) {
    Napi::TypeError::New(env, "openSystemAudio: pid is a process id").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (hasPid && bundleId) {
    Napi::TypeError::New(env, "openSystemAudio: a pid or a bundleId, not both").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  NSMutableArray<NSNumber*>* exclude = [NSMutableArray array];
  if (opts.IsObject() && opts.As<Napi::Object>().Get("exclude").IsArray()) {
    Napi::Array list = opts.As<Napi::Object>().Get("exclude").As<Napi::Array>();
    for (uint32_t i = 0; i < list.Length(); i++) {
      Napi::Value v = list.Get(i);
      if (v.IsNumber()) [exclude addObject:@((pid_t)v.As<Napi::Number>().Int32Value())];
    }
  }
  double rate = 48000, channels = 2;
  OptNum(opts, "sampleRate", &rate);
  OptNum(opts, "channels", &channels);
  rate = fmin(192000, fmax(8000, rate));
  channels = fmin(2, fmax(1, round(channels)));

  CALTap* t = [CALTap new];
  t.tid = CALNextCaptureId();
  t.pid = hasPid ? (pid_t)pid : 0;
  t.bundleId = bundleId;
  t.excludePids = exclude;
  t.sampleRate = rate;
  t.channels = (AVAudioChannelCount)channels;
  t.io = dispatch_queue_create("appkit.systemaudio.io", DISPATCH_QUEUE_SERIAL);
  t.format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:t.channels];
  t->tap = kAudioObjectUnknown;
  t->aggregate = kAudioObjectUnknown;
  t->proc = nullptr;
  t->tapRate = 0;
  t->closed = false;
  t->sent = 0;
  t->inflight = std::make_shared<std::atomic<int>>(0);
  t->dropped = 0;
  t->described = false;
  t->framesIn = t->chunksOut = 0;
  t->peak = 0;
  t->lastReport = Seconds();
  @synchronized(gTapsLock) {
    gTaps[@(t.tid)] = t;
  }
  WatchProcesses();
  double tid = t.tid;
  dispatch_async(Control(), ^{
    if (t->closed.load()) return;
    // a process that is not there is said before anything is asked of the user
    if (t.pid > 0 && [t wanted].count == 0) {
      TapError(tid, "NotFoundError", [NSString stringWithFormat:@"process %d has no audio to tap", t.pid]);
      return;
    }
    const char* status = CALAudioCaptureStatus();
    TAP_LOG("tap %g: System Audio Recording is %s", tid, status);
    if (!strcmp(status, "denied") || !strcmp(status, "restricted")) {
      TapError(tid, "NotAllowedError",
               @"System Audio Recording is not allowed for this app (Privacy & Security › Screen & System "
               @"Audio Recording)");
      return;
    }
    if (!strcmp(status, "notDetermined")) {
      CALAudioCaptureRequest(^{
        dispatch_async(Control(), ^{
          if (t->closed.load()) return;
          TAP_LOG("tap %g: asked; System Audio Recording is %s", tid, CALAudioCaptureStatus());
          if (strcmp(CALAudioCaptureStatus(), "authorized") != 0) {
            TapError(tid, "NotAllowedError",
                     @"System Audio Recording was not allowed — by the user, or by macOS for a process it "
                     @"does not take for an app, or one without NSAudioCaptureUsageDescription");
            return;
          }
          StartTap(t);
        });
      });
      return;
    }
    StartTap(t);
  });
  Napi::Object out = Napi::Object::New(env);
  out.Set("id", tid);
  out.Set("sampleRate", rate);
  out.Set("channels", channels);
  return out;
}

API_AVAILABLE(macos(14.2))
static Napi::Value CloseSystemAudio(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info.Length() || !info[0].IsNumber()) return env.Undefined();
  double tid = info[0].As<Napi::Number>().DoubleValue();
  CALTap* t;
  @synchronized(gTapsLock) {
    t = gTaps[@(tid)];
    [gTaps removeObjectForKey:@(tid)];
  }
  if (!t) return env.Undefined();
  t->closed = true;
  dispatch_async(Control(), ^{ StopTap(t); });
  return env.Undefined();
}

void InitSystemAudio(Napi::Env env, Napi::Object exports) {
  if (@available(macOS 14.2, *)) {
    if (!gTapsLock) {
      gTapsLock = [NSObject new];
      gTaps = [NSMutableDictionary dictionary];
    }
    exports.Set("audioProcesses", Napi::Function::New(env, AudioProcesses));
    exports.Set("openSystemAudio", Napi::Function::New(env, OpenSystemAudio));
    exports.Set("closeSystemAudio", Napi::Function::New(env, CloseSystemAudio));
  }
}
