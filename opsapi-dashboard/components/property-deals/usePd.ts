'use client';

/**
 * Property Deals hooks: who I am here (GET /property-deals/me: permissions per module,
 * workspace settings) and simple data loading with refresh + polling.
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { pdService, pdError, type Me, type PdError } from '@/services/property-deals.service';
import { useNamespaceStore } from '@/store/namespace.store';

export type PdModule =
  | 'deals' | 'properties' | 'buyers' | 'tasks' | 'suppliers' | 'compliance' | 'approvals' | 'ai' | 'settings' | 'reports';
export type PdAction = 'read' | 'create' | 'update' | 'delete' | 'manage';

const meCache: Record<string, { me?: Me; error?: PdError; at: number }> = {};

function currentNamespaceKey(): string {
  return useNamespaceStore.getState().currentNamespace?.uuid || 'default';
}

/** /me for the current workspace, cached for a minute. */
export function usePdMe() {
  const nsKey = useNamespaceStore((s) => s.currentNamespace?.uuid || 'default');
  const cached = meCache[nsKey];
  const [state, setState] = useState<{ me?: Me; error?: PdError; loading: boolean }>(
    cached ? { me: cached.me, error: cached.error, loading: false } : { loading: true },
  );

  const load = useCallback(async (force = false) => {
    const key = currentNamespaceKey();
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
  }, [load, nsKey]);

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

/** Load something, with a refresh() and optional polling (ms). Keeps old data while refreshing. */
export function usePdData<T>(loader: () => Promise<T>, deps: unknown[] = [], pollMs?: number) {
  const [data, setData] = useState<T | undefined>(undefined);
  const [error, setError] = useState<PdError | undefined>(undefined);
  const [loading, setLoading] = useState(true);
  const loaderRef = useRef(loader);
  loaderRef.current = loader;

  const refresh = useCallback(async () => {
    try {
      const v = await loaderRef.current();
      setData(v);
      setError(undefined);
    } catch (e) {
      setError(pdError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    setLoading(true);
    refresh();
    if (!pollMs) return;
    const t = setInterval(() => {
      if (typeof document === 'undefined' || document.visibilityState === 'visible') refresh();
    }, pollMs);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return { data, error, loading, refresh, setData };
}
