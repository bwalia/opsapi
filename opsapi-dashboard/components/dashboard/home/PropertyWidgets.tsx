'use client';

/**
 * Numbers and panels for property portfolio workspaces (Property Deals plugin):
 * one summary fetch (Today + active deals + hot leads + renovations) feeds the stat widgets.
 */
import React from 'react';
import Link from 'next/link';
import { Card } from '@/components/ui';
import { pdService, type Today } from '@/services/property-deals.service';
import { HealthBadge, gbp } from '@/components/property-deals/ui';

export interface PropertySummary {
  today?: Today;
  activeDeals?: number;
  hotLeads?: number;
  renovations?: number;
}

/** Each part is optional: a role without a module just misses that number. */
export async function fetchPropertySummary(): Promise<PropertySummary> {
  const [today, deals, hot, renos] = await Promise.allSettled([
    pdService.today(20),
    pdService.deals({ status: 'active', per_page: 1 }),
    pdService.hotLeads(),
    pdService.renovations({ status: 'active' }),
  ]);
  return {
    today: today.status === 'fulfilled' ? today.value.data : undefined,
    activeDeals: deals.status === 'fulfilled' ? Number(deals.value.meta?.total ?? deals.value.data.length) : undefined,
    hotLeads: hot.status === 'fulfilled' ? hot.value.data.length : undefined,
    renovations: renos.status === 'fulfilled' ? renos.value.data.length : undefined,
  };
}

export function propertyStat(id: string, s?: PropertySummary): { value: string | number; description?: string } {
  const c = s?.today?.counts;
  switch (id) {
    case 'pd_active_deals':
      return { value: s?.activeDeals ?? '—', description: `${s?.today?.red_deals?.length ?? 0} at risk` };
    case 'pd_due_today':
      return { value: c?.due_today ?? '—', description: `${c?.open ?? 0} open in total` };
    case 'pd_overdue':
      return { value: c?.overdue ?? '—', description: 'past their deadline' };
    case 'pd_hot_leads_count':
      return { value: s?.hotLeads ?? '—', description: 'replied keenly — call now' };
    case 'pd_money_at_risk':
      return { value: gbp(s?.today?.money_at_risk ?? 0), description: 'late penalties if dates slip' };
    case 'pd_renovations':
      return { value: s?.renovations ?? '—', description: 'build boards in progress' };
    case 'pd_approvals':
      return { value: s?.today?.approvals_waiting_count ?? '—', description: 'drafts waiting for a person' };
    default:
      return { value: '—' };
  }
}

export function DealsAtRisk({ summary }: { summary?: PropertySummary }) {
  const deals = summary?.today?.red_deals || [];
  return (
    <Card padding="none">
      <div className="flex items-center justify-between border-b border-secondary-200 p-4">
        <h2 className="font-semibold text-secondary-900">Deals at risk</h2>
        <Link href="/dashboard/property-deals/deals" className="text-sm text-primary-600 hover:underline">All deals</Link>
      </div>
      {deals.length === 0 ? (
        <p className="p-4 text-sm text-secondary-500">No deals at risk.</p>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {deals.slice(0, 6).map((d) => (
            <li key={d.uuid} className="flex flex-wrap items-center justify-between gap-2 p-4 text-sm">
              <Link href={`/dashboard/property-deals/deals/${d.uuid}`} className="font-medium text-primary-600 hover:underline">{d.name}</Link>
              <span className="flex items-center gap-2">
                <span className="text-secondary-500">{gbp(d.money_at_risk)} at risk</span>
                <HealthBadge health={d.health} reasons={d.health_reasons} />
              </span>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
