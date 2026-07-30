// NSTimer.h — D3a shim. Header-only-with-trivial-impl; per foundation-usage.md the real user
// (EdenViewController.mm's CADisplayLink-fallback path) is seam-excluded and replaced by
// requestAnimationFrame in src/entry/eden_main.cpp (Stage P2). No non-seam engine file uses
// NSTimer as of this pass — kept for completeness only.
#ifndef EDEN_SHIM_NSTIMER_H
#define EDEN_SHIM_NSTIMER_H

#import "NSObject.h"

@interface NSTimer : NSObject
+ (NSTimer *)scheduledTimerWithTimeInterval:(double)interval target:(id)target
                                     selector:(SEL)sel userInfo:(id)info repeats:(BOOL)repeats;
- (void)invalidate;
@end

#endif
