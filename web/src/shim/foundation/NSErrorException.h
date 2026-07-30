// NSErrorException.h — D3a shim, low priority (4+4 raw mentions, see foundation-usage.md).
// NSException maps to NSLog + abort() — no @try/@catch unwinding support assumed; TODO P1:
// verify no engine (non-seam) file actually @catches one (a scan at write time found none,
// but re-verify if this trips a mysterious abort during the P1 spike).
#ifndef EDEN_SHIM_NSERROREXCEPTION_H
#define EDEN_SHIM_NSERROREXCEPTION_H

#import "NSObject.h"

@class NSString;
@class NSDictionary;

@interface NSError : NSObject
+ (NSError *)errorWithDomain:(NSString *)domain code:(NSInteger)code userInfo:(NSDictionary *)info;
- (NSString *)localizedDescription;
@end

@interface NSException : NSObject
+ (NSException *)exceptionWithName:(NSString *)name reason:(NSString *)reason
                           userInfo:(NSDictionary *)info;
+ (void)raise:(NSString *)name format:(NSString *)fmt, ...;
- (NSString *)reason;
@end

// Standard Foundation exception-name constant — Texture2D.h's `default:` switch cases raise this
// by name (`[NSException raise:NSInternalInconsistencyException format:@""]`), same as real
// Foundation declares it as an `extern NSString * const`.
extern NSString *const NSInternalInconsistencyException;

#endif
