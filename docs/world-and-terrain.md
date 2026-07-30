# World Representation & Terrain System

## Purpose
How voxels are stored in memory, how the "infinite" world illusion works, how blocks
are read/edited, and how gameplay dynamics (fire, TNT, doors, portals) are layered on
top of the voxel grid.

## Key constants (`Classes/Constants.h`)

| Constant | Value | Meaning |
|---|---|---|
| `CHUNK_SIZE` | 16 | Blocks per chunk edge |
| `T_SIZE` | 288 | Resident window edge, in blocks (18 chunks) |
| `T_HEIGHT` | 64 | World height, blocks (4 chunks) |
| `T_RADIUS` | 9 | Half the window, in chunks |
| `CHUNKS_PER_SIDE` | 18 | Window edge in chunks |
| `CHUNKS_PER_COLUMN` | 4 | Vertical chunks |
| `NUM_BLOCKS` | 111 | Highest block type id |
| `BLOCK_SIZE` | 1.0f | World units per block |

World height is hard-capped at 64. (The later 2.2.x App Store builds raised the build
limit; files from those versions load here but are cut off at y=64 — see repo README.)

## Block identity: type + color

Every voxel is two bytes:
- `block8` type — `enum BLOCK_TYPES` in `Constants.h` (0 = air, 1 = bedrock, …,
  ramps/side-ramps in groups of 4 orientations, liquids at 4 fill levels, doors and
  portals as 2-block-tall composites, `TYPE_BT*` = "block TNT" variants that explode
  into a 5×5 patch of their base material).
- `color8` paint — index into the global `colorTable[256]`; 0 = unpainted.
  The table is generated procedurally in `Hud::genColorTable()` (`Hud.mm:151`):
  entry 0 is white, then 54 entries = 9 hues × 6 shades via HSV (hue column 8 is the
  grayscale ramp). `NUM_COLORS` is 54.

Per-type static properties live in `Globals.mm`:
- `blockinfo[NUM_BLOCKS+1]` — bit flags (`IS_FLAMMABLE`, `IS_NOTSOLID`, `IS_RAMP`,
  `IS_ATLAS2` = drawn in transparent pass, `IS_LIQUID`, `IS_WATER/IS_LAVA`,
  `IS_OBJECT` = rendered as a mesh object not a cube, `IS_DOOR`, `IS_PORTAL`,
  `IS_HARD`, `IS_BLOCKTNT`, …). **This table is the single source of truth for block
  behaviour**; adding a block type means adding rows here, in `blockTypeFaces`
  (face→texture mapping) and `blockColor` (default RGB).
- `blockTypeFaces[type][6]` — which atlas tile each of the 6 faces uses.
- `blockColor[type][3]` — intrinsic tint.

## The toroidal resident window

The world is conceptually huge (chunk coordinates are packed into 15 bits each by
`twoToOne` — `Util.mm:1053` — so the addressable world is 32,768 × 32,768 chunks;
the default world's centre sits at chunk (4096, 4096) ⇒ block ≈ 65,536).

Only a **288×288×64 window around the player** is in memory, in two parallel
structures, both indexed *modulo the window size* so absolute world coordinates can be
used directly:

1. **`block8* blockarray`** — flat type-only cache used by all hot-path reads
   (meshing, collision, lighting). Access macros in `Terrain.h:33-37`:
   ```c
   GBLOCKIDX(x,z,y) = ((x+g_offcx)%T_SIZE)*(T_SIZE*T_HEIGHT)
                    + ((z+g_offcz)%T_SIZE)*T_HEIGHT + y
   ```
   `g_offcx = g_offcz = T_SIZE*100` exist only to keep the `%` result positive.
   Because indexing is modular, **no data moves when the player walks** — streaming
   overwrites the cells that now map to the newly-entered columns.
   Note colors are *not* in this array; color reads go through the chunk objects.

2. **`TerrainChunk** chunkTable`** — 18×18×4 = 1296 chunk objects, allocated once in
   `Terrain::allocateMemory()` (`Terrain.mm:241`) and **reused forever** (never
   freed/reallocated during play; `resetForReuse()`/`setBounds()` repurpose them).
   Indexed by the `threeToOne(cx,cy,cz)` macro (`Util.h:120`), again modulo
   `CHUNKS_PER_SIDE`. A chunk knows its absolute bounds in `pbounds[6]` — comparing
   `pbounds` against the expected coordinates is how the code detects that a table
   slot still holds a stale, faraway chunk (see streaming below).

Each `TerrainChunk` (`TerrainChunk.h`) owns:
- `pblocks[4096]`, `pcolors[4096]` — authoritative type+color, layout `CC(x,z,y) =
  x*256 + z*16 + y` (y fastest ⇒ vertical strips are contiguous, matching the save
  format).
- Mesh state (see [rendering.md](rendering.md)): staging vertex arrays, per-face
  vertex counts, GL buffer names — in two copies, plain and `rt*`-prefixed
  ("render-thread") versions swapped by `prepareVBO()`.
- `StaticObject* objects` — extracted door/portal/golden-cube/flower instances.
- `modified` flag — set on any edit; drives incremental saving.

`Vector8* lightarray` (RGB byte per voxel, same toroidal indexing) holds the colored
point-light field; see [lighting-liquids-effects.md](lighting-liquids-effects.md).
Skipped entirely on `LOW_MEM_DEVICE`.

### Memory budget
blockarray ≈ 5.3 MB, chunk blocks+colors ≈ 10.6 MB, lightarray ≈ 15.9 MB, plus
transient meshes. This is why `LOW_MEM_DEVICE` (< ~300 MB RAM) drops the light field
and loads synchronously.

## Reading and writing blocks (`Terrain.mm`)

Read APIs (world coordinates, `(x, z, y)` order — see
[conventions-and-pitfalls.md](conventions-and-pitfalls.md)):
- `getLandc(x,z,y)` — free function, raw `GBLOCK`, no bounds check except what the
  macro provides. Fast path used everywhere.
- `Terrain::getLand` — adds y bounds check and a fully-wrapped `GBLOCK_SAFE`.
- `getColorc` / `Terrain::getColor` — go through the chunk's `pcolors`.

Write path — always go through these, never poke arrays directly:
- `Terrain::setLand(x,z,y,type,chunkToo)` — writes `blockarray` and (if `chunkToo`)
  the owning chunk's `pblocks` + `modified` flag. Does **not** mark meshes dirty.
- `Terrain::updateChunks(x,z,y,type)` (`Terrain.mm:1394`) — the standard "place a
  block" primitive: clears color if erasing, calls `setLand`, then marks the chunk
  and all 6 face-neighbouring chunks dirty via `addToUpdateList2`.
- `Terrain::setColor` — writes chunk color, returns whether it changed.

Dirty-list mechanics: `chunksToUpdate[]` (per chunk) + `columnsToUpdate[]` (per
column, an iteration accelerator). Drained once per frame by
`prepareAndLoadGeometry`; `chunksToUpdateImmediatley[]` then queues the rebuilt
chunks for VBO upload in `updateAllImportantChunks`.

## Gameplay operations on blocks

All in `Terrain.mm`:

- **`buildBlock(x,z,y)`** (`:1042`) — places `hud->blocktype` with
  `hud->block_paintcolor`. Ramp types auto-orient: `getRampType` inspects which of the
  4 side neighbours are solid; two adjacent solid sides ⇒ becomes a corner ("side")
  piece, otherwise faces the player's yaw quadrant. Doors/portals place two stacked
  blocks (`TYPE_*1+r` bottom encoding direction, `TYPE_*_TOP` top). Lightboxes call
  `addlight(…, +1)` and refresh chunks in `LIGHT_RADIUS`. Golden cubes decrement the
  `goldencubes` inventory.
- **`destroyBlock` / `explodeBlock`** (`:742`, `:793`) — refuse bedrock/golden-cube
  (destroy) and bedrock/steel (explosion); remove liquid sources; spawn break/explode
  particles; remove paired door/portal halves; lightboxes subtract their light.
- **`paintBlock(x,z,y,color)`** — recolors, handles lightbox re-light and painting
  both door/portal halves.
- **`burnBlock(x,z,y,causedByExplosion)`** (`:866`) — adds a `BurnNode` to the global
  singly-linked `burnList` if the type `IS_FLAMMABLE`. Life: 6 s normal blocks; 4 s
  TNT (0.5–0.8 s if chained from an explosion). Registers a looping fire sound and a
  fire particle emitter.
- **Fire propagation** (`Terrain::update` `:1954`): 1 s after ignition
  (`BURN_SPREAD_TIME`) a burning block ignites its 6 neighbours. On expiry: TNT →
  `explode` (sphere radius `EXPLOSION_RADIUS=5`; if the TNT was painted, the
  explosion *paints* instead of destroys — that's the paint-bomb feature), firework
  blocks launch, `TYPE_BT*` → `blocktntexplode` (builds a diamond of the base
  material, or ramps for the side variants). More than 300 simultaneous burns trips
  `endDynamics` which clears all fire/liquids/effects — the anti-meltdown valve.
- **`warpToPoint` / `warpToHome`** — save the world with a warp position, then
  unload+reload terrain around the target. Warping is implemented as a save/load
  cycle, not a teleport.

Doors and portals are *stored* as voxels but *rendered and animated* as extracted
`StaticObject`s (see [rendering.md](rendering.md)); portal linking/teleportation is in
`Portal.mm` ([lighting-liquids-effects.md](lighting-liquids-effects.md)).

## Streaming (the "Loading…" hiccup)

`Terrain::prepareAndLoadGeometry` (`Terrain.mm:2117`), every frame while `loaded`:

1. Compute desired window origin `m_chunkOffset* = player.pos/16 - T_RADIUS`.
2. For each of the 18×18 ground-level chunk slots, compare `pbounds` with the desired
   absolute coordinates → count stale slots.
3. If `count > 140` (player crossed roughly a chunk boundary): a two-frame hysteresis
   (`hit_load_counter`) shows the "Loading" status bar, then:
   - `fm->saveWorld()` (flush modified columns **before** they get overwritten!),
   - update `fm->chunkOffsetX/Z` (the render-origin rebase),
   - `fm->readColumn(cx,cz,file)` for every stale column — from the save file if the
     directory has it, else from the bundled default world / generator,
   - `addMoreCreaturesIfNeeded()`, lighting rebuild (`updateLightingBegin` →
     `calculateLighting` on the next geometry pass).
4. Drain dirty lists → `rebuild2()` each chunk → queue VBO uploads.

The old octree (`TreeNode troot`, `addToTree`, …) is vestigial: `renderTree()` says it
plainly — "once upon a time this descended an oct-tree, profiling showed it was
useless, now just iterates through chunk list" (`Terrain.mm:2430`).

## Lifecycle
- `Terrain()` constructed at app start; `allocateMemory()` only when entering a world;
  `deallocateMemory()` on exit to menu (frees blockarray/lightarray/chunk objects).
- `loadTerrain(name, fromArchive)` → `FileManager::loadWorld` does the real work.
- `unloadTerrain` clears portals/fireworks; chunk objects persist for reuse.

## Common pitfalls
- **Argument order is `(x, z, y)` with y vertical** in nearly every terrain API, but
  storage order and some structs differ. Triple-check every call site you write.
- `getLandc` returns garbage (wrapped data) for coordinates outside the resident
  window rather than failing — callers guard with `y` checks only.
- `Terrain::getLand` returns `-1` for out-of-height; `getColorc` returns 0. Several
  callers rely on `-1` being distinct from `TYPE_NONE==0`.
- Editing blocks without `updateChunks` leaves stale meshes; editing during the
  streaming save window can be lost.
- `blockarray` holds **types only**. Any new per-voxel attribute needs either the
  chunk arrays (persisted) or a parallel toroidal array (transient, like light).
- The `TYPE_CUSTOM` / `SmallBlock` half-resolution sub-block system is dead code
  (commented out everywhere) — don't resurrect it casually; the save format never
  supported it.

## Safe vs. risky to modify
- **Safe:** block property tables in `Globals.mm`/`Constants.h` (append, don't renumber
  — saved worlds store raw type bytes), explosion radii, burn times, new gameplay ops
  built from `updateChunks`/`setColor`.
- **Caution:** anything touching `GBLOCKIDX`/`threeToOne` indexing, `T_SIZE`/`T_HEIGHT`
  (changes save format column size! `SIZEOF_COLUMN` depends on them), the streaming
  threshold logic, chunk reuse (`resetForReuse` assumes the slot is being overwritten).
