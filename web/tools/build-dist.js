#!/usr/bin/env node
// build-dist.js — audit row A10: materialise public/ into a real, deployable dist/ tree.
//
// THE PROBLEM: CMake's `file(CREATE_LINK)` points public/audio -> ../media and
// public/Eden.eden -> the repo root using ABSOLUTE paths (see web/CMakeLists.txt). That makes
// public/ correct to serve from THIS checkout with tools/serve.js, but not portable — copying
// public/ to another machine, or handing it to a plain static host that doesn't dereference
// symlinks, ships two broken links instead of a game. `.github/workflows/pages.yml` already
// solved this for the GitHub Pages deploy (`cp -RL public/. _site/public/` dereferences both
// links into real files, scoped to that one CI job) — this script is the same fix, generalised
// so it also works for a local `dist/`-style deploy to a plain static host outside this repo's
// own CI (the gap A10's original finding named as still open after the Pages fix).
//
// Deliberately mirrors the CI "Assemble site" step's shape (see pages.yml) rather than
// reinventing one — same directory layout, same index.html redirect — so `dist/` and the
// deployed Pages site are the same artifact and a difference between them is a real bug, not
// two independently-maintained assembly scripts drifting apart.
//
// Usage:
//   node tools/build-dist.js [--build=rel|st] [--out=dist]
//     --build=rel (default) uses build-rel/ (Release — what pages.yml ships).
//     --build=st            uses build-st/ (Debug, EDEN_DIAGNOSTICS=ON — for a local smoke check
//                            of the assembled tree without a Release rebuild).
//
// Does NOT invoke emcc/cmake — it only copies files a build already produced. Run
// `cmake --build build-rel -j8` (or build-st) first if the chosen build dir is missing or stale.

'use strict';
const fs = require('fs');
const path = require('path');

const webRoot = path.resolve(__dirname, '..');

function argValue(name, fallback) {
  const prefix = `--${name}=`;
  const hit = process.argv.slice(2).find((a) => a.startsWith(prefix));
  return hit ? hit.slice(prefix.length) : fallback;
}

const buildKind = argValue('build', 'rel');
if (buildKind !== 'rel' && buildKind !== 'st') {
  console.error(`build-dist: --build must be "rel" or "st", got "${buildKind}"`);
  process.exit(1);
}
const buildDirName = `build-${buildKind}`;
const buildDir = path.join(webRoot, buildDirName);
const outDir = path.resolve(webRoot, argValue('out', 'dist'));

function requireFile(p, hint) {
  if (!fs.existsSync(p)) {
    console.error(`build-dist: missing ${path.relative(webRoot, p)}${hint ? ` (${hint})` : ''}`);
    console.error(`build-dist: run "cmake --build ${buildDirName} -j8" first.`);
    process.exit(1);
  }
}

requireFile(path.join(buildDir, 'eden.js'));
requireFile(path.join(buildDir, 'eden.wasm'));

console.log(`build-dist: assembling ${buildDirName} -> ${path.relative(webRoot, outDir)}/`);

fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(path.join(outDir, 'public'), { recursive: true });
fs.mkdirSync(path.join(outDir, buildDirName), { recursive: true });

// Real files, not the absolute-path symlinks CMake created for THIS checkout — this is the
// script's actual reason to exist (see the header comment for why public/audio and
// public/Eden.eden are symlinks). NOT fs.cpSync's `dereference` option: that flag only resolves
// the copy's TOP-LEVEL source if it is itself a symlink — it does not dereference symlinks
// encountered while walking a directory recursively (confirmed against Node 26; `cp -RL`, which
// pages.yml uses, has no such limitation). copyDereferenced() below is the manual walk that
// actually behaves like `cp -RL`.
function copyDereferenced(src, dst) {
  const real = fs.existsSync(src) ? fs.realpathSync(src) : src;
  const st = fs.statSync(real);
  if (st.isDirectory()) {
    fs.mkdirSync(dst, { recursive: true });
    for (const entry of fs.readdirSync(real)) {
      copyDereferenced(path.join(real, entry), path.join(dst, entry));
    }
  } else {
    fs.copyFileSync(real, dst);
  }
}
copyDereferenced(path.join(webRoot, 'public'), path.join(outDir, 'public'));

const serviceWorker = path.join(webRoot, 'service-worker.js');
if (fs.existsSync(serviceWorker)) {
  // Registered from eden-st.html as '../service-worker.js' (resolved against the site root) —
  // pages.yml's own comment on this same copy explains why it can't just live under public/.
  fs.copyFileSync(serviceWorker, path.join(outDir, 'service-worker.js'));
}

for (const f of ['eden.js', 'eden.wasm', 'eden.data']) {
  const src = path.join(buildDir, f);
  if (fs.existsSync(src)) fs.copyFileSync(src, path.join(outDir, buildDirName, f));
}

const buildParam = buildKind === 'rel' ? '?build=rel' : '';
fs.writeFileSync(
  path.join(outDir, 'index.html'),
  `<!doctype html>\n<meta charset="utf-8">\n` +
    `<meta http-equiv="refresh" content="0; url=public/eden-st.html${buildParam}">\n` +
    `<p>Loading Eden: World Builder… if nothing happens, ` +
    `<a href="public/eden-st.html${buildParam}">click here</a>.</p>\n`
);

console.log(`build-dist: done. Serve ${path.relative(webRoot, outDir)}/ with any static file`);
console.log('build-dist: server that supports HTTP Range requests (tools/serve.js does; a host');
console.log('build-dist: that does not, like GitHub Pages, silently falls back to the eager');
console.log('build-dist: whole-file Eden.eden path instead of lazy byte-range loading).');
