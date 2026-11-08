// @windowkit/appkit displaystream.mm — a display or a window as a stream of
// frames, for a renderer's screen sharing (react-x11's
// design/architecture/media-capture.md, `getDisplayMedia`): ScreenCaptureKit's
// SCStream (macOS 14), shown on a layer of its own, its frames handed over
// only on request — what a camera is, with the screen behind it.
//
// The windows there are to share — Screen Recording decides what is listed:
//
// - screenCaptureWindows(cb): cb([{ id, title, app: { name, bundleId, pid },
//   x, y, width, height, active }]), the windows on screen at the normal
//   level that are big enough to mean something, frontmost first, in points
//   with a top-left origin; `id` is the window number captureScreenshot and
//   openDisplayStream take. cb({ error, name }) where the list could not be
//   had: NotAllowedError without the grant.
//
// A stream:
//
// - openDisplayStream({ display?, window?, width?, height?, frameRate?,
//   cursor? }) -> { id, layer }: a display (a CGDirectDisplayID; the main
//   display without either) or one window, answered at once; the stream
//   starts on a queue of its own, and `display-started { id, width, height,
//   frameRate }` or `display-error { id, name, message }` says how that went,
//   `name` Media Capture's: NotAllowedError without Screen Recording,
//   NotFoundError for a display or a window that is not there,
//   NotSupportedError before macOS 14, NotReadableError otherwise. The frames
//   are the source's own pixels, scaled to fit `width` x `height` with its
//   aspect kept where one is asked; at `frameRate` at most (30 if not said),
//   and only when something changed: a still screen sends none. `layer`
//   shows the newest, filling its bounds.
// - displayStreamFrames(id, on): while on, `display-frame { id, width,
//   height, format: 'BGRA', planes, strides, time }`, copies, in sRGB, `time`
//   seconds on the capture clock. The newest only, as a camera's.
// - displayStreamCopyFrame(id, surface) -> { width, height, time, written }
//   | null: cameraCopyFrame's contract.
// - displayStreamConfigure(id, { width?, height?, frameRate? }): the stream
//   at another size or rate, without stopping — what is not said stays as it
//   is — answered by `display-configured { id, width, height, frameRate }`,
//   or `display-configured { id, error, name }` where it was refused, the
//   stream running as it was.
// - event `display-muted { id, muted }`: the window minimized, hidden or on
//   another space — no frames until it is back — and `display-ended { id,
//   name?, message? }`: the window closed, the display went, the user stopped
//   it from the menu bar's sharing indicator (`name` NotAllowedError then).
//   A closed window is said within a second of going. closeDisplayStream(id).
//
// Frames arrive on ScreenCaptureKit's queue and cross to JS the way a
// camera's do (capture.mm's Deliver).

#include <napi.h>
#import <Cocoa/Cocoa.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <os/lock.h>
#include <pthread.h>

#include <atomic>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "channel.h"

// capture.mm: one count of capture ids, one way to JS
double CALNextCaptureId();
bool CALCaptureDeliver(dispatch_block_t block);
// video.mm
bool CALPixelBufferToBGRA(Napi::Env env, const char* verb, CVPixelBufferRef pb, uint8_t* dst,
                          size_t dstStride);
bool CALVideoTargetBitmap(Napi::Value v, uint8_t** data, size_t* width, size_t* height,
                          size_t* bytesPerRow);
// backend.mm
void CALNameSurfaceSRGB(IOSurfaceRef ios, bool keep);

static void Send(CALEvent ev) {
  auto held = std::make_shared<CALEvent>(std::move(ev));
  CALCaptureDeliver(^{
    if (CALListening()) CALEmit(std::move(*held));
  });
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

static void StreamError(double sid, const char* name, NSString* message) {
  CALEvent ev("display-error");
  ev.Num("id", sid).Str("name", name).Str("message", message.UTF8String ?: "");
  Send(std::move(ev));
}

/** Media Capture's name for what ScreenCaptureKit said. */
static const char* NameOf(NSError* error) API_AVAILABLE(macos(12.3)) {
  if (!error) return "NotReadableError";
  if ([error.domain isEqualToString:SCStreamErrorDomain]) {
    switch (error.code) {
      case SCStreamErrorUserDeclined:
      case SCStreamErrorUserStopped:
        return "NotAllowedError";
      case SCStreamErrorNoDisplayList:
      case SCStreamErrorNoWindowList:
      case SCStreamErrorAttemptToStartStreamState:
        return "NotReadableError";
      default:
        break;
    }
  }
  return "NotReadableError";
}

// ---------------------------------------------------------------------------
// a stream
// ---------------------------------------------------------------------------

API_AVAILABLE(macos(12.3))
@interface CALDisplayStream : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic) double sid;
@property(atomic, strong) SCStream* stream;
@property(atomic, strong) CALayer* layer;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(atomic) BOOL closed;
- (void)endedWith:(NSError*)error;
// the stream's queue's: the source's size in pixels, and what it runs at
@property(nonatomic) double sourceWidth, sourceHeight, width, height, rate;
@property(nonatomic) BOOL cursor;
// the window streamed, or 0 for a display
@property(nonatomic) double windowID;
@end

@implementation CALDisplayStream {
  os_unfair_lock _lock;
  CVPixelBufferRef _latest;  // for a copy; retained
  double _latestTime;
  uint64_t _latestSeq, _copiedSeq;
  CVPixelBufferRef _pending;  // for JS, while on its way; retained
  double _pendingTime;
  bool _scheduled;
  std::atomic<bool> _frames;
  bool _suspended;  // the stream's queue's
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

// The stream's queue. ScreenCaptureKit suspends a window's stream for two
// reasons it does not tell apart — the window minimized, hidden or on
// another space, and the window gone — and says nothing more either way: no
// error, no stop, no frame. So a suspension is a mute, and the window is
// looked for while it lasts: one the window server no longer lists ends the
// stream.
- (void)suspend {
  if (_suspended || self.closed) return;
  _suspended = true;
  [self sendMuted:true];
  [self lookForWindow];
}

- (void)resume {
  if (!_suspended) return;
  _suspended = false;
  [self sendMuted:false];
}

- (void)sendMuted:(bool)muted {
  CALEvent ev("display-muted");
  ev.Num("id", self.sid).Bool("muted", muted);
  Send(std::move(ev));
}

- (void)lookForWindow {
  if (!_suspended || self.closed || self.windowID == 0) return;
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)self.windowID);
  bool there = list && CFArrayGetCount(list) > 0;
  if (list) CFRelease(list);
  if (!there) {
    [self endedWith:nil];
    return;
  }
  __weak CALDisplayStream* weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self.queue, ^{
    [weak lookForWindow];
  });
}

- (void)setFramesOn:(bool)on {
  _frames = on;
}

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

// ScreenCaptureKit's queue: a frame, which is news only when it is complete —
// an idle frame says nothing changed, and carries no picture of its own.
- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sample
                   ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen || self.closed) return;
  if (!CMSampleBufferIsValid(sample)) return;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (!attachments || CFArrayGetCount(attachments) == 0) return;
  NSDictionary* info = (__bridge NSDictionary*)CFArrayGetValueAtIndex(attachments, 0);
  NSNumber* status = info[SCStreamFrameInfoStatus];
  if (!status) return;
  switch ((SCFrameStatus)status.integerValue) {
    case SCFrameStatusSuspended:
      [self suspend];
      return;
    case SCFrameStatusStopped:
      [self endedWith:nil];
      return;
    case SCFrameStatusComplete:
      [self resume];
      break;
    default:
      // idle (nothing changed), blank, started: no picture of their own
      return;
  }
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
  if (!pb) return;
  double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));

  // the layer shows it: its own transaction, actions off, so a frame is a
  // flip and not a crossfade
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pb);
  CALayer* layer = self.layer;
  if (surface && layer) {
    CALNameSurfaceSRGB(surface, true);
    id contents = (__bridge id)surface;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contents = contents;
    [CATransaction commit];
  }

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
  __weak CALDisplayStream* weak = self;
  if (!CALCaptureDeliver(^{
        CALDisplayStream* s = weak;
        if (s) [s sendPending];
      })) {
    os_unfair_lock_lock(&_lock);
    _scheduled = false;
    os_unfair_lock_unlock(&_lock);
  }
}

// Where JS is: the frame waiting, as the event — the newest by now.
- (void)sendPending {
  os_unfair_lock_lock(&_lock);
  CVPixelBufferRef pb = _pending;
  double time = _pendingTime;
  _pending = nullptr;
  _scheduled = false;
  os_unfair_lock_unlock(&_lock);
  if (!pb) return;
  if (self.closed || !_frames.load() || !CALListening() ||
      CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) {
    CVPixelBufferRelease(pb);
    return;
  }
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  size_t bpr = CVPixelBufferGetBytesPerRow(pb);
  size_t rows = CVPixelBufferGetHeight(pb);
  NSData* plane = [NSData dataWithBytes:CVPixelBufferGetBaseAddress(pb) length:bpr * rows];
  double width = (double)CVPixelBufferGetWidth(pb), height = (double)rows;
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pb);
  double stride = (double)bpr;
  CALEvent ev("display-frame");
  ev.Num("id", self.sid)
      .Num("width", width)
      .Num("height", height)
      .Str("format", "BGRA")
      .Num("time", time)
      .Handle("planes",
              ^Napi::Value(Napi::Env env) {
                Napi::Array a = Napi::Array::New(env, 1);
                a.Set((uint32_t)0, Napi::Buffer<uint8_t>::Copy(env, (const uint8_t*)plane.bytes, plane.length));
                return a;
              })
      .Handle("strides", ^Napi::Value(Napi::Env env) {
        Napi::Array a = Napi::Array::New(env, 1);
        a.Set((uint32_t)0, stride);
        return a;
      });
  ev.FoldBy(self.sid);
  CALEmit(std::move(ev));
}

// The stream stopped of its own accord: the window closed, the display went,
// or the user stopped the sharing from the menu bar.
- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
  [self endedWith:error];
}

- (void)endedWith:(NSError*)error {
  if (self.closed) return;
  self.closed = YES;
  [self dropFrames];
  CALEvent ev("display-ended");
  ev.Num("id", self.sid);
  if (error) {
    ev.Str("name", NameOf(error)).Str("message", error.localizedDescription.UTF8String ?: "");
  }
  Send(std::move(ev));
}

- (void)dropFrames {
  _frames = false;
  os_unfair_lock_lock(&_lock);
  if (_latest) CVPixelBufferRelease(_latest);
  if (_pending) CVPixelBufferRelease(_pending);
  _latest = _pending = nullptr;
  os_unfair_lock_unlock(&_lock);
}

- (void)stop {
  self.closed = YES;
  [self dropFrames];
  SCStream* stream = self.stream;
  self.stream = nil;
  if (stream) [stream stopCaptureWithCompletionHandler:^(NSError*) {}];
}

@end

static NSMutableDictionary<NSNumber*, id>* gStreams;

static NSObject* StreamsLock() {
  static NSObject* lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [NSObject new];
  });
  return lock;
}

static CALDisplayStream* StreamFor(double sid) API_AVAILABLE(macos(12.3)) {
  @synchronized(StreamsLock()) {
    return gStreams[@(sid)];
  }
}

static void Forget(double sid) {
  @synchronized(StreamsLock()) {
    [gStreams removeObjectForKey:@(sid)];
  }
}

// The size frames come at: the source's pixels, or fitted into what was
// asked with the aspect kept — a width alone or a height alone sets the
// other by the aspect. Even numbers, which every encoder downstream wants.
static void FitSize(double sw, double sh, double w, double h, size_t* outW, size_t* outH) {
  double fw = sw, fh = sh;
  if (w > 0 || h > 0) {
    double scale = 1e9;
    if (w > 0) scale = std::min(scale, w / sw);
    if (h > 0) scale = std::min(scale, h / sh);
    fw = sw * scale;
    fh = sh * scale;
  }
  *outW = std::max<size_t>(2, (size_t)llround(fw / 2) * 2);
  *outH = std::max<size_t>(2, (size_t)llround(fh / 2) * 2);
}

// What a stream runs at, as ScreenCaptureKit takes it: BGRA in sRGB, which
// is what a layer shows and an encoder reads without asking.
static SCStreamConfiguration* ConfigFor(CALDisplayStream* s) API_AVAILABLE(macos(14.0)) {
  SCStreamConfiguration* config = [SCStreamConfiguration new];
  config.width = (size_t)s.width;
  config.height = (size_t)s.height;
  config.minimumFrameInterval = CMTimeMake(1000, (int32_t)llround(s.rate * 1000));
  config.pixelFormat = kCVPixelFormatType_32BGRA;
  config.colorSpaceName = kCGColorSpaceSRGB;
  config.showsCursor = s.cursor;
  config.queueDepth = 5;
  config.ignoreShadowsSingleWindow = YES;
  return config;
}

struct StreamAsk {
  bool hasDisplay = false, hasWindow = false, cursor = true;
  double display = 0, window = 0, width = 0, height = 0, rate = 30;
};

static void StreamStarted(CALDisplayStream* s, SCStream* stream, NSError* error) API_AVAILABLE(macos(14.0)) {
  if (s.closed) {
    // closed while it started: `stop` may have run before there was a stream
    if (!error) [stream stopCaptureWithCompletionHandler:^(NSError*) {}];
    return;
  }
  if (error) {
    s.closed = YES;
    s.stream = nil;
    StreamError(s.sid, NameOf(error), error.localizedDescription ?: @"the stream did not start");
    Forget(s.sid);
    return;
  }
  CALEvent ev("display-started");
  ev.Num("id", s.sid).Num("width", s.width).Num("height", s.height).Num("frameRate", s.rate);
  Send(std::move(ev));
}

// On the stream's queue, which `stop` runs on too, so a close lands before
// the stream is made or after it, never between: the filter for what was
// asked, out of what ScreenCaptureKit listed, and the stream started on it.
static void MakeStream(CALDisplayStream* s, StreamAsk ask, SCShareableContent* content, NSError* error)
    API_AVAILABLE(macos(14.0)) {
  if (s.closed) return;
  if (error || !content) {
    bool declined = error.code == SCStreamErrorUserDeclined;
    StreamError(s.sid, declined ? "NotAllowedError" : "NotReadableError",
                declined ? @"Screen Recording is not allowed for this app (Privacy & Security › Screen Recording)"
                         : (error.localizedDescription ?: @"the screen could not be listed"));
    Forget(s.sid);
    return;
  }
  SCContentFilter* filter = nil;
  if (ask.hasWindow) {
    for (SCWindow* w in content.windows) {
      if (w.windowID == (CGWindowID)ask.window) {
        filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:w];
        break;
      }
    }
  } else {
    CGDirectDisplayID want = ask.hasDisplay ? (CGDirectDisplayID)ask.display : CGMainDisplayID();
    for (SCDisplay* d in content.displays) {
      if (d.displayID == want) {
        filter = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
        break;
      }
    }
  }
  if (!filter) {
    StreamError(s.sid, "NotFoundError", ask.hasWindow ? @"there is no such window" : @"there is no such display");
    Forget(s.sid);
    return;
  }
  double scale = filter.pointPixelScale;
  s.sourceWidth = filter.contentRect.size.width * scale;
  s.sourceHeight = filter.contentRect.size.height * scale;
  size_t w = 0, h = 0;
  FitSize(s.sourceWidth, s.sourceHeight, ask.width, ask.height, &w, &h);
  s.width = (double)w;
  s.height = (double)h;
  s.rate = ask.rate > 0 ? std::min(ask.rate, 120.0) : 30;
  s.cursor = ask.cursor;
  s.windowID = ask.hasWindow ? ask.window : 0;
  SCStream* stream = [[SCStream alloc] initWithFilter:filter configuration:ConfigFor(s) delegate:s];
  NSError* addError = nil;
  if (![stream addStreamOutput:s type:SCStreamOutputTypeScreen sampleHandlerQueue:s.queue error:&addError]) {
    StreamError(s.sid, "NotReadableError", addError.localizedDescription ?: @"the stream took no output");
    Forget(s.sid);
    return;
  }
  s.stream = stream;
  [stream startCaptureWithCompletionHandler:^(NSError* startError) {
    StreamStarted(s, stream, startError);
  }];
}

static void StartStream(CALDisplayStream* s, StreamAsk ask) API_AVAILABLE(macos(14.0)) {
  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                             onScreenWindowsOnly:!ask.hasWindow
                                               completionHandler:^(SCShareableContent* content, NSError* error) {
                                                 dispatch_async(s.queue, ^{
                                                   MakeStream(s, ask, content, error);
                                                 });
                                               }];
}

static Napi::Value OpenDisplayStream(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value opts = info.Length() > 0 ? info[0] : env.Undefined();
  StreamAsk ask;
  ask.hasDisplay = OptNum(opts, "display", &ask.display);
  ask.hasWindow = OptNum(opts, "window", &ask.window);
  OptNum(opts, "width", &ask.width);
  OptNum(opts, "height", &ask.height);
  OptNum(opts, "frameRate", &ask.rate);
  OptBool(opts, "cursor", &ask.cursor);
  double sid = CALNextCaptureId();
  Napi::Object out = Napi::Object::New(env);
  out.Set("id", sid);
  if (@available(macOS 14.0, *)) {
    CALDisplayStream* s = [CALDisplayStream new];
    s.sid = sid;
    s.queue = dispatch_queue_create("appkit.displaystream", DISPATCH_QUEUE_SERIAL);
    @synchronized(StreamsLock()) {
      if (!gStreams) gStreams = [NSMutableDictionary dictionary];
      gStreams[@(sid)] = s;
    }
    CALayer* (^make)(void) = ^CALayer* {
      CALayer* layer = [CALayer layer];
      layer.contentsGravity = kCAGravityResize;
      s.layer = layer;
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
    dispatch_async(s.queue, ^{
      if (!s.closed) StartStream(s, ask);
    });
  } else {
    StreamError(sid, "NotSupportedError", @"streaming the screen needs macOS 14 (ScreenCaptureKit)");
  }
  return out;
}

static Napi::Value DisplayStreamFrames(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "displayStreamFrames(id, on): id is the number openDisplayStream answered")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (@available(macOS 14.0, *)) {
    CALDisplayStream* s = StreamFor(info[0].As<Napi::Number>().DoubleValue());
    [s setFramesOn:info.Length() > 1 && info[1].ToBoolean().Value()];
  }
  return env.Undefined();
}

static Napi::Value DisplayStreamCopyFrame(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "displayStreamCopyFrame(id, surface): id is the number openDisplayStream answered")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  uint8_t* data;
  size_t sw, sh, bpr;
  if (!CALVideoTargetBitmap(info[1], &data, &sw, &sh, &bpr)) return env.Undefined();
  if (@available(macOS 14.0, *)) {
    CALDisplayStream* s = StreamFor(info[0].As<Napi::Number>().DoubleValue());
    double time = 0;
    CVPixelBufferRef pb = [s takeNewest:&time];
    if (!pb) return env.Null();
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    Napi::Object out = Napi::Object::New(env);
    out.Set("width", (double)w);
    out.Set("height", (double)h);
    out.Set("time", time);
    bool fits = w == sw && h == sh;
    bool ok = !fits || CALPixelBufferToBGRA(env, "displayStreamCopyFrame", pb, data, bpr);
    CVPixelBufferRelease(pb);
    if (!ok) return env.Undefined();
    out.Set("written", fits);
    return out;
  }
  return env.Null();
}

static Napi::Value DisplayStreamConfigure(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "displayStreamConfigure(id, opts): id is the number openDisplayStream answered")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  double sid = info[0].As<Napi::Number>().DoubleValue();
  Napi::Value opts = info.Length() > 1 ? info[1] : env.Undefined();
  double width = 0, height = 0, rate = 0;
  bool hasWidth = OptNum(opts, "width", &width);
  bool hasHeight = OptNum(opts, "height", &height);
  bool sized = hasWidth || hasHeight;
  bool paced = OptNum(opts, "frameRate", &rate) && rate > 0;
  if (@available(macOS 14.0, *)) {
    CALDisplayStream* s = StreamFor(sid);
    if (!s) return env.Undefined();
    dispatch_async(s.queue, ^{
      SCStream* stream = s.stream;
      if (s.closed || !stream) return;
      if (sized) {
        size_t w = 0, h = 0;
        FitSize(s.sourceWidth, s.sourceHeight, width, height, &w, &h);
        s.width = (double)w;
        s.height = (double)h;
      }
      if (paced) s.rate = std::min(rate, 120.0);
      double w = s.width, h = s.height, r = s.rate;
      [stream updateConfiguration:ConfigFor(s)
                completionHandler:^(NSError* error) {
                  CALEvent ev("display-configured");
                  ev.Num("id", sid);
                  if (error) {
                    ev.Str("name", NameOf(error)).Str("error", error.localizedDescription.UTF8String ?: "");
                  } else {
                    ev.Num("width", w).Num("height", h).Num("frameRate", r);
                  }
                  Send(std::move(ev));
                }];
    });
  }
  return env.Undefined();
}

static Napi::Value CloseDisplayStream(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) return env.Undefined();
  double sid = info[0].As<Napi::Number>().DoubleValue();
  if (@available(macOS 14.0, *)) {
    CALDisplayStream* s = StreamFor(sid);
    if (!s) return env.Undefined();
    Forget(sid);
    // no frame shown or sent after this, whatever is on its way
    s.closed = YES;
    dispatch_async(s.queue, ^{
      [s stop];
    });
    CALOnUI(^{
      s.layer.contents = nil;
    });
  }
  return env.Undefined();
}

// ---------------------------------------------------------------------------
// the windows
// ---------------------------------------------------------------------------

struct WindowInfo {
  double id, x, y, w, h, pid;
  bool active;
  std::string title, app, bundleId;
};

static CALValueBlock WindowsError(const char* name, NSString* message) {
  std::string n = name, m = message.UTF8String ?: "";
  return ^Napi::Value(Napi::Env env) {
    Napi::Object o = Napi::Object::New(env);
    o.Set("error", m);
    o.Set("name", n);
    return o;
  };
}

static Napi::Value ScreenCaptureWindows(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Value last = info.Length() ? info[info.Length() - 1] : env.Undefined();
  if (!last.IsFunction()) {
    Napi::TypeError::New(env, "screenCaptureWindows(cb): expected a callback").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  CALTsfn tsfn = CALReplyTo(env, last.As<Napi::Function>(), "appkit:screenCaptureWindows");
  if (@available(macOS 14.0, *)) {
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:YES
                               onScreenWindowsOnly:YES
                                 completionHandler:^(SCShareableContent* content, NSError* error) {
                                   if (error || !content) {
                                     bool declined = error.code == SCStreamErrorUserDeclined;
                                     CALReply(tsfn, WindowsError(declined ? "NotAllowedError" : "NotReadableError",
                                                                 declined ? @"Screen Recording is not allowed for this app "
                                                                            @"(Privacy & Security › Screen Recording)"
                                                                          : (error.localizedDescription ?: @"the windows could not be listed")));
                                     return;
                                   }
                                   auto list = std::make_shared<std::vector<WindowInfo>>();
                                   for (SCWindow* w in content.windows) {
                                     // the normal level, and big enough to be a window a person
                                     // would pick: not a menu bar item, a tooltip or a shadow
                                     if (w.windowLayer != 0) continue;
                                     CGRect f = w.frame;
                                     if (f.size.width < 40 || f.size.height < 40) continue;
                                     SCRunningApplication* a = w.owningApplication;
                                     WindowInfo one;
                                     one.id = (double)w.windowID;
                                     one.x = f.origin.x;
                                     one.y = f.origin.y;  // a window's frame has its origin top-left
                                     one.w = f.size.width;
                                     one.h = f.size.height;
                                     one.pid = a ? (double)a.processID : 0;
                                     one.active = w.isActive;
                                     one.title = w.title.UTF8String ?: "";
                                     one.app = a.applicationName.UTF8String ?: "";
                                     one.bundleId = a.bundleIdentifier.UTF8String ?: "";
                                     list->push_back(one);
                                   }
                                   CALReply(tsfn, ^Napi::Value(Napi::Env env) {
                                     Napi::Array arr = Napi::Array::New(env, list->size());
                                     for (size_t i = 0; i < list->size(); i++) {
                                       const WindowInfo& w = (*list)[i];
                                       Napi::Object o = Napi::Object::New(env);
                                       o.Set("id", w.id);
                                       o.Set("title", w.title);
                                       Napi::Object app = Napi::Object::New(env);
                                       app.Set("name", w.app);
                                       app.Set("bundleId", w.bundleId);
                                       app.Set("pid", w.pid);
                                       o.Set("app", app);
                                       o.Set("x", w.x);
                                       o.Set("y", w.y);
                                       o.Set("width", w.w);
                                       o.Set("height", w.h);
                                       o.Set("active", w.active);
                                       arr.Set((uint32_t)i, o);
                                     }
                                     return arr;
                                   });
                                 }];
  } else {
    CALReply(tsfn, WindowsError("NotSupportedError", @"listing windows needs macOS 14 (ScreenCaptureKit)"));
  }
  return env.Undefined();
}

void InitDisplayStream(Napi::Env env, Napi::Object exports) {
  exports.Set("screenCaptureWindows", Napi::Function::New(env, ScreenCaptureWindows));
  exports.Set("openDisplayStream", Napi::Function::New(env, OpenDisplayStream));
  exports.Set("displayStreamFrames", Napi::Function::New(env, DisplayStreamFrames));
  exports.Set("displayStreamCopyFrame", Napi::Function::New(env, DisplayStreamCopyFrame));
  exports.Set("displayStreamConfigure", Napi::Function::New(env, DisplayStreamConfigure));
  exports.Set("closeDisplayStream", Napi::Function::New(env, CloseDisplayStream));
}
