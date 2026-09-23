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

export async function pendingCount(): Promise<number> {
  return (await queuedItems()).length;
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
