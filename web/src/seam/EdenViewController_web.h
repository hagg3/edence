// EdenViewController_web.h — Stage P1/P2 seam replacement for Classes/EdenViewController.mm.
//
// UNLIKE EAGLView_web.mm (which is forced to reuse the original Classes/EAGLView.h — see that
// file's header comment for why), NOTHING outside Classes/EdenViewController.mm itself
// includes "EdenViewController.h" (grep-confirmed, see docs/PORT-STATUS.md). So this seam
// replacement is free to be a plain C++ class instead of an Objective-C UIViewController
// subclass — there is no nib/storyboard on the web, no CADisplayLink-vs-NSTimer fallback
// dance (Classes/EdenViewController.mm:135-181, all iOS-runtime-version-detection cruft with
// no web equivalent), and starting this file in C++ rather than perpetuating Objective-C is a
// small early step toward web-port-plan.md Phase R's "D3(b): mechanical de-Obj-C happens
// file-by-file" — this file just never accrues the debt in the first place.
//
// Owns the `World*` and reproduces Classes/EdenViewController.mm's drawFrame() logic
// (etime computation, world->update/render, the IS_RETINA/IS_IPAD graphics-quality swap) —
// see the .cpp for the line-by-line mapping. Driven by src/entry/eden_main.cpp's
// requestAnimationFrame-equivalent loop (Stage P2/D1 worker loop), not by this class itself —
// this class does not own the loop, just one frame's worth of work, matching the original
// split (EdenViewController owned the CADisplayLink target, but drawFrame did the actual work
// per invocation).
#ifndef EDEN_SEAM_EDENVIEWCONTROLLER_WEB_H
#define EDEN_SEAM_EDENVIEWCONTROLLER_WEB_H

class World;

namespace eden_web {

class EdenViewController {
public:
    EdenViewController();
    ~EdenViewController();

    // TODO P2: originally driven by -awakeFromNib (EAGLContext creation, low-memory-device
    // detection via [NSProcessInfo processInfo].physicalMemory — Classes/EdenViewController.mm:24-74).
    // The memory-tier detection (LOW_GRAPHICS/LOW_MEM_DEVICE) has no direct web equivalent;
    // TODO P2: derive a substitute from navigator.deviceMemory (widely but not universally
    // supported) or simply default to best-graphics on desktop browsers and flag it a known
    // "web build differs from device here" note in docs/player-input-camera.md /
    // docs/rendering.md once decided.
    void construct();

    void startAnimation();
    void stopAnimation();
    bool isAnimating() const { return animating; }

    // One frame. Returns what World::update returned (retina-swap-requested flag) so the
    // caller (src/entry/eden_main.cpp) can decide whether to react — mirrors
    // Classes/EdenViewController.mm:188-229's drawFrame, minus the actual EAGLView
    // framebuffer calls (TODO P2, see EAGLView_web.mm).
    //
    // Audit row A4: `renderThisFrame == false` runs the update half only (input consumption,
    // physics, streaming) and hands World::renderFrame(FALSE) the draw skip. The frame-rate cap
    // in eden_main.cpp uses that instead of skipping the whole tick — see that file's gate.
    bool drawFrame(bool renderThisFrame = true);

    World* world = nullptr;

private:
    bool animating = false;
    double startTime = 0.0;   // seconds, monotonic — TODO P1: emscripten_get_now()-backed once
                               // building under emcc (see NSDate.mm's same placeholder note)
    double lastTime = 0.0;
};

} // namespace eden_web

#endif
