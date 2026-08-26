// eden-storage.js — local persistence + the Settings panel's "Storage" tab (pass 29).
// Requires: Module.preRun, FS.*, Module._eden_storage_list_worlds; calls window.EdenLoadError
// (loaded later) only from async syncfs/quota callbacks, never at top-level script time — see
// docs/ui.md's dependency graph (audit I2) for why that ordering is safe. Publishes:
// window.EdenStorage.
//
// Mounts /documents (the REAL FileManager's save directory — see docs/save-load.md) on IndexedDB
// via Emscripten's IDBFS, so world saves survive a reload instead of vanishing with the MEMFS they
// used to live in only (docs/archive/PORT-STATUS-2026-08-13.md's #1 open item). {autoPersist:true} (see
// web/emsdk/.../src/library_idbfs.js) means every file close-after-write, mkdir, unlink or rename
// under /documents queues its own debounced IndexedDB sync — no engine-side save hook, no --wrap,
// nothing on the C++ side needs to know this file exists.
//
// This file's two jobs:
//   1. `mountAndSync`, wired into Module.preRun (see eden-st.html) — mounts IDBFS and populates
//      MEMFS from whatever was saved last time, as a run DEPENDENCY so main() (and therefore
//      Menu::loadWorlds' one-shot directory read) cannot run until that read has actually finished.
//      This has to happen JS-side: the populate is inherently async, and blocking it is exactly
//      what Module.preRun + addRunDependency/removeRunDependency exists for.
//   2. Render the Storage tab's per-world list from Module._eden_storage_list_worlds() /
//      _eden_storage_delete_world_at(i) (src/seam/Storage_web.mm) — INDEX based, like every other
//      wasm call in this port, so nothing here needs _malloc/_free on the export list.
//
// Guarded throughout on `typeof indexedDB`: node's headless `eden.js` (docs/STATUS.md
// "Running it") has none, and must keep working exactly as before — MEMFS, session-only.
(function () {
  'use strict';

  var MOUNT_PATH = '/documents';
  var mounted = false;

  function idbAvailable() {
    try { return typeof indexedDB !== 'undefined'; } catch (e) { return false; }
  }

  // Module.preRun entry (called by the Emscripten runtime with no arguments before main()).
  function mountAndSync() {
    if (!idbAvailable() || typeof FS === 'undefined' || typeof IDBFS === 'undefined') return;
    var M = window.Module;
    try { FS.mkdir(MOUNT_PATH); } catch (e) { /* fine if it already exists */ }
    try {
      FS.mount(IDBFS, { autoPersist: true }, MOUNT_PATH);
    } catch (e) {
      console.warn('[eden-storage] IDBFS mount failed — falling back to session-only storage:', e);
      return;
    }
    mounted = true;
    // Perf-audit C4/§6: without an explicit persist() request, IndexedDB is evictable under
    // browser storage pressure like any other origin data — best-effort, no UI gate (Chrome grants
    // it silently based on site-engagement heuristics; Firefox/Safari may prompt or ignore it).
    // Not awaited: whether it resolved true/false doesn't change anything else in this function.
    if (navigator.storage && navigator.storage.persist) {
      navigator.storage.persist().catch(function () {});
    }
    M.addRunDependency('eden-idbfs-populate');
    FS.syncfs(/*populate:*/true, function (err) {
      if (err) console.warn('[eden-storage] IndexedDB -> MEMFS populate failed:', err);
      M.removeRunDependency('eden-idbfs-populate');
      checkQuotaAndWarn();
    });
  }

  // Audit row A7: a `QuotaExceededError` (or any other) out of `FS.syncfs(false, …)` used to be
  // swallowed by a bare `catch (e) {}` here and at importFile's syncfs below — the player sees a
  // successful-looking save that never actually reached IndexedDB. Surface it through the same
  // dialog eden-loaderror.js already shows for a corrupt load, since both are "your world isn't
  // safe" situations the player must not find out about only on next boot. Reported once per
  // session (`warnedThisSession`) so a string of autosaves during a long play session doesn't spam
  // the dialog for what is, after the first hit, the same underlying full-quota condition.
  var warnedThisSession = false;
  function reportSyncError(err) {
    console.warn('[eden-storage] IndexedDB persist failed:', err);
    if (warnedThisSession) return;
    if (!(window.EdenLoadError && window.EdenLoadError.showStorageWarning)) return;
    var msg = (err && (err.name === 'QuotaExceededError' || /quota/i.test(String(err.message || err))))
      ? 'Your browser’s storage quota is full, so this save did not actually persist.'
      : 'A save to browser storage failed to persist (' + (err && (err.name || err.message) || err) + ').';
    warnedThisSession = true;
    window.EdenLoadError.showStorageWarning(msg);
  }

  // Pre-flight warning: check usage against quota *before* it actually fails, since by the time
  // syncfs errors the write attempt already happened. 80% is the threshold the audit calls out —
  // early enough to give the player a chance to export a world (F2) or clear space.
  function checkQuotaAndWarn() {
    if (warnedThisSession) return;
    estimateQuota(function (est) {
      if (!est || !est.quota) return;
      if (est.usage / est.quota < 0.8) return;
      if (warnedThisSession) return;
      if (!(window.EdenLoadError && window.EdenLoadError.showStorageWarning)) return;
      warnedThisSession = true;
      window.EdenLoadError.showStorageWarning(
        'Browser storage is ' + Math.round(100 * est.usage / est.quota) + '% full (' +
        formatBytes(est.usage) + ' of ' + formatBytes(est.quota) + '). Saves may soon fail to ' +
        'persist — consider exporting a world (Storage tab) or freeing space.');
    });
  }

  // Belt-and-suspenders: autoPersist's own queue fires on a setTimeout(0), which a same-tick page
  // unload can in principle race. Both events actually fire on tab close/backgrounding, unlike
  // 'beforeunload' (unreliable on mobile Safari) or 'unload' (deprecated).
  function flushNow() {
    if (!mounted || typeof FS === 'undefined') return;
    checkQuotaAndWarn();
    try {
      FS.syncfs(false, function (err) { if (err) reportSyncError(err); });
    } catch (e) {
      reportSyncError(e);
    }
  }
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flushNow();
  });
  window.addEventListener('pagehide', flushNow);

  // ---------------------------------------------------------------------------------------------
  // Storage tab data access
  // ---------------------------------------------------------------------------------------------
  function M() { return window.Module; }
  function ready() {
    return window.__edenModuleReady && M() && typeof M()._eden_storage_list_worlds === 'function';
  }
  function utf8(ptr) {
    var H = M().HEAPU8, end = ptr;
    while (H[end]) end++;
    // The Uint8Array copy is load-bearing in the EDEN_THREADED build (shared memory cannot be
    // handed to TextDecoder) — full reasoning on the canonical copy in eden-settings.js.
    return new TextDecoder().decode(new Uint8Array(H.subarray(ptr, end)));
  }

  function listWorlds() {
    if (!ready()) return [];
    try { return JSON.parse(utf8(M()._eden_storage_list_worlds())); }
    catch (e) { return []; }
  }

  function deleteWorldAt(index) {
    if (!ready()) return false;
    return M()._eden_storage_delete_world_at(index) !== 0;
  }

  // 256z Stage 3 item 5: space-reclaim action for a 256z ("New Dawn") world. Destructive (see
  // FileManager::convertWorldTo64's own header for exactly what it discards), so this returns the
  // full report rather than a bool — the Storage tab shows it before/instead of a bare success
  // toast. `index` is the same list-position convention as deleteWorldAt/exportWorldAt.
  function convertTo64zAt(index) {
    if (!ready() || !M()._eden_storage_convert_to_64z_at) {
      return { ok: false, error: 'not available' };
    }
    try { return JSON.parse(utf8(M()._eden_storage_convert_to_64z_at(index))); }
    catch (e) { return { ok: false, error: 'malformed response' }; }
  }

  // Row #18 (perf-audit §6, promoted from pass 35's "quick and dirty test hook" — the mechanism
  // was already right, it just hadn't been paired with export or surfaced as a real feature yet):
  // drop a .eden file straight into Documents so it shows up in the world picker, no engine save
  // path involved. Writes via FS.writeFile (the same MEMFS/IDBFS-backed mount Menu::loadWorlds
  // reads), nudges autoPersist with an explicit syncfs (belt-and-suspenders, same as flushNow
  // above), then asks the engine to re-scan its world list. No format validation — a bad file just
  // fails to load like any other corrupt save (docs/eden-file-format.md is the source of truth if
  // that ever matters); cb(ok, errorMessageOrNull).
  function importFile(file, cb) {
    if (!file) { cb && cb(false, 'no file'); return; }
    var reader = new FileReader();
    reader.onload = function () {
      finishImport(file.name || ('import-' + Date.now()), new Uint8Array(reader.result), cb);
    };
    reader.onerror = function () { cb && cb(false, 'file read failed'); };
    reader.readAsArrayBuffer(file);
  }

  // A world exported via the "Compressed" option (see exportWorldAt) is a plain gzip member wrapped
  // around the raw .eden bytes — not the engine's own RLE variant (docs/eden-file-format.md's "RLE
  // variant" is decode-only, bundled-default-world-only, and has no encoder anywhere in this repo or
  // in eden-world-editor to reuse). Gzip is the browser-native, round-trip-safe choice: detect it
  // either by the `.gz` name (own export) or the gzip magic bytes (someone renamed it), inflate with
  // the same DecompressionStream every modern browser already ships, then import the raw bytes as
  // normal. Detected by magic bytes rather than name alone so a re-named .eden.gz dropped onto the
  // Storage tab's file input still round-trips.
  function isGzip(bytes) {
    return bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b;
  }

  function finishImport(name, bytes, cb) {
    if (isGzip(bytes)) {
      if (typeof DecompressionStream === 'undefined') {
        cb && cb(false, 'This browser cannot decompress gzip worlds (no DecompressionStream support).');
        return;
      }
      name = name.replace(/\.gz$/i, '');
      inflateGzip(bytes).then(function (raw) {
        writeWorldFile(name, raw, cb);
      }, function (e) {
        cb && cb(false, 'gzip decompress failed: ' + (e && e.message || e));
      });
      return;
    }
    writeWorldFile(name, bytes, cb);
  }

  function writeWorldFile(name, bytes, cb) {
    try {
      if (typeof FS === 'undefined') throw new Error('FS unavailable');
      if (!/\.eden$/i.test(name)) name += '.eden';
      FS.writeFile(MOUNT_PATH + '/' + name, bytes);
      if (mounted) {
        try { FS.syncfs(false, function (err) { if (err) reportSyncError(err); }); }
        catch (e) { reportSyncError(e); }
      }
      if (ready() && M()._eden_storage_reload_worlds) M()._eden_storage_reload_worlds();
      cb && cb(true, null);
    } catch (e) {
      cb && cb(false, e.message || String(e));
    }
  }

  function inflateGzip(bytes) {
    var ds = new DecompressionStream('gzip');
    var stream = new Blob([bytes]).stream().pipeThrough(ds);
    return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
  }

  function deflateGzip(bytes) {
    var cs = new CompressionStream('gzip');
    var stream = new Blob([bytes]).stream().pipeThrough(cs);
    return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
  }

  // Row #18 (perf-audit §6): "the single best answer to my browser cleared my storage" —
  // download a world's real .eden file so the player has an off-device copy, independent of
  // navigator.storage.persist()'s best-effort guarantee above. Reads the file straight out of the
  // same IDBFS-backed MEMFS mount importFile() writes into, so export/import round-trip through
  // exactly the format docs/eden-file-format.md describes — no engine call needed, this is a pure
  // file copy out of the mount.
  function downloadBytes(bytes, filename) {
    var blob = new Blob([bytes], { type: 'application/octet-stream' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 4000);
  }

  // `compress: true` gzips the raw .eden bytes before handing them to the browser's normal download
  // flow — same file, smaller download, and losslessly reversible by importFile's gzip detection
  // above. Kept synchronous-shaped (returns true/false immediately) for the uncompressed path since
  // that's what the Storage tab's existing caller expects; compression is inherently async
  // (CompressionStream), so that path takes `cb(ok, errorOrNull)` instead — callers that only care
  // about the uncompressed case can still ignore the third argument.
  function exportWorldAt(index, compress, cb) {
    if (typeof compress === 'function') { cb = compress; compress = false; }
    if (!ready() || typeof FS === 'undefined') { cb && cb(false, 'not ready'); return false; }
    var worlds = listWorlds();
    var w = worlds[index];
    if (!w) { cb && cb(false, 'no such world'); return false; }
    try {
      var data = FS.readFile(MOUNT_PATH + '/' + w.file);
      if (!compress) {
        downloadBytes(data, w.file);
        cb && cb(true, null);
        return true;
      }
      if (typeof CompressionStream === 'undefined') {
        cb && cb(false, 'This browser cannot compress worlds (no CompressionStream support).');
        return false;
      }
      deflateGzip(data).then(function (gz) {
        downloadBytes(gz, w.file + '.gz');
        cb && cb(true, null);
      }, function (e) {
        cb && cb(false, 'gzip compress failed: ' + (e && e.message || e));
      });
      return true;
    } catch (e) {
      console.warn('[eden-storage] export failed:', e);
      cb && cb(false, e.message || String(e));
      return false;
    }
  }

  function canCompress() {
    return typeof CompressionStream !== 'undefined';
  }

  function formatBytes(n) {
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MB';
    return (n / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
  }

  function formatDate(ms) {
    if (!ms) return 'Unknown';
    var d = new Date(ms);
    return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) +
      ' ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  }

  // Best-effort browser-reported IndexedDB usage/quota for the whole origin (covers settings'
  // localStorage too, not just worlds) — not supported everywhere, callback gets null if so.
  function estimateQuota(cb) {
    if (navigator.storage && navigator.storage.estimate) {
      navigator.storage.estimate().then(cb).catch(function () { cb(null); });
    } else {
      cb(null);
    }
  }

  window.EdenStorage = {
    mountAndSync: mountAndSync,
    isPersistent: function () { return mounted; },
    listWorlds: listWorlds,
    deleteWorldAt: deleteWorldAt,
    convertTo64zAt: convertTo64zAt,
    importFile: importFile,
    exportWorldAt: exportWorldAt,
    canCompress: canCompress,
    formatBytes: formatBytes,
    formatDate: formatDate,
    estimateQuota: estimateQuota
  };
})();
