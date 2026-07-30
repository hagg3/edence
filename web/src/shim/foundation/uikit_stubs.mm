#import "uikit_stubs.h"

@implementation UITouch
- (CGPoint)locationInView:(UIView *)view { (void)view; return _location; }
- (UITouchPhase)phase { return _phase; }
- (double)timestamp { return _timestamp; }
// Explicit getter rather than @synthesize: the `view` property exists only so Input.mm's
// `touch.view` dot syntax parses (see uikit_stubs.h), and it feeds straight back into
// -locationInView:, which ignores it. Writing the getter by hand also avoids depending on
// clang's property auto-synthesis under -fobjc-runtime=gnustep-1.9.
- (UIView *)view { return nil; }
@end

@implementation UIEvent
@end

@implementation UIImage
// TODO P2 — every one of these needs the Canvas2D/OffscreenCanvas raster path (Texture2D_web.mm).
// Returning nil/zero rather than aborting is deliberate: the engine's texture setup runs during
// world load, and a hard failure here would stop P1's headless tick from ever being reached.
// Missing textures are visible and diagnosable; an abort at load is not.
+ (UIImage *)imageNamed:(NSString *)name { (void)name; return nil; }
+ (UIImage *)imageWithContentsOfFile:(NSString *)path { (void)path; return nil; } // P4: dead-code link stub
+ (UIImage *)imageWithCGImage:(CGImageRef)cgImage { (void)cgImage; return nil; }
- (CGImageRef)CGImage { return 0; }
- (UIImageOrientation)imageOrientation { return (UIImageOrientation)0; }
- (CGSize)size { CGSize z; z.width = 0; z.height = 0; return z; }
- (void)drawInRect:(CGRect)rect { (void)rect; }
@end

@implementation UIFont
+ (UIFont *)systemFontOfSize:(float)size {
    UIFont *f = [[[UIFont alloc] init] autorelease];
    f->_pointSize = size;
    return f;
}
- (float)pointSize { return _pointSize; }
@end

@implementation UIColor
+ (UIColor *)colorWithRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
    (void)r; (void)g; (void)b; (void)a;
    return [[[UIColor alloc] init] autorelease]; // TODO P2
}
@end

@implementation UIView
- (void)insertSubview:(UIView *)view atIndex:(NSInteger)index { (void)view; (void)index; } // TODO P2/P3
@end

@implementation UIAccelerometer
+ (UIAccelerometer *)sharedAccelerometer { return nil; } // TODO
@end

@implementation EAGLContext {
@public
    EAGLRenderingAPI _api;
}
+ (EAGLContext *)currentContext {
    static EAGLContext *g_current = nil; // TODO P2: real WebGL2-context-backed tracking
    return g_current;
}
+ (BOOL)setCurrentContext:(EAGLContext *)context { (void)context; return YES; } // TODO P2
- (id)initWithAPI:(EAGLRenderingAPI)api {
    self = [super init];
    _api = api;
    return self;
}
@end

// --- CoreGraphics / UIGraphics, all TODO P2 -------------------------------------------------
// See uikit_stubs.h for why these exist and why they are likely to be deleted rather than
// implemented: the single caller is Util.mm's screenshot path, which on web becomes a readPixels
// plus canvas.toBlob(). Every one returns empty rather than aborting, for the same reason UIImage's
// methods do — a hard failure here would stop the world from loading, and the screenshot path is
// not on the critical path to a first frame.
extern "C" {

CGColorSpaceRef CGColorSpaceCreateDeviceRGB(void) { return 0; }
void CGColorSpaceRelease(CGColorSpaceRef cs) { (void)cs; }

CGDataProviderRef CGDataProviderCreateWithData(void *info, const void *data, size_t size,
                                               CGDataProviderReleaseDataCallback cb) {
  (void)info;
  (void)data;
  (void)size;
  (void)cb;
  // NOTE for P2: the real function takes ownership of `data` and calls `cb` to free it. Util.mm
  // relies on that — it allocates the pixel buffer, hands it over, and never frees it itself. A
  // real implementation must honor the callback contract or this leaks a full framebuffer per
  // screenshot.
  return 0;
}

CGImageRef CGImageCreate(size_t width, size_t height, size_t bitsPerComponent,
                         size_t bitsPerPixel, size_t bytesPerRow, CGColorSpaceRef space,
                         CGBitmapInfo bitmapInfo, CGDataProviderRef provider,
                         const float *decode, BOOL shouldInterpolate,
                         CGColorRenderingIntent intent) {
  (void)width; (void)height; (void)bitsPerComponent; (void)bitsPerPixel; (void)bytesPerRow;
  (void)space; (void)bitmapInfo; (void)provider; (void)decode; (void)shouldInterpolate;
  (void)intent;
  return 0;
}

void CGImageRelease(CGImageRef image) { (void)image; }

// P4: link-only stubs for FileManager::loadGenFromDisk (JUST_TERRAIN_GEN path, dead in this build).
size_t CGImageGetWidth(CGImageRef image) { (void)image; return 0; }
size_t CGImageGetHeight(CGImageRef image) { (void)image; return 0; }
CGContextRef CGBitmapContextCreate(void *data, size_t width, size_t height,
                                   size_t bitsPerComponent, size_t bytesPerRow,
                                   CGColorSpaceRef space, CGBitmapInfo bitmapInfo) {
  (void)data; (void)width; (void)height; (void)bitsPerComponent; (void)bytesPerRow;
  (void)space; (void)bitmapInfo;
  return 0;
}
void CGContextDrawImage(CGContextRef c, CGRect rect, CGImageRef image) { (void)c; (void)rect; (void)image; }
void CGContextRelease(CGContextRef c) { (void)c; }

void UIGraphicsBeginImageContext(CGSize size) { (void)size; }
UIImage *UIGraphicsGetImageFromCurrentImageContext(void) { return nil; }
void UIGraphicsEndImageContext(void) {}
NSData *UIImagePNGRepresentation(UIImage *image) { (void)image; return nil; }

}  // extern "C"

// --- App-shell singletons. See uikit_stubs.h for which calls are live and which are archaeology.
@implementation UIScreen
+ (UIScreen *)mainScreen { return [[[UIScreen alloc] init] autorelease]; }   // TODO P2
- (CGRect)bounds { CGRect r; r.origin.x = 0; r.origin.y = 0; r.size.width = 0; r.size.height = 0; return r; } // TODO P2
- (float)scale { return 1.0f; }                                              // TODO P2
@end

@implementation UIDevice
+ (UIDevice *)currentDevice { return [[[UIDevice alloc] init] autorelease]; }
- (NSInteger)orientation { return UIDeviceOrientationLandscapeLeft; }
@end

@implementation UIApplication
+ (UIApplication *)sharedApplication { return [[[UIApplication alloc] init] autorelease]; }
// Genuinely nothing to do, not a deferred stub: a browser page has no status bar to hide.
- (void)setStatusBarHidden:(BOOL)hidden { (void)hidden; }
- (BOOL)openURL:(NSURL *)url { (void)url; return NO; }   // TODO P6 — window.open
@end
