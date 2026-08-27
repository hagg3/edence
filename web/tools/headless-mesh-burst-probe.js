// Measures the worst-case main-thread block a teleport/warp causes, by triggering
// Terrain::prepareAndLoadGeometry's "count>140" bulk-reload path (Classes/Terrain.mm) and
// sampling the inter-timer gap the same way tools/headless-load-timing.js measures the initial
// world load — this is the other half of the same question, applied to the far larger burst a
// fast teleport can produce mid-session rather than the one-time boot load.
//
// WHY A SEPARATE SCRATCH BUILD (build-relwdiag, -DCMAKE_BUILD_TYPE=Release -DEDEN_DIAGNOSTICS=ON):
// eden_console_teleport is EDEN_DIAGNOSTICS-only (DevConsole_web.mm), which build-rel compiles
// out — but build-st is -O0, and a first pass through real Safari (see the tool's own commit
// history / RESUME-HERE) measured ~8x higher per-chunk mesh cost there than build-rel's -O2
// walking measurement, an apples-to-oranges gap, not a real difference. This combination was
// already established clean by pass 53 (project-audit-2026-07-30 row B1's investigation) — Release
// codegen with the diagnostics probes still linked in — so it is the fair way to get both a real
// -O2 number AND console access to trigger a burst deterministically.
//
// Usage:
//   emcmake cmake -B build-relwdiag -DCMAKE_BUILD_TYPE=Release -DEDEN_DIAGNOSTICS=ON -DEDEN_THREADED=OFF
//   cmake --build build-relwdiag -j8
//   node tools/headless-mesh-burst-probe.js [path/to/eden.js]   (defaults to ../build-relwdiag)
// build-relwdiag is a scratch tree, not checked in and not one of the three standard trees —
// delete it when done (RESUME-HERE's "scratch CMake dirs go directly under web/" gotcha).
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const positional = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const edenJsPath = path.resolve(positional[0] || path.join(__dirname, '..', 'build-relwdiag', 'eden.js'));
const edenDir = path.dirname(edenJsPath);

global.require = require;
global.__dirname = edenDir;
global.__filename = edenJsPath;
global.Module = { print: () => {}, printErr: () => {} };

const cwdBefore = process.cwd();
process.chdir(edenDir);
vm.runInThisContext(fs.readFileSync(edenJsPath, 'utf8'), { filename: edenJsPath });
process.chdir(cwdBefore);

function waitUntil(predicate, timeoutMs, label) {
    return new Promise((resolve) => {
        const start = Date.now();
        const poll = () => {
            let ok = false;
            try { ok = predicate(); } catch (e) { /* not ready */ }
            if (ok) return resolve(true);
            if (Date.now() - start > timeoutMs) {
                console.log(`  (timed out waiting for: ${label})`);
                return resolve(false);
            }
            setTimeout(poll, 5);
        };
        poll();
    });
}

const inMenu = () => global.Module._eden_menu_active() === 1;

function readTiming() {
    const ptr = global.Module._eden_debug_mesh_timing();
    let end = ptr;
    while (global.Module.HEAPU8[end] !== 0) end++;
    return JSON.parse(Buffer.from(global.Module.HEAPU8.slice(ptr, end)).toString('utf8'));
}

// Sample the worst inter-timer gap over `body()`, same technique as headless-load-timing.js —
// node's 1ms timer callback shares the thread with the fake-rAF loop, so a gap of N ms IS N ms of
// blocked main thread.
async function timedBlock(label, body) {
    let last = Date.now();
    const gaps = [];
    const sampler = setInterval(() => {
        const now = Date.now();
        gaps.push(now - last);
        last = now;
    }, 1);
    await body();
    clearInterval(sampler);
    gaps.sort((a, b) => b - a);
    // B3 Stage 2 needs a number for the thing B3 is actually FOR, and longest_block_ms is not it.
    // STATUS.md §3 item 2 characterised the remaining bulk-reload problem in real Safari as a
    // ~2 s SOFT DRAG — ~90 of ~148 frames at 20-30 ms — not a lockup; the worst frame was already
    // fixed by pass 70's frame-spreading. over_budget_ms is that drag as one figure: the total
    // wall-clock the main thread spent past the 60 fps budget during the burst, i.e. sum of
    // max(0, gap - 16.66). Halving it means the window fills in at 60 fps where it used to fill in
    // at 45, which is exactly the claim B3 has to make.
    const overBudget = gaps.reduce((a, g) => a + Math.max(0, g - 16.66), 0);
    return {
        label,
        longest_block_ms: gaps[0] || 0,
        blocks_over_16ms: gaps.filter((g) => g > 16.66).length,
        blocks_over_8ms: gaps.filter((g) => g > 8.33).length,
        over_budget_ms: +overBudget.toFixed(1),
    };
}

global.Module.postRun = global.Module.postRun || [];
global.Module.postRun.push(async () => {
    if (!(await waitUntil(inMenu, 15000, 'the menu to come up'))) {
        console.log('FATAL: never reached the menu');
        process.exit(1);
    }
    global.Module._eden_menu_create_world();
    global.Module._eden_menu_set_pending_world_type(0);
    global.Module._eden_menu_play();
    if (!(await waitUntil(() => !inMenu(), 60000, 'GAME_MODE_PLAY'))) {
        console.log('FATAL: never reached play');
        process.exit(1);
    }
    await new Promise((r) => setTimeout(r, 2000)); // let the initial-load churn settle

    const results = [];
    // Several teleports far enough apart that each one re-triggers a near-full-window reload
    // (Terrain.mm's `count>140` gate) — same coordinates used against the real-Safari run.
    const targets = [
        [64700, 40, 65700], [65100, 40, 65350], [64300, 40, 66000],
        [65500, 40, 65100], [63900, 40, 66300],
    ];
    // B1 (ROADMAP Phase B): the lazy Eden.eden node's cache/transport stats. No reset hook, so
    // snapshot-and-diff around each burst. fetchMs is the readRange() transport (fs.readSync
    // headless, sync XHR in-browser); requests/bytesFetched/blockMisses show whether a burst is
    // actually touching disk or replaying a warm cache.
    const fsStats = () => {
        const s = (global.Module.EdenWorldFS && global.Module.EdenWorldFS.stats) || {};
        return { requests: s.requests || 0, bytesFetched: s.bytesFetched || 0,
                 blockHits: s.blockHits || 0, blockMisses: s.blockMisses || 0,
                 evictions: s.evictions || 0, fetchMs: s.fetchMs || 0, fetchMsMax: s.fetchMsMax || 0 };
    };
    for (const [x, y, z] of targets) {
        global.Module._eden_debug_mesh_timing_reset();
        const fs0 = fsStats();
        let fillMs = 0;
        const r = await timedBlock(`teleport to (${x},${y},${z})`, async () => {
            const t0 = Date.now();
            global.Module._eden_console_teleport(x, y, z);
            // B3 Stage 2's honesty check. "Fewer over-budget frames" is a hollow win if the window
            // simply takes twice as long to fill — moving the work off the critical path is only
            // worth anything if the same work still LANDS in the same wall clock. Poll the mesh
            // counter and remember when it last moved: that is when the last of the burst's ~1296
            // chunks was meshed, i.e. when the frontier finished filling in.
            let lastCount = 0;
            const watch = setInterval(() => {
                const c = readTiming().meshCount;
                if (c > lastCount) { lastCount = c; fillMs = Date.now() - t0; }
            }, 10);
            // The bulk-reload gate needs two consecutive over-140 frames (Terrain.mm's
            // hit_load_counter) before it actually loads+meshes — give it real wall-clock frames
            // to reach that, then a little more for the mesh burst itself to finish.
            await new Promise((res) => setTimeout(res, 1500));
            clearInterval(watch);
        });
        r.fill_ms = fillMs;
        const timing = readTiming();
        const fs1 = fsStats();
        const worldfs = {
            requests: fs1.requests - fs0.requests,
            kbFetched: +((fs1.bytesFetched - fs0.bytesFetched) / 1024).toFixed(1),
            blockMisses: fs1.blockMisses - fs0.blockMisses,
            evictions: fs1.evictions - fs0.evictions,
            fetchMs: +(fs1.fetchMs - fs0.fetchMs).toFixed(3),
            fetchMsMax: +fs1.fetchMsMax.toFixed(3),
        };
        // readMs = NSFileHandle I/O (ioMs) + RLE-decode/transpose CPU. ioMs = transport (fetchMs)
        // + block-cache/coalesce overhead. Break it out so B1 has the layered number it asks for.
        const rleCpuMs = +(timing.readMs - timing.ioMs).toFixed(3);
        const cacheMs = +(timing.ioMs - worldfs.fetchMs).toFixed(3);
        results.push({
            ...r, ...timing,
            meshMsPerChunk: timing.meshCount ? +(timing.meshMs / timing.meshCount).toFixed(4) : 0,
            b1_breakdown: { readMs: +timing.readMs.toFixed(3), ioMs: +timing.ioMs.toFixed(3),
                            transportMs: worldfs.fetchMs, cacheMs, rleCpuMs, ...worldfs },
        });
    }

    console.log(JSON.stringify(results, null, 2));
    const worst = results.reduce((a, b) => (b.longest_block_ms > a.longest_block_ms ? b : a));
    console.log(`\nworst single main-thread block across ${results.length} teleport bursts: ` +
        `${worst.longest_block_ms} ms (${worst.meshCount} chunks meshed, ${worst.meshMs.toFixed(1)}ms of ` +
        `mesh CPU time, ${worst.uploadMs.toFixed(2)}ms of GL upload time) — build: ${edenJsPath}`);
    const tot = results.reduce((a, b) => ({
        readMs: a.readMs + b.readMs, ioMs: a.ioMs + b.ioMs,
        transportMs: a.transportMs + b.b1_breakdown.transportMs,
        rleCpuMs: a.rleCpuMs + b.b1_breakdown.rleCpuMs,
    }), { readMs: 0, ioMs: 0, transportMs: 0, rleCpuMs: 0 });
    // B3 Stage 2. dispatched/inlined say whether the worker pool actually took the work or fell
    // back to the inline path (no threads, no free slot, or fire in the chunk — all three are
    // designed fallbacks, not failures); stale says how often an edit landed under a running job;
    // snapshotMs is the 8 KB-per-chunk pblocks+pcolors copy the pool ADDS to the main thread.
    const b3 = results.reduce((a, b) => ({
        dispatched: a.dispatched + (b.dispatched || 0), inlined: a.inlined + (b.inlined || 0),
        published: a.published + (b.published || 0), stale: a.stale + (b.stale || 0),
        snapshotMs: a.snapshotMs + (b.snapshotMs || 0),
        overBudget: a.overBudget + b.over_budget_ms, over16: a.over16 + b.blocks_over_16ms,
    }), { dispatched: 0, inlined: 0, published: 0, stale: 0, snapshotMs: 0, overBudget: 0, over16: 0 });
    console.log(`soft-drag total over ${results.length} bursts: ${b3.overBudget.toFixed(0)} ms past the ` +
        `16.66 ms budget, in ${b3.over16} frames; window fill time ` +
        `${results.map((x) => x.fill_ms).join('/')} ms`);
    console.log(`B3 mesh pool: ${b3.dispatched} chunks dispatched to workers, ${b3.inlined} meshed ` +
        `inline, ${b3.published} published, ${b3.stale} went stale; ` +
        `${b3.snapshotMs.toFixed(1)} ms of snapshot memcpy on the main thread`);
    console.log(`B1 column-read breakdown, summed over ${results.length} bursts: ` +
        `readMs ${tot.readMs.toFixed(1)} = fread I/O ${tot.ioMs.toFixed(1)} ` +
        `(transport ${tot.transportMs.toFixed(1)} + cache/coalesce ${(tot.ioMs - tot.transportMs).toFixed(1)}) ` +
        `+ RLE decode/transpose CPU ${tot.rleCpuMs.toFixed(1)}`);
    process.exit(0);
});
