'use client';

/**
 * Contracts — /dashboard/field-service/contracts
 *
 * Maintenance contracts (Simpro's customer contracts): term, value, the SLA
 * the desk works to, how much plant each covers, and what is up for renewal.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { ScrollText, Search } from 'lucide-react';
import { Card, Input, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { FieldServiceNav, Pill, apiError, money } from '@/components/field-service/shared';
import { SimproBadge } from '@/components/field-service/simpro';
import { formatFsDate } from '@/services/field-service.service';
import { simproCrm, type Contract } from '@/services/simpro-crm.service';
import type { TableColumn } from '@/types';

function plural(n: number, noun: string): string {
  return `${n} ${noun}${n === 1 ? '' : 's'}`;
}

function ExpiryPill({ days }: { days?: number | null }) {
  if (days === null || days === undefined) return <Pill className="bg-secondary-100 text-secondary-600">Open-ended</Pill>;
  if (days < 0) return <Pill className="bg-red-50 text-red-700">Expired</Pill>;
  if (days <= 90) return <Pill className="bg-amber-50 text-amber-700">Renew — {days} days</Pill>;
  return <Pill className="bg-green-50 text-green-700">{Math.round(days / 30)} months left</Pill>;
}

function ContractsPageContent() {
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await simproCrm.getContracts({ per_page: 200, search: search.trim() || undefined });
      setContracts(res.data);
    } catch (err) {
      toast.error(apiError(err, 'Failed to load contracts'));
    } finally {
      setLoading(false);
    }
  }, [search]);

  useEffect(() => {
    const t = setTimeout(load, 250);
    return () => clearTimeout(t);
  }, [load]);

  const annual = contracts.filter((c) => c.status === 'active').reduce((sum, c) => sum + (c.annual_value || 0), 0);
  const renewing = contracts.filter((c) => c.days_to_expiry != null && c.days_to_expiry >= 0 && c.days_to_expiry <= 90).length;

  const columns: TableColumn<Contract>[] = useMemo(
    () => [
      {
        key: 'name',
        header: 'Contract',
        render: (c) => (
          <div>
            <p className="font-medium text-secondary-900">{c.name}</p>
            <p className="text-xs font-mono text-secondary-500">{c.contract_number}</p>
          </div>
        ),
      },
      { key: 'customer_name', header: 'Customer', render: (c) => <span className="text-sm">{c.customer_name}</span> },
      {
        key: 'term',
        header: 'Term',
        render: (c) => (
          <span className="text-sm whitespace-nowrap">
            {formatFsDate(c.start_date)} – {formatFsDate(c.end_date)}
          </span>
        ),
      },
      { key: 'expiry', header: 'Renewal', render: (c) => <ExpiryPill days={c.days_to_expiry} /> },
      {
        key: 'annual_value',
        header: 'Annual value',
        render: (c) => <span className="text-sm tabular-nums">{c.annual_value != null ? money(c.annual_value) : '—'}</span>,
      },
      {
        key: 'sla',
        header: 'SLA (respond / fix / quote)',
        render: (c) => (
          <span className="text-sm whitespace-nowrap">
            {c.response_hours ?? '—'}h / {c.resolve_hours ?? '—'}h / {c.quote_turnaround_hours ?? '—'}h
            {c.covers_out_of_hours && <span className="block text-xs text-secondary-500">24/7 cover</span>}
          </span>
        ),
      },
      {
        key: 'coverage',
        header: 'Covers',
        render: (c) => (
          <span className="text-sm whitespace-nowrap">
            {plural(c.asset_count ?? 0, 'asset')} · {plural(c.site_count ?? 0, 'site')}
          </span>
        ),
      },
      { key: 'sync', header: 'Simpro', render: (c) => <SimproBadge state={c.simpro_sync_state} /> },
    ],
    []
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Contracts"
        description={`${contracts.length} contracts · ${money(annual)} a year under active contract · ${renewing} up for renewal within 90 days`}
        icon={<ScrollText className="w-5 h-5" />}
      />
      <FieldServiceNav />
      <Card padding="md">
        <div className="max-w-md">
          <Input
            placeholder="Search contract name or number…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            leftIcon={<Search className="w-4 h-4" />}
          />
        </div>
      </Card>
      <Table columns={columns} data={contracts} keyExtractor={(c) => c.uuid} isLoading={loading} emptyMessage="No contracts yet." />
    </div>
  );
}

export default function FieldServiceContractsPage() {
  return (
    <ProtectedPage module="fs_contracts" title="Contracts">
      <ContractsPageContent />
    </ProtectedPage>
  );
}
