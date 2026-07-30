// EdenViewController_web.cpp — see header for the design-decision rationale (fresh C++, not a
// reused Objective-C interface).
#include "EdenViewController_web.h"
#include <cstdio>
#include <algorithm>
#include "../../../Classes/World.h"
#include "../../../Classes/Globals.h"
#include <chrono>
#include "../shim/gl/gl_es1_shim.h"
#include "../shim/foundation/NSAutoreleasePool.h"

namespace eden_web {

static double eden_now_seconds() {
    // TODO P1: emscripten_get_now() once building under emcc — see NSDate.mm's identical
    // placeholder; kept as a free function here rather than importing the Foundation shim's
    // NSDate machinery, since this file is plain C++ and shouldn't need an Objective-C
    // dependency just to read a clock (small step toward Phase R's de-Obj-C direction).
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

EdenViewController::EdenViewController() {}

EdenViewController::~EdenViewController() {
    delete world; // mirrors Classes/EdenViewController.mm's -dealloc ("delete world;")
}

void EdenViewController::construct() {
    // Mirrors Classes/EdenViewController.mm:40-51's LOW_GRAPHICS/LOW_MEM_DEVICE memory-tier
    // detection — see header TODO. Defaulting to "best graphics" until that's decided.
    // TODO P2: LOW_GRAPHICS = ...; LOW_MEM_DEVICE = ...;
    world = new World();
}

void EdenViewController::startAnimation() {
    if (animating) return;
    startTime = eden_now_seconds();
    lastTime = 0.0;
    // TODO P2: register the requestAnimationFrame callback here (or confirm
    // src/entry/eden_main.cpp already owns that registration and this flag just gates
    // drawFrame() from doing work — matches the original's animating-bool-gates-drawFrame
    // shape either way).
    animating = true;
}

void EdenViewController::stopAnimation() {
    if (!animating) return;
    // TODO P2: cancel the requestAnimationFrame registration, mirroring
    // Classes/EdenViewController.mm:164-181's displayLink invalidate / animationTimer invalidate.
    animating = false;
}

bool EdenViewController::drawFrame(bool renderThisFrame) {
    // Mirrors Classes/EdenViewController.mm:188-229. TODO P2: the EAGLView setFramebuffer/
    // presentFramebuffer/deleteFramebuffer/createFramebuffer calls are intentionally omitted
    // here — this class's job for Stage P1 is proving `world->update(etime)` runs headless;
    // Stage P2 is where EAGLView_web's (currently no-op) framebuffer methods get called
    // around this.
    double now = eden_now_seconds() - startTime;
    float etime = (float)(now - lastTime);
    lastTime = now;

    // Audit row A3: clamp etime. Unclamped, a backgrounded tab / GC pause / devtools breakpoint
    // / syncfs stall feeds a multi-second delta straight into Terrain::update and physics —
    // guaranteed on the very first tab-switch, not an edge case. Cap chosen as ~3 frames at
    // 30 fps (matches the mobile fps-cap floor elsewhere in this file's caller); World::update
    // itself already substeps large etime less gracefully than this cap avoids needing to rely on.
    constexpr float kMaxEtime = 0.1f;
    etime = std::min(etime, kMaxEtime);

    // Audit row A2 (TODO P1, Classes/EdenViewController.mm:198): real Foundation code wraps
    // each frame in an NSAutoreleasePool. Without one, every autorelease'd object World::update/
    // render create (the shim's NSSet/UIEvent/NSString paths autorelease routinely) accumulated
    // into whatever outer pool existed, or leaked outright — a slow heap climb that only shows up
    // as a long-session memory ramp. C-linkage push/drain (NSAutoreleasePool.h) keeps this file
    // plain C++ per its header comment's rationale.
    void *autoreleasePool = eden_autoreleasepool_push();

    // Stage P1's success bar is "world->update(etime) runs one headless tick", and a run that
    // meets it looks EXACTLY like a run that hung during construction — emscripten_set_main_loop
    // never returns, so `node eden.js` just sits there either way. These three lines are the
    // only difference between the two, hence they stay until P2 puts something on screen.
    // TODO P2: delete once a rendered frame is its own proof.
    // Gated behind EDEN_DIAGNOSTICS (perf audit Q7/C8) — the `node eden.js` regression gate
    // greps for these exact lines (docs/RESUME-HERE.md "Running it"), so they stay for build-st's
    // default-ON diagnostics but are compiled out of a build meant to be played.
#ifdef EDEN_DIAGNOSTICS
    static int tickCount = 0;
    if (tickCount < 3) {
        std::fprintf(stderr, "[eden-p1] tick %d: World::update(%.4f s) entered\n", tickCount, etime);
    }
#endif

    bool retinaSwapRequested = world && world->update(etime);

#ifdef EDEN_DIAGNOSTICS
    if (tickCount < 3) {
        std::fprintf(stderr, "[eden-p1] tick %d: World::update returned (retinaSwap=%d)\n",
                     tickCount, (int)retinaSwapRequested);
        ++tickCount;
    }
#endif

    // Perf-audit item #4: rotate the GL shim's per-frame draw-call accounting. Here rather than
    // inside the shim's glClear, because prepareScene does not clear the colour buffer — see
    // eden_gl_stats_frame_boundary()'s comment. Cheap (two struct copies) and it is what
    // Module._eden_gl_stat() reports. Only rotated on frames that actually draw, so a capped
    // frame does not report a spurious zero-draw frame to _eden_gl_stat().
    if (renderThisFrame) eden_gl_stats_frame_boundary();

    // Audit row A4: even when the cap says "don't draw", renderFrame() is still CALLED — it owns
    // the GAME_MODE_WAIT -> target_game_mode transition and the exit_to_menu check, neither of
    // which is reachable from World::update(). Skipping the call outright wedges a loading world
    // in WAIT forever. (The port's recurring defect class: a replacement owes the side effects,
    // not just the visible output.)
    if (world) world->renderFrame(renderThisFrame);

    if (retinaSwapRequested) {
        // Mirrors Classes/EdenViewController.mm:207-226's IS_RETINA/IS_IPAD/SCALE_WIDTH/
        // SCALE_HEIGHT toggle-and-recreate-framebuffer dance (CLAUDE.md convention #3: screen
        // metrics are globals). TODO P2: actually recreate the WebGL2 context/canvas backing
        // at the new pixel density via EAGLView_web's createFramebuffer/deleteFramebuffer.
        if (IS_RETINA) {
            IS_IPAD = FALSE;
            IS_RETINA = FALSE;
            SCALE_WIDTH = 1;
            SCALE_HEIGHT = 1;
        } else {
            IS_IPAD = TRUE;
            IS_RETINA = TRUE;
            SCALE_WIDTH = 2;
            SCALE_HEIGHT = 2;
        }
    }

    eden_autoreleasepool_drain(autoreleasePool);

    return retinaSwapRequested;
}

} // namespace eden_web
