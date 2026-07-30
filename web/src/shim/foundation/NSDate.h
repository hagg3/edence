// NSDate.h — D3a shim. Backed by double seconds-since-epoch via emscripten_get_now()/
// std::chrono (per plan: "CFAbsoluteTime -> emscripten_get_now"). NSDateFormatter is declared
// but its formatting methods are TODO P4 (see foundation-usage.md — only 2 raw mentions,
// exact format string not worth guessing before that stage re-reads the call sites).
#ifndef EDEN_SHIM_NSDATE_H
#define EDEN_SHIM_NSDATE_H

#import "NSObject.h"

typedef double NSTimeInterval;

@interface NSDate : NSObject {
@public
    NSTimeInterval _secondsSinceEpoch;
}
+ (NSDate *)date;
+ (NSDate *)dateWithTimeIntervalSinceNow:(NSTimeInterval)secs;
- (NSTimeInterval)timeIntervalSinceNow;
- (NSTimeInterval)timeIntervalSince1970;
- (NSTimeInterval)timeIntervalSinceDate:(NSDate *)other;
@end

@interface NSDateFormatter : NSObject
- (void)setDateFormat:(NSString *)fmt; // TODO P4: store + honor format string
- (NSString *)dateFormat;              // TODO P4
- (NSString *)stringFromDate:(NSDate *)date; // TODO P4: currently returns a fixed ISO-ish stamp
- (NSDate *)dateFromString:(NSString *)str;  // TODO P4: currently returns [NSDate date]
@end

#endif
