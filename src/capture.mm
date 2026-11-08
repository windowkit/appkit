// @windowkit/appkit capture.mm — cameras, microphones, speakers, an audio
// out and screenshots, for a renderer's media capture (react-x11's
// design/architecture/media-capture.md): the devices AVFoundation and
// CoreAudio know, a camera shown on a layer of its own with its frames handed
// over only on request, a microphone and every output on one voice-processing
// audio engine, and ScreenCaptureKit's screenshots.
//
// Devices — no authorization asked, nothing prompts:
//
// - captureDevices() -> [{ id, kind: 'camera'|'microphone'|'speaker', name,
//   isDefault, groupId?, position?, formats? }], or the same through
//   captureDevices(cb) from a queue of its own: cameras and microphones from
//   AVCaptureDevice's discovery (`id` is the uniqueID, which for a microphone
//   is CoreAudio's device UID), speakers from CoreAudio. A camera's
//   `formats` are [{ width, height, minFrameRate, maxFrameRate }].
// - event `capture-devices` whenever a device comes or goes or a default
//   input or output changes. Watched from the first captureDevices() on.
//
// A camera:
//
// - openCamera(deviceId | null, { width, height, frameRate }) -> { id, layer,
//   width, height, frameRate, format, range, colorSpace }: the device's
//   format nearest the size asked (a YCbCr one where it has one, so nothing
//   converts) and the rate clamped to it, answered at once; the session
//   starts on a queue of its own, and `camera-started { id }` or
//   `camera-error { id, name, message }` says how that went, `name` Media
//   Capture's: NotAllowedError, NotFoundError, NotReadableError. `layer` is
//   an AVCaptureVideoPreviewLayer — a layer handle every layer verb takes —
//   filling its bounds (the renderer fits the picture) and never mirrored.
// - cameraFrames(id, on): while on, `camera-frame { id, width, height,
//   format, range, colorSpace, planes, strides, time }`, the planes copies
//   of the camera's own (NV12 on every Mac camera seen), `time` seconds on the
//   capture clock. The newest frame only: one that arrives while the last is
//   still on its way replaces it.
// - cameraCopyFrame(id, surface) -> { width, height, time, written } | null:
//   playerCopyFrame's contract — the newest frame into a 2D surface in the
//   layer's colours, null when none is newer than the last one copied.
// - events `camera-muted { id, muted }` (the session interrupted: another
//   app took the camera) and `camera-ended { id }` (unplugged, or a runtime
//   error). closeCamera(id).
//
// The audio: one AVAudioEngine for every microphone and every output, so an
// echo-cancelled microphone has what is played as its reference (react-x11's
// design record §3) — while one is open, voice processing is on for the
// engine's input and output both, and every output plays through it.
//
// - openMicrophone(deviceId | null, { sampleRate, channels, echoCancellation,
//   noiseSuppression, autoGainControl }) -> { id, sampleRate, channels,
//   echoCancellation, noiseSuppression, autoGainControl, latency }:
//   resampled and mixed down here to the rate and count asked. The switches
//   answered are what was asked; `microphone-started { id, … }` carries what
//   the engine actually did — voice processing engaged or not — and
//   `microphone-error { id, name, message }` what went wrong. Then
//   `audio-input { id, sampleRate, channels: [Float32Array], frames, time,
//   dropped? }` every 10 ms, nothing dropped short of two seconds waiting.
//   One input device at a time: the engine has one input. closeMicrophone(id).
// - openAudioOutput({ sampleRate, channels, deviceId }) -> { id, sampleRate,
//   channels, latency }; audioOutputWrite(id, [Float32Array]) -> frames
//   queued; audioOutputState(id) -> { currentTime, queued, latency }, the
//   time in seconds the device has played since the first write;
//   closeAudioOutput(id). Silence where the queue runs dry. One output device
//   for the engine: the first output's `deviceId` picks it.
//
// The screen:
//
// - captureScreenshot({ display, window, rect, cursor }, cb): one picture
//   through ScreenCaptureKit (macOS 14), cb({ width, height, scale, data })
//   with `data` straight RGBA in sRGB, or cb({ error, name }) — NotAllowedError
//   without the Screen Recording grant, NotSupportedError before macOS 14.
//   `rect` is in points of the display; `display` a CGDirectDisplayID,
//   `window` a window number.
// - screenCaptureDisplays() -> [{ id, name, x, y, width, height, scale }],
//   points, top-left origin; through a callback off the main thread.
//
// Everything that arrives on a queue of AVFoundation's or CoreAudio's
// crosses to JS one way: straight into the channel where threaded mode has
// it open, and otherwise through a threadsafe function of the main thread's,
// where pump mode's listener is called (CALEmit is the main thread's then).

#include <napi.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <os/lock.h>
#include <pthread.h>

#include <atomic>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "channel.h"

// video.mm
bool CALPixelBufferToBGRA(Napi::Env env, const char* verb, CVPixelBufferRef pb, uint8_t* dst,
                          size_t dstStride);
bool CALVideoTargetBitmap(Napi::Value v, uint8_t** data, size_t* width, size_t* height,
                          size_t* bytesPerRow);

// ---------------------------------------------------------------------------
// crossing to JS
// ---------------------------------------------------------------------------

struct Delivery {
  dispatch_block_t block;
};

static void CallJsDelivery(Napi::Env env, Napi::Function, void*, Delivery* d) {
  if ((napi_env)env == nullptr || !CALCanCallIntoJS(env)) {
    delete d;
    return;
  }
  d->block();
  delete d;
  CALRaiseUncaughtIfPending(env);
}

using DeliveryTsfn = Napi::TypedThreadSafeFunction<void, Delivery, CallJsDelivery>;
static std::atomic<CALTsfn*> gDeliver{nullptr};

// `block` where it may emit: here, with threaded mode's channel open or on
// the main thread; on the main thread's JS loop otherwise. False when it
// could not be sent — the environment is ending — and it will never run.
static bool Deliver(dispatch_block_t block) {
  if (CALChannelOpen() || pthread_main_np()) {
    block();
    return true;
  }
  CALTsfn* t = gDeliver.load();
  if (!t) return false;
  Delivery* d = new Delivery{block};
  bool queued = t->Use(false, [d](napi_threadsafe_function f) {
    return DeliveryTsfn(f).NonBlockingCall(d);
  });
  if (!queued) delete d;
  return queued;
}

static void Send(CALEvent ev) {
  auto held = std::make_shared<CALEvent>(std::move(ev));
  Deliver(^{
    if (CALListening()) CALEmit(std::move(*held));
  });
}

static NSString* Str(Napi::Value v) {
  if (!v.IsString()) return nil;
  return [NSString stringWithUTF8String:v.As<Napi::String>().Utf8Value().c_str()];
}

static bool OptNum(Napi::Value obj, const char* k, double* out) {
  if (!obj.IsObject()) return false;
  Napi::Object o = obj.As<Napi::Object>();
  if (!o.Has(k)) return false;
  Napi::Value v = o.Get(k);
  if (!v.IsNumber()) return false;
  double d = v.As<Napi::Number>().DoubleValue();
  if (!std::isfinite(d)) return false;
  *out = d;
  return true;
}

static bool OptBool(Napi::Value obj, const char* k, bool* out) {
  if (!obj.IsObject()) return false;
  Napi::Object o = obj.As<Napi::Object>();
  if (!o.Has(k)) return false;
  Napi::Value v = o.Get(k);
  if (!v.IsBoolean()) return false;
  *out = v.As<Napi::Boolean>().Value();
  return true;
}

// ---------------------------------------------------------------------------
// devices
// ---------------------------------------------------------------------------

static NSArray<AVCaptureDevice*>* Cameras() {
  NSMutableArray<AVCaptureDeviceType>* types =
      [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
  if (@available(macOS 14.0, *)) {
    [types addObject:AVCaptureDeviceTypeExternal];
    // Continuity Camera only where the app said it wants it: AVFoundation
    // logs a warning for every discovery that asks without the key
    if ([NSBundle.mainBundle objectForInfoDictionaryKey:@"NSCameraUseContinuityCameraDeviceType"]) {
      [types addObject:AVCaptureDeviceTypeContinuityCamera];
    }
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [types addObject:AVCaptureDeviceTypeExternalUnknown];
#pragma clang diagnostic pop
  }
  return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                                mediaType:AVMediaTypeVideo
                                                                 position:AVCaptureDevicePositionUnspecified]
      .devices;
}

static NSArray<AVCaptureDevice*>* Microphones() {
  NSMutableArray<AVCaptureDeviceType>* types = [NSMutableArray array];
  if (@available(macOS 14.0, *)) {
    [types addObject:AVCaptureDeviceTypeMicrophone];
    [types addObject:AVCaptureDeviceTypeExternal];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [types addObject:AVCaptureDeviceTypeBuiltInMicrophone];
    [types addObject:AVCaptureDeviceTypeExternalUnknown];
#pragma clang diagnostic pop
  }
  return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                                mediaType:AVMediaTypeAudio
                                                                 position:AVCaptureDevicePositionUnspecified]
      .devices;
}

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector sel,
                                          AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
  return {sel, scope, kAudioObjectPropertyElementMain};
}

static NSString* DeviceUID(AudioDeviceID dev) {
  CFStringRef uid = nullptr;
  UInt32 size = sizeof(uid);
  AudioObjectPropertyAddress a = Address(kAudioDevicePropertyDeviceUID);
  if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &uid) != noErr || !uid) return nil;
  return (__bridge_transfer NSString*)uid;
}

static NSString* DeviceName(AudioDeviceID dev) {
  CFStringRef name = nullptr;
  UInt32 size = sizeof(name);
  AudioObjectPropertyAddress a = Address(kAudioObjectPropertyName);
  if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &name) != noErr || !name) return @"";
  return (__bridge_transfer NSString*)name;
}

static AudioDeviceID DefaultDevice(bool input) {
  AudioDeviceID dev = kAudioObjectUnknown;
  UInt32 size = sizeof(dev);
  AudioObjectPropertyAddress a = Address(input ? kAudioHardwarePropertyDefaultInputDevice
                                               : kAudioHardwarePropertyDefaultOutputDevice);
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, &dev);
  return dev;
}

static AudioDeviceID DeviceForUID(NSString* uid) {
  if (!uid.length) return kAudioObjectUnknown;
  AudioDeviceID dev = kAudioObjectUnknown;
  CFStringRef cf = (__bridge CFStringRef)uid;
  AudioValueTranslation t = {&cf, sizeof(cf), &dev, sizeof(dev)};
  UInt32 size = sizeof(t);
  AudioObjectPropertyAddress a = Address(kAudioHardwarePropertyDeviceForUID);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, &t) != noErr) {
    return kAudioObjectUnknown;
  }
  return dev;
}

// An engine makes an aggregate device of its own for the default device
// (`CADefaultDeviceAggregate-<pid>`), and voice processing another: private
// to this process, and no device a person would pick — but CoreAudio lists
// them, and AVFoundation says one was connected.
static bool IsPrivate(NSString* uid) {
  return [uid hasPrefix:@"CADefaultDeviceAggregate"] || [uid hasPrefix:@"VPAUAggregateAudioDevice"];
}

static bool IsHidden(AudioDeviceID dev) {
  UInt32 hidden = 0, size = sizeof(hidden);
  AudioObjectPropertyAddress a = Address(kAudioDevicePropertyIsHidden);
  if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &hidden) == noErr && hidden) return true;
  return IsPrivate(DeviceUID(dev));
}

static bool HasStreams(AudioDeviceID dev, bool input) {
  UInt32 size = 0;
  AudioObjectPropertyAddress a = Address(
      kAudioDevicePropertyStreams, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput);
  return AudioObjectGetPropertyDataSize(dev, &a, 0, nullptr, &size) == noErr && size > 0;
}

static std::vector<AudioDeviceID> AudioDevices() {
  UInt32 size = 0;
  AudioObjectPropertyAddress a = Address(kAudioHardwarePropertyDevices);
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr) return {};
  std::vector<AudioDeviceID> devs(size / sizeof(AudioDeviceID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, devs.data()) != noErr) {
    return {};
  }
  return devs;
}

static dispatch_queue_t AudioQueue();

// What CoreAudio has that a listing shows: every device a person could pick,
// and the two defaults. CoreAudio says its device list changed when an engine
// starts as much as when a headset is plugged in; only a change in this is
// news.
static NSString* AudioSignature() {
  NSMutableArray<NSString*>* parts = [NSMutableArray array];
  for (AudioDeviceID dev : AudioDevices()) {
    if (IsHidden(dev)) continue;
    NSString* uid = DeviceUID(dev);
    if (uid) [parts addObject:uid];
  }
  [parts addObject:DeviceUID(DefaultDevice(true)) ?: @"-"];
  [parts addObject:DeviceUID(DefaultDevice(false)) ?: @"-"];
  return [parts componentsJoinedByString:@"\n"];
}

// From the first listing on: the devices coming and going, and the defaults
// moving, said as `capture-devices`.
static void WatchDevices() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void (^changed)(void) = ^{
      Send(CALEvent("capture-devices"));
    };
    __block NSString* audio = AudioSignature();
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVCaptureDeviceWasConnectedNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* n) {
                  AVCaptureDevice* d = n.object;
                  if (![d isKindOfClass:AVCaptureDevice.class] || !IsPrivate(d.uniqueID)) changed();
                }];
    [nc addObserverForName:AVCaptureDeviceWasDisconnectedNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* n) {
                  AVCaptureDevice* d = n.object;
                  if (![d isKindOfClass:AVCaptureDevice.class] || !IsPrivate(d.uniqueID)) changed();
                }];
    for (AudioObjectPropertySelector sel :
         {kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
          kAudioHardwarePropertyDefaultOutputDevice}) {
      AudioObjectPropertyAddress a = Address(sel);
      AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a, AudioQueue(),
                                          ^(UInt32, const AudioObjectPropertyAddress*) {
                                            NSString* now = AudioSignature();
                                            if ([now isEqualToString:audio]) return;
                                            audio = now;
                                            changed();
                                          });
    }
  });
}

static const char* PositionOf(AVCaptureDevice* d) {
  if (@available(macOS 14.0, *)) {
    if ([d.deviceType isEqualToString:AVCaptureDeviceTypeExternal]) return "external";
  }
  switch (d.position) {
    case AVCaptureDevicePositionFront:
      return "front";
    case AVCaptureDevicePositionBack:
      return "back";
    default:
      return d.transportType == 'bltn' ? "front" : "unspecified";
  }
}

struct FormatInfo {
  double width, height, minFrameRate, maxFrameRate;
};

struct DeviceInfo {
  std::string id, kind, name, position, groupId;
  bool isDefault = false;
  std::vector<FormatInfo> formats;
};

// The devices there are, as plain data: on any thread.
static std::vector<DeviceInfo> ListDevices() {
  std::vector<DeviceInfo> list;
  NSString* defaultCamera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo].uniqueID;
  NSString* defaultInput = DeviceUID(DefaultDevice(true));
  NSString* defaultOutput = DeviceUID(DefaultDevice(false));
  NSArray<AVCaptureDevice*>* cameras = Cameras();
  NSArray<AVCaptureDevice*>* microphones = Microphones();
  // a camera and a microphone that are one piece of hardware share a model
  NSMutableDictionary<NSString*, NSNumber*>* models = [NSMutableDictionary dictionary];
  for (AVCaptureDevice* d in [cameras arrayByAddingObjectsFromArray:microphones]) {
    if (!d.modelID.length) continue;
    models[d.modelID] = @(models[d.modelID].intValue + 1);
  }
  auto base = [&](AVCaptureDevice* d, const char* kind) {
    DeviceInfo info;
    info.id = d.uniqueID.UTF8String;
    info.kind = kind;
    info.name = d.localizedName.UTF8String ?: "";
    if (d.modelID.length && models[d.modelID].intValue > 1) info.groupId = d.modelID.UTF8String;
    return info;
  };
  for (AVCaptureDevice* d in cameras) {
    DeviceInfo info = base(d, "camera");
    info.isDefault = [d.uniqueID isEqualToString:defaultCamera];
    info.position = PositionOf(d);
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
    for (AVCaptureDeviceFormat* fmt in d.formats) {
      CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription);
      double lo = INFINITY, hi = 0;
      for (AVFrameRateRange* r in fmt.videoSupportedFrameRateRanges) {
        lo = fmin(lo, r.minFrameRate);
        hi = fmax(hi, r.maxFrameRate);
      }
      if (!std::isfinite(lo)) lo = hi;
      NSString* key = [NSString stringWithFormat:@"%dx%d@%g-%g", dim.width, dim.height, lo, hi];
      if ([seen containsObject:key]) continue;
      [seen addObject:key];
      info.formats.push_back({(double)dim.width, (double)dim.height, lo, hi});
    }
    list.push_back(info);
  }
  for (AVCaptureDevice* d in microphones) {
    if (IsPrivate(d.uniqueID)) continue;
    DeviceInfo info = base(d, "microphone");
    info.isDefault = [d.uniqueID isEqualToString:defaultInput];
    list.push_back(info);
  }
  for (AudioDeviceID dev : AudioDevices()) {
    if (IsHidden(dev) || !HasStreams(dev, false)) continue;
    NSString* uid = DeviceUID(dev);
    if (!uid) continue;
    DeviceInfo info;
    info.id = uid.UTF8String;
    info.kind = "speaker";
    info.name = DeviceName(dev).UTF8String ?: "";
    info.isDefault = [uid isEqualToString:defaultOutput];
    list.push_back(info);
  }
  return list;
}

static Napi::Value DevicesValue(Napi::Env env, const std::vector<DeviceInfo>& list) {
  Napi::Array out = Napi::Array::New(env, list.size());
  for (size_t i = 0; i < list.size(); i++) {
    const DeviceInfo& d = list[i];
    Napi::Object o = Napi::Object::New(env);
    o.Set("id", d.id);
    o.Set("kind", d.kind);
    o.Set("name", d.name);
    o.Set("isDefault", d.isDefault);
    if (!d.position.empty()) o.Set("position", d.position);
    if (!d.groupId.empty()) o.Set("groupId", d.groupId);
    if (d.kind == "camera") {
      Napi::Array formats = Napi::Array::New(env, d.formats.size());
      for (size_t f = 0; f < d.formats.size(); f++) {
        Napi::Object one = Napi::Object::New(env);
        one.Set("width", d.formats[f].width);
        one.Set("height", d.formats[f].height);
        one.Set("minFrameRate", d.formats[f].minFrameRate);
        one.Set("maxFrameRate", d.formats[f].maxFrameRate);
        formats.Set((uint32_t)f, one);
      }
      o.Set("formats", formats);
    }
    out.Set((uint32_t)i, o);
  }
  return out;
}

// captureDevices() answers at once; captureDevices(cb) lists on a queue of
// its own and answers through cb — the first listing of a process loads
// AVFoundation's camera plug-ins, 100 ms to over a second, which a UI thread
// should not wait out.
static Napi::Value CaptureDevices(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  WatchDevices();
  if (info.Length() && info[info.Length() - 1].IsFunction()) {
    CALTsfn tsfn = CALReplyTo(env, info[info.Length() - 1].As<Napi::Function>(), "appkit:captureDevices");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      auto list = std::make_shared<std::vector<DeviceInfo>>(ListDevices());
      CALReply(tsfn, ^Napi::Value(Napi::Env e) { return DevicesValue(e, *list); });
    });
    return env.Undefined();
  }
  return DevicesValue(env, ListDevices());
}

// ---------------------------------------------------------------------------
// cameras
// ---------------------------------------------------------------------------

@interface CALCamera : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic) double cid;
@property(nonatomic, strong) AVCaptureDevice* device;
@property(nonatomic, strong) AVCaptureDeviceFormat* format;
@property(nonatomic) double frameRate;
@property(nonatomic, strong) AVCaptureSession* session;
@property(nonatomic, strong) AVCaptureVideoDataOutput* output;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer* layer;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableArray* notes;
@property(nonatomic) BOOL closed;
@end

@implementation CALCamera {
  os_unfair_lock _lock;
  CVPixelBufferRef _latest;   // for a copy; retained
  double _latestTime;
  uint64_t _latestSeq, _copiedSeq;
  CVPixelBufferRef _pending;  // for JS, while on its way; retained
  double _pendingTime;
  bool _scheduled;
  std::atomic<bool> _frames;
}

- (instancetype)init {
  if ((self = [super init])) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _frames = false;
  }
  return self;
}

- (void)dealloc {
  if (_latest) CVPixelBufferRelease(_latest);
  if (_pending) CVPixelBufferRelease(_pending);
}

- (void)setFramesOn:(bool)on {
  _frames = on;
}

// The newest frame, if newer than the last one copied: retained, or null.
- (CVPixelBufferRef)takeNewest:(double*)time {
  os_unfair_lock_lock(&_lock);
  CVPixelBufferRef pb = nullptr;
  if (_latest && _latestSeq != _copiedSeq) {
    pb = CVPixelBufferRetain(_latest);
    *time = _latestTime;
    _copiedSeq = _latestSeq;
  }
  os_unfair_lock_unlock(&_lock);
  return pb;
}

- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sample
           fromConnection:(AVCaptureConnection*)connection {
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
  if (!pb) return;
  double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
  bool schedule = false;
  os_unfair_lock_lock(&_lock);
  if (_latest) CVPixelBufferRelease(_latest);
  _latest = CVPixelBufferRetain(pb);
  _latestTime = time;
  _latestSeq++;
  if (_frames.load()) {
    if (_pending) CVPixelBufferRelease(_pending);
    _pending = CVPixelBufferRetain(pb);
    _pendingTime = time;
    schedule = !_scheduled;
    _scheduled = true;
  }
  os_unfair_lock_unlock(&_lock);
  if (!schedule) return;
  __weak CALCamera* weak = self;
  if (!Deliver(^{
        CALCamera* c = weak;
        if (c) [c sendPending];
      })) {
    os_unfair_lock_lock(&_lock);
    _scheduled = false;
    os_unfair_lock_unlock(&_lock);
  }
}

// Where JS is: the frame waiting, as the event — the newest by now, since a
// frame that arrived while this was on its way replaced the one that sent it.
- (void)sendPending {
  os_unfair_lock_lock(&_lock);
  CVPixelBufferRef pb = _pending;
  double time = _pendingTime;
  _pending = nullptr;
  _scheduled = false;
  os_unfair_lock_unlock(&_lock);
  if (!pb) return;
  if (self.closed || !_frames.load() || !CALListening()) {
    CVPixelBufferRelease(pb);
    return;
  }
  OSType type = CVPixelBufferGetPixelFormatType(pb);
  const char* format = nullptr;
  bool full = false;
  switch (type) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      full = true;
      [[fallthrough]];
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      format = "NV12";
      break;
    case kCVPixelFormatType_32BGRA:
      format = "BGRA";
      full = true;
      break;
    default:
      CVPixelBufferRelease(pb);
      return;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CFTypeRef matrix = CVBufferGetAttachment(pb, kCVImageBufferYCbCrMatrixKey, nullptr);
#pragma clang diagnostic pop
  const char* colorSpace =
      matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) ? "bt601" : "bt709";
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  size_t count = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetPlaneCount(pb) : 1;
  NSMutableArray<NSData*>* planes = [NSMutableArray array];
  std::vector<double> strides;
  for (size_t i = 0; i < count; i++) {
    bool planar = CVPixelBufferIsPlanar(pb);
    const void* base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, i) : CVPixelBufferGetBaseAddress(pb);
    size_t bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, i) : CVPixelBufferGetBytesPerRow(pb);
    size_t rows = planar ? CVPixelBufferGetHeightOfPlane(pb, i) : CVPixelBufferGetHeight(pb);
    [planes addObject:[NSData dataWithBytes:base length:bpr * rows]];
    strides.push_back((double)bpr);
  }
  double width = (double)CVPixelBufferGetWidth(pb), height = (double)CVPixelBufferGetHeight(pb);
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pb);
  CALEvent ev("camera-frame");
  ev.Num("id", self.cid)
      .Num("width", width)
      .Num("height", height)
      .Str("format", format)
      .Str("range", full ? "full" : "video")
      .Str("colorSpace", colorSpace)
      .Num("time", time)
      .Handle("planes",
              ^Napi::Value(Napi::Env env) {
                Napi::Array a = Napi::Array::New(env, planes.count);
                for (NSUInteger i = 0; i < planes.count; i++) {
                  NSData* d = planes[i];
                  a.Set((uint32_t)i, Napi::Buffer<uint8_t>::Copy(env, (const uint8_t*)d.bytes, d.length));
                }
                return a;
              })
      .Handle("strides", ^Napi::Value(Napi::Env env) {
        Napi::Array a = Napi::Array::New(env, strides.size());
        for (size_t i = 0; i < strides.size(); i++) a.Set((uint32_t)i, strides[i]);
        return a;
      });
  // threaded mode: a frame queued behind another of this camera's replaces it
  ev.FoldBy(self.cid);
  CALEmit(std::move(ev));
}

- (void)stop {
  self.closed = YES;
  _frames = false;
  for (id note in self.notes) [NSNotificationCenter.defaultCenter removeObserver:note];
  self.notes = nil;
  [self.output setSampleBufferDelegate:nil queue:nil];
  if (self.session.isRunning) [self.session stopRunning];
  os_unfair_lock_lock(&_lock);
  if (_latest) CVPixelBufferRelease(_latest);
  if (_pending) CVPixelBufferRelease(_pending);
  _latest = _pending = nullptr;
  os_unfair_lock_unlock(&_lock);
}

@end

static NSMutableDictionary<NSNumber*, CALCamera*>* gCameras;
static std::atomic<uint32_t> gNextCapture{0};

static CALCamera* CameraFor(double cid) {
  @synchronized([CALCamera class]) {
    return gCameras[@(cid)];
  }
}

static bool IsYCbCr420(AVCaptureDeviceFormat* f) {
  FourCharCode sub = CMFormatDescriptionGetMediaSubType(f.formatDescription);
  return sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

// The format nearest the size asked, YCbCr first, and the rate it can run
// nearest the one asked. Nothing asked: the largest no bigger than 1280x720.
static AVCaptureDeviceFormat* ChooseFormat(AVCaptureDevice* d, double w, double h, double rate,
                                           double* chosenRate) {
  AVCaptureDeviceFormat* best = nil;
  double bestScore = INFINITY;
  for (AVCaptureDeviceFormat* f in d.formats) {
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
    double score;
    if (w > 0 || h > 0) {
      double aw = w > 0 ? w : dim.width, ah = h > 0 ? h : dim.height;
      score = fabs(dim.width - aw) / aw + fabs(dim.height - ah) / ah;
    } else {
      bool fits = dim.width <= 1280 && dim.height <= 720;
      score = fits ? 1.0 / (1.0 + (double)dim.width * dim.height) : 10 + (double)dim.width * dim.height;
    }
    double hi = 0;
    for (AVFrameRateRange* r in f.videoSupportedFrameRateRanges) hi = fmax(hi, r.maxFrameRate);
    if (rate > 0 && hi + 0.01 < rate) score += 0.5 * (rate - hi) / rate;
    if (!IsYCbCr420(f)) score += 100;
    if (score < bestScore) {
      bestScore = score;
      best = f;
    }
  }
  if (best) {
    double lo = INFINITY, hi = 0;
    for (AVFrameRateRange* r in best.videoSupportedFrameRateRanges) {
      lo = fmin(lo, r.minFrameRate);
      hi = fmax(hi, r.maxFrameRate);
    }
    double want = rate > 0 ? rate : fmin(30, hi);
    *chosenRate = fmin(hi, fmax(std::isfinite(lo) ? lo : want, want));
  }
  return best;
}

static void CameraError(double cid, const char* name, NSString* message) {
  Send(std::move(CALEvent("camera-error").Num("id", cid).Str("name", name).Str("message", message.UTF8String)));
}

// On the camera's queue: the session put together and started.
static void StartCamera(CALCamera* c) {
  double cid = c.cid;
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
    CameraError(cid, "NotAllowedError", @"the camera is not allowed for this app (Privacy & Security › Camera)");
    return;
  }
  if (status == AVAuthorizationStatusNotDetermined) {
    // asked here so a request that comes back no is a NotAllowedError and not
    // a session that delivers nothing; the session starts once it says yes
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL granted) {
                               dispatch_async(c.queue, ^{
                                 if (c.closed) return;
                                 if (!granted) {
                                   CameraError(cid, "NotAllowedError",
                                               @"the camera was not allowed — by the user, or by "
                                               @"macOS for a process it does not take for an app");
                                   return;
                                 }
                                 StartCamera(c);
                               });
                             }];
    return;
  }
  NSError* err = nil;
  AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:c.device error:&err];
  if (!input) {
    CameraError(cid, "NotReadableError", err.localizedDescription ?: @"the camera could not be opened");
    return;
  }
  AVCaptureSession* s = c.session;
  [s beginConfiguration];
  if (![s canAddInput:input]) {
    [s commitConfiguration];
    CameraError(cid, "NotReadableError", @"the camera could not be added to a capture session");
    return;
  }
  [s addInput:input];
  AVCaptureVideoDataOutput* out = [AVCaptureVideoDataOutput new];
  out.alwaysDiscardsLateVideoFrames = YES;
  // the format's own layout, so nothing is converted on the way
  FourCharCode sub = CMFormatDescriptionGetMediaSubType(c.format.formatDescription);
  out.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(IsYCbCr420(c.format) ? sub : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
  };
  [out setSampleBufferDelegate:c queue:c.queue];
  if ([s canAddOutput:out]) [s addOutput:out];
  c.output = out;
  [s commitConfiguration];
  if ([c.device lockForConfiguration:&err]) {
    c.device.activeFormat = c.format;
    CMTime d = CMTimeMakeWithSeconds(1.0 / c.frameRate, 1000000);
    c.device.activeVideoMinFrameDuration = d;
    c.device.activeVideoMaxFrameDuration = d;
    [c.device unlockForConfiguration];
  }
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  __weak CALCamera* weak = c;
  c.notes = [NSMutableArray array];
  [c.notes addObject:[nc addObserverForName:AVCaptureSessionWasInterruptedNotification
                                     object:s
                                      queue:nil
                                 usingBlock:^(NSNotification*) {
                                   Send(std::move(CALEvent("camera-muted").Num("id", cid).Bool("muted", true)));
                                 }]];
  [c.notes addObject:[nc addObserverForName:AVCaptureSessionInterruptionEndedNotification
                                     object:s
                                      queue:nil
                                 usingBlock:^(NSNotification*) {
                                   Send(std::move(CALEvent("camera-muted").Num("id", cid).Bool("muted", false)));
                                 }]];
  [c.notes addObject:[nc addObserverForName:AVCaptureSessionRuntimeErrorNotification
                                     object:s
                                      queue:nil
                                 usingBlock:^(NSNotification*) {
                                   CALCamera* cam = weak;
                                   if (!cam || cam.closed) return;
                                   Send(std::move(CALEvent("camera-ended").Num("id", cid)));
                                 }]];
  [c.notes addObject:[nc addObserverForName:AVCaptureDeviceWasDisconnectedNotification
                                     object:c.device
                                      queue:nil
                                 usingBlock:^(NSNotification*) {
                                   CALCamera* cam = weak;
                                   if (!cam || cam.closed) return;
                                   Send(std::move(CALEvent("camera-ended").Num("id", cid)));
                                 }]];
  [s startRunning];
  if (c.closed) return;
  if (!s.isRunning) {
    CameraError(cid, "NotReadableError", @"the capture session did not start — the camera may be in use");
    return;
  }
  Send(std::move(CALEvent("camera-started").Num("id", cid)));
}

static Napi::Value OpenCamera(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value opts = info.Length() > 1 ? info[1] : env.Undefined();
  double w = 0, h = 0, rate = 0;
  OptNum(opts, "width", &w);
  OptNum(opts, "height", &h);
  OptNum(opts, "frameRate", &rate);
  NSString* uid = Str(info[0]);
  AVCaptureDevice* device =
      uid ? [AVCaptureDevice deviceWithUniqueID:uid] : [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  double cid = (double)(++gNextCapture);
  Napi::Object out = Napi::Object::New(env);
  out.Set("id", cid);
  if (!device || ![device hasMediaType:AVMediaTypeVideo]) {
    CameraError(cid, "NotFoundError", uid ? [NSString stringWithFormat:@"there is no camera %@", uid]
                                          : @"there is no camera");
    return out;
  }
  double chosenRate = 30;
  AVCaptureDeviceFormat* format = ChooseFormat(device, w, h, rate, &chosenRate);
  if (!format) {
    CameraError(cid, "NotReadableError", @"the camera lists no format to capture in");
    return out;
  }
  CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
  FourCharCode sub = CMFormatDescriptionGetMediaSubType(format.formatDescription);
  CFTypeRef matrix = CMFormatDescriptionGetExtension(format.formatDescription,
                                                     kCMFormatDescriptionExtension_YCbCrMatrix);
  out.Set("width", (double)dim.width);
  out.Set("height", (double)dim.height);
  out.Set("frameRate", chosenRate);
  out.Set("format", "NV12");
  out.Set("range", sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? "full" : "video");
  out.Set("colorSpace",
          matrix && CFEqual(matrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4) ? "bt601" : "bt709");

  CALCamera* c = [CALCamera new];
  c.cid = cid;
  c.device = device;
  c.format = format;
  c.frameRate = chosenRate;
  c.session = [AVCaptureSession new];
  c.queue = dispatch_queue_create("appkit.camera", DISPATCH_QUEUE_SERIAL);
  @synchronized([CALCamera class]) {
    if (!gCameras) gCameras = [NSMutableDictionary dictionary];
    gCameras[@(cid)] = c;
  }
  AVCaptureVideoPreviewLayer* (^make)(void) = ^AVCaptureVideoPreviewLayer* {
    AVCaptureVideoPreviewLayer* layer = [AVCaptureVideoPreviewLayer layerWithSession:c.session];
    layer.videoGravity = AVLayerVideoGravityResize;
    AVCaptureConnection* conn = layer.connection;
    if (conn.isVideoMirroringSupported) {
      conn.automaticallyAdjustsVideoMirroring = NO;
      conn.videoMirrored = NO;
    }
    c.layer = layer;
    return layer;
  };
  if (pthread_main_np()) {
    void* retained = (void*)CFBridgingRetain(make());
    out.Set("layer", Napi::External<void>::New(env, retained, [](Napi::Env, void* d) { CFRelease(d); }));
  } else {
    CALHandle* handle = CALNewHandle();
    out.Set("layer", CALWrapHandle(env, handle, false));
    CALOnUI(^{ handle->object_ = make(); });
  }
  dispatch_async(c.queue, ^{
    if (!c.closed) StartCamera(c);
  });
  return out;
}

static Napi::Value CameraFrames(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "cameraFrames(id, on): id is the number openCamera answered")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CALCamera* c = CameraFor(info[0].As<Napi::Number>().DoubleValue());
  [c setFramesOn:info.Length() > 1 && info[1].ToBoolean().Value()];
  return env.Undefined();
}

static Napi::Value CameraCopyFrame(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "cameraCopyFrame(id, surface): id is the number openCamera answered")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  uint8_t* data;
  size_t sw, sh, bpr;
  if (!CALVideoTargetBitmap(info[1], &data, &sw, &sh, &bpr)) return env.Undefined();
  CALCamera* c = CameraFor(info[0].As<Napi::Number>().DoubleValue());
  double time = 0;
  CVPixelBufferRef pb = [c takeNewest:&time];
  if (!pb) return env.Null();
  size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
  Napi::Object out = Napi::Object::New(env);
  out.Set("width", (double)w);
  out.Set("height", (double)h);
  out.Set("time", time);
  bool fits = w == sw && h == sh;
  bool ok = !fits || CALPixelBufferToBGRA(env, "cameraCopyFrame", pb, data, bpr);
  CVPixelBufferRelease(pb);
  if (!ok) return env.Undefined();
  out.Set("written", fits);
  return out;
}

static Napi::Value CloseCamera(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) return env.Undefined();
  double cid = info[0].As<Napi::Number>().DoubleValue();
  CALCamera* c;
  @synchronized([CALCamera class]) {
    c = gCameras[@(cid)];
    [gCameras removeObjectForKey:@(cid)];
  }
  if (!c) return env.Undefined();
  c.closed = YES;
  dispatch_async(c.queue, ^{ [c stop]; });
  CALOnUI(^{ c.layer.session = nil; });
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// audio: one engine, its input and its outputs
// ---------------------------------------------------------------------------

// A ring of planar float samples, one writer and one reader — the render
// thread at one end, so neither end takes a lock.
class Ring {
 public:
  Ring(size_t channels, size_t capacity) : channels_(channels), cap_(capacity) {
    data_.resize(channels * capacity);
  }
  size_t channels() const { return channels_; }
  size_t available() const { return w_.load(std::memory_order_acquire) - r_.load(std::memory_order_acquire); }
  // what fitted
  size_t write(const float* const* src, size_t frames) {
    size_t w = w_.load(std::memory_order_relaxed), r = r_.load(std::memory_order_acquire);
    size_t room = cap_ - (w - r);
    size_t n = frames < room ? frames : room;
    for (size_t c = 0; c < channels_; c++) {
      float* dst = &data_[c * cap_];
      const float* s = src[c < channels_ ? c : 0];
      for (size_t i = 0; i < n; i++) dst[(w + i) % cap_] = s ? s[i] : 0;
    }
    w_.store(w + n, std::memory_order_release);
    return n;
  }
  size_t read(float* const* dst, size_t frames) {
    size_t r = r_.load(std::memory_order_relaxed), w = w_.load(std::memory_order_acquire);
    size_t n = frames < w - r ? frames : w - r;
    for (size_t c = 0; c < channels_; c++) {
      const float* src = &data_[c * cap_];
      for (size_t i = 0; i < n; i++) dst[c][i] = src[(r + i) % cap_];
    }
    r_.store(r + n, std::memory_order_release);
    return n;
  }
  void clear() { r_.store(w_.load()); }

 private:
  size_t channels_, cap_;
  std::vector<float> data_;
  std::atomic<size_t> w_{0}, r_{0};
};

@interface CALMicrophone : NSObject
@property(nonatomic) double mid;
@property(nonatomic) double sampleRate;
@property(nonatomic) AVAudioChannelCount channels;
@property(nonatomic) BOOL echoCancellation, noiseSuppression, autoGainControl;
@property(nonatomic, strong) NSString* deviceUID;
@property(nonatomic, strong) AVAudioConverter* converter;
@property(nonatomic, strong) AVAudioFormat* format;
@property(nonatomic) BOOL started;
@end

@implementation CALMicrophone {
 @public
  std::vector<std::vector<float>> pending;  // converted, not yet a 10 ms chunk
  double sent;                              // frames sent, for `time`
  std::shared_ptr<std::atomic<int>> inflight;
  std::atomic<int> dropped;
}
@end

@interface CALOutput : NSObject
@property(nonatomic) double oid;
@property(nonatomic) double sampleRate;
@property(nonatomic) AVAudioChannelCount channels;
@property(nonatomic, strong) AVAudioSourceNode* node;
@end

@implementation CALOutput {
 @public
  std::unique_ptr<Ring> ring;
  std::atomic<uint64_t> played;  // frames the render thread pulled since the first write
  std::atomic<bool> begun;
}
@end

// The audio queue's, and touched nowhere else: the engine and everything
// wired to it. The two things other threads need from it are kept apart —
// the outputs, which JS opens and closes, under their own lock
// (`OutputsNow`), and the latency `audioOutputState` reports, published as
// a number — since a strong pointer the queue reassigns while JS reads it is
// a use after free, and a dictionary JS mutates while the queue enumerates it
// is a corrupted heap: both were seen, as a crash in an unrelated allocation.
static AVAudioEngine* gEngine;
static AVAudioSinkNode* gSink;
static std::unique_ptr<Ring> gInputRing;  // the input's samples, from the render thread
static AVAudioFormat* gInputFormat;
static dispatch_source_t gDrain;
static BOOL gVoice;
static NSString* gInputUID;
static NSMutableDictionary<NSNumber*, CALMicrophone*>* gMics;
static id gConfigNote;
static std::atomic<double> gOutputLatency{0};

// JS's and the queue's alike, only ever under @synchronized([CALOutput class]).
static NSMutableDictionary<NSNumber*, CALOutput*>* gOutputs;
static NSString* gOutputUID;

// The outputs open now and the device the first of them named: a copy, taken
// under the lock, which the queue works from.
static NSArray<CALOutput*>* OutputsNow(NSString** uid) {
  @synchronized([CALOutput class]) {
    if (uid) *uid = gOutputUID;
    return gOutputs.allValues ?: @[];
  }
}

static dispatch_queue_t AudioQueue() {
  static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ q = dispatch_queue_create("appkit.audio", DISPATCH_QUEUE_SERIAL); });
  return q;
}

static void SetUnitDevice(AudioUnit unit, NSString* uid) {
  AudioDeviceID dev = DeviceForUID(uid);
  if (!unit || dev == kAudioObjectUnknown) return;
  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                       sizeof(dev));
}

static void DrainInput();

static void MicrophoneError(double mid, const char* name, NSString* message) {
  Send(std::move(
      CALEvent("microphone-error").Num("id", mid).Str("name", name).Str("message", message.UTF8String)));
}

// On the audio queue: the engine wired for what is open now — its input
// while a microphone is, voice processing while an echo-cancelled one is,
// every output a source node into the mixer — and running while anything is.
// Changing whether there is an input or voice processing stops the engine
// first: neither can change on a running one.
static void Rewire() {
  bool wantInput = gMics.count > 0;
  bool wantVoice = false;
  NSString* wantUID = nil;
  for (CALMicrophone* m in gMics.allValues) {
    wantVoice = wantVoice || m.echoCancellation;
    if (!wantUID) wantUID = m.deviceUID;
  }
  NSString* outputUID = nil;
  NSArray<CALOutput*>* outputs = OutputsNow(&outputUID);
  bool wantOutputs = outputs.count > 0;
  if (!wantInput && !wantOutputs) {
    if (gEngine) {
      [gEngine stop];
      if (gConfigNote) [NSNotificationCenter.defaultCenter removeObserver:gConfigNote];
      gConfigNote = nil;
      if (gDrain) dispatch_source_cancel(gDrain);
      gDrain = nil;
      gEngine = nil;
      gSink = nil;
      gInputRing.reset();
      gVoice = NO;
      gInputUID = nil;
      gOutputLatency = 0;
    }
    return;
  }
  bool hadInput = gSink != nil;
  bool rebuild = !gEngine || hadInput != wantInput || (wantInput && gVoice != wantVoice) ||
                 (wantInput && ![wantUID ?: @"" isEqualToString:gInputUID ?: @""]);
  if (rebuild) {
    if (gEngine) [gEngine stop];
    if (gConfigNote) [NSNotificationCenter.defaultCenter removeObserver:gConfigNote];
    // a new engine each time: voice processing does not come off cleanly
    gEngine = [AVAudioEngine new];
    gSink = nil;
    gInputRing.reset();
    gVoice = NO;
    gInputUID = nil;
    if (wantInput) {
      AVAudioInputNode* input = gEngine.inputNode;
      if (wantUID) SetUnitDevice(input.audioUnit, wantUID);
      gInputUID = wantUID;
      if (wantVoice) {
        NSError* err = nil;
        gVoice = [input setVoiceProcessingEnabled:YES error:&err];
      }
      AVAudioFormat* hw = [input outputFormatForBus:0];
      gInputFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:hw.sampleRate
                                                                    channels:hw.channelCount];
      gInputRing = std::make_unique<Ring>(hw.channelCount, (size_t)(hw.sampleRate * 2));
      Ring* ring = gInputRing.get();
      gSink = [[AVAudioSinkNode alloc] initWithReceiverBlock:^OSStatus(const AudioTimeStamp*, AVAudioFrameCount n,
                                                                       const AudioBufferList* in) {
        const float* ch[16] = {nullptr};
        UInt32 count = in->mNumberBuffers < 16 ? in->mNumberBuffers : 16;
        for (UInt32 i = 0; i < count; i++) ch[i] = (const float*)in->mBuffers[i].mData;
        ring->write(ch, n);
        return noErr;
      }];
      [gEngine attachNode:gSink];
      [gEngine connect:input to:gSink format:gInputFormat];
    }
    if (outputUID) SetUnitDevice(gEngine.outputNode.audioUnit, outputUID);
    gConfigNote = [NSNotificationCenter.defaultCenter
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:gEngine
                     queue:nil
                usingBlock:^(NSNotification*) {
                  // a device came or went under the engine: wired again, at
                  // the formats there are now
                  dispatch_async(AudioQueue(), ^{
                    if (gEngine) {
                      [gEngine stop];
                      gEngine = nil;
                      gSink = nil;
                      for (CALOutput* o in OutputsNow(nullptr)) o.node = nil;
                      for (CALMicrophone* m in gMics.allValues) m.converter = nil;
                    }
                    Rewire();
                  });
                }];
    for (CALOutput* o in outputs) o.node = nil;
    for (CALMicrophone* m in gMics.allValues) m.converter = nil;
  }
  // outputs: a source node each, into the mixer
  AVAudioMixerNode* mixer = gEngine.mainMixerNode;
  for (CALOutput* o in outputs) {
    if (o.node) continue;
    AVAudioFormat* f = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:o.sampleRate channels:o.channels];
    CALOutput* out = o;
    Ring* ring = out->ring.get();
    o.node = [[AVAudioSourceNode alloc]
        initWithFormat:f
           renderBlock:^OSStatus(BOOL* silence, const AudioTimeStamp*, AVAudioFrameCount n, AudioBufferList* buf) {
             float* ch[16] = {nullptr};
             UInt32 count = buf->mNumberBuffers < 16 ? buf->mNumberBuffers : 16;
             for (UInt32 i = 0; i < count; i++) ch[i] = (float*)buf->mBuffers[i].mData;
             size_t got = ring->channels() <= count ? ring->read(ch, n) : 0;
             for (UInt32 i = 0; i < count; i++) {
               for (size_t j = got; j < n; j++) ch[i][j] = 0;
             }
             if (out->begun.load()) out->played.fetch_add(n);
             *silence = got == 0;
             return noErr;
           }];
    [gEngine attachNode:o.node];
    [gEngine connect:o.node to:mixer format:f];
  }
  // microphones: a converter each, from the input's format to theirs
  for (CALMicrophone* m in gMics.allValues) {
    if (m.converter) continue;
    m.format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:m.sampleRate channels:m.channels];
    m.converter = [[AVAudioConverter alloc] initFromFormat:gInputFormat toFormat:m.format];
    if (m.channels < gInputFormat.channelCount && m.channels == 1) {
      m.converter.downmix = YES;
    }
  }
  if (!gEngine.isRunning) {
    [gEngine prepare];
    NSError* err = nil;
    if (![gEngine startAndReturnError:&err]) {
      for (CALMicrophone* m in gMics.allValues) {
        if (!m.started) MicrophoneError(m.mid, "NotReadableError", err.localizedDescription ?: @"the engine did not start");
      }
      return;
    }
  }
  gOutputLatency = gEngine.outputNode.presentationLatency;
  if (wantInput && !gDrain) {
    gDrain = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, AudioQueue());
    dispatch_source_set_timer(gDrain, dispatch_time(DISPATCH_TIME_NOW, 0), 10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gDrain, ^{ DrainInput(); });
    dispatch_resume(gDrain);
  } else if (!wantInput && gDrain) {
    dispatch_source_cancel(gDrain);
    gDrain = nil;
  }
  AVAudioInputNode* input = wantInput ? gEngine.inputNode : nil;
  for (CALMicrophone* m in gMics.allValues) {
    if (m.started) continue;
    m.started = YES;
    bool voice = gVoice;
    bool agc = voice && input.voiceProcessingAGCEnabled;
    if (voice && !m.autoGainControl) {
      input.voiceProcessingAGCEnabled = NO;
      agc = NO;
    }
    double latency = input.presentationLatency;
    Send(std::move(CALEvent("microphone-started")
                       .Num("id", m.mid)
                       .Bool("echoCancellation", voice)
                       .Bool("noiseSuppression", voice)
                       .Bool("autoGainControl", agc)
                       .Num("sampleRate", m.sampleRate)
                       .Num("channels", m.channels)
                       .Num("latency", latency)));
  }
}

// Every 10 ms on the audio queue: what the input gave, converted for each
// microphone, out in 10 ms chunks.
static void DrainInput() {
  Ring* ring = gInputRing.get();
  if (!ring || !gInputFormat) return;
  size_t n = ring->available();
  if (n == 0) return;
  AVAudioPCMBuffer* in = [[AVAudioPCMBuffer alloc] initWithPCMFormat:gInputFormat frameCapacity:(AVAudioFrameCount)n];
  ring->read(in.floatChannelData, n);
  in.frameLength = (AVAudioFrameCount)n;
  for (CALMicrophone* m in gMics.allValues) {
    if (!m.converter) continue;
    double ratio = m.sampleRate / gInputFormat.sampleRate;
    AVAudioFrameCount cap = (AVAudioFrameCount)ceil(n * ratio) + 64;
    AVAudioPCMBuffer* out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:m.format frameCapacity:cap];
    __block bool given = false;
    NSError* err = nil;
    [m.converter convertToBuffer:out
                           error:&err
              withInputFromBlock:^AVAudioBuffer*(AVAudioPacketCount, AVAudioConverterInputStatus* status) {
                if (given) {
                  *status = AVAudioConverterInputStatus_NoDataNow;
                  return nil;
                }
                given = true;
                *status = AVAudioConverterInputStatus_HaveData;
                return in;
              }];
    if (m->pending.size() != m.channels) m->pending.assign(m.channels, {});
    for (AVAudioChannelCount c = 0; c < m.channels; c++) {
      float* src = out.floatChannelData[c];
      m->pending[c].insert(m->pending[c].end(), src, src + out.frameLength);
    }
    size_t chunk = (size_t)llround(m.sampleRate / 100);
    while (!m->pending.empty() && m->pending[0].size() >= chunk) {
      auto planes = std::make_shared<std::vector<std::vector<float>>>();
      for (auto& p : m->pending) {
        planes->emplace_back(p.begin(), p.begin() + chunk);
        p.erase(p.begin(), p.begin() + chunk);
      }
      double time = m->sent / m.sampleRate;
      m->sent += chunk;
      // two seconds waiting is as far as it goes: past that, the oldest wait
      // and this one is counted instead
      if (m->inflight->load() > 200) {
        m->dropped++;
        continue;
      }
      int dropped = m->dropped.exchange(0);
      auto inflight = m->inflight;
      inflight->fetch_add(1);
      double mid = m.mid, rate = m.sampleRate;
      if (!Deliver(^{
            inflight->fetch_sub(1);
            if (!CALListening()) return;
            CALEvent ev("audio-input");
            ev.Num("id", mid).Num("sampleRate", rate).Num("frames", (double)chunk).Num("time", time);
            if (dropped) ev.Num("dropped", dropped);
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
        inflight->fetch_sub(1);
      }
    }
  }
}

static Napi::Value OpenMicrophone(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value opts = info.Length() > 1 ? info[1] : env.Undefined();
  double rate = 48000, channels = 1;
  OptNum(opts, "sampleRate", &rate);
  OptNum(opts, "channels", &channels);
  rate = fmin(192000, fmax(8000, rate));
  channels = fmin(2, fmax(1, round(channels)));
  bool echo = true, noise = true, agc = true;
  OptBool(opts, "echoCancellation", &echo);
  OptBool(opts, "noiseSuppression", &noise);
  OptBool(opts, "autoGainControl", &agc);
  NSString* uid = Str(info[0]);
  double mid = (double)(++gNextCapture);
  Napi::Object out = Napi::Object::New(env);
  out.Set("id", mid);
  out.Set("sampleRate", rate);
  out.Set("channels", channels);
  out.Set("echoCancellation", echo);
  out.Set("noiseSuppression", noise);
  out.Set("autoGainControl", agc);
  CALMicrophone* m = [CALMicrophone new];
  m.mid = mid;
  m.sampleRate = rate;
  m.channels = (AVAudioChannelCount)channels;
  // the canceller brings its suppressor and its gain control: none of the
  // three without it
  m.echoCancellation = echo || noise;
  m.noiseSuppression = noise;
  m.autoGainControl = agc;
  m->inflight = std::make_shared<std::atomic<int>>(0);
  m->sent = 0;
  m->dropped = 0;
  dispatch_async(AudioQueue(), ^{
    // a device that is not there is said before anything is asked of the user
    if (uid && DeviceForUID(uid) == kAudioObjectUnknown) {
      MicrophoneError(mid, "NotFoundError", [NSString stringWithFormat:@"there is no microphone %@", uid]);
      return;
    }
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
      MicrophoneError(mid, "NotAllowedError", @"the microphone is not allowed for this app (Privacy & Security › Microphone)");
      return;
    }
    void (^open)(void) = ^{
      NSString* deviceUID = uid;
      if (deviceUID && [deviceUID isEqualToString:DeviceUID(DefaultDevice(true))]) deviceUID = nil;
      if (deviceUID && DeviceForUID(deviceUID) == kAudioObjectUnknown) {
        MicrophoneError(mid, "NotFoundError", [NSString stringWithFormat:@"there is no microphone %@", deviceUID]);
        return;
      }
      for (CALMicrophone* other in gMics.allValues) {
        if (![other.deviceUID ?: @"" isEqualToString:deviceUID ?: @""]) {
          MicrophoneError(mid, "NotReadableError",
                          @"another microphone is open: the engine has one input at a time");
          return;
        }
      }
      m.deviceUID = deviceUID;
      if (!gMics) gMics = [NSMutableDictionary dictionary];
      gMics[@(mid)] = m;
      @try {
        Rewire();
      } @catch (NSException* e) {
        [gMics removeObjectForKey:@(mid)];
        MicrophoneError(mid, "NotReadableError", e.reason ?: @"the microphone could not be opened");
      }
    };
    if (status == AVAuthorizationStatusNotDetermined) {
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                               completionHandler:^(BOOL granted) {
                                 dispatch_async(AudioQueue(), ^{
                                   if (!granted) {
                                     MicrophoneError(mid, "NotAllowedError",
                                                     @"the microphone was not allowed — by the user, or by "
                                                     @"macOS for a process it does not take for an app");
                                     return;
                                   }
                                   open();
                                 });
                               }];
      return;
    }
    open();
  });
  return out;
}

static Napi::Value CloseMicrophone(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) return env.Undefined();
  double mid = info[0].As<Napi::Number>().DoubleValue();
  dispatch_async(AudioQueue(), ^{
    if (!gMics[@(mid)]) return;
    [gMics removeObjectForKey:@(mid)];
    Rewire();
  });
  return env.Undefined();
}

static CALOutput* OutputFor(double oid) {
  @synchronized([CALOutput class]) {
    return gOutputs[@(oid)];
  }
}

static Napi::Value OpenAudioOutput(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value opts = info.Length() > 0 ? info[0] : env.Undefined();
  double rate = 48000, channels = 2;
  OptNum(opts, "sampleRate", &rate);
  OptNum(opts, "channels", &channels);
  rate = fmin(384000, fmax(1000, rate));
  channels = fmin(16, fmax(1, round(channels)));
  NSString* uid = opts.IsObject() ? Str(opts.As<Napi::Object>().Get("deviceId")) : nil;
  double oid = (double)(++gNextCapture);
  CALOutput* o = [CALOutput new];
  o.oid = oid;
  o.sampleRate = rate;
  o.channels = (AVAudioChannelCount)channels;
  o->ring = std::make_unique<Ring>((size_t)channels, (size_t)(rate * 10));
  o->played = 0;
  o->begun = false;
  @synchronized([CALOutput class]) {
    if (!gOutputs) gOutputs = [NSMutableDictionary dictionary];
    if (uid && gOutputs.count == 0) gOutputUID = uid;
    gOutputs[@(oid)] = o;
  }
  dispatch_async(AudioQueue(), ^{
    @try {
      Rewire();
    } @catch (NSException*) {
      // an engine that would not wire plays nothing; its state says so
    }
  });
  Napi::Object out = Napi::Object::New(env);
  out.Set("id", oid);
  out.Set("sampleRate", rate);
  out.Set("channels", channels);
  out.Set("latency", 0.0);
  return out;
}

static Napi::Value AudioOutputWrite(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber() || !info[1].IsArray()) {
    Napi::TypeError::New(env, "audioOutputWrite(id, channels): channels is a Float32Array a channel")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CALOutput* o = OutputFor(info[0].As<Napi::Number>().DoubleValue());
  if (!o) return Napi::Number::New(env, 0);
  Napi::Array arr = info[1].As<Napi::Array>();
  std::vector<const float*> ch(o.channels, nullptr);
  size_t frames = SIZE_MAX;
  for (uint32_t i = 0; i < arr.Length() && i < o.channels; i++) {
    Napi::Value v = arr.Get(i);
    if (!v.IsTypedArray() || v.As<Napi::TypedArray>().TypedArrayType() != napi_float32_array) {
      Napi::TypeError::New(env, "audioOutputWrite: every channel is a Float32Array").ThrowAsJavaScriptException();
      return env.Undefined();
    }
    Napi::Float32Array f = v.As<Napi::Float32Array>();
    ch[i] = f.Data();
    frames = f.ElementLength() < frames ? f.ElementLength() : frames;
  }
  if (frames == SIZE_MAX) frames = 0;
  // a channel not handed is the first one again
  for (size_t i = 1; i < ch.size(); i++) {
    if (!ch[i]) ch[i] = ch[0];
  }
  o->ring->write(ch.data(), frames);
  if (frames) o->begun = true;
  return Napi::Number::New(env, (double)o->ring->available());
}

static Napi::Value AudioOutputState(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) return env.Undefined();
  CALOutput* o = OutputFor(info[0].As<Napi::Number>().DoubleValue());
  Napi::Object out = Napi::Object::New(env);
  if (!o) {
    out.Set("currentTime", 0.0);
    out.Set("queued", 0.0);
    out.Set("latency", 0.0);
    return out;
  }
  out.Set("currentTime", (double)o->played.load() / o.sampleRate);
  out.Set("queued", (double)o->ring->available());
  out.Set("latency", gOutputLatency.load());
  return out;
}

static Napi::Value CloseAudioOutput(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) return env.Undefined();
  double oid = info[0].As<Napi::Number>().DoubleValue();
  CALOutput* o;
  @synchronized([CALOutput class]) {
    o = gOutputs[@(oid)];
    [gOutputs removeObjectForKey:@(oid)];
    if (gOutputs.count == 0) gOutputUID = nil;
  }
  if (!o) return env.Undefined();
  dispatch_async(AudioQueue(), ^{
    if (o.node && gEngine) {
      [gEngine disconnectNodeOutput:o.node];
      [gEngine detachNode:o.node];
    }
    o.node = nil;
    Rewire();
  });
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// the screen
// ---------------------------------------------------------------------------

static Napi::Value ScreenCaptureDisplays(const Napi::CallbackInfo& info) {
  return CALAnswer(info, "screenCaptureDisplays", ^CALValueBlock {
    NSArray<NSScreen*>* screens = NSScreen.screens;
    CGFloat top = screens.count ? NSMaxY(screens[0].frame) : 0;
    struct One {
      double id, x, y, w, h, scale;
      std::string name;
    };
    auto list = std::make_shared<std::vector<One>>();
    for (NSScreen* s in screens) {
      NSNumber* n = s.deviceDescription[@"NSScreenNumber"];
      NSRect f = s.frame;
      NSString* name = @"";
      if (@available(macOS 10.15, *)) name = s.localizedName ?: @"";
      list->push_back({n.doubleValue, f.origin.x, top - NSMaxY(f), f.size.width, f.size.height,
                       s.backingScaleFactor, name.UTF8String});
    }
    return ^Napi::Value(Napi::Env env) {
      Napi::Array a = Napi::Array::New(env, list->size());
      for (size_t i = 0; i < list->size(); i++) {
        const One& s = (*list)[i];
        Napi::Object o = Napi::Object::New(env);
        o.Set("id", s.id);
        o.Set("name", s.name);
        o.Set("x", s.x);
        o.Set("y", s.y);
        o.Set("width", s.w);
        o.Set("height", s.h);
        o.Set("scale", s.scale);
        a.Set((uint32_t)i, o);
      }
      return a;
    };
  });
}

static CALValueBlock ScreenshotError(const char* name, NSString* message) {
  std::string n = name, m = message.UTF8String ?: "";
  return ^Napi::Value(Napi::Env env) {
    Napi::Object o = Napi::Object::New(env);
    o.Set("error", m);
    o.Set("name", n);
    return o;
  };
}

// A CGImage as straight RGBA in sRGB: drawn into a premultiplied context
// (the only kind CoreGraphics draws into) and divided back out.
static CALValueBlock ScreenshotOf(CGImageRef img, double scale) {
  size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
  auto px = std::make_shared<std::vector<uint8_t>>(w * h * 4);
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(px->data(), w, h, 8, w * 4, srgb,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(srgb);
  if (!ctx) return ScreenshotError("NotReadableError", @"the picture could not be converted");
  CGContextSetBlendMode(ctx, kCGBlendModeCopy);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
  CGContextRelease(ctx);
  uint8_t* p = px->data();
  for (size_t i = 0; i < w * h * 4; i += 4) {
    uint8_t a = p[i + 3];
    if (a == 0 || a == 255) continue;
    p[i] = (uint8_t)fmin(255, p[i] * 255.0 / a + 0.5);
    p[i + 1] = (uint8_t)fmin(255, p[i + 1] * 255.0 / a + 0.5);
    p[i + 2] = (uint8_t)fmin(255, p[i + 2] * 255.0 / a + 0.5);
  }
  return ^Napi::Value(Napi::Env env) {
    Napi::Object o = Napi::Object::New(env);
    o.Set("width", (double)w);
    o.Set("height", (double)h);
    o.Set("scale", scale);
    o.Set("data", Napi::Buffer<uint8_t>::Copy(env, px->data(), px->size()));
    return o;
  };
}

static Napi::Value CaptureScreenshot(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value last = info.Length() ? info[info.Length() - 1] : env.Undefined();
  if (!last.IsFunction()) {
    Napi::TypeError::New(env, "captureScreenshot(options, cb): it answers through cb")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  Napi::Value opts = info.Length() > 1 ? info[0] : env.Undefined();
  double display = 0, window = 0;
  bool hasDisplay = OptNum(opts, "display", &display);
  bool hasWindow = OptNum(opts, "window", &window);
  bool cursor = false;
  OptBool(opts, "cursor", &cursor);
  bool hasRect = false;
  CGRect rect = CGRectZero;
  if (opts.IsObject() && opts.As<Napi::Object>().Get("rect").IsObject()) {
    Napi::Value r = opts.As<Napi::Object>().Get("rect");
    double x = 0, y = 0, w = 0, h = 0;
    bool hx = OptNum(r, "x", &x), hy = OptNum(r, "y", &y);
    bool hw = OptNum(r, "width", &w), hh = OptNum(r, "height", &h);
    hasRect = hx && hy && hw && hh && w > 0 && h > 0;
    rect = CGRectMake(x, y, w, h);
  }
  CALTsfn tsfn = CALReplyTo(env, last.As<Napi::Function>(), "appkit:captureScreenshot");
  if (@available(macOS 14.0, *)) {
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                               onScreenWindowsOnly:YES
                                 completionHandler:^(SCShareableContent* content, NSError* error) {
                                   if (error || !content) {
                                     bool declined = error.code == SCStreamErrorUserDeclined;
                                     CALReply(tsfn, ScreenshotError(
                                                        declined ? "NotAllowedError" : "NotReadableError",
                                                        declined ? @"Screen Recording is not allowed for this app "
                                                                   @"(Privacy & Security › Screen Recording)"
                                                                 : (error.localizedDescription ?: @"the screen could not be listed")));
                                     return;
                                   }
                                   SCContentFilter* filter = nil;
                                   if (hasWindow) {
                                     for (SCWindow* w in content.windows) {
                                       if (w.windowID == (CGWindowID)window) {
                                         filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:w];
                                         break;
                                       }
                                     }
                                   } else {
                                     CGDirectDisplayID want = hasDisplay ? (CGDirectDisplayID)display : CGMainDisplayID();
                                     for (SCDisplay* d in content.displays) {
                                       if (d.displayID == want) {
                                         filter = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
                                         break;
                                       }
                                     }
                                   }
                                   if (!filter) {
                                     CALReply(tsfn, ScreenshotError("NotFoundError", hasWindow ? @"there is no such window on screen"
                                                                                             : @"there is no such display"));
                                     return;
                                   }
                                   double scale = filter.pointPixelScale;
                                   CGRect area = hasRect ? rect : CGRectMake(0, 0, filter.contentRect.size.width,
                                                                             filter.contentRect.size.height);
                                   SCStreamConfiguration* config = [SCStreamConfiguration new];
                                   if (hasRect) config.sourceRect = rect;
                                   config.width = (size_t)llround(area.size.width * scale);
                                   config.height = (size_t)llround(area.size.height * scale);
                                   config.showsCursor = cursor;
                                   config.colorSpaceName = kCGColorSpaceSRGB;
                                   config.ignoreShadowsSingleWindow = YES;
                                   [SCScreenshotManager captureImageWithFilter:filter
                                                                 configuration:config
                                                             completionHandler:^(CGImageRef img, NSError* err) {
                                                               if (!img) {
                                                                 bool no = err.code == SCStreamErrorUserDeclined;
                                                                 CALReply(tsfn, ScreenshotError(
                                                                                    no ? "NotAllowedError" : "NotReadableError",
                                                                                    err.localizedDescription ?: @"no picture came back"));
                                                                 return;
                                                               }
                                                               CALReply(tsfn, ScreenshotOf(img, scale));
                                                             }];
                                 }];
  } else {
    CALReply(tsfn, ScreenshotError("NotSupportedError", @"screenshots need macOS 14 (ScreenCaptureKit)"));
  }
  return env.Undefined();
}

void InitCapture(Napi::Env env, Napi::Object exports) {
  // The delivery function is the main thread's, made the once, for the
  // reason InitNotifications gives: pump mode's listener is called there.
  if (pthread_main_np() && !gDeliver.load()) {
    DeliveryTsfn t = DeliveryTsfn::New(env, "appkit:capture", 0, 1);
    t.Unref(env);
    gDeliver.store(new CALTsfn(CALTsfn::Watch(env, t)));
  }
  exports.Set("captureDevices", Napi::Function::New(env, CaptureDevices));
  exports.Set("openCamera", Napi::Function::New(env, OpenCamera));
  exports.Set("cameraFrames", Napi::Function::New(env, CameraFrames));
  exports.Set("cameraCopyFrame", Napi::Function::New(env, CameraCopyFrame));
  exports.Set("closeCamera", Napi::Function::New(env, CloseCamera));
  exports.Set("openMicrophone", Napi::Function::New(env, OpenMicrophone));
  exports.Set("closeMicrophone", Napi::Function::New(env, CloseMicrophone));
  exports.Set("openAudioOutput", Napi::Function::New(env, OpenAudioOutput));
  exports.Set("audioOutputWrite", Napi::Function::New(env, AudioOutputWrite));
  exports.Set("audioOutputState", Napi::Function::New(env, AudioOutputState));
  exports.Set("closeAudioOutput", Napi::Function::New(env, CloseAudioOutput));
  exports.Set("screenCaptureDisplays", Napi::Function::New(env, ScreenCaptureDisplays));
  exports.Set("captureScreenshot", Napi::Function::New(env, CaptureScreenshot));
}
