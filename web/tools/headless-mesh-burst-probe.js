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
    return { label, longest_block_ms: gaps[0] || 0, blocks_over_16ms: gaps.filter((g) => g > 16.66).length };
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
    for (const [x, y, z] of targets) {
        global.Module._eden_debug_mesh_timing_reset();
        const r = await timedBlock(`teleport to (${x},${y},${z})`, async () => {
            global.Module._eden_console_teleport(x, y, z);
            // The bulk-reload gate needs two consecutive over-140 frames (Terrain.mm's
            // hit_load_counter) before it actually loads+meshes — give it real wall-clock frames
            // to reach that, then a little more for the mesh burst itself to finish.
            await new Promise((res) => setTimeout(res, 1500));
        });
        const timing = readTiming();
        results.push({ ...r, ...timing, meshMsPerChunk: timing.meshCount ? +(timing.meshMs / timing.meshCount).toFixed(4) : 0 });
    }

    console.log(JSON.stringify(results, null, 2));
    const worst = results.reduce((a, b) => (b.longest_block_ms > a.longest_block_ms ? b : a));
    console.log(`\nworst single main-thread block across ${results.length} teleport bursts: ` +
        `${worst.longest_block_ms} ms (${worst.meshCount} chunks meshed, ${worst.meshMs.toFixed(1)}ms of ` +
        `mesh CPU time, ${worst.uploadMs.toFixed(2)}ms of GL upload time) — build: ${edenJsPath}`);
    process.exit(0);
});
