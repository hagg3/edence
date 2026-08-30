#include <emscripten/emscripten.h>  // emscripten_get_now — B1 read-path I/O timing (see below)
#include <unistd.h>   // ftruncate — used by -truncateFileAtOffset:
#include <cstdio>     // rename, remove — used by the backup-slot copy below
#include <cstring>    // strdup — used by the deferred-backup path (_backupPathC)
#include <cstdlib>    // free — used by the deferred-backup path (_backupPathC)

#import "NSFileHandle.h"
#import "NSString.h"
#import "NSData.h"
#include "Constants.h"   // g_save_inplace_threshold — the shared save-strategy threshold

// B1 (ROADMAP Phase B): the column-read/RLE-decode burst characterization needs the file-I/O half
// of FileManager::readColumn measured separately from the RLE decode. Every default-world column
// read bottoms out in the fread() below (via NSData readDataOfLength:), whether it is served from
// the lazy Eden.eden node's block cache or triggers a synchronous XHR/readSync range fetch. Report
// each fread's wall time to MeshTiming_web.mm's accumulator; it is weak so a build that excludes
// that TU (none today) still links.
//
// B6: that comment used to end "two emscripten_get_now() calls per column read = noise", and it
// was wrong on both counts. At the time -readDataOfLength: was called EIGHT times per bundled-map
// column (a 2-byte length prefix plus a payload, for each of the 4 RLE bands), so a column cost 16
// emscripten_get_now() calls -- each one a wasm->JS boundary crossing -- not 2. (B6 also fixed the
// caller: fmh_readColumnRawFromDefault now reads the record in ONE call.) And it was not noise:
// this probe is deliberately not EDEN_DIAGNOSTICS-gated (see MeshTiming_web.mm's header), so
// build-rel, the build players actually run, paid it on every read of the world file. Worse for
// the row that found it, the overhead sat INSIDE the thing B6 had to measure, so an unmodified
// before/after would have credited the fix with removing its own instrumentation.
//
// So the timing is now opt-in at runtime and OFF by default: a probe that wants the B1 split calls
// eden_debug_set_io_timing(1) first and accepts the distortion knowingly. Everything else -- every
// shipped build, and every before/after that is not specifically about fread cost -- pays one
// predictable branch on a static bool. The read counters stay free either way.
extern "C" __attribute__((weak)) void eden_mt_note_io(double ms);

static bool g_io_timing = false;

// Exported so tools/headless-mesh-burst-probe.js --io-timing (and any future probe) can turn the
// B1 split back on for a window. KEEPALIVE, and not diagnostics-gated, for the same reason
// MeshTiming_web.mm's exports are not: the interesting measurement is of build-rel.
extern "C" EMSCRIPTEN_KEEPALIVE void eden_debug_set_io_timing(int on) { g_io_timing = (on != 0); }

@implementation NSFileHandle

+ (NSFileHandle *)fileHandleForReadingAtPath:(NSString *)path {
    FILE *fp = fopen([path UTF8String], "rb");
    if (!fp) return nil;
    NSFileHandle *fh = [[NSFileHandle alloc] init];
    fh->_fp = fp;
    return [fh autorelease];
}

// Perf-audit C4 ("no backup slot"): .eden is append-only with its ColumnIndex directory at the
// END, read to EOF — a save interrupted mid-write (tab discard, OOM, crash) leaves a file whose
// tail is not a valid index, and the engine has no fallback for that. Before this handle starts
// overwriting an EXISTING file, copy its last-known-good bytes to "<path>.bak" (best-effort,
// silently skipped on any error — a missing backup is the status quo, not a new failure mode).
// This does not make the write itself atomic (that needs temp+rename, which the incremental
// seek/write/truncate call pattern FileManager.mm uses does not map onto cleanly without editing
// Classes/), but it means a corrupted save no longer destroys the ONLY copy of the world.
static void eden_backup_before_overwrite(NSString *path) {
    const char *p = [path UTF8String];
    FILE *src = fopen(p, "rb");
    if (!src) return; // nothing to back up yet (first save of this world)
    // 256z Stage 3 / B5: this slot is a whole-file duplicate, so it costs exactly what
    // FileManager::saveWorld()'s scratch copy costs -- tools/headless-save-io-probe.js measured
    // BOTH firing on the same save, 3x the world file written per save on a 279 MB specimen.
    // Above the same threshold that puts saveWorld on its in-place path there is nothing to
    // duplicate onto: the disk cannot hold 2x a multi-gigabyte world and the rollback journal
    // saveWorld writes covers the failure this slot was protecting against. Below it, unchanged.
    // (`g_save_inplace_threshold` is Classes/Constants.h; Classes/ is on this target's include
    // path -- see CMakeLists.txt's target_include_directories.)
    fseeko(src, 0, SEEK_END);
    off_t existing = ftello(src);
    if (existing >= 0 && (unsigned long long)existing >= g_save_inplace_threshold) {
        fclose(src);
        return;
    }
    fseeko(src, 0, SEEK_SET);
    NSString *bakPath = [path stringByAppendingString:@".bak"];
    const char *bak = [bakPath UTF8String];
    FILE *dst = fopen(bak, "wb");
    if (!dst) { fclose(src); return; }
    char buf[65536];
    size_t n;
    bool ok = true;
    while ((n = fread(buf, 1, sizeof(buf), src)) > 0) {
        if (fwrite(buf, 1, n, dst) != n) { ok = false; break; }
    }
    fclose(src);
    fclose(dst);
    if (!ok) remove(bak); // don't leave a truncated/misleading backup behind
}

+ (NSFileHandle *)fileHandleForWritingAtPath:(NSString *)path {
    eden_backup_before_overwrite(path);
    FILE *fp = fopen([path UTF8String], "r+b"); // matches original's real device fix (audit H1:
                                                  // "rw"->"r+") rather than the pre-fix "rw" mode.
    if (!fp) fp = fopen([path UTF8String], "w+b"); // create if missing
    if (!fp) return nil;
    NSFileHandle *fh = [[NSFileHandle alloc] init];
    fh->_fp = fp;
    return [fh autorelease];
}

// Found chasing the web port's load-failure recovery UI (LoadFailure_web.mm): FileManager::
// loadWorld()'s header/directory sanity check opens the REAL save via fileHandleForUpdatingAtPath:
// purely to READ it -- it never writes through this handle in the failure path. Before this fix,
// -fileHandleForUpdatingAtPath: was a bare alias for -fileHandleForWritingAtPath:, so that read-only
// open ALSO fired the eager backup-before-overwrite -- meaning the mere act of attempting to load a
// truncated/corrupt save copied the corrupt bytes over the last-known-good ".bak", destroying the
// only thing the recovery dialog's Restore button could recover, before the length check a few
// lines later even ran. (headless-confirmed: eden_load_restore_backup() returned success but the
// restored file was byte-identical to the corrupt 50-byte input, not the original.) Fix: defer the
// backup to the first actual WRITE through an "updating" handle (-writeData:/-truncateFileAtOffset:
// below) instead of firing it at open -- a pure read-then-close never triggers it, but the atomic-
// rename save path's real writes into ITS `.savetmp` scratch copy (opened via this same call) still
// get one, same as before.
+ (NSFileHandle *)fileHandleForUpdatingAtPath:(NSString *)path {
    FILE *fp = fopen([path UTF8String], "r+b");
    if (!fp) fp = fopen([path UTF8String], "w+b"); // create if missing
    if (!fp) return nil;
    NSFileHandle *fh = [[NSFileHandle alloc] init];
    fh->_fp = fp;
    fh->_backupPathC = strdup([path UTF8String]);
    return [fh autorelease];
}

// Fires the deferred backup (see -fileHandleForUpdatingAtPath: above) the first time this handle
// is actually used to modify the file, then clears _backupPathC so it never fires twice.
static void eden_fire_deferred_backup(NSFileHandle *fh) {
    if (!fh->_backupPathC) return;
    eden_backup_before_overwrite([NSString stringWithCString:fh->_backupPathC encoding:NSUTF8StringEncoding]);
    free(fh->_backupPathC);
    fh->_backupPathC = nullptr;
}

- (void)seekToFileOffset:(eden_offset_t)offset {
    if (_fp) fseeko(_fp, (off_t)offset, SEEK_SET);
}

- (eden_offset_t)seekToEndOfFile {
    if (_fp) { fseeko(_fp, 0, SEEK_END); return (eden_offset_t)ftello(_fp); }
    return 0;
}

- (eden_offset_t)offsetInFile {
    return _fp ? (eden_offset_t)ftello(_fp) : 0;
}

- (NSData *)readDataOfLength:(NSUInteger)length {
    if (!_fp || length == 0) return [NSData data];
    NSMutableData *d = [NSMutableData dataWithCapacity:length];
    // B6: -setLength: has to zero what it grows into, because that is what real Foundation does
    // and callers elsewhere may lean on it. Here the very next statement overwrites every one of
    // those bytes with fread(), so the fill is pure waste -- and this is the world file's read
    // path, called for every column of every chunk-streaming burst. -setLengthUninitialized: is
    // the shim-only escape hatch for exactly this shape: grow, then immediately fill.
    [d setLengthUninitialized:length];
    size_t got;
    if (g_io_timing && eden_mt_note_io) {
        double _t0 = emscripten_get_now();
        got = fread(d->_bytes.data(), 1, length, _fp);
        eden_mt_note_io(emscripten_get_now() - _t0);
    } else {
        got = fread(d->_bytes.data(), 1, length, _fp);
    }
    [d setLength:(NSUInteger)got];   // shrink only; nothing to initialise
    return d;
}

- (NSData *)readDataToEndOfFile {
    if (!_fp) return [NSData data];
    long cur = ftello(_fp);
    fseeko(_fp, 0, SEEK_END);
    long end = ftello(_fp);
    fseeko(_fp, cur, SEEK_SET);
    return [self readDataOfLength:(NSUInteger)(end - cur)];
}

- (void)writeData:(NSData *)data {
    // Perf-audit C4: this is stdio-BUFFERED, and eden-storage.js's flushNow() (FS.syncfs on
    // visibilitychange/pagehide) reads through MEMFS, not through this FILE*'s userspace buffer —
    // so without an explicit flush, a save interrupted before -closeFile leaves MEMFS (and
    // therefore whatever IndexedDB sync follows) holding a TRUNCATED file, even though the
    // in-process bytes were "written" from FileManager.mm's point of view. Flushing after every
    // write makes MEMFS's view of the file match what the engine believes it just wrote, at the
    // cost of a write() syscall per NSFileHandle -writeData: call (already the granularity
    // FileManager.mm calls this at — one per 32 KB column record — so this is not a new
    // per-byte cost).
    if (_fp && data) {
        eden_fire_deferred_backup(self);
        fwrite([data bytes], 1, [data length], _fp); fflush(_fp);
    }
}

- (void)truncateFileAtOffset:(eden_offset_t)offset {
    if (_fp) { eden_fire_deferred_backup(self); fflush(_fp); ftruncate(fileno(_fp), (off_t)offset); }
}

- (void)closeFile {
    if (_fp) { fclose(_fp); _fp = nullptr; }
}

- (void)dealloc {
    [self closeFile];
    free(_backupPathC);
    [super dealloc];
}

@end
