# Eden: World Builder — Web Port (`web/`)

See the main [`../README.md`](../README.md) for what this is and how to build/run it locally.
This file only covers layout that's specific to working inside `web/`. Reference docs for this
port: [`docs/README.md`](docs/README.md); reference docs for the underlying engine (still
accurate on engine internals, iOS-era in framing): [`../docs/README.md`](../docs/README.md).

`web/` is tracked by the **same** git repo as the rest of the tree. Engine history and port
history share one log, which is what makes `git diff pristine-engine -- ../Classes/` a
meaningful question to ask.

## Layout
```
web/
  CMakeLists.txt          # builds the 81 engine sources (via emcmake) + the seam/shims
  cmake/                  # toolchain helpers
  tools/
    engine-sources.txt    # AUTHORITATIVE list of the compiled engine files
  src/
    entry/                # WASM entry point + JS/HTML host, worker bootstrap
    seam/                 # platform-seam replacements (EAGLView/ViewController/AppDelegate/main)
    shim/
      foundation/         # minimal Foundation shim (NSString/NSData/NSFileHandle/…)
      gl/                 # thin ES 1.1 fixed-function -> WebGL2 shim
  public/                 # static host assets (index.html, eden-st.html, audio, Eden.eden)
  build-st/                # single-threaded debug build output (the one actually used) — gitignored
  build/                   # threaded default build output (browser-only, needs COOP/COEP) — gitignored
  emsdk/                   # local emsdk checkout (gitignored, not vendored — see root README)
  docs/                    # topic reference docs (README.md is the index)
```

## Key engine constraints (do not violate)
- Terrain APIs take `(x, z, y)` with y vertical; chunk-local index `CC(x,z,y)=x*256+z*16+y`.
- Never renumber block types / regenerate `colorTable`; on-disk structs are raw-memcpy'd.
- Keep load-bearing misspellings (`chunksToUpdateImmediatley`, `criticle`); keep
  commented-out archaeology; surgical edits in existing style.
- All GL on one thread; the only other thread is the world-load pthread.
- **The answer to a toolchain or browser complaint is a build flag or a shim** (CMake seam
  exclusion, `-Wl,--wrap=`, or a mutable engine global written from a seam) — never an engine
  edit. Platform differences belong in `src/seam/`/`src/shim/`.
- `../Classes/` and the root `.mm` files are editable for *game/engine* work (perf, correctness,
  features). The untouched import is tagged `pristine-engine`; keep engine edits in their own
  commits and update the matching `../docs/` file with them.

`docs/README.md` indexes this port's reference docs; `../docs/README.md` indexes the engine docs.
