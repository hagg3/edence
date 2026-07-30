// NSObject.mm — minimal root-class implementation. Reference-counted retain/release;
// -autorelease defers to the current NSAutoreleasePool (NSAutoreleasePool.h/.mm), matching
// real Foundation/Cocoa semantics closely enough for this engine's usage (it never relies on
// zeroing weak references or KVO, per a scan of Classes/*.mm — plain retain/release/autorelease
// only, CLAUDE.md convention #6).
#import "NSObject.h"
#import "NSAutoreleasePool.h"
#import "NSString.h"
#include <cstdio>
#include <cstdlib>
#include <unordered_map>

// --- Retain counts live here, NOT in an ivar -------------------------------------------
// See the layout comment on @interface NSObject (NSObject.h): NSObject must declare zero
// ivars so clang's statically-emitted `@"..."` instances keep the layout it hard-codes.
// A side table keyed by object address is the simplest storage that satisfies that.
//
// Absent entry == count of 1. This makes the table cheap (only objects that are actually
// retained past their initial reference ever get an entry) and, critically, makes constant
// strings free: they are never inserted, always report 1, and can never reach 0.
//
// NOT thread-safe. That is correct for now — per CLAUDE.md convention #4 the only non-main
// thread is the world-load pthread, and under plan decision D1 the engine runs on a single
// worker thread. TODO P1/D1: if real pthreads land (SharedArrayBuffer), guard this with a
// mutex or switch to atomics, and revisit whether an object header word beats a side table.
namespace {
std::unordered_map<const void *, int> &edenRetainTable() {
    static std::unordered_map<const void *, int> table;
    return table;
}
} // namespace

// Constant strings are immortal: clang emits them as static data, so they were never
// malloc'd and must never be freed. NSConstantString overrides retain/release to no-ops
// (NSString.mm), so they never reach this table at all.

@implementation NSObject

+ (id)alloc {
    // Count of 1 is implicit (absent from the table) — nothing to record here.
    return class_createInstance(self, 0);
}

+ (id)new {
    return [[self alloc] init];
}

// Explicit class-side overrides — NOT redundant with -class/-isKindOfClass: below. Without
// these, `[SomeClass class]`/`+isKindOfClass:` fall through the GNU root-metaclass's
// super_class link to the ROOT CLASS's own INSTANCE method table (the standard trick that lets
// one root class supply both -foo and, via that fallback, +foo). That fallback reuses
// `-class`'s body (`object_getClass(self)`, i.e. `self->isa`) with `self` bound to the CLASS
// object being asked about — which computes its METACLASS, not the class itself. Every
// `[X class]` in the port was silently returning the wrong (metaclass) pointer this way, e.g.
// making `[foo isKindOfClass:[NSString class]]` compare against NSString's metaclass and
// false-negative for every real NSString instance (found via Texture2D_web.mm's `ipad~`
// retina-asset probe: `[NSString stringWithFormat:@"ipad~%@", path]`'s `%@` substitution calls
// `-isKindOfClass:[NSString class]`, always missed, so it fell back to `-description`, which
// NSConstantString/EdenConcreteString don't implement, producing the literal string
// "(null description)" as part of the filename and silently losing every retina asset).
+ (Class)class {
    return self;
}

+ (Class)superclass {
    return class_getSuperclass(self);
}

- (id)init {
    return self;
}

- (id)retain {
    std::unordered_map<const void *, int> &table = edenRetainTable();
    std::unordered_map<const void *, int>::iterator it = table.find(self);
    if (it == table.end()) {
        table[self] = 2; // was the implicit 1
    } else {
        it->second++;
    }
    return self;
}

- (oneway void)release {
    std::unordered_map<const void *, int> &table = edenRetainTable();
    std::unordered_map<const void *, int>::iterator it = table.find(self);
    if (it == table.end()) {
        [self dealloc]; // implicit count of 1 → drops to 0
        return;
    }
    if (--it->second <= 1) {
        table.erase(it); // back down to the implicit 1
    }
}

- (id)autorelease {
    [[NSAutoreleasePool currentPool] addObject:self];
    return self;
}

- (NSUInteger)retainCount {
    std::unordered_map<const void *, int> &table = edenRetainTable();
    std::unordered_map<const void *, int>::iterator it = table.find(self);
    return it == table.end() ? 1 : (NSUInteger)it->second;
}

- (void)dealloc {
    edenRetainTable().erase(self); // never leave a stale entry for a recycled address
    object_dispose(self);
}

- (Class)class {
    return object_getClass(self);
}

- (BOOL)isKindOfClass:(Class)cls {
    Class c = object_getClass(self);
    while (c) {
        if (c == cls) return YES;
        c = class_getSuperclass(c);
    }
    return NO;
}

- (BOOL)isMemberOfClass:(Class)cls {
    return object_getClass(self) == cls;
}

- (BOOL)respondsToSelector:(SEL)sel {
    return class_respondsToSelector(object_getClass(self), sel);
}

- (BOOL)isEqual:(id)other {
    return self == other;
}

- (NSUInteger)hash {
    return (NSUInteger)(uintptr_t)self;
}

- (NSString *)description {
    // TODO P1: format as "<ClassName: 0xADDR>" once NSString's stringWithFormat: is wired to
    // this file's build unit (avoids a header-order dependency for now).
    return nil;
}

@end
