'use client';

// Slim status pill shown only when it matters: offline, or syncing/pending
// queued writes. Sits top-centre, out of the way otherwise.
import { useOfflineStore } from '@/store/offline.store';
import { CloudOff, RefreshCw } from 'lucide-react';

export default function OfflineIndicator() {
  const online = useOfflineStore((s) => s.online);
  const pending = useOfflineStore((s) => s.pending);
  const syncing = useOfflineStore((s) => s.syncing);

  if (online && pending === 0 && !syncing) return null;

  const offline = !online;
  const label = offline
    ? pending > 0
      ? `Offline — ${pending} change${pending === 1 ? '' : 's'} will sync when you reconnect`
      : 'Offline — showing saved data'
    : syncing
      ? `Syncing ${pending || ''} change${pending === 1 ? '' : 's'}…`.replace('  ', ' ')
      : `${pending} change${pending === 1 ? '' : 's'} pending sync`;

  return (
    <div
      role="status"
      aria-live="polite"
      className="fixed inset-x-0 top-2 z-[1000] flex justify-center px-4 pointer-events-none"
    >
      <div
        className={`pointer-events-auto flex items-center gap-2 rounded-full px-4 py-1.5 text-xs font-medium shadow-md ring-1 ${
          offline
            ? 'bg-amber-50 text-amber-900 ring-amber-200'
            : 'bg-secondary-900 text-white ring-black/10'
        }`}
      >
        {offline ? (
          <CloudOff className="h-3.5 w-3.5" aria-hidden="true" />
        ) : (
          <RefreshCw className={`h-3.5 w-3.5 ${syncing ? 'animate-spin' : ''}`} aria-hidden="true" />
        )}
        <span>{label}</span>
      </div>
    </div>
  );
}
