// NSThread.h — D3a shim, near-moot (see foundation-usage.md "NSThread": the only real
// detachNewThreadSelector: call sites are in Appirater.mm, which this port strips entirely;
// the world-load thread uses raw pthread_create, not NSThread — CLAUDE.md convention #4).
// Declared for completeness / in case a straggler call site turns up.
#ifndef EDEN_SHIM_NSTHREAD_H
#define EDEN_SHIM_NSTHREAD_H

#import "NSObject.h"

@interface NSThread : NSObject
+ (void)detachNewThreadSelector:(SEL)sel toTarget:(id)target withObject:(id)arg;
+ (BOOL)isMainThread;
+ (void)sleepForTimeInterval:(double)seconds;
@end

#endif
