# Execution Flow, Boot & Threading (Web Port)

Read [`../../docs/execution-flow.md`](../../docs/execution-flow.md) first for the
`World`/game-mode state machine and per-frame update/render order — those are
unchanged. This file covers what replaces the UIKit app shell and CADisplayLink loop.

## No UIKit shell
There is no `UIApplicationMain`, no `CAEAGLLayer`, no `CADisplayLink`. Their
replacements:
- `main.m` → `src/entry/eden_main.cpp`.
- `EdenAppDelegate`/`EdenViewController`/`EAGLView` → `src/seam/EdenAppDelegate_web.{h,cpp}`,
  `EdenViewController_web.{h,cpp}`, `EAGLView_web.mm`.
- The frame loop is Emscripten's rAF-driven main loop, not a display-link callback.

## Threading
`EDEN_THREADED` (`CMakeLists.txt:39`) defaults to **ON** — real pthreads +
OffscreenCanvas + `PROXY_TO_PTHREAD` + COOP/COEP — but that `build/` tree is currently
**stale and won't configure** (it points at an old absolute repo path); it is not
exercised day to day. The build actually used and runnable (`build-st`,
`-DEDEN_THREADED=OFF`) is **single-threaded end to end**, runnable under `node
eden.js` for headless checks. `EDEN_THREADED` is a build flag, not a source fork —
deliberately kept that way so the engine code stays thread-agnostic. See
[build-and-toolchain.md](build-and-toolchain.md) for both build commands.

Root's "the only other thread is the world-load pthread" does not apply to
`build-st`. The engine's one native thread (`World.mm`'s `pthread_create` →
`loadWorldThread`) is handled there by a synchronous shim,
`src/seam/pthread_sync_web.c`: it runs the load routine **synchronously inside
`pthread_create` itself**, because Emscripten's single-threaded stub `pthread_create`
otherwise never runs the routine at all (this used to freeze "click to load a world"
forever — `doneLoading` never advanced past 1). Two constraints on this file: it must
not link into the threaded build (`if(NOT EDEN_THREADED)`, `CMakeLists.txt:331-333`,
would collide with real pthreads), and it must stay plain C, not `.mm` — a
`prefix-header`/`-x objective-c++` treatment would break it. Consequence: world load
blocks the main thread for its whole duration, with no progress UI.

**How long, measured (2026-07-31, `tools/headless-load-timing.js`, 3 runs each):**

| build | contiguous main-thread block during a world load |
|---|---|
| `build-rel` (what players run) | **20–27 ms** |
| `build-st` (debug, ~2.5× slower) | **51–62 ms** |

That is one dropped frame in release — not the tab-killing freeze this paragraph used
to claim, and not what project-audit row 9 (A6) assumed when it rated the fix Opus 5
(high) and gated the whole threaded build behind it. The load is **bounded by
construction**: it is always the same 324 columns of the toroidal window (18×18 at
32 KB), whatever the size of the save file, so it does not grow with playtime. Re-run
the tool before acting on any claim to the contrary — including this one.

The part that *can* still get slow is not CPU: on a host that honours HTTP `Range`,
the lazy `Eden.eden` FS node issues **18 synchronous XHRs during the load**, i.e. 18
round trips of dead main thread. Invisible under node (`fs.readSync`) and on
localhost, and the deployed site never takes that path at all (GitHub Pages ignores
`Range`, so it uses the eager whole-file fallback — audit row A11). If this port is
ever hosted somewhere that does serve ranges, attack it with read-ahead in the FS
node, not by restructuring the engine's load.

## Boot order (the gotcha that matters)
`Module.onRuntimeInitialized` fires **before** `main()` runs. `main()` asserts screen
metrics of 1136×640 in `establishScreenMetrics` (the same "screen metrics are globals
set once at startup" pattern as the root doc's `EAGLView initWithCoder:` step, just
relocated) — so any page-sizing logic must re-run *after* `callMain` and dedupe
against the real canvas dimensions, never memoize in JS before `main()` has run.

Two async populates are registered as `Module.preRun`/`addRunDependency` gates before
`main()` is allowed to proceed:
1. IDBFS → MEMFS populate (`public/eden-storage.js`) — see
   [save-load.md](save-load.md).
2. The `Eden.eden` bundle setup (`src/seam/js/eden_default_world.pre.js`). As of pass 46 this
   normally downloads nothing at all: it probes once for HTTP byte serving and installs a lazy,
   range-fetching FS node, so what gates `main()` here is a single 1-byte probe rather than a
   52 MB download. On a server without byte serving it falls back to the pass-30 whole-file fetch
   and this gate becomes the long one again. See [save-load.md](save-load.md).

Both block `main()`/`Menu::loadWorlds` until they resolve. `eden_settings_init()` runs
later still, after `main()`.

Two async populates are registered as `Module.preRun`/`addRunDependency` gates before
`main()` is allowed to proceed (see previous section); `eden_settings_init()` runs
even later still, after `main()` (it needs a live `World`) — restored settings that
must take effect before the first frame (`render_scale`, `dpr_cap`) need a one-shot
re-apply gated on `eden_settings_loaded()`, not applied inline during init.

## Frame-boundary gotcha
**`glClear` is not a reliable frame-boundary signal** — `Graphics::prepareMenu`
clears the color buffer but `Graphics::prepareScene` does not (the sky is drawn as
geometry, not a clear) — so any per-frame instrumentation keyed off `glClear` silently
stops updating the instant gameplay starts. The real boundary is the shim's own
`eden_gl_stats_frame_boundary()`, called once per frame from `drawFrame`.

`Module._eden_debug_tick(n)` pumps `n` frames synchronously for headless driving —
useful, but note `checkStackCookie` only runs on the real rAF path, not under a manual
`_eden_debug_tick` pump, so "N frames with no trap" under a manual pump proves less
than N real frames would. Also: a backgrounded browser tab throttles rAF to ~0 fps —
that looks like a hang from the outside but isn't one.

## Frame-rate-dependent gameplay (fixed via wrap, not an engine change)
`Player.mm:940-958` damps velocity per-frame rather than scaling by `etime`, so
steady-state walk speed is proportional to actual frame rate — invisible on iOS's
implicit ~56fps tuning point, very visible at Chrome's 75-144Hz (measured as low as
-61% of intended speed). Fixed entirely outside `Classes/` via
`-Wl,--wrap=_ZN6Player8setSpeedE6Vectorf` (`src/seam/Movement_web.mm`): the wrap
scales only the acceleration term by `k = clamp(DT_REF/dt_smoothed, 1, 4)`, fed once
per rAF from `eden_movement_tick()`; the `max_walk_speed` ceiling and gravity/jump arc
are untouched (preserves the original "bouncy" ramp-up feel). Setting: `fps_normalize`
(default ON). See [player-input-camera.md](player-input-camera.md) for the sibling
sprint-multiplier fix in the same wrap.

## Headless driving
`node build-st/eden.js` never exits by design (`Module.setStatus`'s
`simulate_infinite_loop=true`, matching the browser's own shape). Expected output:
`[eden-gl] no canvas '#eden-canvas'` then three `[eden-p1] tick N: World::update
returned` lines — anything else is a regression. See
[build-and-toolchain.md](build-and-toolchain.md) for the exact invocation and the
`vm.runInThisContext` requirement (a bare `require('./eden.js')` does not share
`Module` with the caller's scope).
