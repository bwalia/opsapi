'use client';

/**
 * Billing — /dashboard/billing/subscriptions
 *
 * Who is on which plan, and access granted without payment (grants).
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { Gift, RefreshCw, Trash2 } from 'lucide-react';
import { Button, Card, ConfirmDialog, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, FilterSelect } from '@/components/field-service/shared';
import { BillingNav, StatusPill, Tabs } from '@/components/billing/shared';
import GrantModal from '@/components/billing/GrantModal';
import { formatDate } from '@/lib/utils';
import { billingService, type BillingApp, type Grant, type Subscription } from '@/services/billing.service';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;
type Tab = 'subscriptions' | 'grants';

const STATUS_OPTIONS = [
  { value: '', label: 'Any status' },
  { value: 'active', label: 'Active' },
  { value: 'trialing', label: 'Trialing' },
  { value: 'past_due', label: 'Past due' },
  { value: 'canceled', label: 'Cancelled' },
];

function CustomerCell({ row }: { row: { customer_uuid: string; customer_email: string; customer_external_id?: string | null } }) {
  return (
    <div className="min-w-0">
      <Link href={`/dashboard/customers/${row.customer_uuid}`} className="font-medium text-secondary-900 hover:text-primary-600 break-all">
        {row.customer_email}
      </Link>
      {row.customer_external_id && <p className="text-xs text-secondary-500 font-mono">{row.customer_external_id}</p>}
    </div>
  );
}

function useList<T>(fetcher: (page: number) => Promise<{ data: T[]; meta: { total: number; total_pages: number } }>) {
  const [rows, setRows] = useState<T[]>([]);
  const [page, setPage] = useState(1);
  const [meta, setMeta] = useState({ total: 0, total_pages: 1 });
  const [loading, setLoading] = useState(true);
  const fetchId = useRef(0);
  const load = useCallback(async () => {
    const id = ++fetchId.current;
    setLoading(true);
    try {
      const res = await fetcher(page);
      if (id === fetchId.current) {
        setRows(res.data);
        setMeta({ total: res.meta.total, total_pages: res.meta.total_pages || 1 });
      }
    } catch (err) {
      if (id === fetchId.current) toast.error(apiError(err, 'Failed to load'));
    } finally {
      if (id === fetchId.current) setLoading(false);
    }
  }, [fetcher, page]);
  useEffect(() => {
    load();
  }, [load]);
  return { rows, page, setPage, meta, loading, reload: load };
}

function SubscriptionsContent() {
  const { canCreate, canDelete } = usePermissions();
  const [tab, setTab] = useState<Tab>('subscriptions');
  const [apps, setApps] = useState<BillingApp[]>([]);
  const [app, setApp] = useState('');
  const [status, setStatus] = useState('');
  const [grantOpen, setGrantOpen] = useState(false);
  const [revokeTarget, setRevokeTarget] = useState<Grant | null>(null);
  const [revoking, setRevoking] = useState(false);

  useEffect(() => {
    billingService.listApps().then(setApps).catch(() => setApps([]));
  }, []);

  const subFetcher = useCallback(
    (page: number) => billingService.listSubscriptions({ app: app || undefined, status: status || undefined, page, per_page: PER_PAGE }),
    [app, status]
  );
  const grantFetcher = useCallback(
    (page: number) => billingService.listGrants({ app: app || undefined, page, per_page: PER_PAGE }),
    [app]
  );
  const subs = useList<Subscription>(subFetcher);
  const grants = useList<Grant>(grantFetcher);
  const { setPage: setSubsPage } = subs;
  const { setPage: setGrantsPage } = grants;
  useEffect(() => {
    setSubsPage(1);
    setGrantsPage(1);
  }, [app, status, setSubsPage, setGrantsPage]);

  const revoke = async () => {
    if (!revokeTarget) return;
    setRevoking(true);
    try {
      await billingService.revokeGrant(revokeTarget.uuid);
      toast.success('Grant revoked');
      setRevokeTarget(null);
      grants.reload();
    } catch (err) {
      toast.error(apiError(err, 'Could not revoke'));
    } finally {
      setRevoking(false);
    }
  };

  const subColumns: TableColumn<Subscription>[] = useMemo(
    () => [
      { key: 'customer', header: 'Customer', render: (s) => <CustomerCell row={s} /> },
      { key: 'app', header: 'App / plan', render: (s) => <span>{s.app_name} · {s.plan_name || '—'}</span> },
      { key: 'status', header: 'Status', render: (s) => <StatusPill status={s.status} /> },
      {
        key: 'period',
        header: 'Renews / ends',
        render: (s) =>
          s.current_period_end ? (
            <span className="text-sm">
              {s.cancel_at_period_end ? 'Ends ' : ''}
              {formatDate(s.current_period_end)}
            </span>
          ) : (
            '—'
          ),
      },
      { key: 'created_at', header: 'Since', render: (s) => formatDate(s.created_at) },
    ],
    []
  );

  const grantColumns: TableColumn<Grant>[] = useMemo(
    () => [
      { key: 'customer', header: 'Customer', render: (g) => <CustomerCell row={g} /> },
      {
        key: 'what',
        header: 'Access',
        render: (g) => (
          <div className="text-sm">
            <p>
              {g.app_name}
              {g.plan_name ? ` · ${g.plan_name}` : ''}
            </p>
            {Object.keys(g.features).length > 0 && (
              <p className="text-xs text-secondary-500">
                {Object.entries(g.features)
                  .map(([k, v]) => `${k}: ${v === null ? 'unlimited' : String(v)}`)
                  .join(', ')}
              </p>
            )}
          </div>
        ),
      },
      { key: 'reason', header: 'Reason', render: (g) => <span className="text-sm text-secondary-600">{g.reason || '—'}</span> },
      { key: 'expires', header: 'Until', render: (g) => (g.expires_at ? formatDate(g.expires_at) : 'Revoked by hand') },
      {
        key: 'actions',
        header: '',
        width: 'w-16',
        render: (g) =>
          canDelete('subscriptions') ? (
            <button
              type="button"
              onClick={() => setRevokeTarget(g)}
              className="p-2 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
              aria-label="Revoke grant"
              title="Revoke grant"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          ) : null,
      },
    ],
    [canDelete]
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Subscriptions"
        description="Customers' plans, and access you've granted without payment."
        icon={<RefreshCw className="w-5 h-5" />}
        actions={
          canCreate('subscriptions') ? (
            <Button onClick={() => setGrantOpen(true)}>
              <Gift className="w-4 h-4 mr-1.5" /> Grant access
            </Button>
          ) : undefined
        }
      />
      <BillingNav />

      <Card padding="md">
        <div className="flex flex-wrap items-end gap-4">
          <FilterSelect
            value={app}
            onChange={setApp}
            options={[{ value: '', label: 'All apps' }, ...apps.map((a) => ({ value: a.uuid, label: a.name }))]}
            ariaLabel="Filter by app"
          />
          {tab === 'subscriptions' && (
            <FilterSelect value={status} onChange={setStatus} options={STATUS_OPTIONS} ariaLabel="Filter by status" />
          )}
        </div>
      </Card>

      <Tabs
        tabs={[
          { id: 'subscriptions', label: `Subscriptions (${subs.meta.total})` },
          { id: 'grants', label: `Grants (${grants.meta.total})` },
        ]}
        value={tab}
        onChange={setTab}
        label="Subscription views"
      />
      <div role="tabpanel">
        {tab === 'subscriptions' ? (
          <>
            <Table
              columns={subColumns}
              data={subs.rows}
              keyExtractor={(s) => s.uuid}
              isLoading={subs.loading}
              emptyMessage="No subscriptions yet. They appear when customers check out (Stripe Connect is coming next); until then use grants."
            />
            <Pagination currentPage={subs.page} totalPages={subs.meta.total_pages} totalItems={subs.meta.total} perPage={PER_PAGE} onPageChange={subs.setPage} />
          </>
        ) : (
          <>
            <Table columns={grantColumns} data={grants.rows} keyExtractor={(g) => g.uuid} isLoading={grants.loading} emptyMessage="No active grants." />
            <Pagination currentPage={grants.page} totalPages={grants.meta.total_pages} totalItems={grants.meta.total} perPage={PER_PAGE} onPageChange={grants.setPage} />
          </>
        )}
      </div>

      <GrantModal
        isOpen={grantOpen}
        onClose={() => setGrantOpen(false)}
        onSaved={() => {
          setGrantOpen(false);
          setTab('grants');
          grants.reload();
        }}
      />
      <ConfirmDialog
        isOpen={!!revokeTarget}
        onClose={() => setRevokeTarget(null)}
        onConfirm={revoke}
        title="Revoke this grant?"
        message={`${revokeTarget?.customer_email || 'The customer'} loses this access at their app's next check.`}
        confirmText="Revoke"
        variant="danger"
        isLoading={revoking}
      />
    </div>
  );
}

export default function SubscriptionsPage() {
  return (
    <ProtectedPage module="subscriptions" title="Subscriptions">
      <SubscriptionsContent />
    </ProtectedPage>
  );
}
