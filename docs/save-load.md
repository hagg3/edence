# Save / Load Pipeline

## Purpose
How world files are opened, streamed, saved and migrated at runtime. The on-disk
format itself is specified in [eden-file-format.md](eden-file-format.md).

## Important files & types
- `Classes/FileManager.mm/.h` — everything: `loadWorld`, `saveWorld`, `readColumn`,
  `saveColumn`, directory management, legacy conversion, plus the offline
  `saveGenColumn`/`writeGenToDisk` used by the world generator.
- `Classes/FileManagerHelper.mm` — read-only access to the **bundled** default world
  `Eden.eden` (its own file handle, header and directory hashmap; the comment at the
  top warns the identically-named statics refer to the *default* world, not the
  active one).
- `Classes/hashmap.mm` — int-keyed hashmap holding `ColumnIndex*` records.
- File-scope statics in `FileManager.mm`: `saveFile` (NSFileHandle), `sfh` (in-memory
  header), `indexes` (directory hashmap), `cur_dir_offset`, `file_version`,
  `imgHash`. **The FileManager is effectively a singleton with global mutable state**
  — two worlds can never be open at once.

## Load flow — `FileManager::loadWorld(name, fromArchive)` (`FileManager.mm:1346`)

```mermaid
flowchart TD
    A[loadWorld] --> B{file exists in Documents?}
    B -- no --> N[New world path]
    B -- yes --> E[Existing world path]
    N --> N1[choose seed: flat=0 / default=333333]
    N1 --> N2[pick spawn: default world → 1 of 10<br/>hand-authored spawn points]
    N2 --> N3[readColumn ×18×18 window<br/>← bundle RLE / generator]
    N3 --> N4[saveWorld → creates the .eden file]
    E --> E1[read header, detect version]
    E1 --> E2{version garbage?}
    E2 -- yes --> E3[convertFile: 1.x → v2 rewrite]
    E2 -- no --> E4[v3→v4 in-place header upgrade]
    E3 --> E4
    E4 --> E5[readDirectory into hashmap]
    E5 --> E6[chunkOffset = player chunk − 9]
    E6 --> E7[readColumn ×18×18 window]
    E7 --> E8[LoadCreatures]
    N4 --> Z[set ZFAR, clear input/effects,<br/>updateSkyColor, loaded=TRUE]
    E8 --> Z
```

Notes:
- New-world types: the `g_terrain_type` switch is hardwired to 9 (`gen_default`);
  types 0–8 (dirt/rivers/mountains/desert/ponies/beach/mix/flat) are the offline
  generator's biome recipes and are only reachable by editing the code. The menu's
  "flat world" option sets `genflat` → seed 0.
- The 10 default spawn points (`spx/spz/spy/spyaw` arrays, `FileManager.mm:1425`) are
  hand-picked scenic locations; consecutive new worlds avoid repeating the last one.
- `player->pos`/`yaw`, `home`, seed, golden cubes, region sky colors all come from the
  header. `chunkOffsetX/Z` (the render-origin/streaming anchor owned by FileManager)
  is derived from the player position.

## Column streaming — `readColumn(cx, cz, fileHandle)` (`FileManager.mm:802`)

Resolution order for a requested column:
1. **Directory hit** → seek `chunk_offset`, read 4 chunks of raw type+color bytes
   into the (reused) `TerrainChunk` objects, memcpy type strips into `blockarray`,
   `ter->addChunk(...)` marks the chunk + neighbours dirty for meshing.
2. **Directory miss, seed == 333333** → `fmh_readColumnFromDefault`: same procedure
   against the bundled `Eden.eden`, RLE-decoding and transposing each chunk. If even
   the bundle lacks the column (outside the generated 2880×2880 area) →
   `generateEmptyColumn` (air).
3. **Directory miss, other seed** → `TerrainGenerator::generateColumn` (flat-world
   layers; see [terrain-generation.md](terrain-generation.md)).

Called from two places: initial load (18×18 loop in `loadWorld`) and the per-frame
streaming check in `Terrain::prepareAndLoadGeometry` (which opens a fresh read-only
NSFileHandle each streaming event).

## Save flow — `FileManager::saveWorld(warpPos)` (`FileManager.mm:366`)

1. `terrain->endDynamics(TRUE)` — extinguish fires, clear liquids/effects (dynamics
   are **not** persisted; a burning world saves as not-burning).
2. Rebuild header from live state (seed, home, pos←warp, yaw, golden cubes, sky
   colors, display name from the menu's selected world, image hash).
3. If the file doesn't exist: create it with a fresh header (v2 bootstrap).
4. `readDirectory()` — re-read the on-disk directory into the hashmap (source of
   truth for existing column offsets).
5. For each of the 18×18 resident columns: `saveColumn(cx,cz)`:
   - skip unless any chunk in the column has `modified` set (flags are cleared here);
   - existing directory entry → overwrite in place at its `chunk_offset`;
   - new entry → `chunk_offset = directory_offset − sizeof(EntityData)·MAX_CREATURES_SAVED`
     (i.e. where the creature block currently starts), `directory_offset += SIZEOF_COLUMN`,
     `writeDirectory=TRUE`;
   - write `CHUNKS_PER_COLUMN`×(pblocks, pcolors) raw.
6. `saveCreatures()` — `SaveModels()` fills `creatureData[]`, written at
   `directory_offset − sizeof(EntityData)·MAX_CREATURES_SAVED`. (v<3 files get the block
   appended and become v3+.)
7. Stamp `version=4` — **unless the file arrived as version ≥ 5**, in which case it keeps its
   own version. If any column was appended, `fwriteDirectory()` rewrites the whole directory at
   `directory_offset` (plus the sign trailer, below), then the header is rewritten at offset 0 —
   **header last**, because it is the only thing that says where the directory is, and on the
   in-place path below it is the nearest thing this format has to a commit record.

### Two save strategies, chosen by file size (2026-08-25)
Steps 3–7 above run against a **scratch copy** of the world (`<file>.savetmp`), which one
`rename()` swaps in at the very end — so any crash before that rename leaves the previous save
byte-identical. That is still what happens for a file **below `g_save_inplace_threshold`**
(`Constants.h`, 16 MiB by default), which is every ordinary world.

At or above the threshold the copy is the problem, not the protection: it is O(file size) in time
*and* in peak memory, and a 256z world can be gigabytes. Measured on a real 279 MB 256z specimen
with **nothing edited** (`web/tools/headless-save-io-probe.js`): 558 MB read + 558 MB written per
save, against ~155 KB of genuinely-changed bytes. So above the threshold `saveWorld` writes
straight into the world file and protects it with a **rollback journal** instead:

The journal has **two phases**, written in that order and both before the first destructive byte:

- **Phase 1 — the structural tail.** `beginSaveJournal()` writes `<file>.savejrnl`: a small header
  (magic `EDNJRNL`, version 2, original length, region offset/length) plus the world's current
  192-byte header and the file's tail from `directory_offset − creature block` to EOF. That tail
  is exactly the region an *append* destroys: a new column record starts at
  `directory_offset − creature block` and overwrites the old creature block and the front of the
  old directory. O(number of columns), not O(file size) — about 410 KB for a 3.97 GB world.
- **Phase 2 — the dirty columns** (2026-09-02, ROADMAP C3). `journalDirtyColumns()` appends one
  `EDNJCOL` record per column this save is about to overwrite *at its own existing offset*,
  holding that column's original bytes. It runs after `readDirectory()`, because "does this column
  already have a directory row" is what separates an overwrite (needs a pre-image) from an append
  (phase 1 already covers it) — and `readDirectory()` only reads, so this is still ahead of every
  destructive write. It must not clear `modified`; `saveColumn()` owns that flag, and if the
  journal fails the save is skipped and the flags have to survive for the next attempt.
- Removing the journal after `closeFile` is the commit. `recoverInterruptedSave()` (called from
  `probeWorldHeight`, i.e. before anything reads the header, and again from `loadWorld`) replays a
  surviving journal: restore the region, truncate to the original length, restore the header, then
  write back each `EDNJCOL` pre-image. It is idempotent; a journal too short to be complete is
  discarded because it proves the crash happened *before* the world file was touched, and the
  record scan stops at the first torn record for the same reason (a half-written pre-image proves
  its column had not been reached yet). Records are disjoint by construction — one per column per
  save — so replay order does not matter.
- **What it costs, measured.** Phase 2 is one extra read + write of exactly the columns the save
  was already writing. On the real 279 MB 256z specimen: a steady-state autosave with nothing
  edited is **unchanged** (127 KB read / 83 KB written — zero dirty columns means zero records),
  and a save with one edited column goes **155 KB → 259 KB read and 214 KB → 345 KB written**
  (+131,096 B = one 131,072 B column plus a 24-byte record header). The in-place path stays
  O(dirty columns) and never returns to O(file size). `g_save_journal_columns`
  (`Classes/Constants.h`, default on) turns phase 2 off, reproducing the pre-C3 behaviour; it
  exists so the cost can be A/B'd and as a one-flag rollback.
- **What it replaced.** Through 2026-09-01 the journal was phase 1 only, and this list ended with
  an honest caveat: a crash between journal and commit could leave an individual dirty column
  half-old/half-new — the file still loaded and the directory was still valid, but a chunk of
  terrain was garbage and nothing could detect or repair it. The estimate that made that trade
  look right ("up to ~42 MB per save at 256z") was the worst case — every column in the resident
  window dirty at once — and the typical case is the two numbers above. The in-place save path is
  fully atomic again.
- Above the threshold the port also stops maintaining a **whole-file backup slot**
  (`<file>.savetmp.bak` / `<file>.bak`, `web/src/shim/foundation/NSFileHandle.mm`) and deletes any
  stale one it finds: nothing above the threshold would ever refresh it, so it is a permanent
  second copy of the world that the load-failure dialog would offer as if it were the previous
  save. Durability above the threshold is the journal.
- If **either phase** of the journal cannot be written (or, below the threshold, if the scratch
  copy fails), the save is **skipped** with a log line and the last complete save is left intact —
  rather than finishing a save with neither protection, which is the one path that can leave a
  world unloadable.

Regression cover: `web/tools/headless-save-inplace-test.js` (both paths, a real
engine-written journal replayed against a deliberately half-written file, a deliberately torn
dirty column repaired from its `EDNJCOL` pre-image — with the lever off as the control showing the
identical damage surviving — and journal hygiene on world delete).

**Every one of those sizes is per-world runtime now** (2026-08-06): `SIZEOF_COLUMN` is 32,768 or
131,072 and `MAX_CREATURES_SAVED` is whatever the file actually has room for. See
"Runtime world height" in [world-and-terrain.md](world-and-terrain.md) and the 256z section of
[eden-file-format.md](eden-file-format.md).

### Two quantities that are DERIVED FROM THE FILE, not from its version
`FileManager::deriveColumnSpans()` (run at the end of every `readDirectory()`) computes both,
from the directory alone, with no extra I/O:

- **Creature-block size** = `directory_offset − (highest chunk_offset + SIZEOF_COLUMN)`, accepted
  only if it is a whole number of 60-byte `EntityData` slots and ≤ 400; otherwise the
  version-implied default (200, or 400 for v≥5). This exists because the version is *not*
  trustworthy: the sibling world editor writes v5 saves with **no creature block at all**, and
  that case is a checked test, not a hypothetical. Zero slots is legal and means creatures simply
  do not persist in that file.
- **Per-column span** = the gap to the next-highest `chunk_offset` (or to the start of the
  creature block, for the last column). A column whose span is *shorter* than `SIZEOF_COLUMN` is
  recorded, and `readColumn` then reads only the bands that are really there and zero-fills the
  rest. The one measured New Dawn world has exactly one such column (107,072 B where 131,072 was
  expected); reading it at full stride would silently splice in 24,000 bytes of its neighbour.

### When saves happen
- Streaming boundary crossings (before overwriting resident columns) — the frequent,
  invisible autosave.
- `warpToPoint`/`warpToHome` (portal travel, home warp) — save-with-warp then reload.
- HUD save button, exit to menu, new-world creation.
- **Not** on app background/termination.

## Legacy conversion (`convertFile`, `FileManager.mm:1302`)
1.x files (version field is garbage) are rewritten: each old column
(4 chunks × 4096 type bytes, no colors) is mapped through `convertType[31]` /
`convertColor[31]` — old baked-color block types (colored crystals/leaves/"blank"
blocks) become modern type+paint pairs — into a temp file which replaces the
original. Shows "Converting World…" in the UI via `convertingWorld`.

## Renaming, hashes, deletion
- `setName(file,display)` rewrites just the header's name field (menu rename).
- `setImageHash(md5)` rewrites the header when a new preview screenshot is taken
  (`md5.c` computes it; sharing uses it to pair world+png server-side).
- `deleteWorld` removes the file, its `.png`, and its `.savejrnl` — a journal must never outlive
  the world it belongs to, or a new world created under the same file name gets "recovered" into
  that stale tail on its first load.
- World *files* in Documents are the identity; the display name lives only in the
  header. `Menu::loadWorlds` lists Documents and reads each header for the name.

## Common pitfalls
- **Global statics**: `sfh` sometimes points into an autoreleased NSData
  (`loadWorld`: `[[saveFile readDataOfLength:...] bytes]`) and sometimes into a
  malloc'd block (`saveWorld`). Lifetime bugs lurk if you reorder operations.
- `saveWorld` must run **before** streaming overwrites chunk contents — the call
  order in `prepareAndLoadGeometry` is deliberate.
- The directory hashmap and the file can diverge between `readDirectory()` calls;
  the code defensively re-reads it at the start of every save.
- Appended columns place themselves relative to the creature block, whose size is now derived
  per file (above). `EntityData`'s 60-byte layout is still frozen — changing it breaks every
  existing file.
- `twoToOne` returns 0 for out-of-range chunk coords and 0 is treated as
  "corrupt/skip" — worlds cannot extend to negative or ≥ 32768 chunk coordinates.
- ~~Column writes are not atomic; a crash mid-save can corrupt a world (there is no
  journaling; the community's corrupted-world lore is real).~~ **No longer true as of this fork**
  — stock 2.1.1 wrote the world file in place with no protection at all, which is where the
  community's corrupted-world lore comes from. A save is now either a scratch copy committed by
  one rename (below the threshold) or an in-place write behind a two-phase rollback journal
  (above it, see "Two save strategies" above), and both are all-or-nothing.
- **`FileManager::loadWorld()` bailing out early (a corrupt/truncated header) does
  NOT, by itself, stop `World::loadWorld()`'s caller from proceeding as if the load
  had succeeded.** `loadWorldThread`/`World::loadWorld` (`World.mm`) unconditionally
  advance `doneLoading` 1→2 and flip `game_mode` to `GAME_MODE_PLAY` once the loader
  thread returns, whether or not it actually populated `Terrain` — a caller that wants
  to detect "the load silently failed" (the web port's `eden_report_load_failure`,
  polled via `eden_load_failed()`) has to check that signal itself at the
  `doneLoading==2` transition and refuse to advance if it's set, or the engine renders
  a `Terrain` that was cleared-but-never-repopulated (reproducibly crashes within a
  frame or two — confirmed both headless and live-browser before this was fixed).

## Safe vs. risky to modify
- **Safe:** adding data to the `reserved` header bytes (that's what it's for —
  subtract from `reserved` as the comment instructs), new save triggers, better
  progress reporting.
- **Caution:** anything that changes `SIZEOF_COLUMN`, the 192-byte header size, the
  append arithmetic, or the `modified`-flag protocol; touching the static file-handle
  state; calling save/load from any thread but the ones that already do.
