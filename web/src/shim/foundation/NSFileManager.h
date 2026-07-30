// NSFileManager.h — D3a shim, P1-adequate (POSIX-backed, works under Emscripten's default
// MEMFS). Stage P4 swaps the backing to OPFS directory APIs; keep this class's public surface
// stable across that swap (see foundation-usage.md "NSFileManager").
#ifndef EDEN_SHIM_NSFILEMANAGER_H
#define EDEN_SHIM_NSFILEMANAGER_H

#import "NSObject.h"

@class NSString;
@class NSArray;
@class NSData;   // -createFileAtPath:contents:attributes: takes one by pointer

typedef NSUInteger NSSearchPathDirectory;
typedef NSUInteger NSSearchPathDomainMask;
#define NSDocumentDirectory 9
#define NSUserDomainMask 1

@interface NSFileManager : NSObject
+ (NSFileManager *)defaultManager;
- (BOOL)fileExistsAtPath:(NSString *)path;
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDir;
- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)contents attributes:(id)attrs;
- (BOOL)createDirectoryAtPath:(NSString *)path
   withIntermediateDirectories:(BOOL)createIntermediates
                    attributes:(id)attrs error:(id *)error;
- (BOOL)removeItemAtPath:(NSString *)path error:(id *)error;
- (BOOL)copyItemAtPath:(NSString *)src toPath:(NSString *)dst error:(id *)error;
- (BOOL)moveItemAtPath:(NSString *)src toPath:(NSString *)dst error:(id *)error;
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(id *)error;
@end

// C function, not a method — matches Foundation's real free-function signature.
NSArray *NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory directory,
                                              NSSearchPathDomainMask domainMask,
                                              BOOL expandTilde);

#endif
