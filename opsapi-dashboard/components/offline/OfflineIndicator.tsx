'use client';

// Slim status pill shown only when it matters: offline, syncing/pending queued
// writes, or writes that failed to sync (click to review). Top-centre, out of
// the way otherwise.
import { useState } from 'react';
import { useOfflineStore } from '@/store/offline.store';
import { CloudOff, RefreshCw, AlertTriangle } from 'lucide-react';
import SyncIssuesPanel from './SyncIssuesPanel';

export default function OfflineIndicator() {
  const online = useOfflineStore((s) => s.online);
  const pending = useOfflineStore((s) => s.pending);
  const syncing = useOfflineStore((s) => s.syncing);
  const failed = useOfflineStore((s) => s.failed);
  const [panelOpen, setPanelOpen] = useState(false);

  const nothing = online && pending === 0 && !syncing && failed === 0;

  return (
    <>
      {!nothing && (
        <div
          role="status"
          aria-live="polite"
          className="fixed inset-x-0 top-2 z-[1000] flex justify-center px-4 pointer-events-none"
        >
          {failed > 0 ? (
            // Actionable: rejected writes waiting for the user to retry/discard.
            <button
              type="button"
              onClick={() => setPanelOpen(true)}
              className="pointer-events-auto flex items-center gap-2 rounded-full bg-red-600 px-4 py-1.5 text-xs font-medium text-white shadow-md ring-1 ring-black/10 transition hover:bg-red-700"
            >
              <AlertTriangle className="h-3.5 w-3.5" aria-hidden="true" />
              <span>
                {failed} change{failed === 1 ? '' : 's'} failed to sync — review
              </span>
            </button>
          ) : (
            <div
              className={`pointer-events-auto flex items-center gap-2 rounded-full px-4 py-1.5 text-xs font-medium shadow-md ring-1 ${
                !online
                  ? 'bg-amber-50 text-amber-900 ring-amber-200'
                  : 'bg-secondary-900 text-white ring-black/10'
              }`}
            >
              {!online ? (
                <CloudOff className="h-3.5 w-3.5" aria-hidden="true" />
              ) : (
                <RefreshCw
                  className={`h-3.5 w-3.5 ${syncing ? 'animate-spin' : ''}`}
                  aria-hidden="true"
                />
              )}
              <span>
                {!online
                  ? pending > 0
                    ? `Offline — ${pending} change${pending === 1 ? '' : 's'} will sync when you reconnect`
                    : 'Offline — showing saved data'
                  : syncing
                    ? `Syncing ${pending} change${pending === 1 ? '' : 's'}…`
                    : `${pending} change${pending === 1 ? '' : 's'} pending sync`}
              </span>
            </div>
          )}
        </div>
      )}

      <SyncIssuesPanel isOpen={panelOpen} onClose={() => setPanelOpen(false)} />
    </>
  );
}
