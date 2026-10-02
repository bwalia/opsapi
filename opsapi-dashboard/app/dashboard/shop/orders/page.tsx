'use client';

import React, { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Search, ShoppingCart } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Card, Input, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { shopService } from '@/services/shop.service';
import { FilterSelect, OrderStatusBadge } from '@/components/shop/shared';
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
      .getOrders({ status, q: q || undefined, limit: PER_PAGE, offset: (page - 1) * PER_PAGE })
      .then((res) => {
        if (!active) return;
        setRows(res.data);
        setTotal(res.meta.total);
      })
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load orders')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [status, q, page]);

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
          <p className="truncate text-secondary-900">{o.customer?.name || o.email || '—'}</p>
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
    { key: 'status', header: 'Status', render: (o) => <OrderStatusBadge status={o.status} /> },
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
      <PageHeader title="Shop orders" description="Orders placed through Stripe Checkout on the shop" icon={<ShoppingCart className="h-5 w-5" />} />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input placeholder="Order number, email, company…" aria-label="Search orders" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <FilterSelect
            aria-label="Status"
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
