// eden-host.js — audit row 28/C5: the shared boot-time primitives every other extracted module
// (eden-viewport.js, eden-keybinds.js, eden-hotbar.js, eden-input.js) and the remaining inline
// script in eden-st.html read or write. MUST be the first of the five eden-st.html split files to
// load — everything below is either a `const` computed from `document`/`location` alone (safe at
// any point) or a value another file's TOP-LEVEL code (not just a later-firing callback) touches
// immediately, e.g. eden-viewport.js's crosshair setup calls `updateCrosshairPosition()` at load
// time, which reads `canvasEl` synchronously.
//
// This split relies on a real, load-bearing fact about classic (non-module, non-defer/async)
// `<script>` tags: every one of them, inline or `src=`, shares ONE top-level scope — a `let`/
// `const` declared in an earlier tag is visible to a later tag exactly as if they were one file.
// (`eden-input.js`'s own header explains the one place this cuts the other way: a function body
// can reference a `let` declared LATER in the same or a later file, because that function only
// ever runs once the whole document's scripts have finished their synchronous first pass — i.e.
// after every declaration has already run. Only TOP-LEVEL code, executed immediately as a script
// loads, must not read a not-yet-declared binding.) Splitting the old single inline script into
// ordered `<script src>` tags does not change any of this, it only makes "who declares what, and
// who must load first" an explicit, documented contract instead of one 1300-line file's implicit
// ordering — which is the actual thing audit row 28/C5 asked for ("extraction must make those
// dependencies explicit").
'use strict';

const statusEl = document.getElementById('eden-status');
const canvasEl = document.getElementById('eden-canvas');

// Flipped true by eden-st.html's Module.onRuntimeInitialized. Read by every other split file's
// event handlers/tick functions to gate on "is the wasm module (and therefore the World) up yet".
let moduleReady = false;
function callIfReady(fn) { if (moduleReady) fn(); }

// Phase 6 wheel-jump pending-end flag — written by eden-input.js's wheelJumpPulse(), consumed one
// frame later by eden-st.html's trackCursorNeed(). Declared here (not in eden-input.js) because
// both files need it and neither is a natural owner of the other.
let jumpPulsePending = false;

// Small transient overlay for state changes that have no on-screen indicator of their own (fly
// mode, block preview) — the engine's HUD is all custom GL, so there is nowhere to put this
// in-world. Used by eden-input.js (action dispatch) and EdenGamepad's onConnect (also wired from
// eden-input.js).
let toastTimer = null;
function showToast(text) {
  let el = document.getElementById('eden-toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'eden-toast';
    el.className = 'eden-toast';   // styled in eden-ui.css
    // Announced rather than silently painted: these messages (fly mode on/off, block preview) are
    // the ONLY feedback those toggles give, so a screen-reader user would otherwise get nothing at
    // all from the keyboard shortcut.
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    document.body.appendChild(el);
  }
  el.textContent = text;
  el.style.opacity = '1';
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.style.opacity = '0'; }, 1400);
}

// Q1 (dazzling-munching-bengio.md perf audit): pick which configured build to run.
// `?build=rel` -> build-rel/ (Release, -O2 -fno-strict-aliasing, no DWARF — see CMakeLists.txt).
// Default (no param, or anything else) -> build-st/ (Debug, -O0 -g -gsource-map), unchanged
// behaviour from every prior pass. Kept as a query param rather than a second HTML file so both
// builds stay behind one set of DOM/input/settings wiring instead of two copies drifting.
// Relative (not root-absolute) so this page still resolves build-rel/build-st correctly when
// served under a URL prefix (e.g. a GitHub Pages project site at /<repo>/public/eden-st.html).
//
// `?build=thr` (audit row 36/C1, pass 63) -> build-thr/, the in-development THREADED build
// (`emcmake cmake -B build-thr -DCMAKE_BUILD_TYPE=Debug -DEDEN_THREADED=ON`). Its wasm memory is
// a SharedArrayBuffer, so the page must be cross-origin isolated or instantiation fails outright
// — tools/serve.js sends the required COOP/COEP headers, `python3 -m http.server` does not, and
// GitHub Pages CANNOT (see tools/build-dist.js's note), which is what public/eden-coi.js exists
// to work around.
//
// `let`, not `const`: edenSettleBuildDir() below can downgrade it. Read LAZILY everywhere (the
// eden.js <script src> and Module.locateFile are both evaluated after that call), so the
// downgrade is seen by everything that matters.
const EDEN_BUILD_PARAM = new URLSearchParams(location.search).get('build');
let EDEN_BUILD_DIR = EDEN_BUILD_PARAM === 'rel' ? '../build-rel/'
  : EDEN_BUILD_PARAM === 'thr' ? '../build-thr/'
  : '../build-st/';

// Audit row 36/C1, pass 65 — FAIL CLOSED. Called by eden-st.html from EdenCOI.whenSettled(), i.e.
// after public/eden-coi.js has had its chance to obtain cross-origin isolation (service worker +
// one reload) and immediately before the chosen build is actually requested.
//
// Loading build-thr into a page that is not isolated does not produce a diagnosable error: the
// module throws "SharedArrayBuffer is not defined" somewhere inside instantiation, main() never
// runs, and what the player sees is a live DOM over a black canvas — the exact picture
// web/CLAUDE.md warns "reads as a renderer bug and is not one". Running the single-threaded build
// instead is strictly better in every case: it is the same game, it always works, and the reason
// for the downgrade is stated on the status line rather than left to devtools archaeology.
function edenSettleBuildDir() {
  if (EDEN_BUILD_PARAM !== 'thr' || self.crossOriginIsolated) return;
  EDEN_BUILD_DIR = '../build-st/';
  const why = window.EdenCOI ? window.EdenCOI.reason() : 'eden-coi.js did not load';
  console.warn('[eden-host] ?build=thr needs a cross-origin-isolated page (COOP: same-origin + ' +
    'COEP: require-corp) for SharedArrayBuffer, and this page is not isolated (' + why + '). ' +
    'Loading the SINGLE-THREADED build instead. Locally, serve with `node tools/serve.js <port>`, ' +
    'which sends both headers directly.');
  statusEl.textContent = 'Threaded build unavailable (' + why + ') — running single-threaded.';
  // …and a toast, because the status line is a single shared line that the shim's own
  // `[eden-gl] drawable resized…` print overwrites a second or two later (verified in Safari,
  // pass 65) — leaving no on-page trace at all of a downgrade the player explicitly asked against.
  showToast('Threaded build unavailable — running single-threaded');
}
// Audit row 15/B6: content-hashed filenames for long-cache-life deploys. Empty here — this file
// is served verbatim (unhashed) by tools/serve.js for local dev, per that file's own header on why
// hashing doesn't belong in the dev loop. `tools/build-dist.js` rewrites this literal object (and
// the 'eden.js' src eden-st.html's own inline script uses) in the COPY it assembles into dist/,
// mapping each bare filename Emscripten's glue asks for to the hashed name actually on disk, so
// eden.js itself never needs to know its own wasm/data file was renamed.
const EDEN_ASSET_MAP = {};
