// NSAutoreleasePool.mm — a real thread-local pool stack over std::vector<id>. Draining
// releases every collected object once, in reverse-insertion order (matches real Foundation's
// LIFO-ish draining closely enough — the engine never depends on exact drain ordering between
// distinct objects, only on "eventually released after the pool that captured it dies").
#import "NSAutoreleasePool.h"
#include <vector>

// THE POOL STACK IS PER-THREAD (audit row 36/C1, pass 63) — as it is in real Foundation, and as
// the file header's old TODO said it would have to become "if that invariant ever changes."
// It changed. The threaded build makes Classes/World.mm's world-load pthread real, and that
// thread's FIRST statement is `[[NSAutoreleasePool alloc] init]` (Classes/World.mm:317,
// loadWorldThread) — so two threads push and pop this stack concurrently. A single shared
// std::vector would corrupt on the concurrent push_back, and worse, `+currentPool` on the load
// thread would hand back the MAIN thread's frame pool, so every NSString the loader autoreleased
// would be drained by the render thread's next frame boundary — a use-after-free that would
// present as terrain corruption, not as a threading bug.
//
// `thread_local` only under -pthread, so the single-threaded build's codegen is unchanged (a
// plain static, no TLS indirection on -autorelease's path). Each thread gets its own lazily
// created fallback root pool via +currentPool below, which is the correct behaviour anyway:
// the load thread's pool must not be the main thread's.
#if defined(__EMSCRIPTEN_PTHREADS__)
#define EDEN_POOL_TLS thread_local
#else
#define EDEN_POOL_TLS
#endif
static EDEN_POOL_TLS std::vector<NSAutoreleasePool *> g_poolStack;

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
