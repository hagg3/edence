// MeshTiming_web.mm — pure measurement, no behaviour change. Wraps TerrainChunk::rebuild2()
// (the CPU meshing pass) and TerrainChunk::prepareVBO() (the GL upload pass) to answer the
// question WORKING/c1-threaded-build-handoff.md's §5 item 1 asks before any off-thread-meshing
// design work: "nothing yet establishes what fraction of a frame meshing costs, or whether the
// bottleneck is meshing (CPU) or VBO upload (main-thread GL, which cannot move)."
//
// Both are exported cross-TU symbols — Classes/Terrain.mm calls chunk->rebuild2()/prepareVBO()
// on a TerrainChunk* whose methods are defined in Classes/TerrainChunk.mm, a different TU — so
// this needed no Classes/ edit. Confirmed via
// `emnm build-st/CMakeFiles/eden.dir/.../Classes/TerrainChunk.mm.o`, not guessed:
//   T _ZN12TerrainChunk8rebuild2Ev
//   T _ZN12TerrainChunk10prepareVBOEv
//
// Deliberately NOT gated behind EDEN_DIAGNOSTICS: the whole point is to measure build-rel, the
// build players actually run (same reasoning as tools/headless-load-timing.js and
// tools/headless-memory-probe.js, both of which avoid every diagnostics probe for the same
// reason). Cost is two emscripten_get_now() calls and a handful of double adds per chunk
// rebuild/upload — chunk rebuilds are at most a few hundred per frame even under heavy churn
// (Terrain.mm's list[] is sized CHUNKS_PER_SIDE^2*CHUNKS_PER_COLUMN_MAX), so this is noise next
// to the work being measured.
#include <emscripten/emscripten.h>
#include <cstdio>

namespace {

double   g_meshMs = 0.0;
double   g_meshMsMax = 0.0;
unsigned g_meshCount = 0;

double   g_uploadMs = 0.0;
double   g_uploadMsMax = 0.0;
unsigned g_uploadCount = 0;

// Added after the first burst measurement: mesh+upload alone didn't add up to the whole observed
// block (see tools/headless-mesh-burst-probe.js), so the column-read/decode step (the OTHER thing
// Terrain::prepareAndLoadGeometry's bulk-reload path does synchronously before meshing) needed its
// own number to close the gap.
double   g_readMs = 0.0;
double   g_readMsMax = 0.0;
unsigned g_readCount = 0;

} // namespace

extern "C" {

// Zero every counter — call before a sampling window so eden_debug_mesh_timing() reports only
// that window rather than a cumulative-since-boot figure.
EMSCRIPTEN_KEEPALIVE
void eden_debug_mesh_timing_reset(void) {
    g_meshMs = g_meshMsMax = g_uploadMs = g_uploadMsMax = g_readMs = g_readMsMax = 0.0;
    g_meshCount = g_uploadCount = g_readCount = 0;
}

// Static buffer, same shape as DebugState_web.mm's other JSON exports (that file is
// EDEN_DIAGNOSTICS-only; this export deliberately is not, so it stays reachable in build-rel).
EMSCRIPTEN_KEEPALIVE
const char* eden_debug_mesh_timing(void) {
    static char buf[384];
    snprintf(buf, sizeof(buf),
        "{\"meshMs\":%.3f,\"meshCount\":%u,\"meshMsMax\":%.3f,"
        "\"uploadMs\":%.3f,\"uploadCount\":%u,\"uploadMsMax\":%.3f,"
        "\"readMs\":%.3f,\"readCount\":%u,\"readMsMax\":%.3f}",
        g_meshMs, g_meshCount, g_meshMsMax,
        g_uploadMs, g_uploadCount, g_uploadMsMax,
        g_readMs, g_readCount, g_readMsMax);
    return buf;
}

} // extern "C"

// ---------------------------------------------------------------------------------------------
// --wrap=_ZN12TerrainChunk8rebuild2Ev — the meshing pass: counts+fills the per-face-direction
// vertex buckets from block data. CPU-only, no GL calls (root CLAUDE.md: its counting pass and
// fill pass must agree exactly, which is exactly the invariant an off-thread mesher would need
// to keep across two threads instead of one call).
// ---------------------------------------------------------------------------------------------
struct TerrainChunk;
extern "C" {

int __real__ZN12TerrainChunk8rebuild2Ev(TerrainChunk* self);
int __wrap__ZN12TerrainChunk8rebuild2Ev(TerrainChunk* self) {
    double t0 = emscripten_get_now();
    int result = __real__ZN12TerrainChunk8rebuild2Ev(self);
    double dt = emscripten_get_now() - t0;
    g_meshMs += dt;
    g_meshCount++;
    if (dt > g_meshMsMax) g_meshMsMax = dt;
    return result;
}

// --wrap=_ZN12TerrainChunk10prepareVBOEv — the GL upload pass. Main-thread-only by construction
// (root CLAUDE.md convention #4); this number is the floor under any off-thread-meshing design,
// since it is the part that categorically cannot move off the main thread.
void __real__ZN12TerrainChunk10prepareVBOEv(TerrainChunk* self);
void __wrap__ZN12TerrainChunk10prepareVBOEv(TerrainChunk* self) {
    double t0 = emscripten_get_now();
    __real__ZN12TerrainChunk10prepareVBOEv(self);
    double dt = emscripten_get_now() - t0;
    g_uploadMs += dt;
    g_uploadCount++;
    if (dt > g_uploadMsMax) g_uploadMsMax = dt;
}

} // extern "C"

// ---------------------------------------------------------------------------------------------
// --wrap=_ZN11FileManager10readColumnEiiP12NSFileHandle — the column-read/decode step the bulk
// reload path (Terrain.mm's `count>140` gate) runs synchronously for every newly-streamed column,
// immediately before the mesh loop. Added after the first burst measurement showed mesh+upload
// did not account for the whole observed block — this closes the gap. Confirmed cross-TU via
// `emnm build-relwdiag/CMakeFiles/eden.dir/.../Classes/FileManager.mm.o`.
// ---------------------------------------------------------------------------------------------
struct NSFileHandle;
extern "C" {

void __real__ZN11FileManager10readColumnEiiP12NSFileHandle(void* self, int cx, int cz, NSFileHandle* fh);
void __wrap__ZN11FileManager10readColumnEiiP12NSFileHandle(void* self, int cx, int cz, NSFileHandle* fh) {
    double t0 = emscripten_get_now();
    __real__ZN11FileManager10readColumnEiiP12NSFileHandle(self, cx, cz, fh);
    double dt = emscripten_get_now() - t0;
    g_readMs += dt;
    g_readCount++;
    if (dt > g_readMsMax) g_readMsMax = dt;
}

} // extern "C"
