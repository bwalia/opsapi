'use client';

import React, { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { Crown, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Card, Input, Table } from '@/components/ui';
import StatsCard from '@/components/dashboard/StatsCard';
import { ProtectedPage } from '@/components/permissions';
import { FilterSelect } from '@/components/shop/shared';
import { VipBadge } from '@/components/shop/VipBadge';
import { shopMembershipService } from '@/services/shop-membership.service';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { formatMoney } from '@/lib/shop';
import type { ShopMember, ShopMembershipStatus, TableColumn } from '@/types';

const STATUS: Record<ShopMembershipStatus, { label: string; variant: 'success' | 'warning' | 'error' | 'secondary' }> = {
  active: { label: 'Active', variant: 'success' },
  past_due: { label: 'Payment overdue', variant: 'error' },
  canceled: { label: 'Cancelled', variant: 'secondary' },
  expired: { label: 'Expired', variant: 'secondary' },
};

const inForce = (m: ShopMember) => m.status === 'active' || m.status === 'past_due';
const DAY = 86_400_000;

function MembersContent() {
  const [rows, setRows] = useState<ShopMember[] | null>(null);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [status, setStatus] = useState<ShopMembershipStatus | ''>('');
  const [now] = useState(() => Date.now());

  useEffect(() => {
    const t = setTimeout(() => setQ(search.trim()), 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let active = true;
    shopMembershipService
      .members({ q, status })
      .then((r) => active && setRows(r))
      .catch((err) => {
        if (!active) return;
        setRows([]);
        toast.error(extractApiError(err, 'Could not load members'));
      });
    return () => {
      active = false;
    };
  }, [q, status]);

  const stats = useMemo(() => {
    const list = rows ?? [];
    const live = list.filter(inForce);
    const weekAgo = now - 7 * DAY;
    return {
      live: live.length,
      founding: live.filter((m) => m.tier === 'founding').length,
      newThisWeek: live.filter((m) => m.joined_at && new Date(m.joined_at).getTime() >= weekAgo).length,
      monthlyNet: live.reduce((s, m) => s + (m.billing_interval === 'year' ? Math.round(m.net_minor / 12) : m.net_minor), 0),
      overdue: live.filter((m) => m.status === 'past_due').length,
    };
  }, [rows, now]);

  const columns: TableColumn<ShopMember>[] = [
    {
      key: 'name',
      header: 'Member',
      render: (m) => (
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <p className="truncate font-medium text-secondary-900">{m.name || m.email}</p>
            {inForce(m) && (
              <VipBadge vip={{ email: m.email, uuid: m.uuid, tier: m.tier, billing_interval: m.billing_interval, status: m.status as 'active' | 'past_due', joined_at: m.joined_at, current_period_end: m.current_period_end, cancel_at_period_end: m.cancel_at_period_end }} />
            )}
          </div>
          <p className="truncate text-xs text-secondary-500">{[m.company, m.name ? m.email : null, m.phone].filter(Boolean).join(' · ')}</p>
        </div>
      ),
    },
    {
      key: 'fee',
      header: 'Fee',
      render: (m) => (
        <div className="text-sm">
          <p className="tabular-nums">{formatMoney(m.net_minor)} + VAT</p>
          <p className="text-xs text-secondary-500">{m.billing_interval === 'year' ? 'Yearly' : 'Monthly'} · {m.tier === 'founding' ? 'Founding' : 'Standard'}</p>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (m) => (
        <div className="space-y-1">
          <Badge size="sm" variant={STATUS[m.status]?.variant ?? 'secondary'}>{STATUS[m.status]?.label ?? m.status}</Badge>
          {m.cancel_at_period_end && inForce(m) && <p className="text-xs text-warning-600">Cancels at period end</p>}
        </div>
      ),
    },
    { key: 'joined_at', header: 'Joined', render: (m) => <span className="whitespace-nowrap text-sm text-secondary-600">{m.joined_at ? formatDateTime(m.joined_at) : '—'}</span> },
    {
      key: 'current_period_end',
      header: 'Paid until',
      render: (m) => <span className="whitespace-nowrap text-sm text-secondary-600">{m.current_period_end ? formatDateTime(m.current_period_end) : '—'}</span>,
    },
    {
      key: 'fees_paid_net_minor',
      header: 'Fees paid (ex VAT)',
      render: (m) => <span className="text-sm tabular-nums">{formatMoney(m.fees_paid_net_minor)}</span>,
    },
    {
      key: 'lead',
      header: '',
      render: (m) =>
        m.lead_uuid ? (
          <Link href={`/dashboard/leads/${m.lead_uuid}`} className="text-sm text-primary-600 hover:underline" onClick={(e) => e.stopPropagation()}>
            Open lead
          </Link>
        ) : null,
    },
  ];

  const loading = rows === null;

  return (
    <div className="space-y-6">
      <PageHeader
        title="VIP members"
        description="Customers who pay for Trade (VIP) membership. Their Trade discount applies to basket orders automatically."
        icon={<Crown className="h-5 w-5" />}
      />

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatsCard title="VIP members" value={loading ? '—' : stats.live} description={loading ? undefined : `${stats.founding} founding`} icon={<Crown className="h-5 w-5" />} isLoading={loading} />
        <StatsCard title="New this week" value={loading ? '—' : stats.newThisWeek} description="Joined in the last 7 days" icon={<Crown className="h-5 w-5" />} isLoading={loading} />
        <StatsCard title="Fees per month" value={loading ? '—' : formatMoney(stats.monthlyNet)} description="Ex VAT, members in force" icon={<Crown className="h-5 w-5" />} isLoading={loading} />
        <StatsCard title="Payment overdue" value={loading ? '—' : stats.overdue} description="Stripe is retrying" icon={<Crown className="h-5 w-5" />} isLoading={loading} />
      </div>

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input placeholder="Email, name or company…" aria-label="Search members" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <FilterSelect aria-label="Status" value={status} onChange={(e) => setStatus(e.target.value as ShopMembershipStatus | '')}>
            <option value="">All statuses</option>
            {(Object.keys(STATUS) as ShopMembershipStatus[]).map((s) => (
              <option key={s} value={s}>{STATUS[s].label}</option>
            ))}
          </FilterSelect>
        </div>
      </Card>

      <Table columns={columns} data={rows ?? []} keyExtractor={(m) => m.uuid} isLoading={loading} emptyMessage="No VIP members yet" caption="VIP members" />
    </div>
  );
}

export default function ShopMembersPage() {
  return (
    <ProtectedPage module="shop" title="VIP members">
      <MembersContent />
    </ProtectedPage>
  );
}
