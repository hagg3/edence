// eden_main.cpp — the real WASM entry point (`int main()`). Owns:
//   1. calling into src/seam/main_web.* to build the EdenAppDelegate/EdenViewController/World
//      chain (mirrors UIApplicationMain() handing off to the app delegate);
//   2. the requestAnimationFrame-equivalent loop that used to be CADisplayLink
//      (Classes/EdenViewController.mm, replaced) — via emscripten_set_main_loop, which
//      internally uses rAF and (critically) does NOT block the browser's event loop, unlike a
//      plain while(true) — this matters doubly under D1 since Stage P2 runs this from a
//      worker via PROXY_TO_PTHREAD/OffscreenCanvas, per web-port-plan.md D1: "Responsive page
//      — the game loop blocking in a worker never freezes the browser UI."
//
// STATUS: sketch-level per the task brief ("Sketch-level is fine; label TODOs"). Nothing here
// touches GL yet (Stage P1's own success bar: "world->update(etime) runs one tick... without
// touching GL" — World::render() is called per EdenViewController_web's drawFrame(), but every
// GL call it makes is currently a tracked-state-only or no-op stub, see src/shim/gl —
// harmless to call, produces nothing on screen until Stage P2).
//
// EDEN_THREADED build (default ON, see CMakeLists.txt): this file is expected to run ON THE
// WORKER thread (PROXY_TO_PTHREAD proxies `main` itself there), talking to an OffscreenCanvas
// transferred from the page — see public/worker-bootstrap.js for the JS-side half of that
// handshake. EDEN_THREADED=OFF (single-thread fallback, plan D1 fallback note): this file runs
// on the browser main thread directly against a normal <canvas>; the #ifdef below is where
// that fork would go once Stage P2 needs to branch on it — TODO P2, not needed yet since
// nothing here is thread-sensitive at the P1 stage.

#include "../seam/main_web.h"
#include "../seam/EdenAppDelegate_web.h"
#include "../shim/gl/gl_es1_shim.h"

#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#endif

// perf-audit row #14: an optional frame-rate cap, mainly for thermal/battery on touch profiles
// (defaulted there — see Settings_web.mm's eden_apply_input_profile). `emscripten_set_main_loop`
// is registered with fps=0 (rAF-driven, the display's native refresh rate) so the cap is a simple
// "skip this rAF callback if we're early" gate rather than a second timer — cheap, and it can
// never make the loop run FASTER than the display, only skip ticks.
extern "C" int eden_get_fps_cap(void);

static void eden_frame_tick() {
    eden_web::EdenAppDelegate* app = eden_web::eden_seam_get_app_delegate();
    if (!app) return;
    if (!app->viewController.isAnimating()) return;

#ifdef __EMSCRIPTEN__
    int capFps = eden_get_fps_cap();
    if (capFps > 0) {
        static double lastFrameMs = 0.0;
        double now = emscripten_get_now();
        double minInterval = 1000.0 / (double)capFps;
        if (lastFrameMs != 0.0 && now - lastFrameMs < minInterval) return;
        lastFrameMs = now;
    }
#endif

    app->viewController.drawFrame();
    // TODO P2: react to a true return (retina/graphics-quality swap requested) by actually
    // recreating the WebGL2 context at the new pixel density via EAGLView_web's
    // create/deleteFramebuffer — EdenViewController_web::drawFrame() already flips the
    // IS_RETINA/SCALE_WIDTH/SCALE_HEIGHT globals (CLAUDE.md convention #3), this loop just
    // doesn't act on the flip yet.
}

#if defined(__EMSCRIPTEN__) && defined(EDEN_DIAGNOSTICS)
// TEMPORARY test-harness aid (pass 22, delete with the DebugState probe): the browser throttles
// the rAF-driven main loop to ~0 fps while the automation tab is backgrounded (document.hidden),
// which makes `_eden_input_pointer_event` -> Menu::update consumption non-deterministic (a touch
// may sit unclaimed for seconds). This lets a test pump N frames synchronously regardless of tab
// visibility: `Module._eden_debug_tick(30)`. It just calls the same frame tick the rAF loop does.
// Gated behind EDEN_DIAGNOSTICS (perf audit Q7) — a shipped build has no scripted driver to serve.
extern "C" EMSCRIPTEN_KEEPALIVE void eden_debug_tick(int n) {
    for (int i = 0; i < n; i++) eden_frame_tick();
}
#endif

int main(int argc, char** argv) {
    (void)argc; (void)argv;

    // The WebGL2 context MUST be live before eden_seam_main(), and that ordering is not a
    // preference — it is measured. `World::World()` calls `Graphics::initGraphics()`, which
    // issues real glGenBuffers/glBufferData/glEnable during construction (PORT-STATUS Pass 8
    // §1). Stage P1's premise that "construction is GL-free" was wrong; creating the context
    // first is what makes those calls land on a real context instead of the headless guard.
    //
    // A failure here is NOT fatal: under `node eden.js` there is no canvas, create() returns 0,
    // and the guard keeps the whole engine running headless — which is exactly what the
    // EDEN_THREADED=OFF debug build wants.
    eden_gl_context_create(0, 0);

    // TODO D1: OffscreenCanvas handshake — see public/worker-bootstrap.js sketch. This main()
    // is expected to be the PROXY_TO_PTHREAD-proxied entry when EDEN_THREADED=ON (the default,
    // see CMakeLists.txt EDEN_THREADED option) — Emscripten runs it on the worker
    // automatically in that configuration, no manual pthread_create needed here.

    eden_web::eden_seam_main();

#ifdef __EMSCRIPTEN__
    // fps=0 -> driven by requestAnimationFrame at the display's native refresh rate;
    // simulate_infinite_loop=true -> main() returns immediately, matching Emscripten's
    // expected shape for a persistent, event-driven web app (mirrors the original's
    // UIApplicationMain() never really "returning" either).
    emscripten_set_main_loop(eden_frame_tick, 0, /*simulate_infinite_loop=*/true);
#else
    // TODO P0.1/P1: no non-Emscripten target is planned (this engine has no desktop port per
    // docs/engine-vs-game.md's own note: "a desktop port was once contemplated but never
    // started"), so this branch exists only so the file has SOME shape to read/reason about
    // on a machine without emcc (this one, currently — see PORT-STATUS.md). Not a real
    // fallback loop.
    eden_frame_tick();
#endif

    return 0;
}
