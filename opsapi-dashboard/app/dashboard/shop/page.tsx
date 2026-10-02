'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import {
  AlertTriangle,
  BookOpen,
  FileText,
  MessageSquare,
  PoundSterling,
  RefreshCw,
  ShoppingCart,
  TrendingUp,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card } from '@/components/ui';
import StatsCard from '@/components/dashboard/StatsCard';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { OrderStatusBadge, QuoteStatusBadge, SHOP_MODULE, SectionTitle } from '@/components/shop/shared';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { formatMoney, humanize } from '@/lib/shop';
import type { ShopDashboardKpis, ShopOrder, ShopQuote, ShopStockRow } from '@/types/shop';

function OverviewContent() {
  const { canUpdate } = usePermissions();
  const [kpis, setKpis] = useState<ShopDashboardKpis | null>(null);
  const [kpiError, setKpiError] = useState(false);
  const [lowStock, setLowStock] = useState<ShopStockRow[] | null>(null);
  const [orders, setOrders] = useState<ShopOrder[] | null>(null);
  const [quotes, setQuotes] = useState<ShopQuote[] | null>(null);
  const [version, setVersion] = useState(0);
  const [busy, setBusy] = useState<'reconcile' | 'reindex' | null>(null);

  const reload = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let active = true;
    shopService
      .getDashboard()
      .then((k) => {
        if (!active) return;
        setKpis(k);
        setKpiError(false);
      })
      .catch(() => active && setKpiError(true));
    shopService
      .getStock({ low_only: true })
      .then((r) => active && setLowStock(r))
      .catch(() => active && setLowStock([]));
    shopService
      .getOrders({ limit: 6 })
      .then((r) => active && setOrders(r.data))
      .catch(() => active && setOrders([]));
    shopService
      .getQuotes({ limit: 6 })
      .then((r) => active && setQuotes(r.data))
      .catch(() => active && setQuotes([]));
    return () => {
      active = false;
    };
  }, [version]);

  const runReconcile = async () => {
    setBusy('reconcile');
    try {
      const res = await shopService.reconcile();
      const parts = Object.entries(res ?? {})
        .filter(([, v]) => typeof v === 'number')
        .map(([k, v]) => `${humanize(k)}: ${v}`);
      toast.success(`Reconcile complete${parts.length ? ` — ${parts.join(', ')}` : ''}`);
      reload();
    } catch (err) {
      toast.error(extractApiError(err, 'Reconcile failed'));
    } finally {
      setBusy(null);
    }
  };

  const runReindex = async () => {
    setBusy('reindex');
    try {
      await shopService.reindexKnowledge(['products', 'cms_posts']);
      toast.success('Knowledge reindexed (products + blog posts)');
    } catch (err) {
      toast.error(extractApiError(err, 'Reindex failed'));
    } finally {
      setBusy(null);
    }
  };

  const cur = kpis?.currency ?? 'GBP';
  const loading = !kpis && !kpiError;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Shop"
        description="Workstation AI Shop — orders, quotes, stock and the AI sales assistant"
        icon={<ShoppingCart className="h-5 w-5" />}
        actions={
          canUpdate(SHOP_MODULE) ? (
            <>
              <Button variant="ghost" leftIcon={<BookOpen className="h-4 w-4" />} isLoading={busy === 'reindex'} disabled={!!busy} onClick={runReindex}>
                Reindex knowledge
              </Button>
              <Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} isLoading={busy === 'reconcile'} disabled={!!busy} onClick={runReconcile}>
                Run reconcile
              </Button>
            </>
          ) : undefined
        }
      />

      {kpiError && (
        <div className="flex items-center justify-between gap-3 rounded-xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm text-warning-700">
          <span>Could not load shop KPIs. Is the shop feature enabled on this OpsAPI?</span>
          <Button size="sm" variant="ghost" onClick={reload}>Retry</Button>
        </div>
      )}

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatsCard
          title="Orders"
          value={kpis ? kpis.orders_30d : '—'}
          description={kpis ? `${kpis.orders_today} today · ${kpis.orders_7d} in 7 days · 30 days` : undefined}
          icon={<ShoppingCart className="h-5 w-5" />}
          isLoading={loading}
        />
        <StatsCard
          title="Revenue (paid, 30d)"
          value={kpis ? formatMoney(kpis.revenue_paid_30d_minor, cur) : '—'}
          description="Inc VAT"
          icon={<PoundSterling className="h-5 w-5" />}
          isLoading={loading}
        />
        <StatsCard
          title="Open quotes"
          value={kpis ? kpis.open_quotes : '—'}
          description={kpis ? `${formatMoney(kpis.open_quotes_value_minor, cur)} pipeline` : undefined}
          icon={<FileText className="h-5 w-5" />}
          isLoading={loading}
        />
        <StatsCard
          title="Quote → order"
          value={kpis ? `${(kpis.quote_conversion_rate * 100).toFixed(1)}%` : '—'}
          description="Conversion"
          icon={<TrendingUp className="h-5 w-5" />}
          isLoading={loading}
        />
        <StatsCard
          title="Low stock"
          value={kpis ? kpis.low_stock_count : '—'}
          description="Items at or below threshold"
          icon={<AlertTriangle className="h-5 w-5" />}
          isLoading={loading}
        />
        <StatsCard
          title="AI chats (7d)"
          value={kpis ? kpis.chats_7d : '—'}
          description="Assistant sessions"
          icon={<MessageSquare className="h-5 w-5" />}
          isLoading={loading}
        />
      </div>

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        <Card>
          <SectionTitle actions={<Link href="/dashboard/shop/stock" className="text-sm text-primary-600 hover:underline">Stock sheet</Link>}>
            Low stock
          </SectionTitle>
          {lowStock === null ? (
            <p className="text-sm text-secondary-500">Loading…</p>
          ) : lowStock.length === 0 ? (
            <p className="text-sm text-secondary-500">Nothing is low on stock.</p>
          ) : (
            <ul className="divide-y divide-secondary-100">
              {lowStock.slice(0, 8).map((r) => (
                <li key={`${r.kind}:${r.uuid}`} className="flex items-center justify-between gap-3 py-2">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-secondary-900">{r.product_name}</p>
                    {r.kind === 'option' && <p className="truncate text-xs text-secondary-500">{r.group_name ? `${r.group_name}: ` : ''}{r.option_name}</p>}
                  </div>
                  <span className="shrink-0 text-sm font-semibold tabular-nums text-error-600">
                    {r.available}
                    <span className="font-normal text-secondary-400"> / {r.low_stock_threshold}</span>
                  </span>
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card>
          <SectionTitle actions={<Link href="/dashboard/shop/orders" className="text-sm text-primary-600 hover:underline">All orders</Link>}>
            Latest orders
          </SectionTitle>
          {orders === null ? (
            <p className="text-sm text-secondary-500">Loading…</p>
          ) : orders.length === 0 ? (
            <p className="text-sm text-secondary-500">No orders yet.</p>
          ) : (
            <ul className="divide-y divide-secondary-100">
              {orders.map((o) => (
                <li key={o.uuid}>
                  <Link href={`/dashboard/shop/orders/${o.uuid}`} className="-mx-2 flex items-center justify-between gap-3 rounded-lg px-2 py-2 hover:bg-secondary-50">
                    <div className="min-w-0">
                      <p className="font-mono text-sm font-medium text-secondary-900">{o.order_number}</p>
                      <p className="truncate text-xs text-secondary-500">{o.customer?.company || o.customer?.name || o.email} · {formatDateTime(o.created_at)}</p>
                    </div>
                    <div className="shrink-0 text-right">
                      <p className="text-sm font-medium tabular-nums">{formatMoney(o.total_minor, o.currency)}</p>
                      <OrderStatusBadge status={o.status} />
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card>
          <SectionTitle actions={<Link href="/dashboard/shop/quotes" className="text-sm text-primary-600 hover:underline">All quotes</Link>}>
            Latest quotes
          </SectionTitle>
          {quotes === null ? (
            <p className="text-sm text-secondary-500">Loading…</p>
          ) : quotes.length === 0 ? (
            <p className="text-sm text-secondary-500">No quotes yet.</p>
          ) : (
            <ul className="divide-y divide-secondary-100">
              {quotes.map((q) => (
                <li key={q.uuid}>
                  <Link href={`/dashboard/shop/quotes/${q.uuid}`} className="-mx-2 flex items-center justify-between gap-3 rounded-lg px-2 py-2 hover:bg-secondary-50">
                    <div className="min-w-0">
                      <p className="font-mono text-sm font-medium text-secondary-900">{q.quote_number}</p>
                      <p className="truncate text-xs text-secondary-500">{q.customer?.company || q.customer?.name || q.customer?.email} · {formatDateTime(q.created_at)}</p>
                    </div>
                    <div className="shrink-0 text-right">
                      <p className="text-sm font-medium tabular-nums">{formatMoney(q.subtotal_minor, q.currency)} <span className="text-xs font-normal text-secondary-400">ex VAT</span></p>
                      <QuoteStatusBadge status={q.status} />
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
    </div>
  );
}

export default function ShopOverviewPage() {
  return (
    <ProtectedPage module="shop" title="Shop">
      <OverviewContent />
    </ProtectedPage>
  );
}
