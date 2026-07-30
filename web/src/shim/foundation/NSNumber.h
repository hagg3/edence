// NSNumber.h — D3a shim, tagged-union backed. Low-traffic (17 mentions, see
// foundation-usage.md) but implemented fully since it's trivial.
#ifndef EDEN_SHIM_NSNUMBER_H
#define EDEN_SHIM_NSNUMBER_H

#import "NSObject.h"

@interface NSNumber : NSObject {
@public
    enum { kInt, kFloat, kDouble, kBool, kUInt } _kind;
    union { int i; float f; double d; BOOL b; unsigned int u; } _v;
}

+ (NSNumber *)numberWithInt:(int)v;
+ (NSNumber *)numberWithFloat:(float)v;
+ (NSNumber *)numberWithDouble:(double)v;
+ (NSNumber *)numberWithBool:(BOOL)v;
+ (NSNumber *)numberWithUnsignedInt:(unsigned int)v;

- (int)intValue;
- (float)floatValue;
- (double)doubleValue;
- (BOOL)boolValue;
- (unsigned int)unsignedIntValue;

@end

#endif
