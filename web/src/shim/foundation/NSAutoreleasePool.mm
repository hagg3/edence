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

// NON-POD IVARS ARE NOT SAFE IN THIS PORT — see the long note in NSUserDefaults.mm for the
// measurement and the mechanism. Short version: class_createInstance() is `calloc`, and the
// hand-written runtime has no `.cxx_construct`/`.cxx_destruct`, so a C++ ivar is neither
// constructed nor destroyed. An all-zero `std::vector` at least *reads* as a valid empty vector,
// so this one never crashed the way NSUserDefaults' `std::unordered_map` did — but the missing
// destructor meant every pool's heap buffer was leaked at `object_dispose`'s bare `free()`.
// -release's `_objects.clear()` releases the contents and drops size to 0; it does not give the
// capacity back. Since audit row A2 (pass 53) there is one pool per frame, so that was a leak at
// display refresh rate, in the very code added to stop a leak. Heap pointer + explicit delete.
@implementation NSAutoreleasePool {
    std::vector<id> *_objects;   // calloc'd to null; allocated by -init, deleted by -release
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
        _objects = new std::vector<id>();
        g_poolStack.push_back(self);
    }
    return self;
}

- (void)addObject:(id)obj {
    _objects->push_back(obj);
}

- (void)drain {
    [self release];
}

- (oneway void)release {
    if (_objects) {
        for (auto it = _objects->rbegin(); it != _objects->rend(); ++it) {
            [*it release];
        }
        _objects->clear();
    }
    if (!g_poolStack.empty() && g_poolStack.back() == self) {
        g_poolStack.pop_back();
    }
    [super release];   // -> NSObject -dealloc -> this class's -dealloc when the count hits 0
}

// The buffer, as opposed to its contents, is freed here rather than in -release: NSObject's
// -release only deallocs at a zero count, and object_dispose() is a bare free() that will not
// run any C++ destructor for us (see the ivar note above).
- (void)dealloc {
    delete _objects;
    _objects = nullptr;
    [super dealloc];
}

@end

// See NSAutoreleasePool.h: C-linkage wrappers for plain-C++ callers (EdenViewController_web.cpp's
// per-frame pool, audit row A2). Manual retain/release, no ARC/bridge casts needed (CLAUDE.md #6).
void *eden_autoreleasepool_push(void) {
    return (void *)[[NSAutoreleasePool alloc] init];
}

void eden_autoreleasepool_drain(void *pool) {
    [(NSAutoreleasePool *)pool drain];
}
