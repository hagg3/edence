# Eden Web Port — Reference Documentation

Topic-organized reference for the Emscripten/WASM port. Mirrors the structure of
[`../../docs/`](../../docs/README.md) so each file can be read as a **delta**: it covers what the
port adds or replaces, and defers to the root doc for everything the port didn't change.

**How this differs from the other doc sets:**

| Location | What it is | Read it for |
|---|---|---|
| `web/docs/` (here) | Durable reference for the port | "how does X work" |
| [`../../docs/`](../../docs/README.md) | **Legacy iOS engine documentation** (2010–2014 Xcode target) | engine behaviour, the `.eden` format, worldgen |

Root `../../docs/` remains the authority on engine internals and is cross-referenced throughout.
Treat it as legacy: it describes the original iOS build, which is no longer built or tested, and
the engine (`../../Classes/`) is no longer frozen, so it can also drift from the code. Where an
engine change lands in `Classes/`, the matching root doc should be updated with it.

## Index

### Orientation
- [architecture-overview.md](architecture-overview.md) — the port's layers over the engine, the
  seam/wrap/shim lever table, reading order. **Start here.**
- [conventions-and-pitfalls.md](conventions-and-pitfalls.md) — **required reading**: the port's own
  hard-won rules, and where a root-doc rule needs a web amendment.
- [build-and-toolchain.md](build-and-toolchain.md) — CMake, emsdk, the build flavours
  (`build-st`/`build-rel`), non-optional link flags and why, `EDEN_SEAM_EXCLUDE`.
- [execution-flow.md](execution-flow.md) — boot order, the Emscripten frame loop, headless driving.

### The shims
- [objc-runtime.md](objc-runtime.md) — the hand-written GNU gnustep-1.9 runtime.
- [gl-shim.md](gl-shim.md) — GL ES 1.1 → WebGL2, matrix-palette emulation, state dirty-tracking.
- [third-party.md](third-party.md) — vendored code, the Foundation subset, ivar-layout fix.

### Core systems (deltas)
- [world-and-terrain.md](world-and-terrain.md) · [rendering.md](rendering.md) ·
  [terrain-generation.md](terrain-generation.md) · [eden-file-format.md](eden-file-format.md) ·
  [save-load.md](save-load.md) — persistence via MEMFS + IDBFS is the big one.

### Gameplay & presentation (deltas)
- [player-input-camera.md](player-input-camera.md) — pointer lock, keyboard/mouse, touch
  arbitration, synthetic HUD touches.
- [ui.md](ui.md) — the DOM host (main menu, load/new world, settings, pause menu,
  hotbar) vs. the GL HUD: what each screen does and how it drives the engine.
- [design-system.md](design-system.md) — how every DOM surface *looks*: tokens,
  components, the `--u` scale unit, iconography, the accessibility contract. Read
  before writing any UI CSS or markup. Live specimen: `public/eden-ui-specimen.html`.
- [entities-and-creatures.md](entities-and-creatures.md) ·
  [lighting-liquids-effects.md](lighting-liquids-effects.md) ·
  [resources-and-audio.md](resources-and-audio.md) · [networking.md](networking.md)
