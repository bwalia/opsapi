// Offline-first data layer (IndexedDB via idb). Two stores:
//   - responses: cached GET payloads, so previously-loaded data is readable
//     offline.
//   - outbox: mutations made while offline, replayed on reconnect (see sync.ts).
//
// SECURITY: everything is scoped by `${userId}:${namespaceId}` (see scope.ts).
// A read only ever returns data cached under the *current* scope, so one tenant
// (or user) can never see another's cached data. clearAll() wipes both stores on
// logout.
//
// This module imports nothing from api-client, to avoid an import cycle
// (api-client imports this).
import { openDB, type DBSchema, type IDBPDatabase } from 'idb';
import { currentScope } from './scope';

export interface CachedResponse {
  key: string; // `${scope}|GET|${uri}`
  scope: string;
  data: unknown;
  cachedAt: number;
}

export interface OutboxItem {
  id?: number;
  scope: string;
  method: string; // post | put | patch | delete
  url: string;
  params?: unknown;
  data?: unknown; // already-serialised request body (string or object)
  headers?: Record<string, string>;
  createdAt: number;
  // 'pending' (default) items are replayed on reconnect; 'failed' items were
  // rejected by the server and wait for the user to retry or discard them.
  status?: 'pending' | 'failed';
  error?: string;
  attempts?: number;
}

interface OfflineDB extends DBSchema {
  responses: { key: string; value: CachedResponse };
  outbox: { key: number; value: OutboxItem; indexes: { 'by-scope': string } };
}

let dbPromise: Promise<IDBPDatabase<OfflineDB>> | null = null;

function db(): Promise<IDBPDatabase<OfflineDB>> | null {
  if (typeof indexedDB === 'undefined') return null;
  if (!dbPromise) {
    dbPromise = openDB<OfflineDB>('opsapi-offline', 1, {
      upgrade(database) {
        database.createObjectStore('responses', { keyPath: 'key' });
        const outbox = database.createObjectStore('outbox', { keyPath: 'id', autoIncrement: true });
        outbox.createIndex('by-scope', 'scope');
      },
    });
  }
  return dbPromise;
}

const respKey = (scope: string, uri: string) => `${scope}|GET|${uri}`;

/** Cache a GET response body under the current scope. No-op if no scope/DB. */
export async function cacheGet(uri: string, data: unknown): Promise<void> {
  const scope = currentScope();
  const d = db();
  if (!scope || !d) return;
  try {
    await (await d).put('responses', { key: respKey(scope, uri), scope, data, cachedAt: Date.now() });
  } catch {
    /* quota / private mode — caching is best-effort */
  }
}

/** Read a cached GET body for the current scope, or undefined. */
export async function readGet(uri: string): Promise<CachedResponse | undefined> {
  const scope = currentScope();
  const d = db();
  if (!scope || !d) return undefined;
  try {
    return await (await d).get('responses', respKey(scope, uri));
  } catch {
    return undefined;
  }
}

/** Queue a mutation for replay on reconnect. Returns false if it couldn't be stored. */
export async function enqueue(item: Omit<OutboxItem, 'id' | 'scope' | 'createdAt'>): Promise<boolean> {
  const scope = currentScope();
  const d = db();
  if (!scope || !d) return false;
  try {
    await (await d).add('outbox', { ...item, scope, createdAt: Date.now() });
    return true;
  } catch {
    return false;
  }
}

/** All queued mutations for the current scope, oldest first. */
export async function queuedItems(): Promise<OutboxItem[]> {
  const scope = currentScope();
  const d = db();
  if (!scope || !d) return [];
  try {
    const items = await (await d).getAllFromIndex('outbox', 'by-scope', scope);
    return items.sort((a, b) => a.createdAt - b.createdAt);
  } catch {
    return [];
  }
}

/** Items still awaiting sync (not server-rejected). */
export async function pendingItems(): Promise<OutboxItem[]> {
  return (await queuedItems()).filter((i) => i.status !== 'failed');
}

/** Items the server rejected — waiting for the user to retry or discard. */
export async function failedItems(): Promise<OutboxItem[]> {
  return (await queuedItems()).filter((i) => i.status === 'failed');
}

export async function pendingCount(): Promise<number> {
  return (await pendingItems()).length;
}

export async function failedCount(): Promise<number> {
  return (await failedItems()).length;
}

/** Mark a queued write as server-rejected (kept for the user to act on). */
export async function markOutboxFailed(id: number, error: string): Promise<void> {
  const d = db();
  if (!d) return;
  try {
    const database = await d;
    const item = await database.get('outbox', id);
    if (!item) return;
    item.status = 'failed';
    item.error = error;
    item.attempts = (item.attempts ?? 0) + 1;
    await database.put('outbox', item);
  } catch {
    /* ignore */
  }
}

/** Put a failed item back in the pending queue so it replays again. */
export async function retryOutbox(id: number): Promise<void> {
  const d = db();
  if (!d) return;
  try {
    const database = await d;
    const item = await database.get('outbox', id);
    if (!item) return;
    item.status = 'pending';
    item.error = undefined;
    await database.put('outbox', item);
  } catch {
    /* ignore */
  }
}

export async function deleteOutbox(id: number): Promise<void> {
  const d = db();
  if (!d) return;
  try {
    await (await d).delete('outbox', id);
  } catch {
    /* ignore */
  }
}

// ---- Optimistic cache reconciliation (Phase 2) ---------------------------
// When a write happens offline, patch already-cached list/detail GETs so the
// change is visible even after navigating away and back (re-reading from cache),
// not just in the view that made it. Best-effort and generic across modules:
// a create prepends, an update merges by id, a delete removes. The real records
// replace these on the next successful online refetch.

function pathnameOf(uri: string): string {
  try {
    return new URL(uri).pathname;
  } catch {
    try {
      return new URL(uri, 'http://_').pathname;
    } catch {
      return uri.split('?')[0];
    }
  }
}

function matchesId(item: unknown, id?: string): boolean {
  if (id == null) return false;
  const it = item as { uuid?: unknown; id?: unknown };
  return String(it?.uuid ?? it?.id ?? '') === String(id);
}

export interface Reconcile {
  op: 'create' | 'update' | 'delete';
  collectionPath: string; // e.g. /api/v2/employees
  id?: string; // for update/delete
  entity?: Record<string, unknown>;
}

export async function reconcileCache(r: Reconcile): Promise<void> {
  const scope = currentScope();
  const d = db();
  if (!scope || !d) return;
  try {
    const database = await d;
    const all = (await database.getAll('responses')).filter((x) => x.scope === scope);
    for (const rec of all) {
      const uri = rec.key.split('|GET|')[1] || '';
      const path = pathnameOf(uri);
      const body = rec.data as { data?: unknown } | unknown[];
      const list = Array.isArray(body)
        ? body
        : Array.isArray((body as { data?: unknown })?.data)
          ? ((body as { data?: unknown }).data as unknown[])
          : null;

      // Collection list at exactly this path.
      if (path === r.collectionPath && list) {
        let next = list;
        if (r.op === 'create' && r.entity) next = [r.entity, ...list];
        else if (r.op === 'update' && r.entity)
          next = list.map((it) => (matchesId(it, r.id) ? { ...(it as object), ...r.entity } : it));
        else if (r.op === 'delete') next = list.filter((it) => !matchesId(it, r.id));

        rec.data = Array.isArray(body) ? next : { ...(body as object), data: next };
        await database.put('responses', rec);
        continue;
      }

      // Detail GET at /collection/{id}.
      if (r.id && path === `${r.collectionPath}/${r.id}`) {
        if (r.op === 'delete') {
          await database.delete('responses', rec.key);
        } else if (r.op === 'update' && r.entity) {
          const wrapped = (body as { data?: unknown })?.data !== undefined;
          const current = (wrapped ? (body as { data?: unknown }).data : body) as object;
          const merged = { ...current, ...r.entity };
          rec.data = wrapped ? { ...(body as object), data: merged } : merged;
          await database.put('responses', rec);
        }
      }
    }
  } catch {
    /* best-effort */
  }
}

/** Wipe all offline data (call on logout). */
export async function clearAll(): Promise<void> {
  const d = db();
  if (!d) return;
  try {
    const database = await d;
    await Promise.all([database.clear('responses'), database.clear('outbox')]);
  } catch {
    /* ignore */
  }
}
