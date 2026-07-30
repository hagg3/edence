// <QuartzCore/QuartzCore.h> — imported by Classes/Util.mm (and by the seam-excluded
// EdenViewController.mm, for CADisplayLink).
//
// Util.mm imports it for CoreGraphics, not for Core Animation: grepping it for `CA*` symbols
// finds nothing (the one apparent hit is the word "CALE" inside an identifier). On iOS,
// <QuartzCore/QuartzCore.h> transitively drags in CoreGraphics, which is what Util.mm's
// screenshot path actually uses — CGImageCreate, CGDataProviderCreateWithData,
// CGColorSpaceCreateDeviceRGB, and the UIGraphics* image-context calls.
//
// So this forwards to the CoreGraphics declarations rather than declaring any CA layer types.
// CADisplayLink, the one genuine Core Animation dependency, lives only in the seam files this
// port replaces outright (src/seam/EdenViewController_web.cpp drives the loop from
// requestAnimationFrame instead), so it is deliberately absent here.
#ifndef EDEN_TRAMPOLINE_QUARTZCORE_H
#define EDEN_TRAMPOLINE_QUARTZCORE_H
#import <UIKit/UIKit.h>
#endif
