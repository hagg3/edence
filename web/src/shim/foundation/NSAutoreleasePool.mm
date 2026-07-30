// NSAutoreleasePool.mm — a real thread-local pool stack over std::vector<id>. Draining
// releases every collected object once, in reverse-insertion order (matches real Foundation's
// LIFO-ish draining closely enough — the engine never depends on exact drain ordering between
// distinct objects, only on "eventually released after the pool that captured it dies").
#import "NSAutoreleasePool.h"
#include <vector>

// TODO P1 (threading): this is NOT actually thread-local yet — engine is single-GL-thread
// (CLAUDE.md convention #4) plus one pthread world-load thread (Classes/World.mm:339) that,
// per that same convention, must NOT touch Foundation/GL. If that invariant ever changes,
// this needs a real thread-local stack (e.g. via pthread_getspecific under EDEN_THREADED).
static std::vector<NSAutoreleasePool *> g_poolStack;

@implementation NSAutoreleasePool {
    std::vector<id> _objects;
}

+ (NSAutoreleasePool *)currentPool {
    if (g_poolStack.empty()) {
        // No pool active — matches real Foundation's "leaked, logged" behavior loosely; here
        // we just lazily create a root pool so -autorelease never crashes during early
        // (pre-main-pool) engine construction, e.g. static initializers.
        [[[NSAutoreleasePool alloc] init] autorelease]; // note: this pool leaks by design,
                                                          // it's the fallback root.
    }
    return g_poolStack.back();
}

- (id)init {
    self = [super init];
    if (self) {
        g_poolStack.push_back(self);
    }
    return self;
}

- (void)addObject:(id)obj {
    _objects.push_back(obj);
}

- (void)drain {
    [self release];
}

- (oneway void)release {
    for (auto it = _objects.rbegin(); it != _objects.rend(); ++it) {
        [*it release];
    }
    _objects.clear();
    if (!g_poolStack.empty() && g_poolStack.back() == self) {
        g_poolStack.pop_back();
    }
    [super release];
}

@end
