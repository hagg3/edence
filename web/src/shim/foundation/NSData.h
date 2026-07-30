// NSData.h — D3a shim, backed by std::vector<uint8_t>. See foundation-usage.md "NSData /
// NSMutableData". writeToFile:/initWithContentsOfFile: are P1-adequate (fopen-backed, works
// under MEMFS); Stage P4 swaps the *callers* (FileManager) to OPFS, not this class.
#ifndef EDEN_SHIM_NSDATA_H
#define EDEN_SHIM_NSDATA_H

#import "NSObject.h"
#include <vector>
#include <cstdint>

@class NSString;
typedef struct _NSRange NSRange;

@interface NSData : NSObject {
@public
    std::vector<uint8_t> _bytes;
}

+ (NSData *)data;
+ (NSData *)dataWithBytes:(const void *)bytes length:(NSUInteger)len;
// P4: FileManager wraps transient stack/heap buffers in NSData for -writeData: (freeWhenDone:FALSE)
// and a couple of malloc'd headers (freeWhenDone:TRUE). This shim COPIES the bytes (like
// -initWithBytesNoCopy:), so the "no copy" is nominal; it honors freeWhenDone by free()ing the
// caller's buffer after the copy when TRUE, matching the ownership contract the engine relies on.
+ (NSData *)dataWithBytesNoCopy:(void *)bytes length:(NSUInteger)len freeWhenDone:(BOOL)freeWhenDone;
+ (NSData *)dataWithContentsOfFile:(NSString *)path;

- (id)initWithBytes:(const void *)bytes length:(NSUInteger)len;
- (id)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)len; // copies anyway (P1: simplest
                                                                  // correct behavior; no engine
                                                                  // call site relies on the
                                                                  // no-copy optimization).
- (id)initWithContentsOfFile:(NSString *)path;
- (id)initWithData:(NSData *)other;

- (const void *)bytes;
- (NSUInteger)length;
- (void)getBytes:(void *)buffer length:(NSUInteger)len;
- (void)getBytes:(void *)buffer range:(NSRange)range;
- (NSData *)subdataWithRange:(NSRange)range;
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomically;

@end

@interface NSMutableData : NSData
+ (NSMutableData *)data;
+ (NSMutableData *)dataWithCapacity:(NSUInteger)capacity;
- (void *)mutableBytes;
- (void)appendBytes:(const void *)bytes length:(NSUInteger)len;
- (void)appendData:(NSData *)other;
- (void)setLength:(NSUInteger)len;
@end

#endif
