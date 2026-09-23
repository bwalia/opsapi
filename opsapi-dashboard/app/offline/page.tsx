'use client';

// Shown by the service worker when a navigation is attempted with no network
// and the page isn't already cached. Must stay self-contained — no data fetches,
// no app providers — so it renders with zero connectivity.
import { WifiOff, RotateCw } from 'lucide-react';

export default function OfflinePage() {
  return (
    <main className="min-h-dvh flex items-center justify-center bg-white px-4 text-center">
      <div className="max-w-sm">
        <div className="mx-auto mb-6 flex h-16 w-16 items-center justify-center rounded-2xl bg-secondary-100">
          <WifiOff className="h-8 w-8 text-secondary-500" aria-hidden="true" />
        </div>
        <h1 className="text-xl font-semibold text-secondary-900">You&rsquo;re offline</h1>
        <p className="mt-2 text-sm text-secondary-600">
          This page needs a connection and hasn&rsquo;t been saved for offline use.
          Reconnect and try again — pages you&rsquo;ve already opened still work offline.
        </p>
        <button
          type="button"
          onClick={() => window.location.reload()}
          className="mt-6 inline-flex min-h-11 items-center gap-2 rounded-xl bg-secondary-900 px-5 text-sm font-medium text-white transition hover:bg-secondary-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-secondary-400"
        >
          <RotateCw className="h-4 w-4" aria-hidden="true" />
          Try again
        </button>
      </div>
    </main>
  );
}
