import axios, { AxiosError, type AxiosInstance, type InternalAxiosRequestConfig } from 'axios';
import { hmrcFraudHeaders } from './hmrc-fraud';
import {
  cacheGet,
  readGet,
  enqueue,
  clearAll as clearOfflineData,
  reconcileCache,
  type Reconcile,
} from './offline/db';
import { useOfflineStore } from '@/store/offline.store';

/** Drive the online/offline state from real backend reachability (reliable,
 *  unlike navigator.onLine): a successful request => online, a network failure
 *  => offline. Self-heals a stuck banner as soon as any request succeeds. */
function markReachable(reachable: boolean): void {
  if (typeof window === 'undefined') return;
  const store = useOfflineStore.getState();
  if (store.online !== reachable) store.setOnline(reachable);
}

// Custom axios config flag: marks a request as an outbox replay so the offline
// interceptor doesn't re-queue it (see lib/offline/sync.ts).
declare module 'axios' {
  interface AxiosRequestConfig {
    _replay?: boolean;
  }
}

const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';

/**
 * Create axios instance with default configuration
 */
export const apiClient: AxiosInstance = axios.create({
  baseURL: API_BASE_URL,
  timeout: 30000,
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
    Accept: 'application/json',
  },
});

// Storage keys
export const NAMESPACE_KEY = 'current_namespace';
export const AUTH_TOKEN_KEY = 'auth_token';
export const AUTH_USER_KEY = 'auth_user';
export const ZUSTAND_AUTH_KEY = 'auth-storage';
export const ZUSTAND_MENU_KEY = 'menu-storage';
export const ZUSTAND_NAMESPACE_KEY = 'namespace-storage';

// Track if we're currently redirecting to prevent loops
let isRedirecting = false;

/**
 * Get auth token from multiple possible storage locations
 * Priority: 1. Direct localStorage key, 2. Zustand persisted storage
 */
function getAuthToken(): string | null {
  if (typeof window === 'undefined') return null;

  // First try direct key
  const directToken = localStorage.getItem(AUTH_TOKEN_KEY);
  if (directToken) return directToken;

  // Fallback to Zustand persisted state
  try {
    const zustandData = localStorage.getItem(ZUSTAND_AUTH_KEY);
    if (zustandData) {
      const parsed = JSON.parse(zustandData);
      if (parsed?.state?.token) {
        // Sync to direct key for consistency
        localStorage.setItem(AUTH_TOKEN_KEY, parsed.state.token);
        return parsed.state.token;
      }
    }
  } catch {
    // Ignore parse errors
  }

  return null;
}

/**
 * Best-effort read of the logged-in user's id (for HMRC Gov-Client-User-IDs).
 * Checks the direct auth_user key, then the Zustand persisted auth state.
 */
function getAuthUserId(): string | undefined {
  if (typeof window === 'undefined') return undefined;
  const pick = (u: unknown): string | undefined => {
    const user = u as { uuid?: string; id?: string | number; email?: string } | undefined;
    const v = user?.uuid ?? user?.id ?? user?.email;
    return v !== undefined && v !== null ? String(v) : undefined;
  };
  try {
    const direct = localStorage.getItem(AUTH_USER_KEY);
    if (direct) {
      const id = pick(JSON.parse(direct));
      if (id) return id;
    }
    const zustand = localStorage.getItem(ZUSTAND_AUTH_KEY);
    if (zustand) return pick(JSON.parse(zustand)?.state?.user);
  } catch {
    // Ignore parse errors
  }
  return undefined;
}

/**
 * Clear all auth-related storage including menu and namespace cache
 */
export function clearAllAuthStorage(): void {
  if (typeof window === 'undefined') return;

  localStorage.removeItem(AUTH_TOKEN_KEY);
  localStorage.removeItem(AUTH_USER_KEY);
  localStorage.removeItem(ZUSTAND_AUTH_KEY);
  localStorage.removeItem(NAMESPACE_KEY);
  localStorage.removeItem(ZUSTAND_MENU_KEY);
  localStorage.removeItem(ZUSTAND_NAMESPACE_KEY);

  // Drop all offline-cached data + queued writes so nothing leaks across logins.
  void clearOfflineData();
}

/** Full request URI (incl. baseURL + params) — the offline cache key. */
function uriOf(config: InternalAxiosRequestConfig): string {
  try {
    return apiClient.getUri(config);
  } catch {
    return config.url || '';
  }
}

/**
 * Build a plausible entity from a queued write's own payload so screens that
 * immediately use the "created" record (e.g. `saved.uuid`) keep working offline.
 * Carries a temp id + `_offlinePending: true`; the real record replaces it on
 * the next refetch after sync. (Per-module reconciliation is Phase 2.)
 */
function optimisticEntity(config: InternalAxiosRequestConfig, id?: string): Record<string, unknown> {
  // Updates keep their real id (from the URL); creates get a temp one.
  const idVal = id ?? `offline-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  let fields: Record<string, unknown> = {};
  try {
    const ct = String((config.headers as Record<string, unknown>)?.['Content-Type'] ?? '');
    if (typeof config.data === 'string') {
      if (ct.includes('application/json')) fields = JSON.parse(config.data);
      else if (ct.includes('x-www-form-urlencoded'))
        fields = Object.fromEntries(new URLSearchParams(config.data));
    } else if (config.data && typeof config.data === 'object') {
      fields = config.data as Record<string, unknown>;
    }
  } catch {
    /* unparseable body — return just the temp identity */
  }
  return { ...fields, uuid: idVal, id: idVal, _offlinePending: true };
}

/** Headers to persist with a queued write so its replay hits the right tenant. */
function outboxHeaders(config: InternalAxiosRequestConfig): Record<string, string> {
  const out: Record<string, string> = {};
  const h = config.headers as Record<string, unknown> | undefined;
  if (h) {
    if (h['X-Namespace-Id']) out['X-Namespace-Id'] = String(h['X-Namespace-Id']);
    const ct = h['Content-Type'] ?? h['content-type'];
    if (ct) out['Content-Type'] = String(ct);
  }
  return out;
}

/**
 * Request interceptor to add auth token and namespace header
 */
apiClient.interceptors.request.use(
  (config: InternalAxiosRequestConfig) => {
    if (typeof window !== 'undefined') {
      const token = getAuthToken();
      if (token && config.headers) {
        config.headers.Authorization = `Bearer ${token}`;
      }

      // Add namespace header from localStorage (user's current namespace context).
      // A caller may pre-set X-Namespace-Id to target a specific namespace
      // (e.g. an admin managing another tenant's API keys) — don't clobber it.
      const namespaceData = localStorage.getItem(NAMESPACE_KEY);
      if (namespaceData && config.headers && !config.headers['X-Namespace-Id']) {
        try {
          const namespace = JSON.parse(namespaceData);
          if (namespace?.uuid) {
            config.headers['X-Namespace-Id'] = namespace.uuid;
          }
        } catch {
          // Ignore parse errors
        }
      }

      // On HMRC-bound requests, forward the browser-collected anti-fraud signals so the
      // backend can build HMRC's mandatory Gov-Client-* fraud-prevention headers.
      if (config.headers && (config.url || '').includes('hmrc')) {
        const fraud = hmrcFraudHeaders(getAuthUserId());
        for (const [k, v] of Object.entries(fraud)) {
          config.headers[k] = v;
        }
      }
    }
    return config;
  },
  (error) => Promise.reject(error)
);

/**
 * Response interceptor for error handling
 */
apiClient.interceptors.response.use(
  (response) => {
    markReachable(true); // a real response means the backend is reachable
    // Cache successful GETs so the same view is readable offline later.
    if (typeof window !== 'undefined' && (response.config.method || '').toLowerCase() === 'get') {
      void cacheGet(uriOf(response.config), response.data);
    }
    return response;
  },
  async (error: AxiosError) => {
    const config = error.config as InternalAxiosRequestConfig | undefined;
    // A network error (no response) means unreachable — but a cancelled request
    // (component unmount, aborted) is not "offline", so exclude it.
    const isNetworkError = !error.response && error.code !== 'ERR_CANCELED';
    if (error.response) markReachable(true);

    // Offline / server unreachable: serve reads from the tenant-scoped cache, and
    // queue writes to replay on reconnect. Skipped for replay requests (let them
    // reject so sync.ts can decide). The 401 path below only runs when there IS a
    // response, so it's unaffected.
    if (typeof window !== 'undefined' && config && isNetworkError && !config._replay) {
      markReachable(false);
      const method = (config.method || 'get').toLowerCase();

      if (method === 'get') {
        const cached = await readGet(uriOf(config));
        if (cached) {
          return {
            data: cached.data,
            status: 200,
            statusText: 'OK (offline cache)',
            headers: { 'x-offline-cache': 'true' },
            config,
            request: error.request,
          };
        }
      } else if (method === 'post' || method === 'put' || method === 'patch' || method === 'delete') {
        const queued = await enqueue({
          method,
          url: config.url || '',
          params: config.params,
          data: config.data,
          headers: outboxHeaders(config),
        });
        if (queued) {
          window.dispatchEvent(new Event('offline:outbox-changed'));

          // Optimistically patch cached lists/detail so the change survives a
          // re-read from cache, and hand the caller a usable entity.
          const rawUrl = (config.url || '').split('?')[0].replace(/\/$/, '');
          let desc: Reconcile | null = null;
          let body: unknown;

          if (method === 'post') {
            const entity = optimisticEntity(config);
            desc = { op: 'create', collectionPath: rawUrl, entity };
            body = entity;
          } else {
            const idx = rawUrl.lastIndexOf('/');
            const collectionPath = idx > 0 ? rawUrl.slice(0, idx) : rawUrl;
            const id = idx > 0 ? rawUrl.slice(idx + 1) : undefined;
            if (method === 'delete') {
              desc = id ? { op: 'delete', collectionPath, id } : null;
              body = { success: true, _offlinePending: true };
            } else {
              const entity = optimisticEntity(config, id);
              desc = id ? { op: 'update', collectionPath, id, entity } : null;
              body = entity;
            }
          }
          if (desc) void reconcileCache(desc);

          return {
            data: body,
            status: 202,
            statusText: 'Queued (offline)',
            headers: { 'x-offline-queued': 'true' },
            config,
            request: error.request,
          };
        }
      }
    }

    if (error.response?.status === 401) {
      if (typeof window !== 'undefined') {
        // Clear ALL auth storage to prevent state mismatch
        clearAllAuthStorage();

        // Prevent redirect loop - only redirect if:
        // 1. Not already redirecting
        // 2. Not already on login page
        // 3. Not an auth-related endpoint (login, validate, etc.)
        const isAuthEndpoint = error.config?.url?.includes('/auth/');
        const isOnLoginPage = window.location.pathname.includes('/login');

        if (!isRedirecting && !isOnLoginPage && !isAuthEndpoint) {
          isRedirecting = true;
          // Use replace instead of href to prevent browser history issues
          window.location.replace('/login');
          // Reset flag after a delay (in case redirect fails)
          setTimeout(() => {
            isRedirecting = false;
          }, 3000);
        }
      }
    }
    return Promise.reject(error);
  }
);

/**
 * Convert object to URL-encoded form data (Lapis API requirement)
 */
export function toFormData(data: Record<string, unknown>): string {
  const params = new URLSearchParams();

  Object.entries(data).forEach(([key, value]) => {
    if (value !== undefined && value !== null) {
      if (Array.isArray(value)) {
        value.forEach((item) => params.append(key, String(item)));
      } else if (typeof value === 'object') {
        params.append(key, JSON.stringify(value));
      } else {
        params.append(key, String(value));
      }
    }
  });

  return params.toString();
}

/**
 * Build query string from params object
 */
export function buildQueryString(params: Record<string, unknown>): string {
  const searchParams = new URLSearchParams();

  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') {
      searchParams.append(key, String(value));
    }
  });

  const queryString = searchParams.toString();
  return queryString ? `?${queryString}` : '';
}

export default apiClient;
