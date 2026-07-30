// NSOperation / NSOperationQueue — declaration-level shim.
//
// One user in this tree: Classes/CocosDenshion.h's `@interface CDAsynchBufferLoader : NSOperation`,
// used by -loadBuffersAsynchronously: to decode sound effects off the main thread. CocosDenshion.h
// is pulled in by Classes/Resources.mm (an ordinary engine file), so the superclass must exist for
// the engine to compile even though the audio implementation waits for Stage P5.
//
// -main is the method a subclass overrides and -start is what a queue calls; both are declared so
// CDAsynchBufferLoader's override compiles. The queue's -addOperation: runs the operation
// SYNCHRONOUSLY here rather than on another thread — see NSOperation.mm for why that is the right
// stub for this port rather than a no-op or a real thread.
#ifndef EDEN_SHIM_NSOPERATION_H
#define EDEN_SHIM_NSOPERATION_H

#import "NSObject.h"

@interface NSOperation : NSObject
- (void)main;
- (void)start;
- (BOOL)isFinished;
- (BOOL)isCancelled;
- (void)cancel;
@end

@interface NSOperationQueue : NSObject
- (void)addOperation:(NSOperation *)op;
- (void)setMaxConcurrentOperationCount:(NSInteger)count;
- (void)cancelAllOperations;
@end

#endif
