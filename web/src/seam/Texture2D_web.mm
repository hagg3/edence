// Texture2D_web.mm — Stage P2 seam replacement for Classes/Texture2D.mm.
//
// WHY THIS FILE REUSES THE ORIGINAL HEADER: Classes/Texture2D.h is `#import "Texture2D.h"`'d
// (quoted) by 8 non-seam ENGINE headers this port must not edit (Graphics.h, Menu.h, Resources.h,
// SettingsMenu.h, Util.h, SharedList.h, Terrain.h, World.h — grep-verified pass 2). Quoted
// includes resolve relative to the including file first, so those headers always see the real,
// untouched Classes/Texture2D.h. This file supplies a NEW @implementation-equivalent (Texture2D
// is a plain C++ class, not Objective-C) of that SAME interface — same pattern as
// EAGLView_web.mm's header comment describes.
//
// WHAT THIS FILE OWES, measured against the real 1555-line Texture2D.mm (PORT-STATUS.md "Pass
// 10"): Texture2D is the engine's immediate-mode quad drawer for ALL 2D/UI/sky — every menu
// button, HUD icon, and the sky backdrop draws through one of the `draw*` methods below. Two
// clean halves:
//   1. THE DRAW METHODS are pure GL (client arrays + glBindTexture + glDrawArrays) and are near-
//      verbatim ports — the ES1 state-pairing risk that made Stage P2 "Opus" lived in the GL shim
//      (gl_es1_shim.cpp GROUP 2d), not here, and that shim is done and browser-verified.
//   2. THE PIXEL SOURCE is the real work this file does: initFromPath decodes PNGs via stb_image
//      instead of UIImage/CGBitmapContext, replicating initFromImage's pow-of-two padding, the
//      upside-down-texture flip (Texture2D.h's own doc comment: "content will be upside-down"),
//      and the per-pixel-format packing (RGB565/RGBA4444/RGBA5551/RGB888) bit-for-bit.
//
// DELIBERATELY NOT PORTED (P2b, later — see RESUME-HERE.md/PORT-STATUS.md "Pass 10"):
//   - initFromImage(CGImageRef, ...) / ManipulateImagePixelData(2) — the creature skin/mask tint
//     pipeline. Grep confirms every real (non-commented) call site is Resources.mm's recolor
//     path, reached only once a creature model loads — not on the menu-frame path, and gated on
//     Model.mm's separate CPU-skinning rewrite anyway (RESUME-HERE.md Task 4's "GL_OES_matrix_
//     palette" note). Left as inert stubs (mirrors what seam_link_stubs.mm had); UIImage's own
//     methods already return nil (uikit_stubs.mm), so this path is a no-op end to end today, not
//     a crash.
//   - initFromString / the `(NSString*, CGSize, UITextAlignment, UIFont*)` text-rasterizing
//     constructor. CORRECTION (see PORT-STATUS.md "Owed/open" + RESUME-HERE pass 35): the old
//     claim here — "confirmed dead code, only call site is the commented-out Graphics::drawText"
//     — was wrong. statusbar.mm's `setStatus` calls `new Texture2D(status, ...)` directly (the
//     world-name label under the menu's world picker, and SharedList.mm's world/date labels), and
//     that path is very much live. Implemented below via an HTML canvas 2D context (EM_JS) rather
//     than stb_truetype, since Emscripten gives this port a real DOM to rasterize with.
//   - storedSkins/storedMasks/storedDoor/... bookkeeping (Texture2D.mm's `if(storeImage)` block):
//     these UIImage* globals are DEFINED in Resources.mm (not here) and read back only by the
//     same deferred recolor path above, so leaving them unpopulated (always nullptr, their C++
//     default) is consistent with "recolor pipeline is a no-op for now" — not a separate gap.

// printg is normally supplied by the force-included Eden_Prefix.pch (engine .mm sources only,
// per CMakeLists.txt's COMPILE_OPTIONS) — this seam file isn't in that list, so it needs its own
// definition before OpenGL_Internal.h's REPORT_ERROR/CHECK_GL_ERROR macros can use it. Matches
// the pch's __DEBUG__ branch (`printg(...) printf(__VA_ARGS__)`) unconditionally.
#define printg(...) printf(__VA_ARGS__)

#import <OpenGLES/ES1/glext.h>   // matches Texture2D.mm's own top-of-file include
// The PVRTC compressed-format tokens are deliberately NOT in this port's glext.h trampoline
// (see src/shim/gl/framework/OpenGLES/ES1/glext.h's header comment — no engine, non-PVRT file
// was believed to need them). initData()'s switch statement below still needs them to name the
// cases even though this port never actually feeds it PVRTC data (assets are plain PNGs decoded
// by stb_image) — Khronos-canonical values, so nothing to renumber if PVRTC decode is ever added.
#ifndef GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG
#define GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG  0x8C00
#define GL_COMPRESSED_RGB_PVRTC_2BPPV1_IMG  0x8C01
#define GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG 0x8C02
#define GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG 0x8C03
#endif
#import "../../../Classes/Texture2D.h"
#import "../../../Classes/OpenGL_Internal.h"
#import "../../../Classes/Globals.h"
#import "../../../Classes/World.h"
#import "../shim/foundation/uikit_stubs.h"
#include "../shim/foundation/NSBundle.h"
#include "../shim/foundation/NSFileManager.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO   // we read the file ourselves (Emscripten preload FS is real POSIX, but
                         // going through NSData keeps one file-reading code path in the port)
#include "stb_image.h"

#include <emscripten/emscripten.h>

#include <cstdlib>
#include <cstring>
#include <algorithm>

// Texture2D.mm's kMaxTextureSize is a private #define local to that .mm, not in the header —
// redeclared here under a distinct name to avoid any accidental collision if that header ever
// changes.
static const int kMaxTextureSize_Eden = 1024;

// =============================================================================================
// initData — UNCHANGED FROM THE ENGINE. This constructor pair takes already-decoded raw pixels
// and is inline in the unmodified Texture2D.h... except initData() itself (the actual GL upload)
// is defined in the .mm, so it is ported here VERBATIM (byte-for-byte identical to
// Classes/Texture2D.mm's initData) — pure GL, no CoreGraphics, nothing to translate.
// =============================================================================================
void Texture2D::initData(const void* data, Texture2DPixelFormat pixelFormat, int width, int height,
                          CGSize size, BOOL genMips) {
    GLint saveName;

    glGenTextures(1, &name);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &saveName);
    glBindTexture(GL_TEXTURE_2D, name);
    if (genMips) {
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_GENERATE_MIPMAP, GL_TRUE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    } else {
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_GENERATE_MIPMAP, GL_TRUE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }

    switch (pixelFormat) {
        case kTexture2DPixelFormat_RGBA8888:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
            break;
        case kTexture2DPixelFormat_RGBA4444:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_SHORT_4_4_4_4, data);
            break;
        case kTexture2DPixelFormat_RGBA5551:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_SHORT_5_5_5_1, data);
            break;
        case kTexture2DPixelFormat_RGB565:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, width, height, 0, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, data);
            break;
        case kTexture2DPixelFormat_RGB888:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, width, height, 0, GL_RGB, GL_UNSIGNED_BYTE, data);
            break;
        case kTexture2DPixelFormat_L8:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, width, height, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, data);
            break;
        case kTexture2DPixelFormat_A8:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, width, height, 0, GL_ALPHA, GL_UNSIGNED_BYTE, data);
            break;
        case kTexture2DPixelFormat_LA88:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE_ALPHA, width, height, 0, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, data);
            break;
        case kTexture2DPixelFormat_RGB_PVRTC2:
            glCompressedTexImage2D(GL_TEXTURE_2D, 0, GL_COMPRESSED_RGB_PVRTC_2BPPV1_IMG, width, height, 0, (width * height) / 4, data);
            break;
        case kTexture2DPixelFormat_RGB_PVRTC4:
            glCompressedTexImage2D(GL_TEXTURE_2D, 0, GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG, width, height, 0, (width * height) / 2, data);
            break;
        case kTexture2DPixelFormat_RGBA_PVRTC2:
            glCompressedTexImage2D(GL_TEXTURE_2D, 0, GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG, width, height, 0, (width * height) / 4, data);
            break;
        case kTexture2DPixelFormat_RGBA_PVRTC4:
            glCompressedTexImage2D(GL_TEXTURE_2D, 0, GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG, width, height, 0, (width * height) / 2, data);
            break;
        default:
            [NSException raise:NSInternalInconsistencyException format:@""];
    }
    glBindTexture(GL_TEXTURE_2D, saveName);

    if (!CHECK_GL_ERROR()) {
        printf("err initing texture\n");
        return;
    }

    _size = size;
    _width = width;
    _height = height;
    _format = pixelFormat;
    _maxS = size.width / (float)width;
    _maxT = size.height / (float)height;
}

Texture2D::Texture2D(const void* data, Texture2DPixelFormat pixelFormat, int width, int height, CGSize size) {
    initData(data, pixelFormat, width, height, size, FALSE);
}
Texture2D::Texture2D(const void* data, Texture2DPixelFormat pixelFormat, int width, int height, CGSize size, BOOL genMips) {
    initData(data, pixelFormat, width, height, size, genMips);
}

Texture2D::~Texture2D() {
    if (name) glDeleteTextures(1, &name);
}

NSString* Texture2D::description() {
    return [NSString stringWithFormat:@"< Texture2D| Name = %i | Dimensions = %ix%i | Coordinates = (%.2f, %.2f)>",
            name, (int)_width, (int)_height, (double)_maxS, (double)_maxT];
}

// =============================================================================================
// PNG decode (stb_image) + the pow-of-two/flip/format-pack pipeline, replacing initFromImage's
// CGBitmapContext version. Ported for behavior, not byte-for-byte, because CGBitmapContext's
// premultiplied-ARGB-big-endian dance is a CoreGraphics implementation detail our stb_image
// buffer (tightly-packed RGBA8, top-left origin) never has in the first place.
// =============================================================================================
namespace {

// Loads `path` via stb_image, forcing 4 channels (RGBA8) so every downstream format-pack case
// has one uniform source layout. `outHasAlpha` reports the image's REAL channel count (stb still
// tells us via `comp` even when we force 4) — needed to reproduce initFromImage's "Automatic"
// pixel-format choice (RGBA8888 if the source had alpha, RGB565 if not).
unsigned char* EdenLoadPNG(NSString* path, int* outW, int* outH, BOOL* outHasAlpha) {
    NSData* fileData = [NSData dataWithContentsOfFile:path];
    if (!fileData || [fileData length] == 0) {
        // Pass 12/13: this branch previously had NO diagnostic, unlike the stb-decode-failure
        // branch below — and a browser run showed draws succeeding (glErr=0, textured=N/N) with
        // a still-black canvas. Prime suspect: this branch is firing silently (path resolution
        // wrong, or the preloaded FS doesn't contain what NSBundle's index thinks it does), name
        // stays 0, every draw binds "no texture", and WebGL samples an unbound/incomplete
        // texture as opaque black (spec-defined) — indistinguishable from the black clear color.
        // The "textured=N/N" debug counter (gl_es1_shim.cpp) only checks GL_TEXTURE_2D-enabled +
        // texcoords-enabled, NOT that the bound texture name is nonzero — so it cannot catch
        // this. TODO next session: if this prints, the bug is path resolution
        // (NSBundle.mm/CMakeLists.txt preload paths); if it does NOT print, decode is reaching
        // stb_image and the black canvas has a different cause (see RESUME-HERE.md).
        printg("Texture2D_web: no data at '%s' (NSData load failed or empty)\n", [path UTF8String]);
        return nullptr;
    }
    int comp = 0;
    unsigned char* pixels = stbi_load_from_memory(
        (const unsigned char*)[fileData bytes], (int)[fileData length], outW, outH, &comp, 4);
    if (!pixels) {
        printg("Texture2D_web: stb_image failed to decode '%s': %s\n",
               [path UTF8String], stbi_failure_reason());
        return nullptr;
    }
    if (outHasAlpha) *outHasAlpha = (comp == 4 || comp == 2) ? YES : NO;
    return pixels;
}

// Same power-of-two rounding rule as the engine's own (Texture2D.mm initFromImage): a dimension
// that is ALREADY a power of two (or exactly 1) is left untouched — only a non-power-of-two
// dimension gets rounded, and sizeToFit changes the rounding target from "next pow2 >= v" to
// "next pow2 such that 2x it >= v" (i.e. one power looser, so scaling up to fill loses less).
int EdenRoundDimension(int v, BOOL sizeToFit) {
    if (v == 1 || (v & (v - 1)) == 0) return v; // already a power of two (or 1): unchanged
    int i = 1;
    while ((sizeToFit ? 2 * i : i) < v) i *= 2;
    return i;
}

}  // namespace

void Texture2D::initFromImage(CGImageRef image, UIImageOrientation orientation, BOOL sizeToFit,
                               Texture2DPixelFormat pixelFormat, BOOL genMips) {
    // Deferred to P2b — see this file's header comment. Every real call site is the creature
    // skin/mask recolor path in Resources.mm, unreached until Model.mm's CPU-skinning rewrite
    // lands (RESUME-HERE.md Task 4).
    (void)image; (void)orientation; (void)sizeToFit; (void)pixelFormat; (void)genMips;
}
Texture2D::Texture2D(CGImageRef image, UIImageOrientation orientation, BOOL sizeToFit,
                     Texture2DPixelFormat pixelFormat, BOOL genMips) {
    initFromImage(image, orientation, sizeToFit, pixelFormat, genMips);
}

// Rasterizes `textC` into an RGBA8 buffer at `outPtr` (width*height*4 bytes, caller-owned,
// pre-zeroed so a headless/no-canvas environment degrades to a blank/transparent texture rather
// than garbage). Row 0 = top, matching this port's "no V-flip" convention established in
// initFromPath above (see its comment: GL's V=0 is the image's top row everywhere in this port) —
// a plain 2D canvas draws top-down already, so unlike the real engine's CGContext version (which
// has to flip because NSString draws in the UIKit referential) no flip is needed here.
EM_JS(void, eden_rasterize_text_rgba, (const char* textC, int width, int height, float fontPx,
                                        int align, unsigned char* outPtr), {
  if (typeof document === 'undefined' && typeof OffscreenCanvas === 'undefined') return;
  var text = UTF8ToString(textC);
  var canvas = (typeof document !== 'undefined')
      ? document.createElement('canvas')
      : new OffscreenCanvas(width, height);
  canvas.width = width;
  canvas.height = height;
  var ctx = canvas.getContext('2d');
  if (!ctx) return;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = '#fff';
  ctx.font = fontPx + 'px sans-serif';
  ctx.textBaseline = 'middle';
  var x;
  if (align === 1) { ctx.textAlign = 'center'; x = width / 2; }
  else if (align === 2) { ctx.textAlign = 'right'; x = width; }
  else { ctx.textAlign = 'left'; x = 0; }
  ctx.fillText(text, x, height / 2);
  var img = ctx.getImageData(0, 0, width, height).data;
  HEAPU8.set(img, outPtr);
});

// Real call sites (NOT dead code — the header comment above this method used to claim the only
// caller was the commented-out Graphics::drawText; that's wrong, statusbar.mm's
// `new Texture2D(status, ...)` calls this directly, and that's what draws the world-name label
// under the menu's world picker and SharedList.mm's world/date labels). Ported for BEHAVIOR, not
// byte-for-byte: the real engine rasterizes via CGBitmapContext + NSString drawInRect; this port
// rasterizes via an HTML canvas 2D context (EM_JS above). Same POT-rounding/pixel-format/
// initData contract as the image path.
void Texture2D::initFromString(NSString* string, CGSize dimensions, UITextAlignment alignment, UIFont* font) {
    if (font == nil) {
        REPORT_ERROR(@"Invalid font", NULL);
        return;
    }
    int width = (int)dimensions.width;
    if (width != 1 && (width & (width - 1))) {
        int i = 1;
        while (i < width) i *= 2;
        width = i;
    }
    if (width > kMaxTextureSize_Eden) width = kMaxTextureSize_Eden;
    int height = (int)dimensions.height;
    if (height != 1 && (height & (height - 1))) {
        int i = 1;
        while (i < height) i *= 2;
        height = i;
    }
    if (height > kMaxTextureSize_Eden) height = kMaxTextureSize_Eden;
    if (width <= 0 || height <= 0) return;

    unsigned char* data = (unsigned char*)calloc((size_t)width * height * 4, 1);
    eden_rasterize_text_rgba([string UTF8String], width, height, [font pointSize], (int)alignment, data);

    initData(data, kTexture2DPixelFormat_RGBA8888, width, height, dimensions, FALSE);
    free(data);
}
Texture2D::Texture2D(NSString* string, CGSize dimensions, UITextAlignment alignment, UIFont* font) {
    initFromString(string, dimensions, alignment, font);
}

Texture2D::Texture2D(NSString* path) { initFromPath(path, NO, kTexture2DPixelFormat_Automatic, FALSE); }
Texture2D::Texture2D(NSString* path, BOOL sizeToFit, BOOL genMips) { initFromPath(path, sizeToFit, kTexture2DPixelFormat_Automatic, genMips); }
Texture2D::Texture2D(NSString* path, BOOL sizeToFit) { initFromPath(path, sizeToFit, kTexture2DPixelFormat_Automatic, FALSE); }
Texture2D::Texture2D(NSString* path, BOOL sizeToFit, Texture2DPixelFormat pixelFormat, BOOL genMips) { initFromPath(path, sizeToFit, pixelFormat, genMips); }

void Texture2D::initFromPath(NSString* path, BOOL sizeToFit, Texture2DPixelFormat pixelFormat, BOOL genMips) {
    // ipad~ retina-variant probe — real engine behavior (Texture2D.mm), kept because
    // NSFileManager/NSBundle are both real (POSIX-backed) in this port, so the check is
    // meaningful: if a preloaded ipad~ variant exists, prefer it.
    if (IS_IPAD || SUPPORTS_RETINA) {
        NSString* oipadPath = [NSString stringWithFormat:@"ipad~%@", path];
        NSString* ipadPath = [[NSBundle mainBundle] pathForResource:oipadPath ofType:nil];
        if ([[NSFileManager defaultManager] fileExistsAtPath:ipadPath]) {
            path = oipadPath;
        }
    }
    if (![path isAbsolutePath]) {
        path = [[NSBundle mainBundle] pathForResource:path ofType:nil];
    }

    int srcW = 0, srcH = 0;
    BOOL hasAlpha = NO;
    unsigned char* src = EdenLoadPNG(path, &srcW, &srcH, &hasAlpha);
    if (!src) {
        // Matches the engine's own silent-failure shape (Texture2D.mm: uiImage may be nil,
        // initFromImage(NULL, ...) just returns) — `name` stays 0, which every draw call already
        // treats as "nothing to bind" via the destructor's `if(name)` guard. TODO P2: surface a
        // missing-asset warning path once art packaging (CMakeLists.txt's --preload-file set) is
        // believed complete; right now silent-missing is expected during bring-up.
        return;
    }

    if (pixelFormat == kTexture2DPixelFormat_Automatic) {
        pixelFormat = hasAlpha ? kTexture2DPixelFormat_RGBA8888 : kTexture2DPixelFormat_RGB565;
    }

    CGSize imageSize = CGSizeMake((float)srcW, (float)srcH);
    int width = EdenRoundDimension(srcW, sizeToFit);
    int height = EdenRoundDimension(srcH, sizeToFit);
    // Oversized cap: proportional halving (not a hard clamp to kMaxTextureSize_Eden), matching
    // Texture2D.mm's `while((width>kMax)||(height>kMax)){width/=2;height/=2;...}` — rare in
    // practice (every current UI/atlas asset is well under 1024) but kept for fidelity.
    while (width > kMaxTextureSize_Eden || height > kMaxTextureSize_Eden) {
        width /= 2;
        height /= 2;
    }

    // Build the RGBA8 canvas at (width, height): sizeToFit scales the source to fill it exactly
    // (nearest-neighbour — the engine's own GL_NEAREST_MIPMAP_LINEAR filtering dominates visually
    // over the resample method, and every sizeToFit=TRUE caller in this engine is UI/icon art at
    // sizes where the difference is not visible); otherwise the source is placed at the top-left
    // with the rest left transparent, matching CGContextClearRect + CGContextTranslateCTM(0,
    // height-imageSize.height) in the original — net effect: image anchored to the texture's
    // TOP edge, remaining rows below it clear.
    //
    // Rows are copied in SOURCE ORDER (no V flip). initFromImage in the original (Texture2D.mm
    // :970-979) does NOT flip: it only translates to anchor at the top, so bitmap row 0 is the
    // image's top row and GL's V=0 lands on the image top. That IS the "upside-down" convention
    // Texture2D.h documents, and every texcoord in the engine is authored against it. The only
    // flipped CTM in the original is in the TEXT path (Texture2D.mm:1111), where the comment
    // spells out that it exists solely because NSString draws in the UIKit referential.
    // This used to flip (dstY = height-1-y), which inverted the 32-tile block atlas through the
    // glScalef(1,1/32,1) texture matrix in Terrain.mm:2597 — tile row r sampled row 31-r, so every
    // block drew a coherent but wrong texture (colors were unaffected, which masked the cause).
    unsigned char* canvas = (unsigned char*)calloc((size_t)width * height * 4, 1);
    for (int y = 0; y < height; ++y) {
        int srcY;
        if (sizeToFit) {
            srcY = (int)((float)y * srcH / (float)height);
            if (srcY >= srcH) srcY = srcH - 1;
        } else {
            srcY = y; // top-left anchor; rows beyond srcH stay transparent (calloc'd)
            if (srcY >= srcH) continue;
        }
        unsigned char* dstRow = canvas + (size_t)y * width * 4;
        for (int x = 0; x < width; ++x) {
            int srcX;
            if (sizeToFit) {
                srcX = (int)((float)x * srcW / (float)width);
                if (srcX >= srcW) srcX = srcW - 1;
            } else {
                srcX = x;
                if (srcX >= srcW) { continue; }
            }
            const unsigned char* s = src + ((size_t)srcY * srcW + srcX) * 4;
            unsigned char* d = dstRow + (size_t)x * 4;
            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];
        }
    }
    stbi_image_free(src);

    // Per-pixel-format packing — bit patterns copied verbatim from Texture2D.mm's initFromImage
    // (RGBA8888 source assumed there too, just produced by CGBitmapContext instead of stb_image).
    void* finalData = canvas;
    void* toFree = canvas;
    size_t pixCount = (size_t)width * height;
    if (pixelFormat == kTexture2DPixelFormat_RGB888) {
        unsigned char* out = (unsigned char*)malloc(pixCount * 3);
        const unsigned char* in = canvas;
        for (size_t i = 0; i < pixCount; ++i) { out[i*3]=in[i*4]; out[i*3+1]=in[i*4+1]; out[i*3+2]=in[i*4+2]; }
        finalData = out;
    } else if (pixelFormat == kTexture2DPixelFormat_RGB565) {
        unsigned short* out = (unsigned short*)malloc(pixCount * 2);
        const unsigned char* in = canvas;
        for (size_t i = 0; i < pixCount; ++i) {
            unsigned char r = in[i*4], g = in[i*4+1], b = in[i*4+2];
            out[i] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
        }
        finalData = out;
    } else if (pixelFormat == kTexture2DPixelFormat_RGBA4444) {
        unsigned short* out = (unsigned short*)malloc(pixCount * 2);
        const unsigned char* in = canvas;
        for (size_t i = 0; i < pixCount; ++i) {
            unsigned char r = in[i*4], g = in[i*4+1], b = in[i*4+2], a = in[i*4+3];
            out[i] = ((r >> 4) << 12) | ((g >> 4) << 8) | ((b >> 4) << 4) | (a >> 4);
        }
        finalData = out;
    } else if (pixelFormat == kTexture2DPixelFormat_RGBA5551) {
        unsigned short* out = (unsigned short*)malloc(pixCount * 2);
        const unsigned char* in = canvas;
        for (size_t i = 0; i < pixCount; ++i) {
            unsigned char r = in[i*4], g = in[i*4+1], b = in[i*4+2], a = in[i*4+3];
            out[i] = ((r >> 3) << 11) | ((g >> 3) << 6) | ((b >> 3) << 1) | (a >> 7);
        }
        finalData = out;
    } else if (pixelFormat == kTexture2DPixelFormat_LA88) {
        unsigned char* out = (unsigned char*)malloc(pixCount * 2);
        const unsigned char* in = canvas;
        for (size_t i = 0; i < pixCount; ++i) { out[i*2]=in[i*4]; out[i*2+1]=in[i*4+3]; }
        finalData = out;
    } else if (pixelFormat == kTexture2DPixelFormat_L8) {
        unsigned char* out = (unsigned char*)malloc(pixCount);
        const unsigned char* in = canvas;
        for (size_t i = 0; i < pixCount; ++i) out[i] = in[i*4];
        finalData = out;
    } else if (pixelFormat == kTexture2DPixelFormat_A8) {
        unsigned char* out = (unsigned char*)malloc(pixCount);
        const unsigned char* in = canvas;
        for (size_t i = 0; i < pixCount; ++i) out[i] = in[i*4+3];
        finalData = out;
    }
    // else RGBA8888: canvas is already exactly that layout, used as-is.

    // Pass 13: one-time-per-texture diagnostic (not per-frame — ~120 assets total, cheap even
    // under printg's stdio path). A browser run showed draws succeeding (glErr=0, textured=N/N)
    // with a still-black canvas, and Pass 13's other diagnostics ruled out "no data reached
    // stb_image" for the menu-critical assets. This is the next rung down the stack: confirm the
    // DECODED pixels are plausible (nonzero, not uniformly transparent) before suspecting GL
    // state. `canvas` (pre-format-pack, always RGBA8) is sampled at its center so padding at the
    // edges (non-sizeToFit loads narrower than their pow2 canvas) can't produce a false negative.
    {
        size_t cx = (size_t)(width / 2), cy = (size_t)(height / 2);
        const unsigned char* p = canvas + (cy * width + cx) * 4;
        printg("Texture2D_web: '%s' decoded %dx%d (canvas %dx%d) fmt=%d center-rgba=(%d,%d,%d,%d)\n",
               [path UTF8String], srcW, srcH, width, height, (int)pixelFormat, p[0], p[1], p[2], p[3]);
    }

    initData(finalData, pixelFormat, width, height, imageSize, genMips);

    if (finalData != toFree) free(finalData);
    free(toFree);
}

// =============================================================================================
// Draw methods — mechanical, near-verbatim ports (client arrays + glBindTexture + glDrawArrays,
// all already handled by gl_es1_shim.cpp GROUP 2d). Byte-for-byte identical control flow to
// Classes/Texture2D.mm; only whitespace differs.
// =============================================================================================
void Texture2D::drawTexture(Texture2D* texture, CGPoint point, CGFloat depth) {
    GLfloat maxS = texture->_maxS, maxT = texture->_maxT,
            pixelsWide = texture->_width, pixelsHigh = texture->_height;
    GLfloat coordinates[] = { 0, maxT, maxS, maxT, 0, 0, maxS, 0 };
    GLfloat width = (GLfloat)pixelsWide * maxS, height = (GLfloat)pixelsHigh * maxT;
    GLfloat vertices[] = {
        -width / 2 + point.x, -height / 2 + point.y, depth,
         width / 2 + point.x, -height / 2 + point.y, depth,
        -width / 2 + point.x,  height / 2 + point.y, depth,
         width / 2 + point.x,  height / 2 + point.y, depth
    };
    glBindTexture(GL_TEXTURE_2D, texture->name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::preload() {
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();
    drawInRect(CGRectMake(-2, -2, 0.1, 0.1));
    glPopMatrix();
    glMatrixMode(GL_PROJECTION);
    glPopMatrix();
}

void Texture2D::drawAtPoint(CGPoint point) { drawAtPoint(point, 0.0, FALSE); }

void Texture2D::drawAtPoint(CGPoint point, CGFloat depth, BOOL center) {
    GLfloat coordinates[] = { 0, _maxT, _maxS, _maxT, 0, 0, _maxS, 0 };
    GLfloat width = (GLfloat)_width * _maxS, height = (GLfloat)_height * _maxT;
    // Both branches vertically center on point.y; only the horizontal anchor differs
    // (center: point.x is the midpoint; !center: point.x is the left edge) — matches the
    // original's separate cvertices/zvertices arrays exactly.
    GLfloat cvertices[] = {
        -width / 2 + point.x, -height / 2 + point.y, depth,
         width / 2 + point.x, -height / 2 + point.y, depth,
        -width / 2 + point.x,  height / 2 + point.y, depth,
         width / 2 + point.x,  height / 2 + point.y, depth
    };
    GLfloat zvertices[] = {
        point.x,         -height / 2 + point.y, depth,
        width + point.x, -height / 2 + point.y, depth,
        point.x,          height / 2 + point.y, depth,
        width + point.x,  height / 2 + point.y, depth
    };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, center ? cvertices : zvertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::drawInRect(CGRect rect) { drawInRect(rect, 0.0); }

void Texture2D::drawInRect(CGRect rect, CGFloat depth) {
    GLfloat coordinates[] = { 0, _maxT, _maxS, _maxT, 0, 0, _maxS, 0 };
    if (IS_IPAD) {
        rect.origin.x *= SCALE_WIDTH;
        rect.origin.y *= SCALE_HEIGHT;
        rect.size.width *= SCALE_WIDTH;
        rect.size.height *= SCALE_HEIGHT;
    }
    GLfloat vertices[] = {
        rect.origin.x, rect.origin.y, depth,
        rect.origin.x + rect.size.width, rect.origin.y, depth,
        rect.origin.x, rect.origin.y + rect.size.height, depth,
        rect.origin.x + rect.size.width, rect.origin.y + rect.size.height, depth
    };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::drawInRect2(CGRect rect) {
    CGFloat depth = 0.0;
    GLfloat coordinates[] = { 0, _maxT, _maxS, _maxT, 0, 0, _maxS, 0 };
    if (IS_IPAD) {
        rect.origin.x *= SCALE_WIDTH;
        rect.origin.y *= SCALE_HEIGHT;
        rect.size.width *= 2;
        rect.size.height *= 2;
    }
    GLfloat vertices[] = {
        rect.origin.x, rect.origin.y, depth,
        rect.origin.x + rect.size.width, rect.origin.y, depth,
        rect.origin.x, rect.origin.y + rect.size.height, depth,
        rect.origin.x + rect.size.width, rect.origin.y + rect.size.height, depth
    };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::drawText(CGRect rect) {
    drawText(rect, FALSE);
}

// flipX mirrors across the X axis (top<->bottom), matching Classes/Texture2D.mm's overload —
// used to turn the up-pointing jump icon into a down-pointing crouch icon.
void Texture2D::drawText(CGRect rect, BOOL flipX) {
    CGFloat depth = 0.0;
    GLfloat coordinates[] = { 0, flipX?0:_maxT, _maxS, flipX?0:_maxT, 0, flipX?_maxT:0, _maxS, flipX?_maxT:0 };
    GLfloat width = roundf((GLfloat)_width * _maxS), height = roundf((GLfloat)_height * _maxT);
    if (!IS_RETINA && SUPPORTS_RETINA) { width /= 2; height /= 2; }
    if (IS_IPAD) {
        rect.origin.x *= SCALE_WIDTH;
        rect.origin.y *= SCALE_HEIGHT;
        rect.origin.x = roundf(rect.origin.x);
        rect.origin.y = roundf(rect.origin.y);
    }
    GLfloat vertices[] = {
        rect.origin.x, rect.origin.y, depth,
        rect.origin.x + width, rect.origin.y, depth,
        rect.origin.x, rect.origin.y + height, depth,
        rect.origin.x + width, rect.origin.y + height, depth
    };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::drawTextHalfsies(CGRect rect) {
    CGFloat depth = 0.0;
    GLfloat coordinates[] = { 0, _maxT, _maxS, _maxT, 0, 0, _maxS, 0 };
    GLfloat width = roundf((GLfloat)_width * _maxS), height = roundf((GLfloat)_height * _maxT);
    if (!IS_RETINA && SUPPORTS_RETINA) { width /= 2; height /= 2; }
    if (IS_IPAD) {
        rect.origin.x *= SCALE_WIDTH;
        rect.origin.y *= SCALE_HEIGHT;
        rect.origin.x = roundf(rect.origin.x);
        rect.origin.y = roundf(rect.origin.y);
    }
    GLfloat vertices[] = {
        rect.origin.x, rect.origin.y, depth,
        rect.origin.x + width, rect.origin.y, depth,
        rect.origin.x, rect.origin.y + height, depth,
        rect.origin.x + width, rect.origin.y + height, depth
    };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::drawTextNoScale(CGRect rect) {
    CGFloat depth = 0.0;
    GLfloat coordinates[] = { 0, _maxT, _maxS, _maxT, 0, 0, _maxS, 0 };
    GLfloat width = roundf((GLfloat)_width * _maxS), height = roundf((GLfloat)_height * _maxT);
    if (!IS_RETINA && SUPPORTS_RETINA) { width /= 2; height /= 2; }
    GLfloat vertices[] = {
        rect.origin.x, rect.origin.y, depth,
        rect.origin.x + width, rect.origin.y, depth,
        rect.origin.x, rect.origin.y + height, depth,
        rect.origin.x + width, rect.origin.y + height, depth
    };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::drawTextM(CGRect rect) {
    CGFloat depth = 0.0;
    GLfloat width = 480, height = roundf((GLfloat)_height * _maxT);
    if (IS_IPAD) {
        rect.origin.x *= SCALE_WIDTH;
        width = 1024;
        rect.origin.y *= SCALE_HEIGHT;
        rect.origin.x = roundf(rect.origin.x);
        rect.origin.y = roundf(rect.origin.y);
    }
    GLfloat vertices[] = {
        rect.origin.x, rect.origin.y, depth,
        rect.origin.x + width, rect.origin.y, depth,
        rect.origin.x, rect.origin.y + height, depth,
        rect.origin.x + width, rect.origin.y + height, depth
    };
    GLfloat coordinates[] = { 0, _maxT, _maxS, _maxT, 0, 0, _maxS, 0 };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::drawNumbers(CGRect rect, int num) {
    if (num < 0 || num > 10) {
        printg("num out of bounds/n");
        if (num < 0) num = 0;
        if (num > 10) num = 10;
    }
    CGFloat depth = 0.0;
    float xoff = num * 1 / 16.0f;
    float xwidth = 1;
    if (num == 10) xwidth = 2;
    GLfloat coordinates[] = {
        xoff, _maxT,
        xoff + _maxS / 16.0f * xwidth, _maxT,
        xoff, 0,
        xoff + _maxS / 16.0f * xwidth, 0
    };
    GLfloat width = roundf((GLfloat)_width * _maxS / 16.0f), height = roundf((GLfloat)_height * _maxT);
    if (num == 10) width = roundf((GLfloat)_width * _maxS / 16.0f * 2);
    if (!IS_RETINA && SUPPORTS_RETINA) { width /= 2; height /= 2; }
    if (IS_IPAD) {
        rect.origin.x *= SCALE_WIDTH;
        rect.origin.y *= SCALE_HEIGHT;
        rect.origin.x = roundf(rect.origin.x);
        rect.origin.y = roundf(rect.origin.y);
    }
    GLfloat vertices[] = {
        rect.origin.x, rect.origin.y, depth,
        rect.origin.x + width, rect.origin.y, depth,
        rect.origin.x, rect.origin.y + height, depth,
        rect.origin.x + width, rect.origin.y + height, depth
    };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void Texture2D::drawButton(Button button) {
    drawButton(button, FALSE);
}

void Texture2D::drawButton(Button button, BOOL flipX) {
    if (button.pressed) {
        button.size.width = roundf((GLfloat)_width * _maxS) / 2.0f;
        button.size.height = roundf((GLfloat)_height * _maxT) / 2.0f;
        float offx = button.size.width * .08f;
        float offy = button.size.height * .08f;
        CGRect rect = CGRectMake(button.origin.x + offx, button.origin.y + offy,
                                  button.size.width - offx * 2, button.size.height - offy * 2);
        CGFloat depth = 0.0;
        GLfloat coordinates[] = { 0, flipX?0:_maxT, _maxS, flipX?0:_maxT, 0, flipX?_maxT:0, _maxS, flipX?_maxT:0 };
        GLfloat width = rect.size.width, height = rect.size.height;
        if (IS_IPAD) {
            rect.origin.x *= SCALE_WIDTH;
            rect.origin.y *= SCALE_HEIGHT;
            width *= 2;
            height *= 2;
            rect.origin.x = roundf(rect.origin.x);
            rect.origin.y = roundf(rect.origin.y);
        }
        GLfloat vertices[] = {
            rect.origin.x, rect.origin.y, depth,
            rect.origin.x + width, rect.origin.y, depth,
            rect.origin.x, rect.origin.y + height, depth,
            rect.origin.x + width, rect.origin.y + height, depth
        };
        glBindTexture(GL_TEXTURE_2D, name);
        glVertexPointer(3, GL_FLOAT, 0, vertices);
        glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    } else {
        CGRect rect = CGRectMake(button.origin.x, button.origin.y, button.size.width, button.size.height);
        drawText(rect, flipX);
    }
}

void Texture2D::drawButton2(Button button) {
    if (button.pressed) {
        drawButton(button);
    } else {
        CGRect rect = CGRectMake(button.origin.x, button.origin.y, button.size.width, button.size.height);
        drawInRect(rect);
    }
}

void Texture2D::drawSky(CGRect rect, CGFloat depth) {
    float pitch = World::getWorld->cam->pitch;
    float sinPitch = sin(D2R(pitch));
    float sty = 0;
    float ety = 1.0f;
    if (sinPitch < 0) {
        sty = -sinPitch;
        if (sty > .8) sty = .8;
    } else {
        ety = 1 - sinPitch;
        if (ety < .2) ety = .2;
    }
    if (IS_IPAD) {
        rect.origin.x *= SCALE_WIDTH;
        rect.origin.y *= SCALE_HEIGHT;
        rect.size.width *= SCALE_WIDTH;
        rect.size.height *= SCALE_HEIGHT;
    }
    GLfloat coordinates[] = {
        0, ety * 32,
        _maxS * rect.size.width / 128, ety * 32,
        0, sty * 32,
        _maxS * rect.size.width / 128, sty * 32
    };
    GLfloat vertices[] = {
        rect.origin.x, rect.origin.y, depth,
        rect.origin.x + rect.size.width, rect.origin.y, depth,
        rect.origin.x, rect.origin.y + rect.size.height, depth,
        rect.origin.x + rect.size.width, rect.origin.y + rect.size.height, depth
    };
    glBindTexture(GL_TEXTURE_2D, name);
    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

// =============================================================================================
// Deferred to P2b (creature skin/mask recolor pipeline) — see this file's header comment.
// =============================================================================================
CGImageRef ManipulateImagePixelData(CGImageRef inImage, CGImageRef inMask, int color) {
    (void)inImage; (void)inMask; (void)color;
    return 0;
}
CGImageRef ManipulateImagePixelData2(CGImageRef inImage, int tint, int mode) {
    (void)inImage; (void)tint; (void)mode;
    return 0;
}

// Texture2D.mm's atlas bookkeeping: which recolored skin/mask variant is currently resident.
// -1 means "nothing cached" — keeps the engine's own guards (`if (storedSkinCounter >= 0 && …)`)
// on the safe path. Not incremented by this file (the storeImage block they gated is part of the
// deferred recolor path — see header comment); Resources.mm resets them to 0/-1 before use.
int storedMaskCounter = -1;
int storedSkinCounter = -1;
int realStoredSkinCounter = 0;
