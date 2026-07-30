// NSAutoreleasePool.h — D3a shim. Real pool-stack semantics (nested pools, drain-on-release),
// because the engine's C3/H6/M2 audit findings (WORKING/audit-report.md, referenced by
// web-port-plan.md D3) are literally about pool *timing* — a fake/no-op pool would silently
// paper over exactly the bugs the port is supposed to carry forward faithfully (plan
// principle #1: "port the working engine before fixing it").
#ifndef EDEN_SHIM_NSAUTORELEASEPOOL_H
#define EDEN_SHIM_NSAUTORELEASEPOOL_H

#import "NSObject.h"

@interface NSAutoreleasePool : NSObject

+ (NSAutoreleasePool *)currentPool; // shim-internal helper, not real Foundation API — used by
                                    // NSObject.mm's -autorelease to find the innermost pool.
- (id)init;
- (void)addObject:(id)obj;
- (void)drain;   // NSAutoreleasePool's modern name for -release
- (oneway void)release;

@end

#endif
