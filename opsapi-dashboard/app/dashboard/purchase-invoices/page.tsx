'use client';

import React, { Suspense, useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { AlertTriangle, CheckCircle2, FileText, Plus, Receipt, Search, Wallet } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import StatsCard from '@/components/dashboard/StatsCard';
import { Badge, Button, Card, Input, Modal, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { InvoiceModal, KIND_DOC_TYPE } from '@/components/purchase-orders/SupplierPortalPanel';
import { fmtMoney } from '@/components/supplier-portal/shared';
import { purchaseOrdersService, type PurchaseOrder } from '@/services/purchase-orders.service';
import { INVOICE_KIND_LABELS, portalError, purchaseOrderPortalService } from '@/services/supplier-portal.service';
import {
  purchaseInvoicesService,
  type PurchaseInvoice,
  type PurchaseInvoiceFilter,
  type PurchaseInvoiceList,
  type PurchaseInvoiceState,
} from '@/services/purchase-invoices.service';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';

const PER_PAGE = 50;

const FILTERS: { key: PurchaseInvoiceFilter; label: string }[] = [
  { key: '', label: 'All' },
  { key: 'owed', label: 'To pay' },
  { key: 'overdue', label: 'Overdue' },
  { key: 'paid', label: 'Paid' },
  { key: 'proforma', label: 'Proformas' },
  { key: 'credit', label: 'Credit notes' },
];

const STATE: Record<PurchaseInvoiceState, { label: string; variant: 'success' | 'warning' | 'error' | 'info' | 'secondary' }> = {
  unpaid: { label: 'To pay', variant: 'warning' },
  part_paid: { label: 'Part paid', variant: 'warning' },
  overdue: { label: 'Overdue', variant: 'error' },
  paid: { label: 'Paid', variant: 'success' },
  proforma: { label: 'Proforma', variant: 'info' },
  credit: { label: 'Credit note', variant: 'secondary' },
};

const OPEN_PO = new Set(['sent', 'acknowledged', 'partially_received', 'received', 'billed']);

/** Step 1 of recording one: which purchase order is it for? */
function PickPurchaseOrder({ open, onClose, onPick }: { open: boolean; onClose: () => void; onPick: (po: PurchaseOrder) => void }) {
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<PurchaseOrder[] | null>(null);

  useEffect(() => {
    if (!open) return;
    let active = true;
    const t = setTimeout(() => {
      purchaseOrdersService
        .getPurchaseOrders({ search: q.trim() || undefined, perPage: 15 })
        .then((r) => active && setRows(r.data.filter((po) => OPEN_PO.has(po.status))))
        .catch(() => active && setRows([]));
    }, 250);
    return () => {
      active = false;
      clearTimeout(t);
    };
  }, [q, open]);

  return (
    <Modal isOpen={open} onClose={onClose} title="Which purchase order is it for?" description="Supplier invoices are kept with the purchase order they bill." size="lg">
      <Input
        id="pick-po"
        autoFocus
        placeholder="PO number, supplier or reference"
        leftIcon={<Search className="h-4 w-4" />}
        value={q}
        onChange={(e) => setQ(e.target.value)}
        aria-label="Find the purchase order"
      />
      <ul className="mt-3 max-h-80 divide-y divide-secondary-100 overflow-y-auto">
        {rows === null && <li className="py-3 text-sm text-secondary-500">Loading…</li>}
        {rows && rows.length === 0 && (
          <li className="py-3 text-sm text-secondary-500">
            No sent purchase orders match. An invoice needs a purchase order that has been sent to the supplier.
          </li>
        )}
        {rows?.map((po) => (
          <li key={po.uuid}>
            <button type="button" onClick={() => onPick(po)} className="flex w-full items-center justify-between gap-3 px-2 py-3 text-left hover:bg-secondary-50">
              <span className="min-w-0">
                <span className="font-mono text-sm font-medium text-secondary-900">{po.po_number}</span>
                <span className="block truncate text-xs text-secondary-500">{po.supplier_name}</span>
              </span>
              <span className="shrink-0 text-sm tabular-nums text-secondary-700">{fmtMoney(String(po.total), po.currency)}</span>
            </button>
          </li>
        ))}
      </ul>
    </Modal>
  );
}

function PurchaseInvoicesContent() {
  const router = useRouter();
  const params = useSearchParams();
  const { canUpdate } = usePermissions();
  const urlState = (params.get('state') ?? '') as PurchaseInvoiceFilter;
  const state: PurchaseInvoiceFilter = FILTERS.some((f) => f.key === urlState) ? urlState : '';
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [page, setPage] = useState(1);
  const [data, setData] = useState<PurchaseInvoiceList | null>(null);
  const [loading, setLoading] = useState(true);
  const [version, setVersion] = useState(0);
  const [picking, setPicking] = useState(false);
  const [po, setPo] = useState<PurchaseOrder | null>(null);

  useEffect(() => {
    const t = setTimeout(() => {
      setQ(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let active = true;
    purchaseInvoicesService
      .list({ q, state, limit: PER_PAGE, offset: (page - 1) * PER_PAGE })
      .then((r) => active && setData(r))
      .catch((e) => active && toast.error(portalError(e, 'Could not load purchase invoices').message))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [q, state, page, version]);

  const setState = useCallback(
    (s: PurchaseInvoiceFilter) => {
      setPage(1);
      router.replace(s ? `/dashboard/purchase-invoices?state=${s}` : '/dashboard/purchase-invoices');
    },
    [router]
  );

  const totals = data ? Object.entries(data.summary) : [];
  const main = totals.find(([c]) => c === 'GBP') ?? totals[0];
  const cur = main?.[0] ?? 'GBP';
  const sum = main?.[1];
  const others = totals.filter(([c]) => c !== cur);

  const record = async (kind: Parameters<React.ComponentProps<typeof InvoiceModal>['onSubmit']>[0], invoice: Parameters<React.ComponentProps<typeof InvoiceModal>['onSubmit']>[1], file: File | null, visible: boolean) => {
    if (!po) return false;
    try {
      if (file) {
        await purchaseOrderPortalService.uploadDocument(po.uuid, { file, doc_type: KIND_DOC_TYPE[kind], invoice, visible_to_supplier: visible });
      } else {
        await purchaseOrderPortalService.recordInvoice(po.uuid, { ...invoice, kind });
      }
      toast.success(`${INVOICE_KIND_LABELS[kind]} recorded on ${po.po_number}`);
      setVersion((v) => v + 1);
      return true;
    } catch (e) {
      toast.error(portalError(e, 'Could not record it').message);
      return false;
    }
  };

  const columns: TableColumn<PurchaseInvoice>[] = [
    {
      key: 'number',
      header: 'Invoice',
      render: (i) => (
        <div>
          <p className="font-mono font-medium text-secondary-900">{i.number}</p>
          <p className="text-xs text-secondary-500">{INVOICE_KIND_LABELS[i.kind]}{i.recorded_by === 'supplier' ? ' · from the supplier' : ''}</p>
        </div>
      ),
    },
    {
      key: 'supplier',
      header: 'Supplier',
      render: (i) => (
        <div className="min-w-0">
          <p className="truncate text-secondary-900">{i.supplier_name}</p>
          <Link href={`/dashboard/purchase-orders/${i.purchase_order.uuid}`} onClick={(e) => e.stopPropagation()} className="font-mono text-xs text-primary-600 hover:underline">
            {i.purchase_order.po_number}
          </Link>
        </div>
      ),
    },
    {
      key: 'dates',
      header: 'Dated / due',
      render: (i) => (
        <div className="text-sm">
          <p className="text-secondary-700">{formatDate(i.invoice_date)}</p>
          {i.due_date && (
            <p className={i.state === 'overdue' ? 'text-xs font-medium text-error-700' : 'text-xs text-secondary-500'}>
              Due {formatDate(i.due_date)}
              {i.state === 'overdue' && i.days_late ? ` · ${i.days_late} day${i.days_late === 1 ? '' : 's'} late` : ''}
            </p>
          )}
        </div>
      ),
    },
    {
      key: 'total',
      header: 'Total',
      render: (i) => (
        <div className="tabular-nums">
          <p className="font-medium text-secondary-900">{fmtMoney(i.total, i.currency)}</p>
          <p className="text-xs text-secondary-500">VAT {fmtMoney(i.vat, i.currency)}</p>
        </div>
      ),
    },
    {
      key: 'outstanding',
      header: 'To pay',
      render: (i) =>
        i.kind === 'invoice' ? (
          <div className="tabular-nums">
            <p className={Number(i.outstanding) > 0 ? 'font-medium text-secondary-900' : 'text-secondary-500'}>{fmtMoney(i.outstanding, i.currency)}</p>
            {Number(i.paid) > 0 && <p className="text-xs text-success-700">Paid {fmtMoney(i.paid, i.currency)}</p>}
          </div>
        ) : (
          <span className="text-xs text-secondary-400">—</span>
        ),
    },
    {
      key: 'state',
      header: 'Status',
      render: (i) => <Badge variant={STATE[i.state].variant}>{STATE[i.state].label}</Badge>,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Purchase invoices"
        description="Invoices, proformas and credit notes from suppliers, across all purchase orders: what you owe, what is overdue and what is paid."
        icon={<Receipt className="h-5 w-5" />}
        actions={
          canUpdate('purchase_orders') ? (
            <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setPicking(true)}>
              Record a supplier invoice
            </Button>
          ) : undefined
        }
      />

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <StatsCard
          title="To pay"
          value={data ? fmtMoney(sum?.owed ?? '0', cur) : '—'}
          description={data ? `${sum?.owed_count ?? 0} invoice${sum?.owed_count === 1 ? '' : 's'}` : undefined}
          icon={<Wallet className="h-5 w-5" />}
          isLoading={loading && !data}
          href="/dashboard/purchase-invoices?state=owed"
        />
        <StatsCard
          title="Overdue"
          value={data ? fmtMoney(sum?.overdue ?? '0', cur) : '—'}
          description={data ? `${sum?.overdue_count ?? 0} past the due date` : undefined}
          icon={<AlertTriangle className="h-5 w-5" />}
          isLoading={loading && !data}
          href="/dashboard/purchase-invoices?state=overdue"
        />
        <StatsCard
          title="Paid"
          value={data ? fmtMoney(sum?.paid ?? '0', cur) : '—'}
          description="On the invoices listed"
          icon={<CheckCircle2 className="h-5 w-5" />}
          isLoading={loading && !data}
          href="/dashboard/purchase-invoices?state=paid"
        />
      </div>
      {others.length > 0 && (
        <p className="text-xs text-secondary-500">
          Also in other currencies: {others.map(([c, t]) => `${fmtMoney(t.owed, c)} to pay`).join(' · ')}
        </p>
      )}

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-3">
          <div className="min-w-[220px] max-w-sm flex-1">
            <Input placeholder="Invoice number, supplier, PO…" aria-label="Search purchase invoices" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <div className="flex flex-wrap gap-2" role="group" aria-label="Show">
            {FILTERS.map((f) => (
              <button
                key={f.key || 'all'}
                type="button"
                aria-pressed={state === f.key}
                onClick={() => setState(f.key)}
                className={`rounded-full border px-3 py-1 text-sm ${state === f.key ? 'border-primary-500 bg-primary-50 text-primary-700' : 'border-secondary-200 text-secondary-700 hover:bg-secondary-50'}`}
              >
                {f.label}
              </button>
            ))}
          </div>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={data?.data ?? []}
          keyExtractor={(i) => i.uuid}
          onRowClick={(i) => router.push(`/dashboard/purchase-orders/${i.purchase_order.uuid}`)}
          isLoading={loading && !data}
          emptyMessage={
            q || state
              ? 'Nothing matches. Clear the search or pick another filter.'
              : 'No supplier invoices yet. Record one when it arrives, or the supplier can upload it in the supplier portal.'
          }
          caption="Purchase invoices"
        />
        <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil((data?.total ?? 0) / PER_PAGE))} totalItems={data?.total ?? 0} perPage={PER_PAGE} onPageChange={setPage} />
      </div>

      <p className="flex items-center gap-2 text-xs text-secondary-500">
        <FileText className="h-3.5 w-3.5" aria-hidden="true" />
        Payments to suppliers are recorded on each purchase order. A payment or credit note pays the oldest invoice of its order first.
      </p>

      <PickPurchaseOrder
        open={picking}
        onClose={() => setPicking(false)}
        onPick={(p) => {
          setPicking(false);
          setPo(p);
        }}
      />
      <InvoiceModal isOpen={!!po} onClose={() => setPo(null)} onSubmit={record} />
    </div>
  );
}

export default function PurchaseInvoicesPage() {
  return (
    <ProtectedPage module="purchase_orders" title="Purchase Invoices">
      <Suspense fallback={null}>
        <PurchaseInvoicesContent />
      </Suspense>
    </ProtectedPage>
  );
}
