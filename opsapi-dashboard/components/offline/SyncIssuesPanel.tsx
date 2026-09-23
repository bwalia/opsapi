'use client';

// Lists offline writes the server rejected on sync, and lets the user retry or
// discard each one (or all). Opened from the OfflineIndicator when failed > 0.
import { useCallback, useEffect, useState } from 'react';
import { RefreshCw, Trash2, AlertTriangle } from 'lucide-react';
import { Modal, Button } from '@/components/ui';
import { failedItems, type OutboxItem } from '@/lib/offline/db';
import { retryFailed, retryAllFailed, discardFailed, discardAllFailed } from '@/lib/offline/sync';

const VERB: Record<string, string> = { post: 'Create', put: 'Update', patch: 'Update', delete: 'Delete' };

function describe(item: OutboxItem): string {
  const path = (item.url || '').split('?')[0];
  const resource = path.replace(/^\/?api\/v\d+\//, '').split('/')[0] || 'record';
  return `${VERB[item.method] || item.method} · ${resource.replace(/-/g, ' ')}`;
}

export default function SyncIssuesPanel({ isOpen, onClose }: { isOpen: boolean; onClose: () => void }) {
  const [items, setItems] = useState<OutboxItem[]>([]);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const list = await failedItems();
    setItems(list);
    if (list.length === 0) onClose();
  }, [onClose]);

  useEffect(() => {
    if (isOpen) void load();
  }, [isOpen, load]);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    try {
      await fn();
    } finally {
      setBusy(false);
      await load();
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Sync issues" size="lg">
      <div className="space-y-4">
        <p className="text-sm text-secondary-600">
          These changes were made offline but the server rejected them when reconnecting.
          Retry them, or discard the ones you no longer want.
        </p>

        <ul className="space-y-2 max-h-80 overflow-y-auto">
          {items.map((item) => (
            <li
              key={item.id}
              className="flex items-start gap-3 rounded-lg border border-secondary-200 p-3"
            >
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" aria-hidden="true" />
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium text-secondary-900">{describe(item)}</p>
                <p className="mt-0.5 truncate text-xs text-secondary-500" title={item.error}>
                  {item.error || 'Rejected by the server'}
                </p>
              </div>
              <div className="flex shrink-0 items-center gap-1">
                <button
                  type="button"
                  onClick={() => item.id != null && run(() => retryFailed(item.id!))}
                  disabled={busy}
                  className="inline-flex min-h-8 items-center gap-1 rounded-md px-2 text-xs font-medium text-primary-700 hover:bg-primary-50 disabled:opacity-50"
                >
                  <RefreshCw className="h-3.5 w-3.5" aria-hidden="true" />
                  Retry
                </button>
                <button
                  type="button"
                  onClick={() => item.id != null && run(() => discardFailed(item.id!))}
                  disabled={busy}
                  aria-label="Discard change"
                  className="inline-flex min-h-8 items-center rounded-md px-2 text-xs font-medium text-red-600 hover:bg-red-50 disabled:opacity-50"
                >
                  <Trash2 className="h-3.5 w-3.5" aria-hidden="true" />
                </button>
              </div>
            </li>
          ))}
        </ul>

        <div className="flex justify-end gap-2 border-t border-secondary-100 pt-3">
          <Button variant="ghost" onClick={() => run(discardAllFailed)} disabled={busy}>
            Discard all
          </Button>
          <Button onClick={() => run(retryAllFailed)} isLoading={busy}>
            Retry all
          </Button>
        </div>
      </div>
    </Modal>
  );
}
