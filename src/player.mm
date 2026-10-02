// @windowkit/appkit player.mm — a file or URL played by AVFoundation, for a
// renderer's `<video src>`: the platform's decoder, audio, seeking and HLS,
// none of it the renderer's.
//
// - createPlayer(url, { autoPlay, loop, muted, volume, rate }) -> { id, layer }:
//   an AVPlayer over the URL (a path, a file:// URL or an http(s) one), and
//   the AVPlayerLayer that shows it — a layer handle every layer verb takes,
//   so a renderer places it among its own layers like any other. Its
//   `videoGravity` fills the layer: the renderer fits the picture itself.
// - playerSet(id, { paused, rate, volume, muted, loop }), playerSeek(id, s).
// - playerCopyFrame(id, surface) -> { width, height, time } | null: the frame
//   showing now, converted into a 2D surface — for a renderer that draws the
//   video in its own paint order because something is drawn over it — or
//   null when there is no frame newer than the last one copied. Converted in
//   the colours the layer shows the same frame in (video.mm), so a video
//   moving between the two does not change shade.
// - releasePlayer(id): stopped, and everything it holds let go.
//
// Events, by `id`: `player-metadata { width, height, duration }` when the
// item is ready and whenever its size changes (`duration` is Infinity for a
// live stream); `player-state { playing, rate }` when it starts or stops;
// `player-time { currentTime }` four times a second while it plays, and
// after a seek; `player-ended` at the end of an item that does not loop;
// `player-error { message }` when the item fails.
//
// Everything about a player happens on the UI thread — AVFoundation's KVO and
// notifications arrive there — and a worker's verbs are commands to it, the
// layer a handle answered at the call. The one exception is the copy, which
// reads AVPlayerItemVideoOutput from the calling thread as a display link
// would, into a surface that thread draws with.

#include <napi.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

#include <pthread.h>

#include <atomic>
#include <cmath>
#include <string>

#include "channel.h"

// video.mm
bool CALPixelBufferToBGRA(Napi::Env env, const char* verb, CVPixelBufferRef pb, uint8_t* dst,
                          size_t dstStride);
bool CALVideoTargetBitmap(Napi::Value v, uint8_t** data, size_t* width, size_t* height,
                          size_t* bytesPerRow);

@interface CALPlayer : NSObject
@property(nonatomic) double pid;
@property(nonatomic, strong) AVPlayer* player;
@property(nonatomic, strong) AVPlayerItem* item;
@property(nonatomic, strong) AVPlayerLayer* layer;
// written on the UI thread, read by a copy on any other
@property(atomic, strong) AVPlayerItemVideoOutput* output;
@property(nonatomic) BOOL loop;
@property(nonatomic) float rate;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, strong) NSMutableArray* notes;
@property(nonatomic) CGSize lastSize;
@property(nonatomic) double lastDuration;
@property(nonatomic) BOOL observing;
@end

static void* kStatusContext = &kStatusContext;
static void* kControlContext = &kControlContext;
static void* kSizeContext = &kSizeContext;

static double Seconds(CMTime t) {
  if (CMTIME_IS_INDEFINITE(t)) return INFINITY;
  double s = CMTimeGetSeconds(t);
  return std::isfinite(s) ? s : 0;
}

@implementation CALPlayer

// Once the item is ready, and again whenever its size or its duration
// moves: before it is ready a size can arrive with the duration still
// unknown, and a renderer would lay a clip out as a live stream.
- (void)metadata {
  if (self.item.status != AVPlayerItemStatusReadyToPlay) return;
  CGSize size = self.item.presentationSize;
  if (size.width <= 0 || size.height <= 0) return;
  double duration = Seconds(self.item.duration);
  if (CGSizeEqualToSize(size, self.lastSize) && duration == self.lastDuration) return;
  self.lastSize = size;
  self.lastDuration = duration;
  CALEmit(std::move(CALEvent("player-metadata")
                        .Num("id", self.pid)
                        .Num("width", size.width)
                        .Num("height", size.height)
                        .Num("duration", duration)));
}

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
  if (context == kStatusContext) {
    if (self.item.status == AVPlayerItemStatusReadyToPlay) {
      [self metadata];
    } else if (self.item.status == AVPlayerItemStatusFailed) {
      NSString* why = self.item.error.localizedDescription ?: @"the item could not be played";
      CALEmit(std::move(CALEvent("player-error").Num("id", self.pid).Str("message", why.UTF8String)));
    }
  } else if (context == kControlContext) {
    BOOL playing = self.player.timeControlStatus != AVPlayerTimeControlStatusPaused;
    CALEmit(std::move(
        CALEvent("player-state").Num("id", self.pid).Bool("playing", playing).Num("rate", self.player.rate)));
  } else if (context == kSizeContext) {
    [self metadata];
  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

- (void)start {
  AVPlayerItem* item = self.item;
  [item addObserver:self forKeyPath:@"status" options:0 context:kStatusContext];
  [item addObserver:self forKeyPath:@"presentationSize" options:0 context:kSizeContext];
  [item addObserver:self forKeyPath:@"duration" options:0 context:kSizeContext];
  [self.player addObserver:self forKeyPath:@"timeControlStatus" options:0 context:kControlContext];
  self.observing = YES;
  __weak CALPlayer* weak = self;
  self.timeObserver = [self.player
      addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, 600)
                                   queue:dispatch_get_main_queue()
                              usingBlock:^(CMTime time) {
                                CALPlayer* p = weak;
                                if (!p) return;
                                CALEmit(std::move(CALEvent("player-time")
                                                      .Num("id", p.pid)
                                                      .Num("currentTime", Seconds(time))));
                              }];
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  self.notes = [NSMutableArray array];
  [self.notes addObject:[nc addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                        object:item
                                         queue:NSOperationQueue.mainQueue
                                    usingBlock:^(NSNotification* n) {
                                      CALPlayer* p = weak;
                                      if (!p) return;
                                      if (p.loop) {
                                        [p.player seekToTime:kCMTimeZero
                                             toleranceBefore:kCMTimeZero
                                              toleranceAfter:kCMTimeZero];
                                        [p.player playImmediatelyAtRate:p.rate];
                                      } else {
                                        CALEmit(std::move(CALEvent("player-ended").Num("id", p.pid)));
                                      }
                                    }]];
  [self.notes addObject:[nc addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                                        object:item
                                         queue:NSOperationQueue.mainQueue
                                    usingBlock:^(NSNotification* n) {
                                      CALPlayer* p = weak;
                                      if (!p) return;
                                      NSError* e = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
                                      NSString* why = e.localizedDescription ?: @"playback stopped";
                                      CALEmit(std::move(CALEvent("player-error")
                                                            .Num("id", p.pid)
                                                            .Str("message", why.UTF8String)));
                                    }]];
}

- (void)stop {
  [self.player pause];
  if (self.observing) {
    [self.item removeObserver:self forKeyPath:@"status" context:kStatusContext];
    [self.item removeObserver:self forKeyPath:@"presentationSize" context:kSizeContext];
    [self.item removeObserver:self forKeyPath:@"duration" context:kSizeContext];
    [self.player removeObserver:self forKeyPath:@"timeControlStatus" context:kControlContext];
    self.observing = NO;
  }
  if (self.timeObserver) [self.player removeTimeObserver:self.timeObserver];
  self.timeObserver = nil;
  for (id note in self.notes) [NSNotificationCenter.defaultCenter removeObserver:note];
  self.notes = nil;
  if (self.output) [self.item removeOutput:self.output];
  self.output = nil;
  [self.player replaceCurrentItemWithPlayerItem:nil];
  self.layer.player = nil;
}

@end

// id -> CALPlayer; the UI thread's, but a copy on another thread looks a
// player's output up, so every access is under the lock
static NSMutableDictionary<NSNumber*, CALPlayer*>* gPlayers;
static std::atomic<uint32_t> gNextPlayer{0};

static CALPlayer* PlayerFor(double pid) {
  @synchronized([CALPlayer class]) {
    return gPlayers[@(pid)];
  }
}

static NSURL* URLFrom(NSString* s) {
  if ([s rangeOfString:@"://"].location != NSNotFound) return [NSURL URLWithString:s];
  return [NSURL fileURLWithPath:s.stringByExpandingTildeInPath];
}

static bool OptBool(Napi::Object o, const char* k, bool* out) {
  if (!o.Has(k)) return false;
  Napi::Value v = o.Get(k);
  if (!v.IsBoolean()) return false;
  *out = v.As<Napi::Boolean>().Value();
  return true;
}

static bool OptNum(Napi::Object o, const char* k, double* out) {
  if (!o.Has(k)) return false;
  Napi::Value v = o.Get(k);
  if (!v.IsNumber()) return false;
  double d = v.As<Napi::Number>().DoubleValue();
  if (!std::isfinite(d)) return false;
  *out = d;
  return true;
}

// The settings an options object names, read on the calling thread and
// applied on the UI thread: what is left out stays as it is.
struct PlayerSettings {
  bool hasPaused = false, paused = false;
  bool hasRate = false;
  double rate = 1;
  bool hasVolume = false;
  double volume = 1;
  bool hasMuted = false, muted = false;
  bool hasLoop = false, loop = false;
};

static PlayerSettings ReadSettings(Napi::Value v) {
  PlayerSettings s;
  if (!v.IsObject()) return s;
  Napi::Object o = v.As<Napi::Object>();
  s.hasPaused = OptBool(o, "paused", &s.paused);
  s.hasRate = OptNum(o, "rate", &s.rate) && s.rate > 0;
  s.hasVolume = OptNum(o, "volume", &s.volume);
  s.hasMuted = OptBool(o, "muted", &s.muted);
  s.hasLoop = OptBool(o, "loop", &s.loop);
  return s;
}

static void Apply(CALPlayer* p, const PlayerSettings& s) {
  if (s.hasLoop) p.loop = s.loop;
  if (s.hasMuted) p.player.muted = s.muted;
  if (s.hasVolume) p.player.volume = (float)fmin(1, fmax(0, s.volume));
  if (s.hasRate) {
    p.rate = (float)s.rate;
    if (p.player.rate != 0) p.player.rate = p.rate;
  }
  if (s.hasPaused) {
    if (s.paused) [p.player pause];
    else [p.player playImmediatelyAtRate:p.rate];
  }
}

static Napi::Value CreatePlayer(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsString() || info[0].As<Napi::String>().Utf8Value().empty()) {
    Napi::TypeError::New(env, "createPlayer(url, options): url is a path or a URL string")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  NSString* url = [NSString stringWithUTF8String:info[0].As<Napi::String>().Utf8Value().c_str()];
  NSURL* u = URLFrom(url);
  if (!u) {
    Napi::TypeError::New(env, "createPlayer: " + info[0].As<Napi::String>().Utf8Value() +
                                  " is not a URL AVFoundation can open")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  PlayerSettings settings = ReadSettings(info.Length() > 1 ? info[1] : env.Undefined());
  bool autoPlay = false;
  if (info.Length() > 1 && info[1].IsObject()) OptBool(info[1].As<Napi::Object>(), "autoPlay", &autoPlay);
  double pid = (double)(++gNextPlayer);

  CALPlayer* (^make)(void) = ^CALPlayer* {
    CALPlayer* p = [CALPlayer new];
    p.pid = pid;
    p.rate = 1;
    p.item = [AVPlayerItem playerItemWithURL:u];
    p.player = [AVPlayer playerWithPlayerItem:p.item];
    // the end is the renderer's to answer — loop, or say it ended
    p.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    p.layer = [AVPlayerLayer playerLayerWithPlayer:p.player];
    p.layer.videoGravity = AVLayerVideoGravityResize;
    // YCbCr out, in the layout VideoToolbox decodes to: a copy for the drawn
    // presentation is then converted here, in the layer's colours
    p.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
      (id)kCVPixelBufferPixelFormatTypeKey : @[
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
      ],
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    }];
    [p.item addOutput:p.output];
    Apply(p, settings);
    [p start];
    if (autoPlay) [p.player playImmediatelyAtRate:p.rate];
    @synchronized([CALPlayer class]) {
      if (!gPlayers) gPlayers = [NSMutableDictionary dictionary];
      gPlayers[@(pid)] = p;
    }
    return p;
  };

  Napi::Object out = Napi::Object::New(env);
  out.Set("id", pid);
  if (pthread_main_np()) {
    CALPlayer* p = make();
    void* retained = (void*)CFBridgingRetain(p.layer);
    out.Set("layer", Napi::External<void>::New(env, retained, [](Napi::Env, void* d) { CFRelease(d); }));
  } else {
    CALHandle* h = CALNewHandle();
    out.Set("layer", CALWrapHandle(env, h, false));
    CALOnUI(^{ h->object_ = make().layer; });
  }
  return out;
}

static Napi::Value PlayerSet(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "playerSet(id, settings): id is the number createPlayer answered")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  double pid = info[0].As<Napi::Number>().DoubleValue();
  PlayerSettings settings = ReadSettings(info.Length() > 1 ? info[1] : env.Undefined());
  CALOnUI(^{
    CALPlayer* p = PlayerFor(pid);
    if (p) Apply(p, settings);
  });
  return env.Undefined();
}

static Napi::Value PlayerSeek(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber() || !info[1].IsNumber()) {
    Napi::TypeError::New(env, "playerSeek(id, seconds): two numbers").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  double pid = info[0].As<Napi::Number>().DoubleValue();
  double seconds = fmax(0, info[1].As<Napi::Number>().DoubleValue());
  CALOnUI(^{
    CALPlayer* p = PlayerFor(pid);
    if (!p) return;
    __weak CALPlayer* weak = p;
    [p.player seekToTime:CMTimeMakeWithSeconds(seconds, 600)
         toleranceBefore:kCMTimeZero
          toleranceAfter:kCMTimeZero
       completionHandler:^(BOOL finished) {
         CALPlayer* q = weak;
         if (!q || !finished) return;
         // the time the seek landed on, at once: a paused player's periodic
         // observer would otherwise say nothing until it plays
         CALEmit(std::move(CALEvent("player-time")
                               .Num("id", q.pid)
                               .Num("currentTime", Seconds(q.player.currentTime))));
       }];
  });
  return env.Undefined();
}

static Napi::Value PlayerCopyFrame(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) {
    Napi::TypeError::New(env, "playerCopyFrame(id, surface): id is the number createPlayer answered")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  uint8_t* data;
  size_t sw, sh, bpr;
  if (!CALVideoTargetBitmap(info[1], &data, &sw, &sh, &bpr)) return env.Undefined();
  CALPlayer* p = PlayerFor(info[0].As<Napi::Number>().DoubleValue());
  AVPlayerItemVideoOutput* output = p.output;
  if (!output) return env.Null();
  CMTime t = [output itemTimeForHostTime:CACurrentMediaTime()];
  if (![output hasNewPixelBufferForItemTime:t]) return env.Null();
  CMTime shown = kCMTimeInvalid;
  CVPixelBufferRef pb = [output copyPixelBufferForItemTime:t itemTimeForDisplay:&shown];
  if (!pb) return env.Null();
  size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
  Napi::Object out = Napi::Object::New(env);
  out.Set("width", (double)w);
  out.Set("height", (double)h);
  out.Set("time", Seconds(CMTIME_IS_VALID(shown) ? shown : t));
  // a surface of another size than the frame is the renderer's to remake:
  // it is told the size, and nothing is written
  bool fits = w == sw && h == sh;
  bool ok = !fits || CALPixelBufferToBGRA(env, "playerCopyFrame", pb, data, bpr);
  CVPixelBufferRelease(pb);
  if (!ok) return env.Undefined();
  out.Set("written", fits);
  return out;
}

static Napi::Value ReleasePlayer(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!info[0].IsNumber()) return env.Undefined();
  double pid = info[0].As<Napi::Number>().DoubleValue();
  CALOnUI(^{
    CALPlayer* p;
    @synchronized([CALPlayer class]) {
      p = gPlayers[@(pid)];
      [gPlayers removeObjectForKey:@(pid)];
    }
    [p stop];
  });
  return env.Undefined();
}

void InitPlayer(Napi::Env env, Napi::Object exports) {
  exports.Set("createPlayer", Napi::Function::New(env, CreatePlayer));
  exports.Set("playerSet", Napi::Function::New(env, PlayerSet));
  exports.Set("playerSeek", Napi::Function::New(env, PlayerSeek));
  exports.Set("playerCopyFrame", Napi::Function::New(env, PlayerCopyFrame));
  exports.Set("releasePlayer", Napi::Function::New(env, ReleasePlayer));
}
