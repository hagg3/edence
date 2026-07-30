# The `.eden` World File Format

Authoritative reference, reconstructed from `Classes/FileManager.h/.mm`,
`FileManagerHelper.mm`, and cross-checked against the two documents in the repo root:
- `Eden_file_format.txt` — the developer's own 24-line summary.
- `MROB.txt` — Robert Munafo's pre-source-release reverse engineering (matches the
  code exactly for v2-era files; his "12×12 columns" observation is the 1.7-era
  window size, 18×18 in this version).

## Layout

```
┌────────────────────────────────────────────┐ offset 0
│ WorldFileHeader              (192 bytes)   │
├────────────────────────────────────────────┤ offset 192
│ BLOCK DATA: column records, append-only    │
│   each column = 32768 bytes (uncompressed) │
├────────────────────────────────────────────┤ directory_offset − 200·sizeof(EntityData)
│ CREATURES: 200 × EntityData  (fixed size)  │   (only if version ≥ 3)
├────────────────────────────────────────────┤ directory_offset
│ DIRECTORY: ColumnIndex × N until EOF       │
└────────────────────────────────────────────┘
```

Design rationale (from `Eden_file_format.txt`): newly touched columns are **appended**
— they overwrite the creatures+directory region, which is then rewritten after the
new data, and only `directory_offset` in the header changes. Block data never shifts.

## Header — `WorldFileHeader` (`FileManager.h:20-35`)

```c
typedef struct {
    int level_seed;                  // terrain gen seed; 0=flat, 333333=default world
    Vector pos;                      // player position (3 floats, world units)
    Vector home;                     // home/spawn block coordinates
    float yaw;                       // player yaw, degrees
    unsigned long long directory_offset;
    char name[50];                   // display name, NUL-terminated
    // ---- added after 1.1.1 ----
    int version;                     // FILE_VERSION == 4 in this build
    char hash[36];                   // MD5 (hex string) of the preview screenshot
    unsigned char skycolors[16];     // 4×4 region sky-color palette indices
    int goldencubes;                 // remaining golden-cube inventory
    char reserved[...];              // pads struct to exactly 192 bytes
} WorldFileHeader;
```

The comment in the header is emphatic: **192 bytes including padding is load-bearing**
("be careful modifying this to not corrupt old maps"). `saveColumn` even asserts
`(chunk_offset−192) % SIZEOF_COLUMN == 0`. The `hash` links a world file to its
uploaded `.png` preview for the sharing service (see [networking.md](networking.md)).

Note: the struct is written/read by raw `memcpy`/`fwrite` — the format is
**little-endian, ARM/x86 struct layout** (4-byte alignment for the first section, the
`unsigned long long` lands at offset 32). MROB.txt's dump confirms this layout
empirically (directory pointer observed at bytes 0x20–0x27).

## Block data — column records

One record per 16×16 **column** = `CHUNKS_PER_COLUMN` (4) chunks stacked bottom-up:

```
for cy in 0..3:
    block8 types [4096]   // CC order: x*256 + z*16 + y  (y fastest — vertical strips)
    color8 colors[4096]
```

`SIZEOF_COLUMN = 16·16·16·4·2 = 32768` bytes. Types are signed bytes (block ids
0..111), colors unsigned bytes (palette indices, 0 = unpainted).

Special cases in the type byte you must preserve when writing tools:
- Liquids encode fill level in the type (`TYPE_WATER`=full, `WATER3/2/1` descending;
  same for lava).
- Ramps/side-pieces encode orientation in groups of 4 consecutive ids.
- Doors/portals: bottom block `TYPE_DOOR1..4`/`TYPE_PORTAL1..4` encodes facing;
  top block is `TYPE_DOOR_TOP`/`TYPE_PORTAL_TOP`.

## Creatures (version ≥ 3)

`MAX_CREATURES_SAVED = 200` fixed slots of `EntityData` (`Vector.h:38-49`):

```c
typedef struct {
    Vector pos, vel;       // 24 bytes
    float angle;
    int   type;            // creature id 0..6, or -1 = empty slot
    int   color;
    float touched, extra2, extra3;
    Vector extra4;
} EntityData;              // 60 bytes → block = 12,000 bytes
```

Located at `directory_offset − 200*sizeof(EntityData)`. Files with version < 3 have no
creature block; the loader fills slots with `type=-1`.

## Directory

Read from `directory_offset` to EOF (`FileManager::readDirectory` — there is **no
count field**; EOF terminates):

```c
typedef struct {
    int x, z;                        // absolute chunk-column coordinates
    unsigned long long chunk_offset; // absolute file offset of the column record
} ColumnIndex;                       // 16 bytes with padding
```

In memory the directory is a hashmap keyed by `twoToOne(x,z) = (x<<15)|z` — hence the
hard limit of 15-bit chunk coordinates. Key 0 is treated as invalid/corrupt and
skipped.

## RLE variant (bundled default world only)

The shipped `Eden.eden` (repo root / app bundle) uses the same header/directory but
**compressed column records**, written by `FileManager::saveGenColumn` and read only by
`FileManagerHelper::fmh_readColumnFromDefault`:

```
per chunk (4 per column):
    uint16_be length              // total bytes including these 2
    repeat: { int8 type, uint8 color, uint8 count (1..127) }
```

Additionally the voxel order inside RLE chunks is **transposed** to `CC(y,z,x)`
(x fastest) "to maximize compression" (horizontal runs compress better), and the
reader un-transposes: `pblocks[CC(x,z,y)] = tblocks[CC(y,z,x)]`
(`FileManagerHelper.mm:203-208`). User save files are always raw (the `rle` flag in
`FileManager::readColumn` is hardcoded `false`).

## Version history (as handled by `FileManager::loadWorld`)

| version | Era | Differences |
|---|---|---|
| garbage (<1 or >1000) | 1.x | Legacy format: 1 byte/block, **no colors**, 30 block types. Converted in place by `convertFile` using `convertType`/`convertColor` tables (old colored blocks become type+paint). |
| 2 | early 2.0 | Current layout, no creature block (`chunk_offset` points relative to a file without it). |
| 3 | 2.x | Adds the creatures block before the directory. |
| 4 | 2.1 (current, `FILE_VERSION`) | Adds `goldencubes` + `skycolors[16]` to the header (upgraded in-place on load: v3 files get 10 cubes and all-blue sky). |

Files are silently upgraded to v4 on the first save.

## Auxiliary files
- `<world>.png` in Documents — preview screenshot (taken by the HUD camera mode),
  uploaded alongside the world when sharing; MD5 stored in the header.
- `FileArchive.h` (compress-on-exit via zlib/`zpipe`) is **entirely commented out** —
  `compressLastPlayed()` is a no-op. Worlds on disk are uncompressed.

## Practical notes for tool authors
- To enumerate worlds: list the Documents directory; any file whose first 192 bytes
  parse as a header with a non-empty `name` is a world (`Menu::loadWorlds` +
  `FileManager::getName` do exactly this, `error~` sentinel for failures).
- To read a column: header → seek `directory_offset` → scan `ColumnIndex` records →
  hash/scan for (x,z) → seek `chunk_offset` → read 4×(4096+4096).
- Columns never in the directory: untouched default-world terrain (fetch from the
  bundled `Eden.eden` by the same algorithm) or ungenerated flat terrain.
- When writing: append the column at `directory_offset − 12000`, bump
  `directory_offset` by 32768, rewrite creatures + directory + header.

## Uncertainties
- `EntityData.touched/extra2/extra3/extra4` semantics are only partially clear
  (`touched` is a timer in creature AI; the extras appear unused — confidence: medium.
  Verify in `Model.mm` `SaveModels`/`LoadModels2` before repurposing).
- Exact byte offsets inside the 192-byte header past `name` depend on compiler padding;
  they were stable across the shipped armv7 builds but **verify with a hex dump before
  hard-coding offsets in an external tool** (the repo's `Eden.eden` is a ready-made
  reference specimen).
