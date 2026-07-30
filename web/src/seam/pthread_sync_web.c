// pthread_sync_web.c — SINGLE-THREADED-BUILD ONLY synchronous pthread_create.
//
// Compiled ONLY when EDEN_THREADED=OFF (see CMakeLists.txt). The threaded build links real
// Emscripten pthreads (-pthread), where this file is absent and the engine's world-load thread
// runs for real.
//
// WHY THIS EXISTS: the engine spawns exactly one thread — the world-load thread
// (Classes/World.mm:340, `pthread_create(&foo,NULL,loadWorldThread,name)`, the only
// pthread_create call in the whole engine, CLAUDE.md convention #4). In a NON-pthread Emscripten
// build there is no thread support, and Emscripten's stub `pthread_create` returns without ever
// running `start_routine`. The engine's loadWorldThread is what sets `doneLoading=2`; if it never
// runs, `World::loadWorld` is stuck forever at `doneLoading==1` and the menu hangs on the
// "Loading World..." bar — the freeze reported when clicking a world in eden-st.html.
//
// FIX: run the start routine synchronously on the calling (main) thread and return success. The
// world-load routine touches no GL and is fire-and-forget (the engine never joins/detaches it),
// so inline execution is behaviorally correct here — the only observable difference is that the
// progress bar jumps straight to done in one frame instead of animating, which is fine for the
// debug build. The CMakeLists.txt EDEN_THREADED=OFF branch already documented this as the
// intended single-thread behavior ("load runs synchronously") but never implemented it.
//
// This is a user-object-file definition, so it takes precedence over Emscripten libc's archive
// stub at link time (no --allow-multiple-definition needed). If the threaded build ever tried to
// link this file it WOULD collide with real pthreads — hence the CMake gate.
#include <pthread.h>

int pthread_create(pthread_t *thread,
                   const pthread_attr_t *attr,
                   void *(*start_routine)(void *),
                   void *arg) {
    (void)attr;
    if (thread) *thread = (pthread_t)0;
    start_routine(arg);
    return 0;
}
