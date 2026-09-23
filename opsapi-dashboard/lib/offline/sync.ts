// Replays queued offline mutations when connectivity returns.
//
// Strategy (Phase 1, last-write-wins): re-issue each queued request in the order
// it was made. On success, drop it. If the server *rejects* it (a real HTTP
// response — validation/conflict/permission), we drop it too and report it, so a
// permanently-bad write can't wedge the queue. If it fails with no response
// (still offline), we stop and retry on the next reconnect.
//
// NOTE: this does not yet do optimistic list insertion or field-level conflict
// merging — that's per-module Phase 2 work.
import toast from 'react-hot-toast';
import type { AxiosError } from 'axios';
import { apiClient } from '../api-client';
import { queuedItems, deleteOutbox, pendingCount } from './db';
import { useOfflineStore } from '@/store/offline.store';

let running = false;

export async function refreshPending(): Promise<void> {
  useOfflineStore.getState().setPending(await pendingCount());
}

export async function replayOutbox(): Promise<void> {
  if (running) return;
  if (typeof navigator !== 'undefined' && !navigator.onLine) return;

  const items = await queuedItems();
  if (items.length === 0) return;

  running = true;
  const store = useOfflineStore.getState();
  store.setSyncing(true);
  store.setPending(items.length);

  let synced = 0;
  let rejected = 0;

  for (const item of items) {
    try {
      await apiClient.request({
        method: item.method as 'post' | 'put' | 'patch' | 'delete',
        url: item.url,
        params: item.params,
        data: item.data,
        headers: item.headers,
        _replay: true, // don't let the offline interceptor re-queue this
      });
      if (item.id != null) await deleteOutbox(item.id);
      synced += 1;
    } catch (err) {
      const axErr = err as AxiosError;
      if (axErr.response) {
        // Server rejected the write — drop it so it can't block the queue.
        if (item.id != null) await deleteOutbox(item.id);
        rejected += 1;
      } else {
        // Still offline / unreachable — stop and try again on next reconnect.
        break;
      }
    }
  }

  await refreshPending();
  store.setSyncing(false);
  store.markSynced();
  running = false;

  if (synced > 0) toast.success(`Synced ${synced} offline change${synced === 1 ? '' : 's'}`);
  if (rejected > 0) {
    toast.error(
      `${rejected} offline change${rejected === 1 ? '' : 's'} couldn't be saved and ${
        rejected === 1 ? 'was' : 'were'
      } discarded.`
    );
  }
}
