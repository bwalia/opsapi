'use client';

/**
 * Sales Orders: every order of the workspace in one list — orders from the shop (online checkout, orders built by
 * staff for a customer on the phone, accepted quotes) and from online stores (checkout, or created here by staff).
 * Shop orders open their own page; store orders open here. Data: GET /api/v2/sales-orders.
 */
import React, { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { CheckCircle2, ChevronDown, Clock, Package, Plus, PoundSterling, RefreshCw, Search, ShoppingCart, Truck } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import StatsCard from '@/components/dashboard/StatsCard';
import { Badge, Button, Card, Input, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useMenu } from '@/hooks/useMenu';
import { useAuthStore } from '@/store/auth.store';
import { CreateOrderModal } from '@/components/orders/CreateOrderModal';
import { StoreOrderDetailsModal } from '@/components/orders/StoreOrderDetailsModal';
import { ordersService } from '@/services/orders.service';
import {
  salesOrdersService,
  type SalesOrder,
  type SalesOrderChannel,
  type SalesOrderList,
  type SalesOrderStageFilter,
} from '@/services/sales-orders.service';
import { extractApiError, formatDateTime } from '@/lib/utils';
import type { Order, TableColumn } from '@/types';

const PER_PAGE = 25;

const STAGES: { value: SalesOrderStageFilter; label: string }[] = [
  { value: '', label: 'All statuses' },
  { value: 'awaiting_payment', label: 'Awaiting payment' },
  { value: 'in_progress', label: 'In progress' },
  { value: 'confirmed', label: 'Confirmed' },
  { value: 'processing', label: 'Processing' },
  { value: 'shipped', label: 'Shipped' },
  { value: 'delivered', label: 'Delivered' },
  { value: 'cancelled', label: 'Cancelled' },
  { value: 'refunded', label: 'Refunded' },
  { value: 'failed', label: 'Payment failed' },
];

const STAGE_BADGE: Record<SalesOrder['stage'], { label: string; variant: 'success' | 'warning' | 'error' | 'info' | 'secondary' | 'default' }> = {
  awaiting_payment: { label: 'Awaiting payment', variant: 'warning' },
  confirmed: { label: 'Confirmed', variant: 'info' },
  processing: { label: 'Processing', variant: 'info' },
  shipped: { label: 'Shipped', variant: 'info' },
  delivered: { label: 'Delivered', variant: 'success' },
  cancelled: { label: 'Cancelled', variant: 'secondary' },
  refunded: { label: 'Refunded', variant: 'secondary' },
  failed: { label: 'Payment failed', variant: 'error' },
};

const CHANNELS: { value: SalesOrderChannel | ''; label: string }[] = [
  { value: '', label: 'All channels' },
  { value: 'online', label: 'Online' },
  { value: 'phone', label: 'Phone' },
  { value: 'in_person', label: 'In person' },
  { value: 'email', label: 'Email' },
  { value: 'pos', label: 'Point of sale' },
  { value: 'staff', label: 'Built by staff (shop)' },
  { value: 'quote', label: 'From a quote' },
];

const CHANNEL_LABEL: Record<SalesOrderChannel, string> = {
  online: 'Online', phone: 'Phone', in_person: 'In person', email: 'Email', pos: 'Point of sale', staff: 'Built by staff', quote: 'From a quote',
};

function money(v: string | number, currency = 'GBP') {
  try {
    return new Intl.NumberFormat('en-GB', { style: 'currency', currency }).format(Number(v) || 0);
  } catch {
    return `${Number(v).toFixed(2)} ${currency}`;
  }
}

const selectClass =
  'rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm text-secondary-800 focus:outline-none focus:ring-2 focus:ring-primary-500/30';

function SalesOrdersContent() {
  const router = useRouter();
  const params = useSearchParams();
  const { allMenu } = useMenu();
  const { canCreate } = usePermissions();
  const { user } = useAuthStore();
  const hasShop = allMenu.some((m) => m.key === 'shop');
  const urlStage = (params.get('stage') ?? '') as SalesOrderStageFilter;
  const stage: SalesOrderStageFilter = STAGES.some((s) => s.value === urlStage) ? urlStage : '';

  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [channel, setChannel] = useState<SalesOrderChannel | ''>('');
  const [source, setSource] = useState<'shop' | 'store' | ''>('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const [data, setData] = useState<SalesOrderList | null>(null);
  const [loading, setLoading] = useState(true);
  const [version, setVersion] = useState(0);
  const [storeOrder, setStoreOrder] = useState<Order | null>(null);
  const [creating, setCreating] = useState(false);
  const [chooser, setChooser] = useState(false);
  const chooserRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const t = setTimeout(() => {
      setQ(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let active = true;
    salesOrdersService
      .list({ q, stage, channel, source, from, to, page, per_page: PER_PAGE })
      .then((r) => active && setData(r))
      .catch((e) => active && toast.error(extractApiError(e, 'Could not load orders')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [q, stage, channel, source, from, to, page, version]);

  // Close the "Create order" choice when clicking elsewhere.
  useEffect(() => {
    if (!chooser) return;
    const close = (e: MouseEvent) => {
      if (chooserRef.current && !chooserRef.current.contains(e.target as Node)) setChooser(false);
    };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [chooser]);

  const setStage = useCallback(
    (s: SalesOrderStageFilter) => {
      setPage(1);
      router.replace(s ? `/dashboard/orders?stage=${s}` : '/dashboard/orders');
    },
    [router]
  );

  const open = useCallback(
    async (o: SalesOrder) => {
      if (o.path) {
        router.push(o.path);
        return;
      }
      try {
        setStoreOrder(await ordersService.getOrder(o.uuid));
      } catch (e) {
        toast.error(extractApiError(e, 'Could not open the order'));
      }
    },
    [router]
  );

  const sources = data?.sources ?? [];
  const canShopOrder = hasShop && canCreate('shop');
  const canStoreOrder = sources.includes('store') && canCreate('orders');
  const revenue = data ? Object.entries(data.stats.revenue) : [];
  const mainRevenue = revenue.find(([c]) => c === 'GBP') ?? revenue[0];
  const isAdmin = !!user?.roles?.some((r) => r.role_name === 'administrative');

  const createOrder = () => {
    if (canShopOrder && canStoreOrder) setChooser((v) => !v);
    else if (canShopOrder) router.push('/dashboard/shop/quotes/new');
    else setCreating(true);
  };

  const columns: TableColumn<SalesOrder>[] = useMemo(
    () => [
      {
        key: 'order_number',
        header: 'Order',
        render: (o) => (
          <div>
            <p className="font-mono font-medium text-secondary-900">{o.order_number}</p>
            <p className="text-xs text-secondary-500">
              {o.source === 'shop' ? 'Shop' : 'Online store'} · {CHANNEL_LABEL[o.channel] ?? o.channel}
            </p>
          </div>
        ),
      },
      {
        key: 'customer',
        header: 'Customer',
        render: (o) => (
          <div className="min-w-0">
            <p className="truncate text-secondary-900">{o.company || o.customer_name || o.customer_email || '—'}</p>
            <p className="truncate text-xs text-secondary-500">{o.company ? o.customer_name || o.customer_email : o.customer_name ? o.customer_email : ''}</p>
          </div>
        ),
      },
      {
        key: 'total',
        header: 'Total',
        render: (o) => <span className="font-medium tabular-nums">{money(o.total, o.currency)}</span>,
      },
      {
        key: 'stage',
        header: 'Status',
        render: (o) => (
          <div className="flex flex-col items-start gap-1">
            <Badge variant={STAGE_BADGE[o.stage]?.variant ?? 'default'}>{STAGE_BADGE[o.stage]?.label ?? o.stage}</Badge>
            {o.payment === 'paid' && o.stage !== 'awaiting_payment' && <span className="text-xs text-success-700">Paid</span>}
          </div>
        ),
      },
      {
        key: 'placed_at',
        header: 'Placed',
        render: (o) => <span className="text-sm text-secondary-600">{formatDateTime(o.placed_at)}</span>,
      },
    ],
    []
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Sales Orders"
        description="Every order in one place, however it came in: online, by phone, by email or in person, from your shop and your online stores."
        icon={<ShoppingCart className="h-5 w-5" />}
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" leftIcon={<RefreshCw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />} onClick={() => setVersion((v) => v + 1)}>
              Refresh
            </Button>
            {(canShopOrder || canStoreOrder) && (
              <div className="relative" ref={chooserRef}>
                <Button
                  leftIcon={<Plus className="h-4 w-4" />}
                  rightIcon={canShopOrder && canStoreOrder ? <ChevronDown className="h-4 w-4" /> : undefined}
                  onClick={createOrder}
                  aria-haspopup={canShopOrder && canStoreOrder ? 'menu' : undefined}
                  aria-expanded={canShopOrder && canStoreOrder ? chooser : undefined}
                >
                  Create order
                </Button>
                {chooser && (
                  <div role="menu" className="absolute right-0 z-20 mt-2 w-72 overflow-hidden rounded-xl border border-secondary-200 bg-surface shadow-lg">
                    <button role="menuitem" type="button" className="block w-full px-4 py-3 text-left hover:bg-secondary-50"
                      onClick={() => router.push('/dashboard/shop/quotes/new')}>
                      <span className="block text-sm font-medium text-secondary-900">Shop order</span>
                      <span className="block text-xs text-secondary-500">For a customer on the phone or by email: they confirm it and pay online or by bank transfer.</span>
                    </button>
                    <button role="menuitem" type="button" className="block w-full border-t border-secondary-100 px-4 py-3 text-left hover:bg-secondary-50"
                      onClick={() => { setChooser(false); setCreating(true); }}>
                      <span className="block text-sm font-medium text-secondary-900">Online store order</span>
                      <span className="block text-xs text-secondary-500">Products from one of your online stores; mark it paid if they already paid.</span>
                    </button>
                  </div>
                )}
              </div>
            )}
          </div>
        }
      />

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <StatsCard title="Total orders" value={data ? data.stats.total : '—'} icon={<Package className="h-5 w-5" />} isLoading={loading && !data} href="/dashboard/orders" />
        <StatsCard title="Awaiting payment" value={data ? data.stats.awaiting_payment : '—'} icon={<Clock className="h-5 w-5" />} isLoading={loading && !data}
          href="/dashboard/orders?stage=awaiting_payment" />
        <StatsCard title="In progress" value={data ? data.stats.in_progress : '—'} description="Confirmed, processing or shipped" icon={<Truck className="h-5 w-5" />}
          isLoading={loading && !data} href="/dashboard/orders?stage=in_progress" />
        <StatsCard title="Delivered" value={data ? data.stats.delivered : '—'} icon={<CheckCircle2 className="h-5 w-5" />} isLoading={loading && !data}
          href="/dashboard/orders?stage=delivered" />
        <StatsCard title="Paid" value={mainRevenue ? money(mainRevenue[1], mainRevenue[0]) : data ? money(0) : '—'}
          description={revenue.length > 1 ? revenue.filter((r) => r !== mainRevenue).map(([c, v]) => money(v, c)).join(' · ') : 'Orders paid'}
          icon={<PoundSterling className="h-5 w-5" />} isLoading={loading && !data} />
      </div>

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-3">
          <div className="min-w-[220px] max-w-sm flex-1">
            <Input placeholder="Order number, customer, email…" aria-label="Search orders" value={search} onChange={(e) => setSearch(e.target.value)}
              leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <select aria-label="Status" className={selectClass} value={stage} onChange={(e) => setStage(e.target.value as SalesOrderStageFilter)}>
            {STAGES.map((s) => <option key={s.value || 'all'} value={s.value}>{s.label}</option>)}
          </select>
          <select aria-label="Channel" className={selectClass} value={channel} onChange={(e) => { setChannel(e.target.value as SalesOrderChannel | ''); setPage(1); }}>
            {CHANNELS.map((c) => <option key={c.value || 'all'} value={c.value}>{c.label}</option>)}
          </select>
          {sources.length > 1 && (
            <select aria-label="Where from" className={selectClass} value={source} onChange={(e) => { setSource(e.target.value as 'shop' | 'store' | ''); setPage(1); }}>
              <option value="">Shop and online stores</option>
              <option value="shop">Shop only</option>
              <option value="store">Online stores only</option>
            </select>
          )}
          <label className="flex items-center gap-2 text-sm text-secondary-600">
            From <input type="date" className={selectClass} value={from} onChange={(e) => { setFrom(e.target.value); setPage(1); }} />
          </label>
          <label className="flex items-center gap-2 text-sm text-secondary-600">
            To <input type="date" className={selectClass} value={to} onChange={(e) => { setTo(e.target.value); setPage(1); }} />
          </label>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={data?.data ?? []}
          keyExtractor={(o) => `${o.source}:${o.uuid}`}
          onRowClick={open}
          isLoading={loading && !data}
          emptyMessage={q || stage || channel || source || from || to ? 'No orders match. Clear the search or the filters.' : 'No orders yet.'}
          caption="Sales orders"
        />
        <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil((data?.total ?? 0) / PER_PAGE))} totalItems={data?.total ?? 0}
          perPage={PER_PAGE} onPageChange={setPage} />
      </div>

      <CreateOrderModal open={creating} onClose={() => setCreating(false)} onCreated={() => setVersion((v) => v + 1)} hasShop={hasShop} />
      <StoreOrderDetailsModal order={storeOrder} isOpen={!!storeOrder} onClose={() => setStoreOrder(null)} isAdmin={isAdmin} />
    </div>
  );
}

export default function OrdersPage() {
  return (
    <ProtectedPage module={['orders', 'shop']} title="Sales Orders">
      <Suspense fallback={null}>
        <SalesOrdersContent />
      </Suspense>
    </ProtectedPage>
  );
}
