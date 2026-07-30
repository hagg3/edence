#!/usr/bin/env node
// serve.js — small static file server with real compression + conditional caching
// (perf-audit-dazzling-munching-bengio.md row 10 / Q8: "python3 -m http.server sends no
// Cache-Control and no compression").
//
// Deliberately NOT "far-future immutable caching on content-hashed filenames" (Q8's fuller
// recommendation) — eden.wasm/eden.data/Eden.eden are unhashed, literal filenames the Emscripten
// glue (eden.js) and eden_default_world.pre.js both reference directly, and RESUME-HERE's own
// workflow ("serve on a FRESH PORT after a rebuild") depends on being able to force a refetch by
// changing the origin. Adding content-hashing would need a build-time rename/rewrite step —
// bigger than this row's scope, left as future work if it's ever picked up.
//
// What this DOES give, safely, without touching that workflow:
//   - Brotli (falls back to gzip, falls back to identity) compression of text/wasm/binary assets,
//     computed once and cached in memory — cuts the ~69 MB cold-start transfer noticeably (Eden.eden
//     is RLE'd but not entropy-coded, so it compresses further; eden.wasm's DWARF-free Release
//     build and eden.data both compress well too).
//   - ETag (mtime+size) + If-None-Match -> 304, so a reload in the SAME session that didn't change
//     any file re-validates in one round trip instead of re-transferring 69 MB. This is the
//     practical form of "near-zero warm start" achievable without a hashing pipeline: correctness
//     (a real rebuild changes mtime/size, so the ETag changes and a real refetch happens) over the
//     raw speed of an immutable far-future header.
//   - Byte serving (Accept-Ranges + real 206 responses, added pass 46). The lazy Eden.eden FS node
//     (perf-audit row 9, src/seam/js/eden_default_world.pre.js) needs Range requests to avoid
//     holding 52 MB resident; python3 -m http.server has no byte serving at all, so with it the
//     port silently falls back to fetching the whole file. Range responses are always identity-
//     encoded — a range of a Brotli'd body is not the range the client asked for.
//   - Cache-Control: no-cache, must-revalidate on everything — always at least one round trip to
//     confirm freshness (compatible with "serve on a fresh port after a rebuild" — a fresh origin
//     has no cache entries to revalidate against anyway), never a silently stale asset.
//
// Usage: node tools/serve.js [port] [root]
//   node tools/serve.js 8123        # from web/, same working directory python3 -m http.server needs
//   node tools/serve.js 8123 public # serve public/ as the root, e.g. http://localhost:8123/eden-st.html

'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const PORT = parseInt(process.argv[2], 10) || 8123;
const ROOT = path.resolve(process.argv[3] || '.');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.eden': 'application/octet-stream',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.mp3': 'audio/mpeg',
  '.ogg': 'audio/ogg',
  '.wav': 'audio/wav',
  '.svg': 'image/svg+xml',
};

// Compress once per (path, mtime, encoding) and keep the result in memory — every subsequent
// request for an unchanged file is a cache hit, not a re-compress. A real rebuild changes mtime,
// which naturally evicts the stale entry (checked below, not just appended to).
const compressedCache = new Map(); // key: `${filePath}:${encoding}` -> {mtimeMs, size, buf}

function pickEncoding(acceptEncoding) {
  const ae = acceptEncoding || '';
  if (/\bbr\b/.test(ae)) return 'br';
  if (/\bgzip\b/.test(ae)) return 'gzip';
  return null;
}

// Only worth compressing compressible content; skip already-lossy media.
function shouldCompress(ext) {
  return ['.html', '.js', '.mjs', '.css', '.json', '.wasm', '.data', '.eden', '.svg'].includes(ext);
}

function getCompressed(filePath, stat, encoding, raw) {
  const key = filePath + ':' + encoding;
  const cached = compressedCache.get(key);
  if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) return cached.buf;
  const buf = encoding === 'br'
    ? zlib.brotliCompressSync(raw, {
        params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 6 } // 6: real ratio, not multi-second stalls on 52 MB Eden.eden
      })
    : zlib.gzipSync(raw, { level: 6 });
  compressedCache.set(key, { mtimeMs: stat.mtimeMs, size: stat.size, buf });
  return buf;
}

// Single-range only ("bytes=START-END", "bytes=START-", "bytes=-SUFFIX"), which is all any client
// of this server asks for. Multipart/byteranges is out of scope; an unparseable header is treated
// as no range at all (RFC 9110 says to ignore it), an out-of-bounds one as 416.
function parseRange(header, size) {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m || (m[1] === '' && m[2] === '')) return null;
  let start, end;
  if (m[1] === '') {                       // suffix: last N bytes
    const n = parseInt(m[2], 10);
    if (n <= 0) return 'unsatisfiable';
    start = Math.max(0, size - n); end = size - 1;
  } else {
    start = parseInt(m[1], 10);
    end = m[2] === '' ? size - 1 : parseInt(m[2], 10);
  }
  if (start >= size || start > end) return 'unsatisfiable';
  return { start, end: Math.min(end, size - 1) };
}

const server = http.createServer((req, res) => {
  let urlPath = decodeURIComponent(req.url.split('?')[0]);
  if (urlPath.endsWith('/')) urlPath += 'index.html';
  const filePath = path.normalize(path.join(ROOT, urlPath));
  if (!filePath.startsWith(ROOT)) { res.writeHead(403); res.end('Forbidden'); return; }

  fs.stat(filePath, (err, stat) => {
    if (err || !stat.isFile()) { res.writeHead(404); res.end('Not found: ' + urlPath); return; }

    const ext = path.extname(filePath).toLowerCase();
    const etag = '"' + crypto.createHash('sha1').update(filePath + ':' + stat.mtimeMs + ':' + stat.size).digest('hex').slice(0, 16) + '"';

    res.setHeader('Cache-Control', 'no-cache, must-revalidate');
    res.setHeader('ETag', etag);
    res.setHeader('Content-Type', MIME[ext] || 'application/octet-stream');
    // Byte serving, required by the lazy Eden.eden FS node (perf-audit row 9 —
    // src/seam/js/eden_default_world.pre.js probes for this and silently falls back to fetching
    // the whole 52 MB file if it's missing, which is exactly what python3 -m http.server does).
    res.setHeader('Accept-Ranges', 'bytes');

    if (req.headers['if-none-match'] === etag) { res.writeHead(304); res.end(); return; }
    if (req.method === 'HEAD') { res.setHeader('Content-Length', stat.size); res.writeHead(200); res.end(); return; }

    const range = parseRange(req.headers['range'], stat.size);
    if (range === 'unsatisfiable') {
      res.setHeader('Content-Range', 'bytes */' + stat.size);
      res.writeHead(416); res.end(); return;
    }
    if (range) {
      // Deliberately served IDENTITY-encoded: a Content-Encoding on a 206 would make the byte
      // range a range of the COMPRESSED body, which is not what the client asked for. Read only
      // the requested slice — a range request must not cost a 52 MB readFileSync.
      const len = range.end - range.start + 1;
      const buf = Buffer.alloc(len);
      const fd = fs.openSync(filePath, 'r');
      let got = 0;
      try { got = fs.readSync(fd, buf, 0, len, range.start); } finally { fs.closeSync(fd); }
      res.setHeader('Content-Range', `bytes ${range.start}-${range.end}/${stat.size}`);
      res.setHeader('Content-Length', got);
      res.writeHead(206);
      res.end(buf.subarray(0, got));
      return;
    }

    const raw = fs.readFileSync(filePath);
    const encoding = shouldCompress(ext) ? pickEncoding(req.headers['accept-encoding']) : null;

    if (encoding) {
      const body = getCompressed(filePath, stat, encoding, raw);
      res.setHeader('Content-Encoding', encoding);
      res.setHeader('Vary', 'Accept-Encoding');
      res.setHeader('Content-Length', body.length);
      res.writeHead(200);
      res.end(body);
    } else {
      res.setHeader('Content-Length', raw.length);
      res.writeHead(200);
      res.end(raw);
    }
  });
});

server.listen(PORT, () => {
  console.log(`[serve] ${ROOT} -> http://localhost:${PORT}/  (Brotli/gzip + ETag revalidation)`);
});
