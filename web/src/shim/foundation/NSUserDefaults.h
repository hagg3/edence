// NSUserDefaults.h — D3a shim. In-memory only this pass; TODO P7: persist via a small JS
// EM_ASM bridge to localStorage, or an OPFS-backed key file — not load-bearing for P1-P4 (see
// foundation-usage.md "NSUserDefaults").
#ifndef EDEN_SHIM_NSUSERDEFAULTS_H
#define EDEN_SHIM_NSUSERDEFAULTS_H

#import "NSObject.h"

@class NSString;

@interface NSUserDefaults : NSObject
+ (NSUserDefaults *)standardUserDefaults;
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (BOOL)synchronize;
@end

#endif
