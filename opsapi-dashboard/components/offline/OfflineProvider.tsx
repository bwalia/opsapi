'use client';

// Wires connectivity + background sync into the app:
//  - tracks online/offline in the offline store,
//  - replays queued writes when the connection returns (and once on load),
//  - refreshes the pending count when a write is queued.
// Renders nothing.
import { useEffect } from 'react';
import { useOfflineStore } from '@/store/offline.store';
import { replayOutbox, refreshPending } from '@/lib/offline/sync';

export default function OfflineProvider() {
  const setOnline = useOfflineStore((s) => s.setOnline);

  useEffect(() => {
    setOnline(navigator.onLine);
    void refreshPending();
    if (navigator.onLine) void replayOutbox();

    const onOnline = () => {
      setOnline(true);
      void replayOutbox();
    };
    const onOffline = () => setOnline(false);
    const onOutboxChanged = () => void refreshPending();

    window.addEventListener('online', onOnline);
    window.addEventListener('offline', onOffline);
    window.addEventListener('offline:outbox-changed', onOutboxChanged);
    return () => {
      window.removeEventListener('online', onOnline);
      window.removeEventListener('offline', onOffline);
      window.removeEventListener('offline:outbox-changed', onOutboxChanged);
    };
  }, [setOnline]);

  return null;
}
