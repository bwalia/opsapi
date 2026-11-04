'use client';

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  BarChart3,
  Bot,
  ChevronDown,
  CreditCard,
  Download,
  EyeOff,
  FileText,
  Info,
  PoundSterling,
  Receipt,
  RefreshCw,
  ShoppingBasket,
  ShoppingCart,
  Users,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { SectionTitle } from '@/components/shop/shared';
import {
  BarList,
  Funnel,
  KpiTile,
  Row,
  Stat,
  TREND_METRICS,
  TrendChart,
  count,
  longDate,
  pct,
  pounds,
  type TrendMetric,
} from '@/components/shop/analytics/parts';
import { SHOP_ANALYTICS_MODULE, shopAnalyticsService } from '@/services/shop-analytics.service';
import { cn, extractApiError } from '@/lib/utils';
import { formatMoney } from '@/lib/shop';
import type { ShopAnalyticsExport, ShopAnalyticsQuery, ShopAnalyticsReport } from '@/types/shop-analytics';

type Preset = '7' | '30' | '90' | '365' | 'custom';
const PRESETS: { key: Preset; label: string }[] = [
  { key: '7', label: '7 days' },
  { key: '30', label: '30 days' },
  { key: '90', label: '90 days' },
  { key: '365', label: '12 months' },
  { key: 'custom', label: 'Custom' },
];

const EXPORTS: { key: ShopAnalyticsExport; label: string }[] = [
  { key: 'daily', label: 'Trend by period' },
  { key: 'products', label: 'Products' },
  { key: 'chat_tools', label: 'AI tool use' },
];

const TOOL_LABELS: Record<string, string> = {
  search_catalog: 'Searched the catalogue',
  get_product: 'Looked up a product',
  price_configuration: 'Priced a configuration',
  add_to_cart: 'Added to cart',
  update_cart_line: 'Changed a cart line',
  remove_cart_line: 'Removed a cart line',
  view_cart: 'Viewed the cart',
  search_knowledge: 'Searched guides',
  create_quote: 'Created a quote',
  start_checkout: 'Started checkout',
  record_requirements: 'Recorded requirements',
  get_membership_offer: 'Offered Trade membership',
  check_market_prices: 'Checked market prices',
};

const regionNames = (() => {
  try {
    return new Intl.DisplayNames(['en-GB'], { type: 'region' });
  } catch {
    return null;
  }
})();
const countryName = (code?: string | null) => {
  if (!code) return 'Unknown';
  try {
    return regionNames?.of(code) ?? code;
  } catch {
    return code;
  }
};

function AnalyticsContent() {
  const [preset, setPreset] = useState<Preset>('30');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [query, setQuery] = useState<ShopAnalyticsQuery>({ days: 30 });
  const [report, setReport] = useState<ShopAnalyticsReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [metric, setMetric] = useState<TrendMetric>('revenue_minor');
  const [exporting, setExporting] = useState<ShopAnalyticsExport | null>(null);
  const [exportOpen, setExportOpen] = useState(false);
  const [version, setVersion] = useState(0);
  const exportRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const ctrl = new AbortController();
    setLoading(true);
    setError(null);
    shopAnalyticsService
      .getReport(query, ctrl.signal)
      .then((r) => {
        setReport(r);
        if (r?.window) {
          setFrom(r.window.from);
          setTo(r.window.to);
        }
      })
      .catch((err) => {
        if (ctrl.signal.aborted) return;
        setError(extractApiError(err, 'Could not load shop analytics'));
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoading(false);
      });
    return () => ctrl.abort();
  }, [query, version]);

  useEffect(() => {
    if (!exportOpen) return;
    const close = (e: MouseEvent) => {
      if (exportRef.current && !exportRef.current.contains(e.target as Node)) setExportOpen(false);
    };
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && setExportOpen(false);
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', esc);
    return () => {
      document.removeEventListener('mousedown', close);
      document.removeEventListener('keydown', esc);
    };
  }, [exportOpen]);

  const choosePreset = (p: Preset) => {
    setPreset(p);
    if (p !== 'custom') setQuery({ days: Number(p) });
  };

  const applyCustom = (e: React.FormEvent) => {
    e.preventDefault();
    if (!from || !to) return toast.error('Choose both dates');
    if (from > to) return toast.error('The start date must be on or before the end date');
    setQuery({ from, to });
  };

  const download = useCallback(
    async (key: ShopAnalyticsExport) => {
      setExportOpen(false);
      setExporting(key);
      try {
        const { blob, filename } = await shopAnalyticsService.downloadCsv(key, query);
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = filename;
        a.click();
        URL.revokeObjectURL(url);
      } catch (err) {
        toast.error(extractApiError(err, 'CSV export failed'));
      } finally {
        setExporting(null);
      }
    },
    [query]
  );

  const r = report;
  const ch = r?.changes ?? {};
  const busy = loading && !r;
  const cur = r?.currency ?? 'GBP';
  const prevLabel = r ? `${longDate(r.window.previous.from)} – ${longDate(r.window.previous.to)}` : '';

  const seriesTotal = useMemo(() => {
    if (!r) return null;
    return r.series.reduce((s, p) => s + (Number(p[metric]) || 0), 0);
  }, [r, metric]);
  const metricMeta = TREND_METRICS.find((m) => m.key === metric)!;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Shop Analytics"
        description="Sales, checkout, carts, quotes and the AI advisor, from shop orders and chat transcripts"
        icon={<BarChart3 className="h-5 w-5" />}
        actions={
          <>
            <Button
              variant="ghost"
              leftIcon={<RefreshCw className={cn('h-4 w-4', loading && r && 'animate-spin')} />}
              onClick={() => setVersion((v) => v + 1)}
              disabled={loading}
            >
              Refresh
            </Button>
            <div className="relative" ref={exportRef}>
              <Button
                variant="outline"
                leftIcon={<Download className="h-4 w-4" />}
                rightIcon={<ChevronDown className="h-4 w-4" />}
                isLoading={!!exporting}
                disabled={!r}
                onClick={() => setExportOpen((o) => !o)}
                aria-haspopup="menu"
                aria-expanded={exportOpen}
              >
                Export CSV
              </Button>
              {exportOpen && (
                <div
                  role="menu"
                  className="absolute right-0 z-20 mt-2 w-52 overflow-hidden rounded-xl border border-secondary-200 bg-surface py-1 shadow-lg"
                >
                  {EXPORTS.map((x) => (
                    <button
                      key={x.key}
                      role="menuitem"
                      type="button"
                      className="block w-full px-4 py-2 text-left text-sm text-secondary-700 hover:bg-secondary-50"
                      onClick={() => download(x.key)}
                    >
                      {x.label}
                    </button>
                  ))}
                </div>
              )}
            </div>
          </>
        }
      />

      {/* Period ------------------------------------------------------------- */}
      <Card padding="sm" className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex flex-wrap items-center gap-1 rounded-xl bg-secondary-100 p-1" role="group" aria-label="Period">
          {PRESETS.map((p) => (
            <button
              key={p.key}
              type="button"
              onClick={() => choosePreset(p.key)}
              aria-pressed={preset === p.key}
              className={cn(
                'rounded-lg px-3 py-1.5 text-sm font-medium transition-colors',
                preset === p.key ? 'bg-primary-500 text-white shadow-sm' : 'text-secondary-600 hover:text-secondary-900'
              )}
            >
              {p.label}
            </button>
          ))}
        </div>
        {preset === 'custom' ? (
          <form onSubmit={applyCustom} className="flex flex-wrap items-end gap-2">
            <div className="w-40">
              <Input label="From" type="date" value={from} max={to || undefined} onChange={(e) => setFrom(e.target.value)} />
            </div>
            <div className="w-40">
              <Input label="To" type="date" value={to} min={from || undefined} onChange={(e) => setTo(e.target.value)} />
            </div>
            <Button type="submit" disabled={loading}>Apply</Button>
          </form>
        ) : (
          r && (
            <p className="text-sm text-secondary-500">
              <span className="font-medium text-secondary-800">{longDate(r.window.from)} – {longDate(r.window.to)}</span>
              {' · '}compared with {prevLabel}
            </p>
          )
        )}
      </Card>

      {error && (
        <div className="flex items-center justify-between gap-3 rounded-xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm text-warning-700" role="alert">
          <span>{error}</span>
          <Button size="sm" variant="ghost" onClick={() => setVersion((v) => v + 1)}>Retry</Button>
        </div>
      )}

      {/* Headline KPIs ------------------------------------------------------ */}
      <div className={cn('grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4', loading && r && 'opacity-70 transition-opacity')}>
        <KpiTile
          label="Revenue"
          value={r ? pounds(r.sales.revenue_minor) : '—'}
          change={ch.revenue_minor}
          sub={r ? `${pounds(r.sales.net_revenue_minor)} after refunds` : undefined}
          icon={<PoundSterling />}
          loading={busy}
          hint="Inc VAT and shipping, orders paid in the period"
        />
        <KpiTile
          label="Paid orders"
          value={r ? count(r.sales.orders) : '—'}
          change={ch.orders}
          sub={r && r.sales.refunded_orders > 0 ? `${count(r.sales.refunded_orders)} refunded` : undefined}
          icon={<Receipt />}
          loading={busy}
        />
        <KpiTile
          label="Average order"
          value={r ? pounds(r.sales.aov_minor) : '—'}
          change={ch.aov_minor}
          sub="inc VAT"
          icon={<CreditCard />}
          loading={busy}
        />
        <KpiTile
          label="Customers"
          value={r ? count(r.sales.customers) : '—'}
          change={ch.customers}
          sub={r ? `${count(r.sales.new_customers)} new · ${count(r.sales.returning_customers)} returning` : undefined}
          icon={<Users />}
          loading={busy}
          hint="Distinct buyer emails with a paid order in the period"
        />
        <KpiTile
          label="Checkout → paid"
          value={r ? pct(r.checkout.paid_rate) : '—'}
          change={null}
          sub={r ? `${count(r.checkout.paid)} of ${count(r.checkout.started)} checkouts` : undefined}
          icon={<ShoppingCart />}
          loading={busy}
        />
        <KpiTile
          label="Abandoned carts"
          value={r ? count(r.carts.abandoned) : '—'}
          change={ch.abandoned}
          lowerIsBetter
          sub={r ? `${pounds(r.carts.abandoned_value_minor)} ex VAT left behind` : undefined}
          icon={<ShoppingBasket />}
          loading={busy}
          hint={`Items in the cart, never paid, untouched for ${r?.carts.abandon_after_hours ?? 24} hours`}
        />
        <KpiTile
          label="Quotes"
          value={r ? count(r.quotes.created) : '—'}
          change={ch.quotes}
          sub={r ? `${pct(r.quotes.conversion_rate)} became orders` : undefined}
          icon={<FileText />}
          loading={busy}
        />
        <KpiTile
          label="AI chats completed"
          value={r ? count(r.chat.completed) : '—'}
          change={ch.chat_completed}
          sub={r ? `${pct(r.chat.completion_rate)} of ${count(r.chat.chats)} chats` : undefined}
          icon={<Bot />}
          loading={busy}
          hint="The AI replied and the chat led to saved contact details, a quote, an add-to-cart or an order"
        />
      </div>

      {/* Trend --------------------------------------------------------------- */}
      <Card>
        <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 className="text-base font-semibold text-secondary-900">Trend</h2>
            {r && seriesTotal !== null && (
              <p className="text-sm text-secondary-500">
                <span className="font-medium tabular-nums text-secondary-800">
                  {metricMeta.money ? formatMoney(seriesTotal, cur) : count(seriesTotal)}
                </span>{' '}
                {metricMeta.label.toLowerCase()} · per {r.window.bucket}
                {metric === 'revenue_minor' && ' · inc VAT'}
              </p>
            )}
          </div>
          <div className="flex flex-wrap gap-1" role="tablist" aria-label="Trend metric">
            {TREND_METRICS.map((m) => (
              <button
                key={m.key}
                type="button"
                role="tab"
                aria-selected={metric === m.key}
                onClick={() => setMetric(m.key)}
                className={cn(
                  'rounded-full px-3 py-1 text-xs font-medium transition-colors',
                  metric === m.key
                    ? 'bg-primary-500 text-white'
                    : 'bg-secondary-100 text-secondary-600 hover:bg-secondary-200 hover:text-secondary-900'
                )}
              >
                {m.label}
              </button>
            ))}
          </div>
        </div>
        {r ? (
          <TrendChart series={r.series} bucket={r.window.bucket} metric={metric} />
        ) : (
          <div className="h-64 animate-pulse rounded-xl bg-secondary-100" />
        )}
      </Card>

      {r && (
        <>
          {/* Funnel + sales breakdown ---------------------------------------- */}
          <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
            <Card className="xl:col-span-2">
              <SectionTitle>Cart to order</SectionTitle>
              <Funnel
                steps={[
                  { label: 'Carts with items', value: r.carts.with_items },
                  { label: 'Reached checkout', value: r.carts.reached_checkout },
                  { label: 'Paid', value: r.carts.converted },
                ]}
              />
              <div className="mt-5 grid grid-cols-2 gap-2 sm:grid-cols-4">
                <Stat label="Cart conversion" value={pct(r.carts.conversion_rate)} hint="Paid carts ÷ carts with items" />
                <Stat
                  label="Abandonment"
                  value={pct(r.carts.abandonment_rate)}
                  hint="Abandoned ÷ (abandoned + paid); carts still open are left out"
                />
                <Stat label="Still open" value={count(r.carts.open)} hint={`Touched in the last ${r.carts.abandon_after_hours} hours`} />
                <Stat label="Failed payments" value={count(r.checkout.payment_failed)} />
              </div>
              <p className="mt-3 text-xs text-secondary-500">
                Carts created in the period. {count(r.checkout.from_quote)} checkout
                {r.checkout.from_quote === 1 ? '' : 's'} started from a quote rather than a cart.
              </p>
            </Card>

            <Card>
              <SectionTitle>Sales breakdown</SectionTitle>
              <dl>
                <Row label="Revenue (inc VAT)" value={formatMoney(r.sales.revenue_minor, cur)} />
                <Row label="VAT" value={formatMoney(r.sales.vat_minor, cur)} muted />
                <Row label="Shipping" value={formatMoney(r.sales.shipping_minor, cur)} muted />
                <Row label="Revenue ex VAT" value={formatMoney(r.sales.revenue_ex_vat_minor, cur)} />
                <Row label="Refunds" value={`−${formatMoney(r.sales.refunds_minor, cur)}`} />
                <Row label="Net revenue" value={formatMoney(r.sales.net_revenue_minor, cur)} strong />
                {(r.sales.trade_discount_minor > 0 || r.sales.credit_used_minor > 0) && (
                  <>
                    <Row label="Trade discount given" value={formatMoney(r.sales.trade_discount_minor, cur)} muted />
                    <Row label="Credit used" value={formatMoney(r.sales.credit_used_minor, cur)} muted />
                  </>
                )}
              </dl>
              {r.trade && (
                <div className="mt-4 grid grid-cols-3 gap-2">
                  <Stat label="Trade joins" value={count(r.trade.joins)} />
                  <Stat label="Cancelled" value={count(r.trade.cancellations)} />
                  <Stat label="Active now" value={count(r.trade.active_now)} />
                </div>
              )}
            </Card>
          </div>

          {/* AI advisor --------------------------------------------------------- */}
          <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
            <Card className="xl:col-span-2">
              <SectionTitle>AI advisor</SectionTitle>
              <Funnel
                steps={[
                  { label: 'Chats', value: r.chat.chats, note: 'Sessions where the visitor typed at least one message' },
                  { label: 'AI replied', value: r.chat.ai_replied },
                  { label: 'Completed', value: r.chat.completed, note: 'Led to saved contact details, a quote, an add-to-cart or an order' },
                ]}
              />
              <div className="mt-5 grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6">
                <Stat label="Contact saved" value={count(r.chat.contact_saved)} />
                <Stat label="Quotes" value={count(r.chat.quotes)} />
                <Stat label="Added to cart" value={count(r.chat.added_to_cart)} />
                <Stat label="Orders" value={count(r.chat.orders)} />
                <Stat label="Chat revenue" value={pounds(r.chat.revenue_minor)} hint="Paid orders on carts the chat was attached to" />
                <Stat label="No reply" value={count(r.chat.no_reply)} hint="The AI returned nothing (timeout or provider error)" />
              </div>
              <p className="mt-3 text-xs text-secondary-500">
                {r.chat.avg_user_messages !== null ? `${r.chat.avg_user_messages.toFixed(1)} visitor messages per chat · ` : ''}
                {count(r.chat.member_chats)} from signed-in Trade members
              </p>
            </Card>
            <Card>
              <SectionTitle>What the AI did</SectionTitle>
              <BarList
                empty="No tools used in this period"
                rows={r.chat_tools.slice(0, 8).map((t) => ({
                  key: t.name,
                  label: TOOL_LABELS[t.name] ?? t.name,
                  value: t.chats,
                  extra: 'chats',
                }))}
              />
              {r.chat_countries.length > 0 && (
                <>
                  <h3 className="mb-2 mt-5 text-sm font-medium text-secondary-700">Chats by country</h3>
                  <BarList
                    empty=""
                    rows={r.chat_countries.slice(0, 5).map((c) => ({
                      key: c.country ?? 'unknown',
                      label: countryName(c.country),
                      value: c.chats,
                    }))}
                  />
                </>
              )}
            </Card>
          </div>

          {/* Products + quotes -------------------------------------------------- */}
          <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
            <Card padding="none" className="overflow-hidden xl:col-span-2">
              <div className="px-6 pt-6">
                <SectionTitle>Top products</SectionTitle>
              </div>
              {r.top_products.length === 0 ? (
                <p className="px-6 pb-8 pt-2 text-center text-sm text-secondary-500">No paid orders in this period</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-y border-secondary-200 bg-secondary-50 text-left text-xs uppercase tracking-wide text-secondary-500">
                        <th scope="col" className="px-4 py-2.5 font-medium sm:px-6">Product</th>
                        <th scope="col" className="px-3 py-2.5 text-right font-medium">Units</th>
                        <th scope="col" className="hidden px-3 py-2.5 text-right font-medium sm:table-cell">Orders</th>
                        <th scope="col" className="px-4 py-2.5 text-right font-medium sm:px-6">Revenue ex VAT</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-secondary-100">
                      {r.top_products.map((p) => {
                        const share = r.sales.revenue_ex_vat_minor > 0 ? p.revenue_ex_vat_minor / r.sales.revenue_ex_vat_minor : null;
                        return (
                          <tr key={p.product_uuid ?? p.name ?? ''}>
                            <td className="max-w-0 px-4 py-2.5 sm:px-6">
                              <p className="truncate font-medium text-secondary-900">{p.name ?? 'Unknown product'}</p>
                              {p.sku && <p className="truncate text-xs text-secondary-500">{p.sku}</p>}
                            </td>
                            <td className="px-3 py-2.5 text-right tabular-nums">{count(p.units)}</td>
                            <td className="hidden px-3 py-2.5 text-right tabular-nums sm:table-cell">{count(p.orders)}</td>
                            <td className="whitespace-nowrap px-4 py-2.5 text-right tabular-nums sm:px-6">
                              <span className="font-medium text-secondary-900">{formatMoney(p.revenue_ex_vat_minor, cur)}</span>
                              {share !== null && <span className="ml-2 hidden text-xs text-secondary-500 sm:inline">{pct(share, 0)}</span>}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
              <p className="px-6 py-3 text-xs text-secondary-500">Fully refunded orders are left out.</p>
            </Card>

            <div className="space-y-6">
              <Card>
                <SectionTitle>Most added to basket</SectionTitle>
                <BarList
                  empty="Nothing added to a basket"
                  rows={r.basket_adds.slice(0, 6).map((a) => ({
                    key: a.product_uuid,
                    label: a.name,
                    value: a.adds,
                    extra: `${count(a.carts)} ${a.carts === 1 ? 'cart' : 'carts'}`,
                  }))}
                />
                {!r.basket_adds_complete && (
                  <p className="mt-3 flex gap-1.5 text-xs text-secondary-500">
                    <Info className="mt-px h-3.5 w-3.5 shrink-0" aria-hidden="true" />
                    Basket adds are kept for 30 days, so this covers only the last 30 days of the period.
                  </p>
                )}
              </Card>
              <Card>
                <SectionTitle>Quotes</SectionTitle>
                <dl>
                  <Row label="From the cart" value={count(r.quotes.by_source.cart)} />
                  <Row label="From the AI advisor" value={count(r.quotes.by_source.chat)} />
                  <Row label="Raised by staff" value={count(r.quotes.by_source.admin)} />
                  <Row label="Quoted value (inc VAT)" value={formatMoney(r.quotes.value_minor, cur)} strong />
                  <Row label="Won" value={`${count(r.quotes.converted)} · ${formatMoney(r.quotes.converted_value_minor, cur)}`} />
                  <Row label="Viewed by the customer" value={count(r.quotes.viewed)} muted />
                  <Row label="Expired" value={count(r.quotes.expired)} muted />
                </dl>
              </Card>
            </div>
          </div>

          {/* Visitors (off) + definitions ------------------------------------- */}
          <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
            <Card className="border-dashed">
              <div className="flex items-start gap-3">
                <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-secondary-100 text-secondary-500">
                  <EyeOff className="h-4 w-4" />
                </span>
                <div>
                  <h2 className="text-base font-semibold text-secondary-900">Visitor analytics are off</h2>
                  <p className="mt-1 text-sm text-secondary-600">
                    Unique and returning visitors, page views, traffic sources and devices need a privacy and cookie
                    decision first. Until it is signed off, the shop collects no visitor data and sets no analytics cookies.
                  </p>
                  <p className="mt-2 text-xs text-secondary-500">Everything on this page comes from orders, carts, quotes and chats the shop already keeps.</p>
                </div>
              </div>
            </Card>
            <Card className="xl:col-span-2">
              <details className="group">
                <summary className="flex cursor-pointer list-none items-center justify-between text-base font-semibold text-secondary-900">
                  How these are measured
                  <ChevronDown className="h-4 w-4 text-secondary-500 transition-transform group-open:rotate-180" aria-hidden="true" />
                </summary>
                <dl className="mt-4 grid gap-x-8 gap-y-3 text-sm sm:grid-cols-2">
                  {[
                    ['Period', `UK calendar days (${r.window.timezone}), ${longDate(r.window.from)} to ${longDate(r.window.to)} inclusive, compared with the ${r.window.days} days before.`],
                    ['Revenue', 'Order totals inc VAT and shipping, for orders paid in the period (by payment date), including orders refunded later.'],
                    ['Net revenue', 'Revenue minus money refunded on those orders.'],
                    ['Customers', 'Distinct buyer emails. New means their first paid order falls in the period.'],
                    ['Checkout', 'A checkout creates an order. Repeat attempts on the same cart or quote count once.'],
                    ['Abandoned cart', `Has items, was never paid for, and has not been touched for ${r.carts.abandon_after_hours} hours.`],
                    ['Completed chat', 'The AI replied and the chat led to saved contact details, a quote, an add-to-cart or an order.'],
                    ['Chat revenue', 'Paid orders placed on a cart the chat was attached to.'],
                  ].map(([k, v]) => (
                    <div key={k}>
                      <dt className="font-medium text-secondary-800">{k}</dt>
                      <dd className="text-secondary-600">{v}</dd>
                    </div>
                  ))}
                </dl>
              </details>
              <p className="mt-4 text-xs text-secondary-400">
                Generated {new Date(r.generated_at).toLocaleString('en-GB', { timeZone: 'Europe/London' })} UK time
              </p>
            </Card>
          </div>
        </>
      )}
    </div>
  );
}

export default function ShopAnalyticsPage() {
  return (
    <ProtectedPage module={SHOP_ANALYTICS_MODULE} action="read" title="Shop Analytics">
      <AnalyticsContent />
    </ProtectedPage>
  );
}
