// NSArray.h — D3a shim. NSArray/NSMutableArray backed by std::vector<id> (real 4+2 call sites,
// see foundation-usage.md). NSSet also lives here: it shares the same backing store and is
// load-bearing for Input.h's real signature (touchesBegan:(NSSet*)...) which the port cannot
// change (Input.mm is an ENGINE file, not seam). NSDictionary is declared but left
// unimplemented (2 raw mentions, no confirmed non-seam call site after excluding networking
// files) — flagged TODO rather than guessed at.
#ifndef EDEN_SHIM_NSARRAY_H
#define EDEN_SHIM_NSARRAY_H

#import "NSObject.h"
#include <vector>

@interface NSArray : NSObject {
@public
    std::vector<id> _items;
}
+ (NSArray *)array;
+ (NSArray *)arrayWithObjects:(id)first, ...; // nil-terminated, classic Foundation varargs form
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)index;
- (NSUInteger)indexOfObject:(id)obj;
- (BOOL)containsObject:(id)obj;
@end

@interface NSMutableArray : NSArray
+ (NSMutableArray *)array;
+ (NSMutableArray *)arrayWithCapacity:(NSUInteger)capacity;
- (void)addObject:(id)obj;
- (void)removeObjectAtIndex:(NSUInteger)index;
- (void)removeObject:(id)obj;
- (void)removeAllObjects;
@end

// NSSet — see file-header note. Implements only what the engine's real usage needs: fast
// enumeration (`for (UITouch *t in touches)`, via NSFastEnumeration), count, anyObject.
@interface NSSet : NSObject <NSFastEnumeration> {
@public
    std::vector<id> _items;
}
+ (NSSet *)setWithObject:(id)obj;
+ (NSSet *)setWithArray:(NSArray *)arr;
- (NSUInteger)count;
- (id)anyObject;
- (BOOL)containsObject:(id)obj;
- (NSArray *)allObjects;
@end

@interface NSMutableSet : NSSet
+ (NSMutableSet *)set;
- (void)addObject:(id)obj;
- (void)removeObject:(id)obj;
@end

// NSDictionary — declared only; no implemented methods. TODO P1-if-blocking: implement over
// std::vector<std::pair<id,id>> with linear -isEqual: lookup (matches the engine's tiny
// dictionary sizes, if/when a real non-seam call site turns up — none found by grep as of
// this pass, see foundation-usage.md).
@interface NSDictionary : NSObject
+ (NSDictionary *)dictionary;
- (id)objectForKey:(id)key;
- (NSUInteger)count;
@end

@interface NSMutableDictionary : NSDictionary
+ (NSMutableDictionary *)dictionary;
- (void)setObject:(id)obj forKey:(id)key;
- (void)removeObjectForKey:(id)key;
@end

#endif
