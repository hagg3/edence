# Eden: Community Edition (edence)

An experimental web port and expansion of Eden: World Builder 2.1.
Eden: World Builder was created and is developed by Ari Ronen / Kingly Games.

Forked from: [BarrelDevelopment](https://github.com/BarrelDevelopment/EdenWorldBuilder), which
itself is a fork of the Eden: World Builder 2.1 source code released in 2018 by Ari Ronen.

Join the official [Discord](http://discord.gg/rjYXwBC) for the game and community.

## Acknowledgments
* [Ari Ronen + Eden - World Builder](https://apps.apple.com/us/app/eden-world-builder/id405743220)
* [BarrelDevelopment](https://github.com/BarrelDevelopment/EdenWorldBuilder)

## What this is

This repo contains the original 2010–2014 iOS engine source (`Classes/`, `Lighting.mm`) plus a
WebAssembly + WebGL port of it (`web/`), built with Emscripten. The web port runs the
**unmodified** ObjC++ engine (via a hand-written wasm ObjC runtime + a thin ES1→WebGL2 shim);
only the platform seam (surface, input, file I/O, audio, networking) is replaced — see
`web/src/seam/` and `web/src/shim/`.

The game is playable in a browser today: menu → pick a world → walk, look, mine, build, hear
sound.

Documentation: [`docs/README.md`](docs/README.md) covers the engine (voxel storage, the `.eden`
format, rendering, worldgen, etc. — iOS-era in framing but still accurate on engine internals).
[`web/docs/README.md`](web/docs/README.md) covers everything specific to the web port. Start with
[`web/README.md`](web/README.md) for the port's own layout.

## Building and running the web port locally

Prerequisites: `cmake` (4.x), `node`, and the [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html).
This repo does not vendor emsdk — install it wherever convenient and either add it to `web/emsdk/`
or `source` its `emsdk_env.sh` from anywhere before configuring.

```
cd web && source /path/to/emsdk/emsdk_env.sh

# single-threaded debug build — the one to use day-to-day, runs under node or a browser
emcmake cmake -B build-st -DCMAKE_BUILD_TYPE=Debug -DEDEN_THREADED=OFF
cmake --build build-st -j8

# serve from web/ (NOT from build-st/) — a wrong cwd 404s eden.js and the page hangs.
# Use tools/serve.js, not `python3 -m http.server`: it does compression, ETag revalidation,
# and real HTTP byte-range serving, which the bundled ~52 MB Eden.eden needs.
node tools/serve.js 8123
# open http://localhost:8123/public/eden-st.html
```

- **Use a fresh port after every rebuild.** The browser will happily serve a stale `eden.wasm`;
  a new origin is the cheapest way to bust the cache.
- To reconfigure after touching audio assets, rerun the `emcmake cmake -B build-st …` line above —
  it regenerates `public/audio-manifest.json`.
- **Headless smoke test** (no browser, much faster for logic bugs): `cd build-st && node eden.js`.
  It does not exit (`simulate_infinite_loop=true`, the correct browser shape) — expect
  `[eden-gl] no canvas '#eden-canvas'` then `[eden-p1] tick 0/1/2: World::update returned`; anything
  else is a regression. Checked-in headless tests live in `web/tools/headless-*.js`.
- The threaded default build (`emcmake cmake -B build && cmake --build build`) needs COOP/COEP
  headers and OffscreenCanvas support; prefer `build-st` unless you're specifically testing that
  path.

### Building the optimized Release build locally

```
cd web && source /path/to/emsdk/emsdk_env.sh
emcmake cmake -B build-rel -DCMAKE_BUILD_TYPE=Release -DEDEN_THREADED=OFF
cmake --build build-rel -j8

node tools/serve.js 8123   # from web/, same as above
# open http://localhost:8123/public/eden-st.html?build=rel
```

This is `-O2 -fno-strict-aliasing`, no DWARF, no `ASSERTIONS` — the build meant for hosting.
`build-rel/`, `build/`, `build-st/` and `emsdk/` are all gitignored; no build output is committed.

## Hosting it on GitHub Pages

[`.github/workflows/pages.yml`](.github/workflows/pages.yml) builds and deploys the Release build
automatically: on every push to `main` that touches `Classes/`, `Lighting.mm`, or `web/`, it
installs a pinned emsdk, configures/builds `build-rel` (Release, single-threaded — no
SharedArrayBuffer/COOP/COEP needed, so plain static Pages hosting works), assembles a
`web/_site/` with real (dereferenced) copies of `public/` plus the wasm/js/data output, and
publishes it via `actions/upload-pages-artifact` + `actions/deploy-pages`.

To enable it on a fresh clone of this repo: Settings → Pages → source "GitHub Actions" (or
`gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow`), then push to `main` or run
the workflow manually from the Actions tab (it also has `workflow_dispatch`).
