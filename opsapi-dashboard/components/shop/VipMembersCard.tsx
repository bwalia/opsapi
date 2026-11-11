'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Crown } from 'lucide-react';
import { Card } from '@/components/ui';
import { VipBadge } from '@/components/shop/VipBadge';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopMembershipService } from '@/services/shop-membership.service';
import { formatDateTime } from '@/lib/utils';
import type { ShopMember } from '@/types/shop';

const NEW_DAYS = 14;

/**
 * Newest VIP members, with anyone who joined in the last two weeks called out in gold so a new
 * sign-up can't go unnoticed. Hidden for people without shop access and when there are no members.
 */
export function VipMembersCard({ limit = 5, hideWhenEmpty = false }: { limit?: number; hideWhenEmpty?: boolean }) {
  const { hasPermission } = usePermissions();
  const allowed = hasPermission('shop', 'read');
  const [rows, setRows] = useState<ShopMember[] | null>(null);
  const [now] = useState(() => Date.now());

  useEffect(() => {
    if (!allowed) return;
    let active = true;
    shopMembershipService
      .members()
      .then((r) => active && setRows(r.filter((m) => m.status === 'active' || m.status === 'past_due')))
      .catch(() => active && setRows([]));
    return () => {
      active = false;
    };
  }, [allowed]);

  if (!allowed || (hideWhenEmpty && (!rows || rows.length === 0))) return null;
  const since = now - NEW_DAYS * 86_400_000;
  const fresh = (rows ?? []).filter((m) => m.joined_at && new Date(m.joined_at).getTime() >= since);

  return (
    <Card className={fresh.length ? 'border-amber-300 ring-1 ring-amber-200 dark:border-amber-500/50 dark:ring-amber-500/20' : undefined}>
      <div className="mb-3 flex items-center justify-between gap-3">
        <h3 className="flex items-center gap-2 text-base font-semibold text-secondary-900">
          <Crown className="h-5 w-5 text-amber-500" aria-hidden="true" />
          VIP members
          {rows && <span className="text-sm font-normal text-secondary-500">({rows.length})</span>}
        </h3>
        <Link href="/dashboard/shop/members" className="text-sm text-primary-600 hover:underline">All members</Link>
      </div>
      {fresh.length > 0 && (
        <p className="mb-3 rounded-lg bg-amber-50 px-3 py-2 text-sm font-medium text-amber-800 dark:bg-amber-500/10 dark:text-amber-300">
          {fresh.length === 1 ? '1 new VIP' : `${fresh.length} new VIPs`} in the last {NEW_DAYS} days. Give them a call.
        </p>
      )}
      {rows === null ? (
        <p className="text-sm text-secondary-500">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-secondary-500">No VIP members yet.</p>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {rows.slice(0, limit).map((m) => {
            const isNew = !!m.joined_at && new Date(m.joined_at).getTime() >= since;
            const inner = (
              <>
                <div className="min-w-0">
                  <p className="flex items-center gap-2 truncate text-sm font-medium text-secondary-900">
                    {m.name || m.email}
                    {isNew && <span className="rounded bg-amber-500 px-1.5 py-0.5 text-[10px] font-bold uppercase text-white">New</span>}
                  </p>
                  <p className="truncate text-xs text-secondary-500">{[m.company, m.phone].filter(Boolean).join(' · ') || m.email}</p>
                </div>
                <div className="shrink-0 text-right">
                  <VipBadge vip={{ email: m.email, uuid: m.uuid, tier: m.tier, billing_interval: m.billing_interval, status: m.status as 'active' | 'past_due', joined_at: m.joined_at, current_period_end: m.current_period_end, cancel_at_period_end: m.cancel_at_period_end }} />
                  <p className="mt-1 text-xs text-secondary-500">{m.joined_at ? formatDateTime(m.joined_at) : ''}</p>
                </div>
              </>
            );
            return (
              <li key={m.uuid}>
                {m.lead_uuid ? (
                  <Link href={`/dashboard/leads/${m.lead_uuid}`} className="-mx-2 flex items-center justify-between gap-3 rounded-lg px-2 py-2 hover:bg-secondary-50">{inner}</Link>
                ) : (
                  <div className="flex items-center justify-between gap-3 py-2">{inner}</div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}

export default VipMembersCard;
