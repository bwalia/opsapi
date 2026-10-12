'use client';

/**
 * Property Deals hooks: who I am here (GET /property-deals/me: permissions per module,
 * workspace settings) and simple data loading with refresh + polling.
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { pdService, pdError, type Me, type PdError } from '@/services/property-deals.service';
import { useNamespaceStore } from '@/store/namespace.store';
import { useAuthStore } from '@/store/auth.store';

export type PdModule =
  | 'deals' | 'properties' | 'buyers' | 'tasks' | 'suppliers' | 'compliance' | 'approvals' | 'ai' | 'settings' | 'reports';
export type PdAction = 'read' | 'create' | 'update' | 'delete' | 'manage';

// Keyed by user + workspace: another account signing in on this tab must not see the last one's permissions.
const meCache: Record<string, { me?: Me; error?: PdError; at: number }> = {};

function currentKey(): string {
  return `${useAuthStore.getState().user?.uuid || 'anon'}:${useNamespaceStore.getState().currentNamespace?.uuid || 'default'}`;
}

/** /me for the current user in the current workspace, cached for a minute. */
export function usePdMe() {
  const nsKey = useNamespaceStore((s) => s.currentNamespace?.uuid || 'default');
  const userKey = useAuthStore((s) => s.user?.uuid || 'anon');
  const cached = meCache[`${userKey}:${nsKey}`];
  const [state, setState] = useState<{ me?: Me; error?: PdError; loading: boolean }>(
    cached ? { me: cached.me, error: cached.error, loading: false } : { loading: true },
  );

  const load = useCallback(async (force = false) => {
    const key = currentKey();
    const c = meCache[key];
    if (!force && c && Date.now() - c.at < 60_000) {
      setState({ me: c.me, error: c.error, loading: false });
      return;
    }
    setState((s) => ({ ...s, loading: true }));
    try {
      const res = await pdService.me();
      meCache[key] = { me: res.data, at: Date.now() };
      setState({ me: res.data, loading: false });
    } catch (e) {
      const err = pdError(e);
      meCache[key] = { error: err, at: Date.now() };
      setState({ error: err, loading: false });
    }
  }, []);

  useEffect(() => {
    const t = setTimeout(() => load(), 0);
    return () => clearTimeout(t);
  }, [load, nsKey, userKey]);

  const can = useCallback(
    (module: PdModule, action: PdAction = 'read') => {
      const perms = (state.me?.permissions || {}) as Record<string, string[] | undefined>;
      const list = perms[module] || perms[`property_deals_${module}`] || [];
      return list.includes('manage') || list.includes(action);
    },
    [state.me],
  );

  return { ...state, can, reload: () => load(true) };
}

/** `value`, once it has stopped changing for `ms` (search boxes, sliders: one request, not one per keystroke). */
export function useDebounced<T>(value: T, ms = 300): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

/**
 * Load something, with a refresh() and optional polling (ms). Keeps old data while refreshing.
 * Only the latest request wins: a slow response for old inputs never overwrites a newer one.
 */
export function usePdData<T>(loader: () => Promise<T>, deps: unknown[] = [], pollMs?: number) {
  const [data, setData] = useState<T | undefined>(undefined);
  const [error, setError] = useState<PdError | undefined>(undefined);
  const [loading, setLoading] = useState(true);
  const loaderRef = useRef(loader);
  loaderRef.current = loader;
  const seq = useRef(0);

  const refresh = useCallback(async () => {
    const id = ++seq.current;
    try {
      const v = await loaderRef.current();
      if (id !== seq.current) return;
      setData(v);
      setError(undefined);
    } catch (e) {
      if (id === seq.current) setError(pdError(e));
    } finally {
      if (id === seq.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    setLoading(true);
    refresh();
    const t = pollMs
      ? setInterval(() => {
          if (typeof document === 'undefined' || document.visibilityState === 'visible') refresh();
        }, pollMs)
      : undefined;
    return () => {
      if (t) clearInterval(t);
      seq.current += 1; // inputs changed or unmounted: drop what's still in flight
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return { data, error, loading, refresh, setData };
}
