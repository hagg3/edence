# Eden: World Builder — Engineering Documentation *(legacy iOS source)*

Internal documentation for the Eden 2.1.1 source release. Written to minimize
reverse-engineering: start with the overview, then jump to your subsystem.

> ⚠️ **This doc set describes the original iOS/Xcode target**, which is no longer
> built or tested. The live project is the Emscripten/WASM port in
> [`../web/`](../web/README.md); its own reference docs are
> [`../web/docs/`](../web/docs/README.md), organized to mirror this set so each file
> there reads as a delta against the file here.
>
> These files remain the authority on **engine internals** — voxel storage, the
> `.eden` format, meshing, worldgen, the coordinate conventions — and the web docs
> cross-reference them directly. Read them as iOS-era in *framing* only: build
> instructions, platform assumptions (UIKit, CADisplayLink, ES 1.1, touch-only input)
> and anything implying `Classes/` is pristine are stale.
>
> `Classes/` became editable on 2026-07-25 (the web port's never-edit rule was retired;
> the untouched import is tagged `pristine-engine`). **Engine changes must update the
> matching file here in the same commit** — otherwise this set silently stops being true.

## Index

### Orientation
- [architecture-overview.md](architecture-overview.md) — the big picture, ownership
  graph, the three core architectural ideas, reading order.
- [conventions-and-pitfalls.md](conventions-and-pitfalls.md) — **required reading**:
  the `(x,z,y)` convention, coordinate spaces, technical debt, assumptions,
  limitations, change-impact table.
- [execution-flow.md](execution-flow.md) — boot, frame loop, game-mode state machine,
  threading model.

### Core systems
- [world-and-terrain.md](world-and-terrain.md) — voxel storage, the toroidal window,
  block edit operations, fire/TNT dynamics, streaming.
- [rendering.md](rendering.md) — GL ES 1.1 pipeline, chunk meshing, render passes,
  vertex formats, culling.
- [terrain-generation.md](terrain-generation.md) — the offline default-world
  generator, runtime flat gen, bundle streaming.
- [eden-file-format.md](eden-file-format.md) — the `.eden` binary format (header,
  columns, creatures, directory, RLE variant, version history).
- [save-load.md](save-load.md) — FileManager pipeline, autosave triggers, legacy
  conversion.

### Gameplay & presentation
- [player-input-camera.md](player-input-camera.md) — touches, picking raycast,
  physics/collision, portals, fly mode.
- [entities-and-creatures.md](entities-and-creatures.md) — the creature system.
- [lighting-liquids-effects.md](lighting-liquids-effects.md) — colored lights,
  water/lava, portals, fireworks, particles, sky colors.
- [ui.md](ui.md) — HUD modes, menu system, world browser, GL text/UI toolkit.
- [resources-and-audio.md](resources-and-audio.md) — atlases, textures, sound engine.

### Ecosystem
- [networking.md](networking.md) — world sharing client + the `edenweb/` server.
- [third-party.md](third-party.md) — vendored libraries and repo-root miscellany.
- [engine-vs-game.md](engine-vs-game.md) — reusable vs. game-specific code, seams,
  refactoring/porting roadmap.

## Provenance & confidence
These documents were produced by close reading of the 2.1.1 source (July 2026),
cross-checked against the in-repo format docs (`MROB.txt`, `Eden_file_format.txt`)
and the Xcode project. Statements of uncertain confidence are flagged inline
("confidence: medium", "verify in …"). File/line references use the current tree;
line numbers will drift with edits — prefer the symbol names for grepping.
