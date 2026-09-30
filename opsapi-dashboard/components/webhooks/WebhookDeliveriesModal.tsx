'use client';

/**
 * Delivery log of one webhook: what was sent, the receiver's answer, retries,
 * and a "Redeliver" action. Delivered entries are kept 7 days, failed 30.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { RefreshCw, RotateCcw } from 'lucide-react';
import { Modal, Button, Table, Pagination } from '@/components/ui';
import { FilterSelect, Pill, apiError } from '@/components/field-service/shared';
import { formatRelativeTime } from '@/lib/utils';
import { webhooksService, type DeliveryStatus, type Webhook, type WebhookDelivery } from '@/services/webhooks.service';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;

/** Postgres timestamps ("2026-09-30 07:31:36.1+00") → "3 minutes ago". */
export function when(ts?: string | null): string {
  if (!ts) return '—';
  const iso = ts.replace(' ', 'T').replace(/([+-]\d\d)$/, '$1:00');
  try {
    return formatRelativeTime(iso);
  } catch {
    return ts;
  }
}

export const STATUS_STYLE: Record<DeliveryStatus, { label: string; className: string }> = {
  done: { label: 'Delivered', className: 'bg-green-50 text-green-700' },
  pending: { label: 'Retrying', className: 'bg-amber-50 text-amber-700' },
  running: { label: 'Sending', className: 'bg-blue-50 text-blue-700' },
  dead: { label: 'Failed', className: 'bg-error-50 text-error-700' },
};

const STATUS_FILTER = [
  { value: '', label: 'All deliveries' },
  { value: 'done', label: 'Delivered' },
  { value: 'pending', label: 'Retrying' },
  { value: 'dead', label: 'Failed' },
];

export default function WebhookDeliveriesModal({
  webhook,
  initialStatus = '',
  canRedeliver,
  onClose,
}: {
  /** null = closed */
  webhook: Webhook | null;
  initialStatus?: DeliveryStatus | '';
  canRedeliver: boolean;
  onClose: () => void;
}) {
  return (
    <Modal isOpen={!!webhook} onClose={onClose} title="Deliveries" description={webhook?.url} size="3xl">
      {webhook && (
        <DeliveryLog key={webhook.uuid} webhook={webhook} initialStatus={initialStatus} canRedeliver={canRedeliver} />
      )}
    </Modal>
  );
}

function DeliveryLog({
  webhook,
  initialStatus,
  canRedeliver,
}: {
  webhook: Webhook;
  initialStatus: DeliveryStatus | '';
  canRedeliver: boolean;
}) {
  const [rows, setRows] = useState<WebhookDelivery[]>([]);
  const [status, setStatus] = useState<DeliveryStatus | ''>(initialStatus);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<number | null>(null);
  const fetchId = useRef(0);

  const load = useCallback(async () => {
    const id = ++fetchId.current;
    setLoading(true);
    try {
      const res = await webhooksService.deliveries(webhook.uuid, { page, per_page: PER_PAGE, status });
      if (id === fetchId.current) {
        setRows(res.data);
        setTotalPages(res.meta.total_pages || 1);
        setTotal(res.meta.total);
      }
    } catch (err) {
      if (id === fetchId.current) toast.error(apiError(err, 'Could not load deliveries'));
    } finally {
      if (id === fetchId.current) setLoading(false);
    }
  }, [webhook.uuid, page, status]);

  useEffect(() => {
    load();
  }, [load]);

  const redeliver = async (d: WebhookDelivery) => {
    setBusy(d.id);
    try {
      await webhooksService.redeliver(webhook.uuid, d.id);
      toast.success('Queued — it will be sent within a few seconds');
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not redeliver'));
    } finally {
      setBusy(null);
    }
  };

  const columns: TableColumn<WebhookDelivery>[] = [
    {
      key: 'event',
      header: 'Event',
      render: (d) => (
        <div className="min-w-0">
          <p className="font-mono text-sm text-secondary-900">{d.event}</p>
          <p className="text-xs text-secondary-500">{when(d.created_at)}</p>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (d) => (
        <div className="space-y-1">
          <Pill className={STATUS_STYLE[d.status].className}>{STATUS_STYLE[d.status].label}</Pill>
          {d.status === 'pending' && d.next_attempt_at && (
            <p className="text-xs text-secondary-500">next try {when(d.next_attempt_at)}</p>
          )}
        </div>
      ),
    },
    {
      key: 'response',
      header: 'Response',
      render: (d) => (
        <div className="text-sm">
          <p className="text-secondary-800">{d.response_status ? `HTTP ${d.response_status}` : '—'}</p>
          {d.duration_ms != null && <p className="text-xs text-secondary-500">{d.duration_ms} ms</p>}
        </div>
      ),
    },
    {
      key: 'attempts',
      header: 'Attempts',
      render: (d) => <span className="text-sm text-secondary-700">{d.attempts}</span>,
    },
    {
      key: 'error',
      header: 'Error',
      render: (d) =>
        d.last_error ? (
          <span className="text-xs text-error-700 break-words" title={d.last_error}>
            {d.last_error.length > 90 ? `${d.last_error.slice(0, 89)}…` : d.last_error}
          </span>
        ) : (
          <span className="text-secondary-400">—</span>
        ),
    },
    ...(canRedeliver
      ? [
          {
            key: 'actions',
            header: '',
            width: 'w-28',
            render: (d: WebhookDelivery) =>
              d.status === 'running' ? null : (
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => redeliver(d)}
                  isLoading={busy === d.id}
                  leftIcon={<RotateCcw className="w-3.5 h-3.5" />}
                >
                  Redeliver
                </Button>
              ),
          },
        ]
      : []),
  ];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-3">
        <FilterSelect
          value={status}
          onChange={(v) => {
            setStatus(v as DeliveryStatus | '');
            setPage(1);
          }}
          options={STATUS_FILTER}
          ariaLabel="Filter deliveries by status"
        />
        <Button variant="outline" size="sm" onClick={load} leftIcon={<RefreshCw className="w-3.5 h-3.5" />}>
          Refresh
        </Button>
      </div>
      <Table
        columns={columns}
        data={rows}
        keyExtractor={(d) => d.id}
        isLoading={loading}
        emptyMessage="No deliveries yet. Send a test or wait for an event."
        caption="Webhook deliveries"
      />
      <Pagination
        currentPage={page}
        totalPages={totalPages}
        totalItems={total}
        perPage={PER_PAGE}
        onPageChange={setPage}
      />
      <p className="text-xs text-secondary-500">
        Failed deliveries are retried with increasing delays for about an hour. Delivered entries are kept for 7 days,
        failed ones for 30.
      </p>
    </div>
  );
}
