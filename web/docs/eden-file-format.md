# The `.eden` World File Format (Web Port)

**Format is identical to the root docs — see
[`../../docs/eden-file-format.md`](../../docs/eden-file-format.md).** The 192-byte
header, 32 KB column records, and end-of-file `ColumnIndex` directory are read/written
by the same `FileManager.mm`/`FileManagerHelper.mm` code as the native build (these
files are compiled unmodified — see [save-load.md](save-load.md) for why that was
possible). Nothing about the byte layout changes for the web port; only where the
bytes physically live changes (IDBFS-backed `/documents`, see
[save-load.md](save-load.md)).

## How the bundle gets to the browser
The bundled `Eden.eden` (~52.5 MB, RLE variant) is symlinked into `public/Eden.eden`
and populated into `/bundle/Eden.eden` via a `--pre-js` (`src/seam/js/
eden_default_world.pre.js`) registered as a `Module.preRun` run dependency — it works
under both a browser `fetch()` and `node eden.js`'s `fs.readFileSync`. This is
**concurrent with, not deferred past,** the main asset package load; it is not truly
lazy/byte-range-fetched. `FS.createLazyFile` throws outside a Web Worker on the
emsdk version this port pins, and deferring the read past `main()` would need
Asyncify, because `FileManagerHelper::fmh_init` reads the bundle synchronously and
unconditionally during `World::World()`. Net effect: the whole ~52.5 MB file is held
fully resident in MEMFS for the session — a real, currently-unsolved memory cost (see
[world-and-terrain.md](world-and-terrain.md)). The eventual fix would be either a
custom FS node backed by a byte-range-request LRU cache, or moving to the threaded
build (where a synchronous `XHR` in a worker is legal) — neither is done.

## One real divergence, not caused by the web port
Upstream Eden has since moved to a v5 `.eden` format with auto-migration. This
fork — both native and web — stays a faithful v4 port; that's a divergence in time
from upstream, not a web-specific behavior change. Worth knowing if you ever compare
save files against a current App Store build.
