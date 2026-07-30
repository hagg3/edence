// NSBundle.h — D3a shim. Backed by a fixed virtual root (see .mm); real asset resolution
// happens once Stage P4's lazy-fetch bundle layer exists (web-port-plan.md Stage P4: "Bundle
// the ~52 MB RLE Eden.eden as a lazily fetched asset"). P1 headless doesn't read through this.
#ifndef EDEN_SHIM_NSBUNDLE_H
#define EDEN_SHIM_NSBUNDLE_H

#import "NSObject.h"

@class NSString;

@interface NSBundle : NSObject
+ (NSBundle *)mainBundle;
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext;
- (NSString *)bundlePath;
- (NSString *)resourcePath;
@end

#endif
