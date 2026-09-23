'use client';

// In the App Router, clicking around is client-side navigation — the browser
// never fetches the route's HTML document, so the service worker never caches
// it. Then a hard refresh of that route while offline misses the cache and falls
// back to the offline page.
//
// This warms the SW cache with the current route's document (once, while online)
// on every navigation, so a later offline refresh finds it and boots the app —
// which then renders from the IndexedDB data cache.
import { usePathname } from 'next/navigation';
import { useEffect } from 'react';

// Must match the CACHE name in public/sw.js.
const PWA_CACHE = 'opsapi-v1';

export default function RouteCacheWarmer() {
  const pathname = usePathname();

  useEffect(() => {
    // The SW only runs in production; caches is only present in secure contexts.
    if (process.env.NODE_ENV !== 'production') return;
    if (typeof caches === 'undefined' || !navigator.onLine) return;

    const url = window.location.href;
    (async () => {
      try {
        const cache = await caches.open(PWA_CACHE);
        if (!(await cache.match(url))) await cache.add(url);
      } catch {
        /* best-effort — a redirect/non-200 just means no warm for this route */
      }
    })();
  }, [pathname]);

  return null;
}
