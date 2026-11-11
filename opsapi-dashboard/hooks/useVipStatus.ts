'use client';

import { useEffect, useMemo, useState } from 'react';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopMembershipService } from '@/services/shop-membership.service';
import type { ShopVipStatus } from '@/types/shop';

// Shared across pages for a minute, so moving between lists doesn't re-ask for the same emails.
const TTL_MS = 60_000;
const cache = new Map<string, { at: number; vip: ShopVipStatus | null }>();

const norm = (e: string | null | undefined) => (e ?? '').trim().toLowerCase();

/**
 * VIP status for the customer emails on screen. Returns a map of lower-cased email → status
 * (missing = not a VIP). Quietly returns nothing for people without shop access or on any error:
 * a badge must never break the page it decorates.
 */
export function useVipStatus(emails: (string | null | undefined)[]): Record<string, ShopVipStatus> {
  const { hasPermission } = usePermissions();
  const allowed = hasPermission('shop', 'read');
  const key = useMemo(
    () => Array.from(new Set(emails.map(norm).filter((e) => e.includes('@')))).sort().join('\n'),
    [emails]
  );
  // Bumped when a lookup lands; the result is always read from the shared cache.
  const [tick, setTick] = useState(0);

  useEffect(() => {
    if (!allowed || !key) return;
    const now = Date.now();
    const missing = key.split('\n').filter((e) => {
      const hit = cache.get(e);
      return !hit || now - hit.at >= TTL_MS;
    });
    if (missing.length === 0) return;
    let active = true;
    shopMembershipService
      .lookup(missing.slice(0, 200))
      .then((res) => {
        const at = Date.now();
        for (const e of missing) cache.set(e, { at, vip: res[e] ?? null });
        if (active) setTick((t) => t + 1);
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [allowed, key]);

  return useMemo(() => {
    const out: Record<string, ShopVipStatus> = {};
    if (!allowed || !key) return out;
    for (const e of key.split('\n')) {
      const vip = cache.get(e)?.vip;
      if (vip) out[e] = vip;
    }
    return out;
    // tick: re-read the cache after a lookup lands.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [allowed, key, tick]);
}

/** VIP status for a single email. */
export function useVipFor(email: string | null | undefined): ShopVipStatus | null {
  const map = useVipStatus(useMemo(() => [email], [email]));
  return map[norm(email)] ?? null;
}

export default useVipStatus;
