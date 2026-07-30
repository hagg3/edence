// service-worker.js — perf-audit row #21: PWA installability + a one-time-download cost for the
// static app shell, without fighting two things this port already depends on:
//
//   1. RESUME-HERE's documented dev workflow ("serve on a FRESH PORT after a rebuild") exists
//      because nothing else in this port caches build-st/build-rel output — a service worker that
//      cached eden.js/eden.wasm/eden.data cache-first would silently start serving a stale build
//      to anyone who'd ever visited before, in a way a fresh port can't fix (a SW's cache persists
//      across ports/origins-are-per-origin-not-per-port... actually per ORIGIN, and localhost:PORT
//      is a distinct origin per port, so a genuinely fresh port *would* dodge a stale SW too — but
//      the reasoning below holds regardless: don't add a second source of staleness on top of the
//      one that workflow already manages by hand).
//   2. Row #9's lazy `Eden.eden` FS node (pass 46) — a hand-written Range-request byte-server. A
//      SW that intercepted a Range request and answered it out of a whole-file cache entry (or
//      cached a 206 response as if it were the full body) would silently break that contract.
//
// So the strategy is NETWORK-FIRST for everything, falling back to a cache ONLY when the network
// genuinely fails (the actual offline case a PWA exists for) — never cache-first. An online dev
// session or player always gets the freshest bytes; nothing here can make a rebuild look stale.
// Range requests and `Eden.eden` itself are never intercepted at all — those requests pass straight
// to the network exactly as if this file didn't exist.
'use strict';

const CACHE_NAME = 'eden-shell-v1';

// Precached at install time: the app shell JS/CSS/HTML/icons, which change only across an
// intentional deploy, not across every local rebuild — the *reason* build-st/build-rel/Eden.eden
// are deliberately absent from this list (see header). Those are still cached, just lazily, by the
// network-first fetch handler below the first time they're successfully requested.
const SHELL_URLS = [
  'public/eden-st.html',
  'public/manifest.webmanifest',
  'public/eden-ui.js',
  'public/eden-ui.css',
  'public/eden-icons.js',
  'public/eden-assets.js',
  'public/eden-menu.js',
  'public/eden-pausemenu.js',
  'public/eden-settings.js',
  'public/eden-storage.js',
  'public/eden-loading.js',
  'public/eden-loaderror.js',
  'public/audio/icons/Icon_57.png',
  'public/audio/icons/Icon_72.png',
  'public/audio/icons/Icon_114.png',
  'public/audio/icons/Icon_144.png',
];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_URLS))
      .catch((err) => console.warn('[eden-sw] shell precache incomplete:', err))
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;                    // never touch saves/POSTs
  if (req.headers.has('range')) return;                 // never touch the lazy Eden.eden byte-server
  let url;
  try { url = new URL(req.url); } catch (e) { return; }
  if (url.origin !== self.location.origin) return;      // don't cache cross-origin requests
  if (/\/Eden\.eden$/.test(url.pathname)) return;        // never cache the default-world file itself

  event.respondWith(
    fetch(req).then((res) => {
      if (res && res.ok) {
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, copy)).catch(() => {});
      }
      return res;
    }).catch(() => caches.match(req).then((cached) => {
      if (cached) return cached;
      throw new Error('eden-sw: offline and not cached: ' + url.pathname);
    }))
  );
});
