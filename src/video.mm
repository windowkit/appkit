// @windowkit/appkit video.mm — video frames a renderer is handed as bytes,
// shown on a layer as they are or drawn into a surface.
//
// A decoder that is not the platform's — ffmpeg over a pipe, a WASM module,
// an addon — hands a renderer planes of bytes, and the cheapest way to put
// them on the screen is the way VideoToolbox's own output gets there: a
// YCbCr IOSurface as a plain layer's contents. The render server converts
// and scales it, in the GPU, on its own clock; the CPU's share is the copy
// in and a transaction. Measured for react-x11's video design record
// (docs/architecture/video.md §3.4): `420v`, `420f` and `2vuy` surfaces all
// show on screen — through the window server, not through
// CALayer.render(in:), which draws none of them — and the three-plane
// layouts (`y420`, `f420`) draw nothing. So:
//
// - createVideoSurface(width, height, { format, colorSpace, range })
//   -> { handle, iosurfaceId }: an IOSurface-backed CVPixelBuffer, `NV12`
//   (two planes, `420v` or `420f` by range) or `BGRA`, carrying the colour
//   attachments CoreVideo gives a decoded frame — matrix, primaries and
//   transfer function, which CoreVideo mirrors onto the IOSurface where Core
//   Animation reads them. Shown through setLayerContentsIOSurface by id,
//   like any other IOSurface; that verb keeps the colour the surface names.
// - writeVideoSurface(target, format, planes, options?): one frame in.
//   `NV12` and `I420` into an NV12 surface — I420's two chroma planes
//   interleaved on the way, the copy the write makes anyway — and `BGRA`
//   into a BGRA one. Into a BGRA surface, or into a 2D surface
//   (createSurface, createSurfaceIOSurface) for a renderer that draws the
//   frame in its own paint order, a YCbCr frame is converted by
//   VideoToolbox's pixel transfer, colour-matched to sRGB, so that the
//   frame drawn into a bitmap and the same frame on a layer show the same
//   colours.
// - videoSurfaceIsInUse(handle), releaseVideoSurface(handle) — the
//   surface verbs' counterparts, so a renderer keeping a ring of them writes
//   only into one the render server has let go.
// - videoFormats() -> { surfaces, frames }: what this bridge makes and
//   takes, for a renderer to ask rather than assume.
//
// Every verb runs on the calling thread — a worker's, in threaded mode —
// and none touches a layer: the copy is IOSurface memory under its own
// lock, and the flip is setLayerContentsIOSurface's, which goes through the
// layer queue like every other layer change.

#include <napi.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Accelerate/Accelerate.h>

#include <cmath>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// A 2D surface's bitmap (backend.mm): false, with a JS error pending, when
// `v` is not a live surface handle.
struct CALSurfaceBits {
  uint8_t* data;
  size_t width, height, bytesPerRow;
};
bool CALSurfaceBitmap(Napi::Value v, CALSurfaceBits* out);
// Name an IOSurface's colour space sRGB (backend.mm).
void CALNameSurfaceSRGB(IOSurfaceRef ios, bool keep);

namespace {

// What tells a video surface's handle from a 2D surface's: both are
// Externals, and writeVideoSurface takes either.
const napi_type_tag kVideoSurfaceTag = {0x8c1e5b2d7a4f4e19ULL,
                                        0xb36d0f2a91c84e57ULL};

const size_t kMaxSide = 16384;

enum class Format { NV12, I420, BGRA };

const char* FormatName(Format f) {
  switch (f) {
    case Format::NV12:
      return "NV12";
    case Format::I420:
      return "I420";
    case Format::BGRA:
      return "BGRA";
  }
  return "?";
}

bool ParseFormat(Napi::Value v, Format* out) {
  if (!v.IsString()) return false;
  std::string s = v.As<Napi::String>().Utf8Value();
  if (s == "NV12") *out = Format::NV12;
  else if (s == "I420") *out = Format::I420;
  else if (s == "BGRA") *out = Format::BGRA;
  else return false;
  return true;
}

// What a frame's numbers mean: the attachments CoreVideo puts on a decoded
// buffer, which Core Animation and VideoToolbox both read.
struct Colour {
  CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
  CFStringRef primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
  CFStringRef transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
  bool full = false;
};

// `colorSpace` ('bt709' by default, 'bt601', 'bt2020') and `range`
// ('video' by default, 'full') off an options object. False, with a
// TypeError pending, for a value that is not one of those.
bool ParseColour(Napi::Env env, const char* verb, Napi::Object o, Colour* c) {
  if (o.Has("colorSpace") && !o.Get("colorSpace").IsUndefined()) {
    Napi::Value v = o.Get("colorSpace");
    std::string s = v.IsString() ? v.As<Napi::String>().Utf8Value() : "";
    if (s == "bt709") {
      // the defaults
    } else if (s == "bt601") {
      // SD: the 601 matrix with SMPTE C primaries (SMPTE 170M), which is
      // what an untagged SD stream is taken to be
      c->matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
      c->primaries = kCVImageBufferColorPrimaries_SMPTE_C;
    } else if (s == "bt2020") {
      // SDR only: the 2020 matrix and primaries, the 709 curve (which is
      // what 2020's SDR transfer is)
      c->matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
      c->primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
    } else {
      Napi::TypeError::New(env, std::string(verb) +
                                    ": colorSpace must be 'bt709', 'bt601' "
                                    "or 'bt2020'")
          .ThrowAsJavaScriptException();
      return false;
    }
  }
  if (o.Has("range") && !o.Get("range").IsUndefined()) {
    Napi::Value v = o.Get("range");
    std::string s = v.IsString() ? v.As<Napi::String>().Utf8Value() : "";
    if (s == "full") {
      c->full = true;
    } else if (s != "video") {
      Napi::TypeError::New(env, std::string(verb) +
                                    ": range must be 'video' or 'full'")
          .ThrowAsJavaScriptException();
      return false;
    }
  }
  return true;
}

void Attach(CVPixelBufferRef pb, const Colour& c) {
  CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, c.matrix,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, c.primaries,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, c.transfer,
                        kCVAttachmentMode_ShouldPropagate);
}

// sRGB, as attachments: what every bitmap this bridge draws into is, and so
// what a converted frame is matched to.
void AttachSRGB(CVPixelBufferRef pb) {
  CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_sRGB,
                        kCVAttachmentMode_ShouldPropagate);
}

// The IOSurface alone, not the CVPixelBuffer it was made through: a pixel
// buffer holds a use count on its surface for as long as it lives, so
// IOSurfaceIsInUse would answer true for a surface nothing shows, and a
// renderer could never tell which of its ring the render server let go.
// The attachments are the surface's own values by then, and a pixel buffer
// is wrapped around it again only for the call that needs one.
struct VideoSurface {
  IOSurfaceRef ios = nullptr;  // nullptr once released
  bool nv12 = true;
  size_t width = 0, height = 0;
  Colour colour;
  int64_t bytes = 0;
};

void VideoSurfaceFree(Napi::Env env, VideoSurface* s) {
  if (!s->ios) return;
  CFRelease(s->ios);
  s->ios = nullptr;
  if (s->bytes) {
    Napi::MemoryManagement::AdjustExternalMemory(env, -s->bytes);
    s->bytes = 0;
  }
}

bool IsVideoSurface(Napi::Value v) {
  return v.IsExternal() &&
         v.As<Napi::External<VideoSurface>>().CheckTypeTag(&kVideoSurfaceTag);
}

// The surface behind a handle, or nullptr with an error pending: not a
// video surface's handle, or one released.
VideoSurface* VideoSurfaceFrom(Napi::Value v, const char* verb) {
  if (!IsVideoSurface(v)) {
    Napi::TypeError::New(v.Env(), std::string(verb) +
                                      ": expected a handle from "
                                      "createVideoSurface")
        .ThrowAsJavaScriptException();
    return nullptr;
  }
  VideoSurface* s = v.As<Napi::External<VideoSurface>>().Data();
  if (!s->ios) {
    Napi::Error::New(v.Env(), std::string(verb) + ": video surface was released")
        .ThrowAsJavaScriptException();
    return nullptr;
  }
  return s;
}

// --- a frame's planes ---------------------------------------------------------

// One plane as handed over: its bytes, and how far apart its rows are.
struct Plane {
  const uint8_t* data = nullptr;
  size_t length = 0;
  size_t stride = 0;
  size_t rowBytes = 0;  // what one row holds of the picture
  size_t rows = 0;
};

// A frame of `format` at width x height: its planes out of `planes` (an
// array of Buffers or typed arrays) with `strides` (an array of numbers, or
// undefined for rows packed edge to edge), each checked to hold every row
// it claims. False, with a TypeError pending, otherwise.
bool ReadPlanes(Napi::Env env, const char* verb, Format format, size_t w,
                size_t h, Napi::Value planesV, Napi::Value stridesV,
                std::vector<Plane>* out) {
  const size_t cw = (w + 1) / 2, ch = (h + 1) / 2;
  std::vector<Plane> want;
  switch (format) {
    case Format::NV12:
      want = {{nullptr, 0, 0, w, h}, {nullptr, 0, 0, cw * 2, ch}};
      break;
    case Format::I420:
      want = {{nullptr, 0, 0, w, h}, {nullptr, 0, 0, cw, ch}, {nullptr, 0, 0, cw, ch}};
      break;
    case Format::BGRA:
      want = {{nullptr, 0, 0, w * 4, h}};
      break;
  }
  if (!planesV.IsArray() || planesV.As<Napi::Array>().Length() != want.size()) {
    Napi::TypeError::New(env, std::string(verb) + ": a " + FormatName(format) +
                                  " frame is an array of " +
                                  std::to_string(want.size()) + " plane" +
                                  (want.size() == 1 ? "" : "s"))
        .ThrowAsJavaScriptException();
    return false;
  }
  Napi::Array planes = planesV.As<Napi::Array>();
  Napi::Array strides;
  bool hasStrides = stridesV.IsArray();
  if (hasStrides) strides = stridesV.As<Napi::Array>();
  else if (!stridesV.IsUndefined() && !stridesV.IsNull()) {
    Napi::TypeError::New(env, std::string(verb) + ": strides must be an array")
        .ThrowAsJavaScriptException();
    return false;
  }
  for (uint32_t i = 0; i < want.size(); i++) {
    Plane& p = want[i];
    Napi::Value pv = planes.Get(i);
    if (pv.IsTypedArray()) {
      Napi::TypedArray t = pv.As<Napi::TypedArray>();
      p.data = (const uint8_t*)t.ArrayBuffer().Data() + t.ByteOffset();
      p.length = t.ByteLength();
    } else if (pv.IsArrayBuffer()) {
      Napi::ArrayBuffer b = pv.As<Napi::ArrayBuffer>();
      p.data = (const uint8_t*)b.Data();
      p.length = b.ByteLength();
    } else {
      Napi::TypeError::New(env, std::string(verb) + ": plane " +
                                    std::to_string(i) +
                                    " is not a Buffer or a typed array")
          .ThrowAsJavaScriptException();
      return false;
    }
    p.stride = p.rowBytes;
    if (hasStrides && i < strides.Length()) {
      Napi::Value sv = strides.Get(i);
      if (!sv.IsUndefined()) {
        double sd = sv.IsNumber() ? sv.As<Napi::Number>().DoubleValue() : -1;
        if (!(sd >= (double)p.rowBytes) || sd != (double)(size_t)sd) {
          Napi::TypeError::New(env, std::string(verb) + ": the stride of plane " +
                                        std::to_string(i) + " must be a whole number of at least " +
                                        std::to_string(p.rowBytes))
              .ThrowAsJavaScriptException();
          return false;
        }
        p.stride = (size_t)sd;
      }
    }
    size_t need = p.stride * (p.rows - 1) + p.rowBytes;
    if (p.length < need) {
      Napi::TypeError::New(env, std::string(verb) + ": plane " + std::to_string(i) +
                                    " of a " + std::to_string(w) + "x" + std::to_string(h) +
                                    " " + FormatName(format) + " frame needs " +
                                    std::to_string(need) + " bytes, and has " +
                                    std::to_string(p.length))
          .ThrowAsJavaScriptException();
      return false;
    }
  }
  *out = std::move(want);
  return true;
}

void CopyRows(uint8_t* dst, size_t dstStride, const Plane& p) {
  for (size_t y = 0; y < p.rows; y++)
    memcpy(dst + y * dstStride, p.data + y * p.stride, p.rowBytes);
}

// I420's two chroma planes into NV12's one, CbCr pairs.
void InterleaveRows(uint8_t* dst, size_t dstStride, const Plane& u, const Plane& v) {
  for (size_t y = 0; y < u.rows; y++) {
    uint8_t* d = dst + y * dstStride;
    const uint8_t* cb = u.data + y * u.stride;
    const uint8_t* cr = v.data + y * v.stride;
    for (size_t x = 0; x < u.rowBytes; x++) {
      d[2 * x] = cb[x];
      d[2 * x + 1] = cr[x];
    }
  }
}

// BGRA rows with the alpha byte set: a frame is opaque, whatever a decoder
// left in its fourth byte, and a bitmap that is premultiplied would read a
// zero there as a hole.
void CopyOpaqueRows(uint8_t* dst, size_t dstStride, const Plane& p, size_t w) {
  for (size_t y = 0; y < p.rows; y++) {
    const uint8_t* s = p.data + y * p.stride;
    uint8_t* d = dst + y * dstStride;
    for (size_t x = 0; x < w; x++) {
      uint32_t px;
      memcpy(&px, s + 4 * x, 4);
      px |= 0xff000000u;
      memcpy(d + 4 * x, &px, 4);
    }
  }
}

// --- conversion ---------------------------------------------------------------
//
// Into a bitmap, a frame has to come out the colours Core Animation shows
// for the same frame on a layer, or a video moving between the two — which
// a renderer does whenever something is drawn over it — visibly changes
// shade. Two routes, because Core Animation itself takes two:
//
// - **BT.709**, the whole of HD and the colour every decoder tags by
//   default. Core Animation linearises a surface tagged 709 throughout with
//   the exact BT.709 curve (its linear toe included), where VideoToolbox's
//   pixel transfer, Core Image and Core Animation's own matching of any
//   other tagging use a pure 1.961 gamma: a video-range grey of Y'=50 shows
//   as sRGB 55 on a layer and 44 converted. Measured on screen on macOS 15
//   (test/video-surface.js holds a ramp to it). So a 709 frame is converted
//   here: vImage's matrix for the range, then that curve into sRGB as a
//   lookup — 709's primaries are sRGB's, so nothing else changes.
// - **Anything else** (601, 2020), through VideoToolbox's pixel transfer,
//   colour-matched to sRGB, which agrees with Core Animation's matching of
//   those taggings to within a level.
//
// What still differs is gamut: a layer keeps a colour that is outside sRGB
// and shows it on a wide-gamut panel, and an 8-bit sRGB bitmap clips it, so
// a saturated frame can lose a few levels in the drawn half.

// BT.709's opto-electronic curve undone, then sRGB's applied: the 8-bit
// lookup a 709 frame's R'G'B' goes through on its way into an sRGB bitmap.
const uint8_t* Rec709ToSRGB() {
  static uint8_t table[256];
  static bool made = false;
  if (made) return table;
  for (int i = 0; i < 256; i++) {
    double v = i / 255.0;
    double l = v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45);
    double o = l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055;
    long q = lround(o * 255);
    table[i] = (uint8_t)(q < 0 ? 0 : q > 255 ? 255 : q);
  }
  made = true;
  return table;
}

bool Convert709(Napi::Env env, const char* verb, Format format, const std::vector<Plane>& planes,
                size_t w, size_t h, bool full, uint8_t* dst, size_t dstStride) {
  // vImage's ranges: bias, the span the bias is taken from, and the clamp
  vImage_YpCbCrPixelRange range = full ? vImage_YpCbCrPixelRange{0, 128, 255, 255, 255, 0, 255, 0}
                                       : vImage_YpCbCrPixelRange{16, 128, 235, 240, 235, 16, 240, 16};
  vImageYpCbCrType in = format == Format::NV12 ? kvImage420Yp8_CbCr8 : kvImage420Yp8_Cb8_Cr8;
  // made per thread and per layout and range, since the arguments differ
  thread_local vImage_YpCbCrToARGB infos[4];
  thread_local bool made[4] = {false, false, false, false};
  int slot = (format == Format::NV12 ? 0 : 2) + (full ? 1 : 0);
  if (!made[slot]) {
    if (vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
                                                      &range, &infos[slot], in, kvImageARGB8888,
                                                      kvImageNoFlags) != kvImageNoError) {
      Napi::Error::New(env, std::string(verb) + ": vImage could not make a BT.709 conversion")
          .ThrowAsJavaScriptException();
      return false;
    }
    made[slot] = true;
  }
  vImage_Buffer out = {dst, (vImagePixelCount)h, (vImagePixelCount)w, dstStride};
  vImage_Buffer y = {(void*)planes[0].data, (vImagePixelCount)h, (vImagePixelCount)w,
                     planes[0].stride};
  const size_t cw = (w + 1) / 2, ch = (h + 1) / 2;
  // ARGB out of vImage, BGRA in memory: what a premultiplied-first bitmap in
  // host byte order holds
  const uint8_t permute[4] = {3, 2, 1, 0};
  vImage_Error err;
  if (format == Format::NV12) {
    vImage_Buffer uv = {(void*)planes[1].data, (vImagePixelCount)ch, (vImagePixelCount)cw,
                        planes[1].stride};
    err = vImageConvert_420Yp8_CbCr8ToARGB8888(&y, &uv, &out, &infos[slot], permute, 255,
                                               kvImageNoFlags);
  } else {
    vImage_Buffer cb = {(void*)planes[1].data, (vImagePixelCount)ch, (vImagePixelCount)cw,
                        planes[1].stride};
    vImage_Buffer cr = {(void*)planes[2].data, (vImagePixelCount)ch, (vImagePixelCount)cw,
                        planes[2].stride};
    err = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &cb, &cr, &out, &infos[slot], permute, 255,
                                                 kvImageNoFlags);
  }
  if (err == kvImageNoError) {
    static uint8_t identity[256];
    for (int i = 0; i < 256; i++) identity[i] = (uint8_t)i;
    const uint8_t* curve = Rec709ToSRGB();
    // the table slots follow memory order, which is B, G, R, A here
    err = vImageTableLookUp_ARGB8888(&out, &out, curve, curve, curve, identity, kvImageNoFlags);
  }
  if (err != kvImageNoError) {
    Napi::Error::New(env, std::string(verb) + ": vImage could not convert the frame (" +
                              std::to_string(err) + ")")
        .ThrowAsJavaScriptException();
    return false;
  }
  return true;
}

// One per thread: a session is not safe to share across threads, and a
// worker's renderer converts on its own. Its destination is always plain
// memory (a BGRA video surface's is wrapped as bytes too): a session that
// has written into an IOSurface-backed buffer refuses
// (kVTPixelTransferNotSupportedErr) a three-plane frame into plain memory
// afterwards, and converts the same frame to other numbers.
thread_local VTPixelTransferSessionRef tlTransfer = nullptr;

VTPixelTransferSessionRef Transfer(bool fresh) {
  if (tlTransfer && fresh) {
    VTPixelTransferSessionInvalidate(tlTransfer);
    CFRelease(tlTransfer);
    tlTransfer = nullptr;
  }
  if (tlTransfer) return tlTransfer;
  if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &tlTransfer) != noErr) {
    tlTransfer = nullptr;
    return nullptr;
  }
  VTSessionSetProperty(tlTransfer, kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                       kCVImageBufferColorPrimaries_ITU_R_709_2);
  VTSessionSetProperty(tlTransfer, kVTPixelTransferPropertyKey_DestinationTransferFunction,
                       kCVImageBufferTransferFunction_sRGB);
  VTSessionSetProperty(tlTransfer, kVTPixelTransferPropertyKey_RealTime, kCFBooleanTrue);
  return tlTransfer;
}

bool ConvertMatched(Napi::Env env, const char* verb, Format format,
                    const std::vector<Plane>& planes, size_t w, size_t h, const Colour& colour,
                    uint8_t* dstData, size_t dstStride) {
  OSType type = format == Format::NV12
                    ? (colour.full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                   : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                    : (colour.full ? kCVPixelFormatType_420YpCbCr8PlanarFullRange
                                   : kCVPixelFormatType_420YpCbCr8Planar);
  size_t n = planes.size();
  void* bases[3];
  size_t widths[3], heights[3], bprs[3];
  const size_t cw = (w + 1) / 2, ch = (h + 1) / 2;
  for (size_t i = 0; i < n; i++) {
    bases[i] = (void*)planes[i].data;
    widths[i] = i == 0 ? w : cw;
    heights[i] = i == 0 ? h : ch;
    bprs[i] = planes[i].stride;
  }
  CVPixelBufferRef src = nullptr, dst = nullptr;
  CVReturn rv = CVPixelBufferCreateWithPlanarBytes(
      kCFAllocatorDefault, w, h, type, nullptr, 0, n, bases, widths, heights, bprs,
      nullptr, nullptr, nullptr, &src);
  if (rv == kCVReturnSuccess)
    rv = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                      dstData, dstStride, nullptr, nullptr, nullptr, &dst);
  if (rv != kCVReturnSuccess || !src || !dst) {
    if (src) CVPixelBufferRelease(src);
    if (dst) CVPixelBufferRelease(dst);
    Napi::Error::New(env, std::string(verb) + ": could not wrap the frame (" +
                              std::to_string(rv) + ")")
        .ThrowAsJavaScriptException();
    return false;
  }
  Attach(src, colour);
  AttachSRGB(dst);
  VTPixelTransferSessionRef session = Transfer(false);
  OSStatus st = session ? VTPixelTransferSessionTransferImage(session, src, dst) : -1;
  if (st != noErr) {
    // and once more on a session of its own, for whatever else a long-lived
    // one turns out to remember
    session = Transfer(true);
    st = session ? VTPixelTransferSessionTransferImage(session, src, dst) : -1;
  }
  CVPixelBufferRelease(src);
  CVPixelBufferRelease(dst);
  if (st != noErr) {
    Napi::Error::New(env, std::string(verb) + ": VideoToolbox could not convert the frame (" +
                              std::to_string(st) + ")")
        .ThrowAsJavaScriptException();
    return false;
  }
  return true;
}

// A YCbCr frame converted into BGRA rows at `dst`, opaque, in sRGB, the
// colours Core Animation shows it in on a layer. False with an error
// pending when the conversion was refused.
bool ConvertToBGRA(Napi::Env env, const char* verb, Format format,
                   const std::vector<Plane>& planes, size_t w, size_t h, const Colour& colour,
                   uint8_t* dst, size_t dstStride) {
  bool rec709 = CFEqual(colour.matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) &&
                CFEqual(colour.primaries, kCVImageBufferColorPrimaries_ITU_R_709_2) &&
                CFEqual(colour.transfer, kCVImageBufferTransferFunction_ITU_R_709_2);
  if (rec709) return Convert709(env, verb, format, planes, w, h, colour.full, dst, dstStride);
  return ConvertMatched(env, verb, format, planes, w, h, colour, dst, dstStride);
}

// --- verbs --------------------------------------------------------------------

Napi::Value CreateVideoSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* verb = "createVideoSurface";
  double wd = info[0].IsNumber() ? info[0].As<Napi::Number>().DoubleValue() : 0;
  double hd = info[1].IsNumber() ? info[1].As<Napi::Number>().DoubleValue() : 0;
  if (!(wd >= 1 && hd >= 1 && wd <= kMaxSide && hd <= kMaxSide) ||
      wd != (double)(size_t)wd || hd != (double)(size_t)hd) {
    Napi::TypeError::New(env, "createVideoSurface(width, height, options): width and "
                              "height are whole numbers of pixels, 1 to 16384")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  size_t w = (size_t)wd, h = (size_t)hd;
  Format format = Format::NV12;
  Colour colour;
  if (info.Length() > 2 && info[2].IsObject()) {
    Napi::Object o = info[2].As<Napi::Object>();
    if (o.Has("format") && !o.Get("format").IsUndefined() &&
        (!ParseFormat(o.Get("format"), &format) || format == Format::I420)) {
      Napi::TypeError::New(env, "createVideoSurface: format must be 'NV12' or 'BGRA' "
                                "(an I420 frame is written into an NV12 surface)")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    if (!ParseColour(env, verb, o, &colour)) return env.Undefined();
  }
  bool nv12 = format == Format::NV12;
  OSType type = nv12 ? (colour.full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                     : kCVPixelFormatType_32BGRA;
  NSDictionary* attrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferPixelFormatTypeKey : @(type),
  };
  CVPixelBufferRef pb = nullptr;
  CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault, w, h, type,
                                    (__bridge CFDictionaryRef)attrs, &pb);
  IOSurfaceRef ios = pb ? CVPixelBufferGetIOSurface(pb) : nullptr;
  if (rv != kCVReturnSuccess || !ios) {
    if (pb) CVPixelBufferRelease(pb);
    Napi::Error::New(env, "createVideoSurface: CVPixelBufferCreate failed (" +
                              std::to_string(rv) + ")")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  // black, so a surface shown before its first frame shows no garbage
  CVPixelBufferLockBaseAddress(pb, 0);
  if (nv12) {
    uint8_t* y = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    memset(y, colour.full ? 0 : 16, CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * h);
    uint8_t* uv = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * ((h + 1) / 2));
  } else {
    uint8_t* p = (uint8_t*)CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    for (size_t r = 0; r < h; r++) {
      uint32_t* row = (uint32_t*)(p + r * bpr);
      for (size_t x = 0; x < w; x++) row[x] = 0xff000000u;
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, 0);
  if (nv12) {
    Attach(pb, colour);
  } else {
    // what is written into it is what an sRGB bitmap holds
    AttachSRGB(pb);
    CALNameSurfaceSRGB(ios, false);
  }
  CFRetain(ios);
  CVPixelBufferRelease(pb);
  auto* s = new VideoSurface();
  s->ios = ios;
  s->nv12 = nv12;
  s->width = w;
  s->height = h;
  s->colour = colour;
  s->bytes = (int64_t)IOSurfaceGetAllocSize(ios);
  Napi::MemoryManagement::AdjustExternalMemory(env, s->bytes);
  auto handle = Napi::External<VideoSurface>::New(env, s, [](Napi::Env e, VideoSurface* d) {
    VideoSurfaceFree(e, d);
    delete d;
  });
  handle.TypeTag(&kVideoSurfaceTag);
  Napi::Object out = Napi::Object::New(env);
  out.Set("handle", handle);
  out.Set("iosurfaceId", (double)IOSurfaceGetID(ios));
  return out;
}

Napi::Value WriteVideoSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  const char* verb = "writeVideoSurface";
  Format format;
  if (!ParseFormat(info[1], &format)) {
    Napi::TypeError::New(env, "writeVideoSurface(target, format, planes, options): format "
                              "must be 'NV12', 'I420' or 'BGRA'")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  Napi::Object opts = info.Length() > 3 && info[3].IsObject() ? info[3].As<Napi::Object>()
                                                              : Napi::Object::New(env);
  Napi::Value strides = opts.Has("strides") ? opts.Get("strides") : env.Undefined();
  bool yuv = format != Format::BGRA;

  if (IsVideoSurface(info[0])) {
    VideoSurface* s = VideoSurfaceFrom(info[0], verb);
    if (!s) return env.Undefined();
    if (s->nv12 && !yuv) {
      Napi::TypeError::New(env, "writeVideoSurface: an NV12 surface takes an NV12 or I420 "
                                "frame, not BGRA — make the surface with format 'BGRA'")
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    std::vector<Plane> planes;
    if (!ReadPlanes(env, verb, format, s->width, s->height, info[2], strides, &planes))
      return env.Undefined();
    if (!s->nv12 && yuv) {
      // into a BGRA surface: converted, in the frame's own colour
      Colour colour;
      if (!ParseColour(env, verb, opts, &colour)) return env.Undefined();
      IOSurfaceLock(s->ios, 0, nullptr);
      ConvertToBGRA(env, verb, format, planes, s->width, s->height, colour,
                    (uint8_t*)IOSurfaceGetBaseAddress(s->ios), IOSurfaceGetBytesPerRow(s->ios));
      IOSurfaceUnlock(s->ios, 0, nullptr);
      return env.Undefined();
    }
    IOSurfaceLock(s->ios, 0, nullptr);
    if (!s->nv12) {
      CopyOpaqueRows((uint8_t*)IOSurfaceGetBaseAddress(s->ios),
                     IOSurfaceGetBytesPerRow(s->ios), planes[0], s->width);
    } else {
      CopyRows((uint8_t*)IOSurfaceGetBaseAddressOfPlane(s->ios, 0),
               IOSurfaceGetBytesPerRowOfPlane(s->ios, 0), planes[0]);
      uint8_t* uv = (uint8_t*)IOSurfaceGetBaseAddressOfPlane(s->ios, 1);
      size_t bpr = IOSurfaceGetBytesPerRowOfPlane(s->ios, 1);
      if (format == Format::NV12) CopyRows(uv, bpr, planes[1]);
      else InterleaveRows(uv, bpr, planes[1], planes[2]);
    }
    IOSurfaceUnlock(s->ios, 0, nullptr);
    return env.Undefined();
  }

  // a 2D surface: the frame at its top-left corner, `width` x `height` of it
  CALSurfaceBits bits;
  if (!CALSurfaceBitmap(info[0], &bits)) return env.Undefined();
  size_t w = bits.width, h = bits.height;
  for (const char* key : {"width", "height"}) {
    if (!opts.Has(key) || opts.Get(key).IsUndefined()) continue;
    Napi::Value v = opts.Get(key);
    double d = v.IsNumber() ? v.As<Napi::Number>().DoubleValue() : 0;
    size_t limit = key[0] == 'w' ? bits.width : bits.height;
    if (!(d >= 1 && d <= (double)limit) || d != (double)(size_t)d) {
      Napi::TypeError::New(env, std::string("writeVideoSurface: ") + key +
                                    " must be a whole number of pixels, at most the "
                                    "surface's " + std::to_string(limit))
          .ThrowAsJavaScriptException();
      return env.Undefined();
    }
    (key[0] == 'w' ? w : h) = (size_t)d;
  }
  std::vector<Plane> planes;
  if (!ReadPlanes(env, verb, format, w, h, info[2], strides, &planes)) return env.Undefined();
  if (!yuv) {
    CopyOpaqueRows(bits.data, bits.bytesPerRow, planes[0], w);
    return env.Undefined();
  }
  Colour colour;
  if (!ParseColour(env, verb, opts, &colour)) return env.Undefined();
  ConvertToBGRA(env, verb, format, planes, w, h, colour, bits.data, bits.bytesPerRow);
  return env.Undefined();
}

Napi::Value VideoSurfaceIsInUse(const Napi::CallbackInfo& info) {
  VideoSurface* s = VideoSurfaceFrom(info[0], "videoSurfaceIsInUse");
  if (!s) return info.Env().Undefined();
  return Napi::Boolean::New(info.Env(), IOSurfaceIsInUse(s->ios));
}

// Free the surface now rather than when the collector reaches the handle.
// A layer showing it keeps it alive until the layer lets it go. Idempotent.
Napi::Value ReleaseVideoSurface(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (!IsVideoSurface(info[0])) {
    Napi::TypeError::New(env, "releaseVideoSurface: expected a handle from createVideoSurface")
        .ThrowAsJavaScriptException();
    return env.Undefined();
  }
  VideoSurfaceFree(env, info[0].As<Napi::External<VideoSurface>>().Data());
  return env.Undefined();
}

Napi::Value VideoFormats(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Object out = Napi::Object::New(env);
  Napi::Array surfaces = Napi::Array::New(env, 2);
  surfaces.Set(0u, "NV12");
  surfaces.Set(1u, "BGRA");
  Napi::Array frames = Napi::Array::New(env, 3);
  frames.Set(0u, "NV12");
  frames.Set(1u, "I420");
  frames.Set(2u, "BGRA");
  out.Set("surfaces", surfaces);
  out.Set("frames", frames);
  return out;
}

}  // namespace

void InitVideo(Napi::Env env, Napi::Object exports) {
  exports.Set("createVideoSurface", Napi::Function::New(env, CreateVideoSurface));
  exports.Set("writeVideoSurface", Napi::Function::New(env, WriteVideoSurface));
  exports.Set("videoSurfaceIsInUse", Napi::Function::New(env, VideoSurfaceIsInUse));
  exports.Set("releaseVideoSurface", Napi::Function::New(env, ReleaseVideoSurface));
  exports.Set("videoFormats", Napi::Function::New(env, VideoFormats));
}
