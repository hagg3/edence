# World Representation & Terrain (Web Port)

**Identical to the root docs — see
[`../../docs/world-and-terrain.md`](../../docs/world-and-terrain.md).**

`Classes/Terrain.mm`/`TerrainChunk.mm` are compiled as-is (not in `CMakeLists.txt`'s
`EDEN_SEAM_EXCLUDE` list). The toroidal window, chunk storage layout, block edit
operations, and streaming logic are unmodified. The one place the web port touches
anything adjacent is the mesher's *output* (vertex upload to WebGL2), covered in
[gl-shim.md](gl-shim.md), not the storage/edit model covered by the root doc.

## The 18×18 window is a hard floor on web too
The resident window size (`T_SIZE` etc.) is baked into `SIZEOF_COLUMN`/the save
format (root docs), so it can't be shrunk to save browser memory without breaking
every existing save including the bundled default world — don't treat it as a lever
for a web memory budget. The bundled `Eden.eden` itself is also currently held fully
resident (not lazily paged) once fetched — see
[eden-file-format.md](eden-file-format.md) for why, and
[save-load.md](save-load.md) for the similar "two full copies resident" situation
with saved-world data (MEMFS + IndexedDB).
