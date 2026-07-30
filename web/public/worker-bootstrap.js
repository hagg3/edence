// worker-bootstrap.js — sketch of the D1 Web Worker entry that hosts the actual Emscripten
// module (OffscreenCanvas + PROXY_TO_PTHREAD + WASMFS/OPFS, per web-port-plan.md decision D1).
// NOT executable yet: emsdk is not installed on this machine (see docs/PORT-STATUS.md), so
// there is no eden.js/eden.wasm to import. This file exists to pin down the intended shape of
// the handshake with public/index.html before Stage P2 makes it real.
//
// Once a real Emscripten build exists (`emcmake cmake -B build && cmake --build build`, see
// web/cmake/README.md), this file's job becomes:
//   1. receive the transferred OffscreenCanvas from the page (see index.html's postMessage
//      sketch),
//   2. import the Emscripten-generated glue script (Module = {...}) with
//      Module.canvas = theOffscreenCanvas,
//   3. forward pointer/lifecycle messages from the page into whatever C-exported function
//      Stage P3's Input remap ends up using (ccall/cwrap around a small `eden_web_pointer_*`
//      C API — TODO P3, not designed yet),
//   4. let the WASM module's own main() (src/entry/eden_main.cpp) drive the
//      emscripten_set_main_loop-based frame loop from here on; this script does not run its
//      own loop.
//
// self.onmessage = (e) => {
//   const msg = e.data;
//   if (msg.type === 'init') {
//     self.__edenCanvas = msg.canvas; // OffscreenCanvas, transferred
//     importScripts('eden.js'); // TODO P2: emcc -o eden.js output, does not exist yet
//     // Module.canvas = self.__edenCanvas; -- set before Module's own bootstrap runs, per
//     // Emscripten's OffscreenCanvas docs (exact hook name TODO P2, verify against the emsdk
//     // version pinned in docs/PORT-STATUS.md once installed).
//   } else if (msg.type === 'hide' || msg.type === 'show' || msg.type === 'pagehide') {
//     // TODO P7: forward into the C++ lifecycle hooks (EdenAppDelegate_web::onVisibilityHidden
//     // / onVisibilityVisible / onPageHide, src/seam/EdenAppDelegate_web.h) via a small
//     // ccall-exposed C API — not exported yet (TODO, needs EMSCRIPTEN_KEEPALIVE wrappers).
//   } else if (msg.type.startsWith('pointer')) {
//     // TODO P3: forward into Input.mm via the (not-yet-written) web pointer-event remap —
//     // see src/seam/EAGLView_web.mm's touchesBegan/Moved/Ended/Cancelled TODO.
//   }
// };

console.log('[eden] worker-bootstrap.js is a sketch only — see file header TODOs, no build to load yet.');
