# Save / Load Pipeline (Web Port)

Read [`../../docs/save-load.md`](../../docs/save-load.md) first — the load/save
control flow, streaming-boundary triggers, and legacy conversion logic described
there are **unmodified**: `FileManager.mm`/`FileManagerHelper.mm` are compiled
verbatim from `../Classes/`, not seam-replaced. This was a deliberate choice (pass
22): the Foundation surface they call (`NSFileHandle`/`NSFileManager`/`NSBundle`/
`NSData`/`NSSearchPathForDirectoriesInDomains`) is fully shimmed over stdio +
persistent storage in `src/shim/foundation/`, so reusing the original, tested
RLE-column/directory/creature logic was far lower-risk than reimplementing it. This
doc covers only what backs that Foundation surface and how it becomes durable.

> **Update (pass 37, 2026-07-25):** the atomicity fix predicted above landed. `FileManager::
> saveWorld()` (`Classes/FileManager.mm`) now saves to a `.savetmp` scratch copy and swaps it
> in with one `removeItemAtPath:`+`moveItemAtPath:` at the end, instead of seeking/writing/
> truncating the real file in place — the same temp+rename pattern `convertFile()` already
> used. `loadWorld()` also sanity-checks a save's header/directory before trusting it and
> reports failure via `eden_report_load_failure()` (`web/src/seam/LoadFailure_web.mm`) instead
> of reading garbage; `public/eden-loaderror.js` shows a recovery dialog. The `.bak` backup
> slot (`NSFileHandle.mm`, described below) is now belt-and-braces rather than the load-bearing
> mechanism. See `../../docs/save-load.md`'s "Common pitfalls" for the `doneLoading`/`game_mode`
> gotcha this surfaced (pass 42).

## Storage backend
Saves land in `/documents` inside the wasm virtual filesystem, backed by
**IDBFS** (`-lidbfs.js`), mounted with `{autoPersist: true}` in
`public/eden-storage.js`. Every write/unlink/rename under `/documents` self-queues a
debounced IndexedDB sync through IDBFS's own node_ops hooks — there is no engine-side
hook and no `--wrap`; `Classes/` is untouched, the persistence is entirely a mount
option.

The bundled default world (`Eden.eden`) lives read-only at `/bundle/Eden.eden` and is
resolved via the shimmed `NSBundle` — same role as the app-bundle copy on iOS. It is
**not** resident in memory; see the next section.

## The bundled default world: a lazy, range-fetched FS node
*(pass 46, perf-audit ROI row 9 / §5b.1b — `src/seam/js/eden_default_world.pre.js`)*

`Eden.eden` is ~52.5 MB and used to be held whole in MEMFS for the entire session (and
before pass 30, `--preload-file`d into `eden.data`, so first paint waited on it). The
engine only ever reads small pieces of it — a 192-byte header and a 518,400-byte
`ColumnIndex` directory at boot (`fmh_init`), then one column of RLE chunks at a time as
the player walks (`fmh_readColumnFromDefault`) — which is a textbook range-request
workload.

It is now a **custom Emscripten FS node**: `stream_ops.read` is served from an LRU of
32 KB blocks (128 of them, a 4 MB residency ceiling), filled on demand by **synchronous**
same-origin HTTP `Range` requests in the browser and by `fs.readSync` under headless
`node`. Everything above `readRange` is backend-agnostic, which is what lets the headless
test exercise the real cache/coalescing/eviction logic.

Three properties are load-bearing and must survive any change here:

- **The file must be fully openable and synchronously readable before `main()`.**
  `FileManagerHelper::fmh_init` opens it and reads the header + directory inside
  `FileManager`'s constructor, during `World::World()`. A lazy node satisfies this
  because the node exists at its real size (`usedBytes` is defined as a getter, which is
  what MEMFS's own `getattr`/`llseek` read) and every `read` is synchronous. Deferring
  the *open* past `main()` would still need Asyncify — that is not what this is.
- **Sync XHR on the main thread is the mechanism** (deprecated but functional).
  `responseType` cannot be set on a synchronous main-thread XHR, so bytes come back via
  `overrideMimeType('text/plain; charset=x-user-defined')` and `charCodeAt(i) & 0xFF`.
  Emscripten's own `FS.createLazyFile` refuses to do this outside a Worker, which is why
  the port implements the idea itself — and gains request coalescing, a bounded cache
  (`createLazyFile` never evicts) and a fallback path in the process.
- **Byte serving is not assumed.** A one-byte async `Range` probe runs before the run
  dependency is released; if the server answers 200, omits `Content-Range`, or applies a
  `Content-Encoding` (a range of a Brotli'd body is not the requested range), the port
  falls back to the pass-30 whole-file fetch. `python3 -m http.server` has **no** byte
  serving, so **the win only materialises behind `node tools/serve.js`** (which grew real
  206 support in the same pass). `?worldfs=eager` forces the fallback by hand.
  **GitHub Pages is also in the no-byte-serving bucket** — confirmed with `curl -H "Range:
  bytes=0-0"` against a live deployment: it answers `200` with the full body and a
  `content-length` equal to the whole file, despite advertising `accept-ranges: bytes` in
  every response. So **the public/production deployment always takes the eager fallback
  path**, not just local testing under the wrong dev server. See "The eager fallback is
  the production path" below — this is not a rare edge case to shrug off.

### The eager fallback is the production path, not a rare edge case (pass 50)
Because GitHub Pages never answers `206`, `hagg3.github.io/edence` (and any other GitHub
Pages deployment of this port) downloads the **whole 52 MB `Eden.eden`** on every cold
boot, synchronously blocking the `eden-default-world-fetch` run dependency until it
finishes. That used to also **double-buffer** the file in memory: the streaming
`fetch()` reader accumulated a `chunks[]` array and concatenated it into a second buffer
(`eagerFetch`), which `populateEager` then copied a *third* time via `FS.writeFile`
(MEMFS allocates and `memcpy`s its own backing buffer). Transient peak residency for one
52 MB file could reach ~150 MB.

Desktop Chrome/Safari tolerated this; **iOS/iPadOS Safari did not** — it failed silently
(no console error, no crash dialog) with the loading screen never dismissing, or — if
boot got just far enough to release the run dependency before the tab was killed — a
live WebGL2 context with a permanently black canvas at frame 0 (`World::update` never
ticking because `main()` was still blocked). This is exactly the "iOS Safari will
terminate the tab well before desktop does" risk `WORKING/archive/project-audit-2026-07-30.md`
flags generally (D2) — this was a concrete, now-fixed instance of it, not the same bug
as A2's per-frame autorelease-pool ramp (that's a slow climb over a session; this was a
single large spike during boot).

**Fix:** `eagerFetch` now pre-sizes one destination `Uint8Array` from the response's
`Content-Length` (falling back to the old `chunks[]`+concat path only if a chunk would
overflow it — i.e. the header under-reported the real size) and fills it in place while
streaming, instead of accumulating-then-concatenating. `populateEager` now installs a
read-only FS node backed directly by that buffer (same shape as the lazy node's
`stream_ops.read`, just serving from an already-fully-resident array instead of
fetching blocks over the network) instead of `FS.writeFile`. One 52 MB buffer, not two
or three. Verified via `tools/headless-lazy-world-test.js`'s existing `--eager` A/B leg
(mode/settling behavior unchanged) and confirmed fixed live on iPhone/iPad Safari.

**Why not just fix the hosting instead?** Investigated first: GitHub Release assets
support `Range` (206) but not CORS (no `Access-Control-Allow-Origin`, preflight 405s);
`raw.githubusercontent.com` supports CORS but not `Range` (same as Pages); jsDelivr's
GitHub CDN supports both but caps individual files at 20 MB, well under 52 MB. None of
GitHub's own free hosting surfaces give both properties for a file this size — a real
fix there needs third-party object storage (Cloudflare R2, S3, Backblaze B2 + a CDN),
which is a deliberate infra decision, not something to bolt on unasked. The memory fix
above is host-agnostic and was the right scope for this pass.

Measured on the real file (`tools/headless-lazy-world-test.js`): cold boot reads 596 KB in
10 requests (vs. 52.5 MB), and creating + loading a normal world costs another ~2.4 MB in
~37 requests, with a ~97% block hit rate. `Module.EdenWorldFS` exposes
`{mode, size, blockSize, maxBlocks, stats, blocksResident(), dropCaches()}`.

Block size / cache size / read-ahead are **measured** defaults, not guesses —
`node tools/headless-lazy-world-test.js --sweep` re-runs a real boot + world load once per
combination (each in its own process; the tunables are read at `preRun` time and can be
overridden via `Module.EDEN_WORLD_FS_BLOCK`/`_BLOCKS`/`_READAHEAD`). Request count is
weighted over raw bytes because each request is a *synchronous* XHR: they cannot overlap,
so N requests are N unavoidable round trips of blocked main thread.

**Verification** (`tools/headless-lazy-world-test.js`, and a live Chrome session in pass
46): the whole 52 MB is read back *through the node* in pseudo-random chunk sizes and
hashed — the SHA-1 must equal the real file's, which covers block boundaries, partial
blocks, the EOF short read, multi-block coalescing and constant eviction. Do not weaken
that test into sampling; a silent off-by-one here would look like a worldgen bug, not a
filesystem bug.

## Boot-time populate
Before `main()` can run, `Module.preRun` registers an async **IndexedDB → MEMFS
populate** as a run dependency (`public/eden-storage.js`) — this blocks `main()`/
`Menu::loadWorlds` until existing saves are loaded off IndexedDB into the in-memory
filesystem IDBFS backs. See [execution-flow.md](execution-flow.md) for where this
sits relative to `main()`. Guarded on `typeof indexedDB` so headless `node eden.js`
degrades gracefully to previous in-memory-only (MEMFS, no persistence) behavior.

## Storage management UI
A **Storage tab** (`src/seam/Storage_web.mm` + `public/eden-settings.js`) lists and
deletes saved worlds. Listing re-derives names/sizes each call via
`FileManager::getName` + `stat()` over the documents directory (index-based delete,
chosen to avoid needing `_malloc`/`_free` exports across the JS boundary); deletion
reuses `FileManager::deleteWorld` verbatim — no reimplementation. Each row also carries
a `height` field (`FileManager::probeWorldHeight`, the same header peek
`World::loadWorld` does before sizing arrays) — 64 or 256 — which both this tab and
`eden-menu.js`'s Load World list use to label 256z ("New Dawn") worlds correctly and to
show a memory-footprint warning before playing one; see
[world-and-terrain.md](world-and-terrain.md)'s "A 256z world costs 413 MB of wasm heap".

The Storage tab also offers a **"Convert to 64z"** action (2026-08-26, 256z Stage 3 item 5) on any
row with `height===256`, via `eden_storage_convert_to_64z_at` (same index convention as delete) ->
`FileManager::convertWorldTo64` (`Classes/FileManager.mm`). That function is a from-scratch C++
restatement of `web/tools/eden-convert.js`'s `--to-64` algorithm over `NSFileHandle` — a browser
has no Node to shell out to the CLI tool, so the byte-surgery logic is duplicated by hand rather
than shared; keep the two in sync if the format's rules ever change. Same temp+rename atomicity as
`saveWorld()` (writes to `<file>.64zconv`, only replaces the original after a full successful
write), and refuses outright if the target is the world currently open in this session. Regression
test: `tools/headless-256z-authoring-test.js` (also covers the New World height picker below).

## Durability hardening
- **Two save strategies, chosen by file size** (2026-08-25, 256z Stage 3 / B5). Below
  `g_save_inplace_threshold` (`Classes/Constants.h`, 16 MiB) nothing changed: the save is built
  in a `.savetmp` whole-file scratch copy and committed by one rename. At or above it the save
  writes the world file in place behind a small `.savejrnl` rollback journal. The full design,
  the failure it trades away, and the recovery path are in
  [`../../docs/save-load.md`](../../docs/save-load.md) — they are engine-level, not web-specific.
  What is **web**-specific is why the threshold has to exist at all:
  - The `copyItemAtPath:` shim reads the whole file into an `NSData` (a `std::vector<uint8_t>`) —
    i.e. a **transient wasm-heap allocation the size of the world**, on a 32-bit heap that this
    build grows from 96 MB and that a loaded 256z world already occupies ~413 MB of. A
    multi-gigabyte world cannot be saved that way at all, at any speed.
  - MEMFS is JS-heap, so every copy is also a second full-size resident copy, and IDBFS's
    `{autoPersist:true}` then has to push whatever changed into IndexedDB against a finite quota.
  - Measured with `tools/headless-save-io-probe.js` against a real 279 MB 256z specimen, saving
    with **nothing edited**: 558 MB read + 558 MB written per save before, 127 KB read +
    83 KB written after. Three whole-file copies were involved, not one — `copyItemAtPath:`,
    plus the `.savetmp.bak` slot below.
  - Above the threshold the port therefore also stops maintaining the whole-file backup slot and
    reclaims any stale one (see the next bullet); `eden-loaderror.js`'s Restore action has
    nothing to offer for such a world, by design, because the journal covers the failure it
    existed for and a permanently-stale second copy of a gigabyte world is not a fair trade.
- `NSFileHandle`'s `-writeData:` now `fflush()`s, so a later `flushNow()`-style sync
  can't silently persist a stdio-buffered/stale file to IndexedDB.
- `+fileHandleForWritingAtPath:` copies the existing file to a `.bak` sibling before
  overwrite. `+fileHandleForUpdatingAtPath:` is a separate opener (NOT an alias for
  `-Writing...` as of pass 42) that defers this same backup to the first actual
  **write** through the handle (`-writeData:`/`-truncateFileAtOffset:`), rather than
  firing it eagerly at open. This matters because `FileManager::loadWorld()`'s
  header/directory sanity check opens the real save via `fileHandleForUpdatingAtPath:`
  purely to *read* it — before pass 42's fix, that read-only open still fired the
  eager backup, so the mere act of attempting to load a corrupt save clobbered the
  last-known-good `.bak` with the corrupt bytes, before the length check even ran.
  The atomic-rename save path's genuine writes into its own `.savetmp` scratch copy
  (also opened via `fileHandleForUpdatingAtPath:`) still get a backup, unchanged —
  only a pure read-then-close is now exempt. As of 2026-08-25 the backup is **also** skipped for
  any file at or above `g_save_inplace_threshold`, because it is itself a whole-file copy and
  was firing on the same save as `saveWorld`'s scratch copy (that is the third of the three
  full-size copies the I/O probe found). The pending-backup path is stored as a
  plain `strdup`'d C string ivar, not a retained `NSString*` — see the comment in
  `NSFileHandle.mm` for why (this class's ivar-offset layout was only ever measured
  with one own ivar, and adding an ObjC-object ivar hit a real, reproducible "function
  signature mismatch" crash; a C string sidesteps it).
- `navigator.storage.persist()` is requested so the browser doesn't evict the
  IndexedDB-backed origin under storage pressure.
- **A failed load must also be caught by the caller, not just detected.** Pass 42
  found that `FileManager::loadWorld()` correctly detecting and reporting a corrupt
  save wasn't sufficient on its own — `World::loadWorld()`'s `doneLoading` state
  machine (`Classes/World.mm`) advanced to `GAME_MODE_PLAY` regardless, and the
  engine crashed a frame or two later trying to render a `Terrain` that was cleared
  but never repopulated. Fixed by checking `eden_load_failed()` at that transition;
  see `../../docs/save-load.md`'s "Common pitfalls" section for the full mechanism.
  This is why "the dialog rendered, no crash" (pass 38's claim) wasn't actually
  sufficient verification — the JS dialog is plain DOM and kept rendering right up
  until the underlying wasm instance crashed.

`FileArchive.mm` (the disabled compression path) stays seam-excluded — grep-verified
to be referenced only from commented-out code in both files, so it costs nothing to
leave out.
