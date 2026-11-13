'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Landmark, Plus, Search, ShoppingCart } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { shopService } from '@/services/shop.service';
import { FilterSelect, OrderStatusBadge } from '@/components/shop/shared';
import { VipBadge } from '@/components/shop/VipBadge';
import { useVipStatus } from '@/hooks/useVipStatus';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { formatMoney, humanize } from '@/lib/shop';
import { SHOP_ORDER_STATUSES, type ShopOrder, type ShopOrderStatus, type TableColumn } from '@/types';

const PER_PAGE = 25;

function OrdersContent() {
  const router = useRouter();
  const [rows, setRows] = useState<ShopOrder[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [status, setStatus] = useState<ShopOrderStatus | ''>('');
  const [page, setPage] = useState(1);
  // "Bank transfer due": orders awaiting a bank transfer, oldest first.
  const [btDue, setBtDue] = useState(false);
  const [btDueCount, setBtDueCount] = useState(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setQ(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let active = true;
    shopService
      .getOrders({
        status: btDue ? '' : status,
        q: q || undefined,
        bank_transfer_due: btDue,
        limit: PER_PAGE,
        offset: (page - 1) * PER_PAGE,
      })
      .then((res) => {
        if (!active) return;
        setRows(res.data);
        setTotal(res.meta.total);
        setBtDueCount(res.bankTransferDue);
      })
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load orders')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [status, q, page, btDue]);

  const vips = useVipStatus(rows.map((o) => o.email));

  const columns: TableColumn<ShopOrder>[] = [
    {
      key: 'order_number',
      header: 'Order',
      render: (o) => (
        <div>
          <p className="font-mono font-medium text-secondary-900">{o.order_number}</p>
          <p className="text-xs text-secondary-500">{o.lines?.length ?? 0} line{o.lines?.length === 1 ? '' : 's'}</p>
        </div>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      render: (o) => (
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <p className="truncate text-secondary-900">{o.customer?.name || o.email || '—'}</p>
            <VipBadge vip={vips[(o.email ?? '').toLowerCase()]} />
          </div>
          <p className="truncate text-xs text-secondary-500">{o.customer?.company || (o.customer?.name ? o.email : '')}</p>
        </div>
      ),
    },
    {
      key: 'total',
      header: 'Total (inc VAT)',
      render: (o) => (
        <div>
          <p className="font-medium tabular-nums">{formatMoney(o.total_minor, o.currency)}</p>
          <p className="text-xs tabular-nums text-secondary-500">{formatMoney(o.subtotal_minor, o.currency)} ex VAT</p>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (o) => (
        <div className="flex flex-col items-start gap-1">
          <OrderStatusBadge status={o.status} />
          {o.bank_transfer_due && (
            <span className="inline-flex items-center rounded-full bg-warning-50 px-2 py-0.5 text-xs font-medium text-warning-700">
              <Landmark className="mr-1 h-3 w-3" /> Bank transfer due
              {typeof o.days_waiting === 'number' && ` · ${o.days_waiting === 0 ? 'today' : `${o.days_waiting} day${o.days_waiting === 1 ? '' : 's'}`}`}
            </span>
          )}
        </div>
      ),
    },
    {
      key: 'created_at',
      header: 'Placed',
      render: (o) => (
        <div className="text-sm text-secondary-600">
          <p>{formatDateTime(o.created_at)}</p>
          {o.paid_at && <p className="text-xs text-success-600">Paid {formatDateTime(o.paid_at)}</p>}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Shop orders"
        description="Paid and pending orders. Build an order for a customer with Create order: they confirm it and pay online."
        icon={<ShoppingCart className="h-5 w-5" />}
        actions={
          <Link href="/dashboard/shop/quotes/new">
            <Button leftIcon={<Plus className="h-4 w-4" />}>Create order</Button>
          </Link>
        }
      />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input placeholder="Order number, email, company…" aria-label="Search orders" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <button
            type="button"
            aria-pressed={btDue}
            onClick={() => {
              setBtDue((v) => !v);
              setPage(1);
            }}
            className={`inline-flex items-center gap-2 rounded-lg border px-3 py-2 text-sm font-medium transition ${
              btDue
                ? 'border-warning-400 bg-warning-50 text-warning-800'
                : 'border-secondary-300 bg-surface text-secondary-700 hover:border-warning-300'
            }`}
          >
            <Landmark className="h-4 w-4" /> Bank transfer due
            <span className={`rounded-full px-1.5 text-xs ${btDueCount > 0 ? 'bg-warning-500 text-white' : 'bg-secondary-200 text-secondary-600'}`}>
              {btDueCount}
            </span>
          </button>
          <FilterSelect
            aria-label="Status"
            disabled={btDue}
            value={status}
            onChange={(e) => {
              setStatus(e.target.value as ShopOrderStatus | '');
              setPage(1);
            }}
          >
            <option value="">All statuses</option>
            {SHOP_ORDER_STATUSES.map((s) => (
              <option key={s} value={s}>{humanize(s)}</option>
            ))}
          </FilterSelect>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(o) => o.uuid}
          onRowClick={(o) => router.push(`/dashboard/shop/orders/${o.uuid}`)}
          isLoading={loading}
          emptyMessage="No orders found"
          caption="Shop orders"
        />
        <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil(total / PER_PAGE))} totalItems={total} perPage={PER_PAGE} onPageChange={setPage} />
      </div>
    </div>
  );
}

export default function ShopOrdersPage() {
  return (
    <ProtectedPage module="shop" title="Shop Orders">
      <OrdersContent />
    </ProtectedPage>
  );
}
