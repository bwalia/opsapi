// Replays queued offline mutations when connectivity returns.
//
// Strategy (last-write-wins): re-issue each pending request in the order it was
// made. On success, drop it. If the server *rejects* it (a real HTTP response —
// validation / conflict / permission), we keep it as a FAILED item (not silently
// dropped) so the user can review it and retry or discard (see SyncIssuesPanel).
// If it fails with no response (still offline), we stop and retry on the next
// reconnect.
import toast from 'react-hot-toast';
import type { AxiosError } from 'axios';
import { apiClient } from '../api-client';
import {
  pendingItems,
  failedItems,
  deleteOutbox,
  markOutboxFailed,
  retryOutbox,
  pendingCount,
  failedCount,
} from './db';
import { useOfflineStore } from '@/store/offline.store';

let running = false;

/** Refresh the pending + failed counts shown in the UI. */
export async function refreshCounts(): Promise<void> {
  const store = useOfflineStore.getState();
  store.setPending(await pendingCount());
  store.setFailed(await failedCount());
}

// Back-compat alias (OfflineProvider imported this name).
export const refreshPending = refreshCounts;

function errorMessageOf(err: AxiosError): string {
  const data = err.response?.data as { message?: string; error?: string } | undefined;
  return (
    data?.message ||
    data?.error ||
    (err.response ? `Server error (${err.response.status})` : 'Request failed')
  );
}

export async function replayOutbox(): Promise<void> {
  if (running) return;
  if (typeof navigator !== 'undefined' && !navigator.onLine) return;

  const items = await pendingItems();
  if (items.length === 0) {
    await refreshCounts();
    return;
  }

  running = true;
  const store = useOfflineStore.getState();
  store.setSyncing(true);

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
        // Server rejected the write — keep it as FAILED for the user to act on.
        if (item.id != null) await markOutboxFailed(item.id, errorMessageOf(axErr));
        rejected += 1;
      } else {
        // Still offline / unreachable — stop and try again on next reconnect.
        break;
      }
    }
  }

  await refreshCounts();
  store.setSyncing(false);
  store.markSynced();
  running = false;

  if (synced > 0) toast.success(`Synced ${synced} offline change${synced === 1 ? '' : 's'}`);
  if (rejected > 0) {
    toast.error(
      `${rejected} offline change${rejected === 1 ? '' : 's'} couldn't be saved — review under the sync status.`
    );
  }
}

/** Requeue every failed item and replay. */
export async function retryAllFailed(): Promise<void> {
  const items = await failedItems();
  for (const item of items) if (item.id != null) await retryOutbox(item.id);
  await refreshCounts();
  await replayOutbox();
}

/** Requeue one failed item and replay. */
export async function retryFailed(id: number): Promise<void> {
  await retryOutbox(id);
  await refreshCounts();
  await replayOutbox();
}

/** Permanently drop one failed item. */
export async function discardFailed(id: number): Promise<void> {
  await deleteOutbox(id);
  await refreshCounts();
}

/** Permanently drop all failed items. */
export async function discardAllFailed(): Promise<void> {
  const items = await failedItems();
  for (const item of items) if (item.id != null) await deleteOutbox(item.id);
  await refreshCounts();
}
