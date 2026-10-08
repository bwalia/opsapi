'use client';

/**
 * Billing — /dashboard/billing/licenses
 *
 * Licence keys for desktop and self-hosted apps, and the devices using them.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { KeyRound, Plus } from 'lucide-react';
import { Button, Card, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, FilterSelect } from '@/components/field-service/shared';
import { BillingNav, StatusPill } from '@/components/billing/shared';
import { IssueLicenseModal, LicenseDetailModal } from '@/components/billing/LicenseModals';
import { formatDate } from '@/lib/utils';
import { billingService, type BillingApp, type License } from '@/services/billing.service';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;
const STATUS_OPTIONS = [
  { value: '', label: 'Any status' },
  { value: 'active', label: 'Active' },
  { value: 'suspended', label: 'Suspended' },
  { value: 'expired', label: 'Expired' },
  { value: 'revoked', label: 'Revoked' },
];

function LicensesContent() {
  const { canCreate } = usePermissions();
  const [apps, setApps] = useState<BillingApp[]>([]);
  const [app, setApp] = useState('');
  const [status, setStatus] = useState('');
  const [rows, setRows] = useState<License[]>([]);
  const [page, setPage] = useState(1);
  const [meta, setMeta] = useState({ total: 0, total_pages: 1 });
  const [loading, setLoading] = useState(true);
  const [issueOpen, setIssueOpen] = useState(false);
  const [openUuid, setOpenUuid] = useState<string | null>(null);
  const fetchId = useRef(0);

  useEffect(() => {
    billingService.listApps().then(setApps).catch(() => setApps([]));
  }, []);

  const load = useCallback(async () => {
    const id = ++fetchId.current;
    setLoading(true);
    try {
      const res = await billingService.listLicenses({ app: app || undefined, status: status || undefined, page, per_page: PER_PAGE });
      if (id === fetchId.current) {
        setRows(res.data);
        setMeta({ total: res.meta.total, total_pages: res.meta.total_pages || 1 });
      }
    } catch (err) {
      if (id === fetchId.current) toast.error(apiError(err, 'Failed to load licences'));
    } finally {
      if (id === fetchId.current) setLoading(false);
    }
  }, [app, status, page]);

  useEffect(() => {
    load();
  }, [load]);

  const columns: TableColumn<License>[] = useMemo(
    () => [
      {
        key: 'key',
        header: 'Key',
        render: (l) => <code className="text-sm tracking-wider">{l.key_prefix}-•••••</code>,
      },
      {
        key: 'customer',
        header: 'Customer',
        render: (l) => (
          <Link
            href={`/dashboard/customers/${l.customer_uuid}`}
            onClick={(e) => e.stopPropagation()}
            className="text-secondary-900 hover:text-primary-600 break-all"
          >
            {l.customer_email}
          </Link>
        ),
      },
      { key: 'app', header: 'App / plan', render: (l) => `${l.app_name} · ${l.plan_name || "customer's plan"}` },
      {
        key: 'devices',
        header: 'Devices',
        render: (l) => (
          <span className="tabular-nums">
            {l.active_activations} / {l.max_activations ?? '∞'}
          </span>
        ),
      },
      { key: 'status', header: 'Status', render: (l) => <StatusPill status={l.status} /> },
      { key: 'expires', header: 'Expires', render: (l) => (l.expires_at ? formatDate(l.expires_at) : 'Never') },
    ],
    []
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Licences"
        description="Keys for desktop and self-hosted software, and the devices using them."
        icon={<KeyRound className="w-5 h-5" />}
        actions={
          canCreate('licenses') ? (
            <Button onClick={() => setIssueOpen(true)}>
              <Plus className="w-4 h-4 mr-1.5" /> Issue licence
            </Button>
          ) : undefined
        }
      />
      <BillingNav />

      <Card padding="md">
        <div className="flex flex-wrap items-end gap-4">
          <FilterSelect
            value={app}
            onChange={(v) => {
              setApp(v);
              setPage(1);
            }}
            options={[{ value: '', label: 'All apps' }, ...apps.map((a) => ({ value: a.uuid, label: a.name }))]}
            ariaLabel="Filter by app"
          />
          <FilterSelect
            value={status}
            onChange={(v) => {
              setStatus(v);
              setPage(1);
            }}
            options={STATUS_OPTIONS}
            ariaLabel="Filter by status"
          />
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(l) => l.uuid}
          onRowClick={(l) => setOpenUuid(l.uuid)}
          isLoading={loading}
          emptyMessage="No licences yet."
        />
        <Pagination currentPage={page} totalPages={meta.total_pages} totalItems={meta.total} perPage={PER_PAGE} onPageChange={setPage} />
      </div>

      <IssueLicenseModal isOpen={issueOpen} onClose={() => setIssueOpen(false)} onIssued={load} />
      <LicenseDetailModal uuid={openUuid} onClose={() => setOpenUuid(null)} onChanged={load} />
    </div>
  );
}

export default function LicensesPage() {
  return (
    <ProtectedPage module="licenses" title="Licences">
      <LicensesContent />
    </ProtectedPage>
  );
}
