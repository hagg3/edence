// HeapProbe_web.mm — pure measurement, no behaviour change. ROADMAP Phase M / M0.
//
// tools/headless-memory-probe.js reads the module's real heap high-water by intercepting
// `emscripten_resize_heap`, but that interceptor ONLY fires in build-st — in Release and in the
// threaded build the JS glue takes a different growth path (findings doc §1 footnote 1), so the
// one number M1's -sMAXIMUM_MEMORY sizing actually needs is invisible in exactly the builds that
// ship. This export gives it from the C side, where it is the same in every build:
//
//   heapSize     — emscripten_get_heap_size(): the WebAssembly.Memory byte length RIGHT NOW,
//                  i.e. reserved linear memory after whatever growth has happened.
//   sbrkTop      — sbrk(0): the current top of the sbrk/emmalloc region, i.e. linear memory the
//                  allocator has actually handed out to the program (<= heapSize).
//   heapMax      — emscripten_get_heap_max(): the -sMAXIMUM_MEMORY cap this build was linked
//                  with. Added for M1, which turned that cap from 2 GB into a real number, so
//                  every probe can report headroom rather than a bare byte count.
//   usedPct      — sbrkTop as a percentage of heapMax, i.e. how close this session is to the
//                  hard abort. See eden_heap_pressure_tick() below.
//   peakSbrkTop  — high-water of sbrkTop across every call to this export. SAMPLE-BASED: it is
//                  only as good as how often the probe polls. tools/browser-memory-probe.js polls
//                  on a fixed schedule through a scripted session including a reload burst, which
//                  is where the peak lives.
//
// Deliberately NOT gated on EDEN_DIAGNOSTICS — same reasoning as MeshTiming_web.mm.
#include <emscripten/emscripten.h>
#include <emscripten/heap.h>
#include <unistd.h>
#include <cstdint>
#include <cstdio>

namespace {
uintptr_t g_peakSbrkTop = 0;
bool      g_warned80 = false;
bool      g_warned90 = false;
}

extern "C" {

EMSCRIPTEN_KEEPALIVE
const char* eden_debug_heap(void) {
    static char buf[192];
    size_t    heapSize = emscripten_get_heap_size();
    uintptr_t sbrkTop  = (uintptr_t)sbrk(0);
    if (sbrkTop > g_peakSbrkTop) g_peakSbrkTop = sbrkTop;
    size_t    heapMax  = emscripten_get_heap_max();
    double    usedPct  = heapMax ? (100.0 * (double)sbrkTop / (double)heapMax) : 0.0;
    std::snprintf(buf, sizeof(buf),
        "{\"heapSize\":%llu,\"sbrkTop\":%llu,\"peakSbrkTop\":%llu,"
        "\"heapMax\":%llu,\"usedPct\":%.1f}",
        (unsigned long long)heapSize,
        (unsigned long long)sbrkTop,
        (unsigned long long)g_peakSbrkTop,
        (unsigned long long)heapMax,
        usedPct);
    return buf;
}

EMSCRIPTEN_KEEPALIVE
void eden_debug_heap_reset_peak(void) {
    g_peakSbrkTop = (uintptr_t)sbrk(0);
}

// ROADMAP Phase M / M1 step 5: "instrument the cap so it can't fail silently in the field."
//
// Before M1 the heap could grow to Emscripten's 2 GB default, so running out of linear memory was
// not a case anyone would hit. -sMAXIMUM_MEMORY makes it reachable, and with -sMALLOC=emmalloc's
// default ABORTING_MALLOC=true, reaching it ends the session. It is a CLEAN abort with a message
// rather than corruption — but without this warning the first field report would be "it crashed",
// with no way to tell a cap abort from any other abort.
//
// It is a live case, not a theoretical one: the M1 sizing run measured a ~22 MB-per-world-load
// leak with no plateau (see the -sMAXIMUM_MEMORY comment in CMakeLists.txt, and Phase M row M6),
// so a long enough session walks toward this cap by construction. Warning at 80% gives roughly
// three more world loads of notice at 768 MB.
//
// Called from eden_frame_tick() (src/entry/eden_main.cpp), throttled to once every 600 frames
// (~10 s at 60 fps) because sbrk(0) is cheap but not free and this is a slow-moving number.
// One-shot per threshold: a warning that repeats every 10 seconds is a warning nobody reads.
//
// This is a BROWSER-only surface in practice: the headless (`node eden.js`) harnesses tick the
// frame loop only a handful of times per run (headless-p1-gate reports 3), so 600 frames is never
// reached there. To exercise it from a script, call `_eden_heap_pressure_tick()` directly in a
// loop — that is how the thresholds and the message text were verified for M1.
EMSCRIPTEN_KEEPALIVE
void eden_heap_pressure_tick(void) {
    static int frames = 0;
    if (++frames < 600) return;
    frames = 0;
    if (g_warned90) return;

    size_t heapMax = emscripten_get_heap_max();
    if (!heapMax) return;
    uintptr_t sbrkTop = (uintptr_t)sbrk(0);
    if (sbrkTop > g_peakSbrkTop) g_peakSbrkTop = sbrkTop;
    double pct = 100.0 * (double)sbrkTop / (double)heapMax;

    if (pct >= 90.0 && !g_warned90) {
        g_warned90 = true;
        std::fprintf(stderr, "Eden: wasm heap at %.0f%% of its %llu MB cap (-sMAXIMUM_MEMORY). "
                             "The session will abort if it fills. Save and reload.\n",
                     pct, (unsigned long long)(heapMax / (1024 * 1024)));
    } else if (pct >= 80.0 && !g_warned80) {
        g_warned80 = true;
        std::fprintf(stderr, "Eden: wasm heap at %.0f%% of its %llu MB cap (-sMAXIMUM_MEMORY). "
                             "Memory grows ~22 MB per world load (Phase M row M6).\n",
                     pct, (unsigned long long)(heapMax / (1024 * 1024)));
    }
}

} // extern "C"
