/*
 * OpsAPI service worker — Level 1 PWA (installable + offline shell + static
 * asset caching). Hand-written (no build step) so it's independent of the
 * bundler (Next 16 uses Turbopack).
 *
 * Caching policy — deliberately conservative for a multi-tenant app:
 *   - Cross-origin requests (the backend API lives on another origin): NOT
 *     handled here → straight to network, never cached.
 *   - Same-origin /api/*: never cached (authenticated, tenant-scoped data must
 *     not sit in a shared cache).
 *   - Navigations (HTML): network-first, fall back to the last cached copy, then
 *     to the offline page. So you always get fresh pages online, and visited
 *     pages still open offline.
 *   - Static build assets (/_next/static, icons, fonts, images): stale-while-
 *     revalidate for instant repeat loads.
 *
 * Bump CACHE_VERSION to force every client to drop old caches on next load.
 */
const CACHE_VERSION = 'v1';
const CACHE = `opsapi-${CACHE_VERSION}`;
const OFFLINE_URL = '/offline';

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.addAll([OFFLINE_URL]))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)));
      await self.clients.claim();
    })()
  );
});

const isStaticAsset = (url) =>
  url.pathname.startsWith('/_next/static') ||
  url.pathname.startsWith('/icons/') ||
  /\.(?:css|js|woff2?|ttf|otf|png|jpe?g|svg|webp|gif|ico)$/.test(url.pathname);

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Never touch cross-origin (backend API, third parties) or same-origin /api —
  // authenticated / tenant-scoped responses must never be cached.
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/api')) return;

  // Navigations: network-first with an offline fallback.
  if (request.mode === 'navigate') {
    event.respondWith(
      (async () => {
        try {
          const fresh = await fetch(request);
          const cache = await caches.open(CACHE);
          cache.put(request, fresh.clone());
          return fresh;
        } catch {
          const cache = await caches.open(CACHE);
          return (await cache.match(request)) || (await cache.match(OFFLINE_URL));
        }
      })()
    );
    return;
  }

  // Static assets: stale-while-revalidate.
  if (isStaticAsset(url)) {
    event.respondWith(
      (async () => {
        const cache = await caches.open(CACHE);
        const cached = await cache.match(request);
        const network = fetch(request)
          .then((res) => {
            if (res && res.ok) cache.put(request, res.clone());
            return res;
          })
          .catch(() => cached);
        return cached || network;
      })()
    );
  }
});
