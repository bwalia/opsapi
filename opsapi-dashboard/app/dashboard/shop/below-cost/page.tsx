'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { TrendingDown } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Card, Switch, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { MarginHint, QuoteStatusBadge, SectionTitle } from '@/components/shop/shared';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import { formatMoney, humanize } from '@/lib/shop';
import type { ShopBelowCostOption, ShopBelowCostProduct, ShopBelowCostQuote, ShopBelowCostReport, TableColumn } from '@/types';

const productHref = (uuid: string) => `/dashboard/shop/products/${uuid}`;

function Source({ source }: { source: string | null }) {
  return source ? <span className="text-xs text-secondary-500">{humanize(source)} cost</span> : null;
}

function BelowCostContent() {
  const [report, setReport] = useState<ShopBelowCostReport | null>(null);
  const [loading, setLoading] = useState(true);
  const [includeQuotes, setIncludeQuotes] = useState(false);

  useEffect(() => {
    let active = true;
    shopService
      .getBelowCostReport(includeQuotes)
      .then((r) => active && setReport(r))
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load the below-cost report')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [includeQuotes]);

  const productColumns: TableColumn<ShopBelowCostProduct>[] = [
    {
      key: 'product',
      header: 'Product',
      render: (p) => (
        <div className="min-w-0">
          <Link href={productHref(p.uuid)} className="truncate text-primary-600 hover:underline">
            {p.name}
          </Link>
          <p className="font-mono text-xs text-secondary-500">
            {p.sku} · {humanize(p.price_mode)}
          </p>
        </div>
      ),
    },
    { key: 'status', header: 'Status', render: (p) => <Badge variant={p.status === 'active' ? 'success' : 'secondary'}>{humanize(p.status)}</Badge> },
    { key: 'price', header: 'Price (ex VAT)', render: (p) => <span className="tabular-nums">{formatMoney(p.price_minor)}</span> },
    {
      key: 'cost',
      header: 'Cost',
      render: (p) => (
        <div className="tabular-nums">
          <p>{formatMoney(p.cost_minor)}</p>
          <Source source={p.cost_source} />
        </div>
      ),
    },
    { key: 'margin', header: 'Margin', render: (p) => <MarginHint priceMinor={p.price_minor} costMinor={p.cost_minor} className="text-sm" /> },
  ];

  const optionColumns: TableColumn<ShopBelowCostOption>[] = [
    {
      key: 'product',
      header: 'Product',
      render: (o) => (
        <div className="min-w-0">
          <Link href={productHref(o.product_uuid)} className="truncate text-primary-600 hover:underline">
            {o.product_name}
          </Link>
          <p className="font-mono text-xs text-secondary-500">{o.product_sku}</p>
        </div>
      ),
    },
    {
      key: 'option',
      header: 'Option',
      render: (o) => (
        <div className="min-w-0">
          <p className="truncate text-secondary-900">
            {o.group_name} › {o.option_name}
          </p>
          <p className="font-mono text-xs text-secondary-500">
            {o.group_code}.{o.option_code}
          </p>
        </div>
      ),
    },
    { key: 'price', header: 'Price Δ (ex VAT)', render: (o) => <span className="tabular-nums">{formatMoney(o.price_minor)}</span> },
    {
      key: 'cost',
      header: 'Cost',
      render: (o) => (
        <div className="tabular-nums">
          <p>{formatMoney(o.cost_minor)}</p>
          <Source source={o.cost_source} />
        </div>
      ),
    },
    { key: 'margin', header: 'Margin', render: (o) => <MarginHint priceMinor={o.price_minor} costMinor={o.cost_minor} className="text-sm" /> },
  ];

  const quoteColumns: TableColumn<ShopBelowCostQuote>[] = [
    {
      key: 'quote',
      header: 'Quote',
      render: (q) => (
        <div>
          <Link href={`/dashboard/shop/quotes/${q.uuid}`} className="font-mono text-primary-600 hover:underline">
            {q.quote_number}
          </Link>
          <p className="text-xs text-secondary-500">
            {q.customer_name || '—'}
            {q.kind ? ` · ${humanize(q.kind)}` : ''}
          </p>
        </div>
      ),
    },
    { key: 'status', header: 'Status', render: (q) => <QuoteStatusBadge status={q.status} /> },
    {
      key: 'lines',
      header: 'Lines below current cost',
      render: (q) => (
        <ul className="space-y-0.5 text-sm">
          {q.lines.map((l) => (
            <li key={l.line_uuid} className="tabular-nums">
              {l.qty} × {l.product_name}: {formatMoney(l.unit_price_minor)} vs cost {formatMoney(l.unit_cost_minor)}{' '}
              <MarginHint priceMinor={l.unit_price_minor} costMinor={l.unit_cost_minor} />
            </li>
          ))}
        </ul>
      ),
    },
  ];

  const missing = report?.missing_cost;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Below cost"
        description="Products and options priced under their cost (supplier cost when linked, else the manual cost). Saving a product with a price below cost is refused."
        icon={<TrendingDown className="h-5 w-5" />}
      />

      <section className="space-y-3">
        <SectionTitle>Products below cost{report ? ` (${report.products.length})` : ''}</SectionTitle>
        <Table
          columns={productColumns}
          data={report?.products ?? []}
          keyExtractor={(p) => p.uuid}
          isLoading={loading && !report}
          emptyMessage="No products are priced below cost"
          caption="Products below cost"
        />
      </section>

      <section className="space-y-3">
        <SectionTitle>Options below cost{report ? ` (${report.options.length})` : ''}</SectionTitle>
        <Table
          columns={optionColumns}
          data={report?.options ?? []}
          keyExtractor={(o) => `${o.product_uuid}:${o.group_code}:${o.option_code}`}
          isLoading={loading && !report}
          emptyMessage="No options are priced below cost"
          caption="Options below cost"
        />
      </section>

      <Card padding="md">
        <SectionTitle>No known cost</SectionTitle>
        {missing ? (
          <>
            <p className="text-sm text-secondary-600">
              <strong className="tabular-nums">{missing.products}</strong> product{missing.products === 1 ? '' : 's'} and{' '}
              <strong className="tabular-nums">{missing.options}</strong> option{missing.options === 1 ? '' : 's'} have no cost, so they
              cannot be checked. Link a supplier item or enter a manual cost in the product editor.
            </p>
            {report && report.missing_cost_products.length > 0 && (
              <>
                <p className="mt-3 text-xs text-secondary-500">
                  {report.missing_cost_products.length < missing.products
                    ? `First ${report.missing_cost_products.length} active products to fill in:`
                    : 'Active products to fill in:'}
                </p>
                <ul className="mt-1 grid grid-cols-1 gap-x-6 gap-y-1 text-sm sm:grid-cols-2 lg:grid-cols-3">
                  {report.missing_cost_products.map((p) => (
                    <li key={p.uuid} className="min-w-0 truncate">
                      <Link href={productHref(p.uuid)} className="text-primary-600 hover:underline">
                        {p.name}
                      </Link>{' '}
                      <span className="font-mono text-xs text-secondary-500">{p.sku}</span>
                    </li>
                  ))}
                </ul>
              </>
            )}
          </>
        ) : (
          <p className="text-sm text-secondary-500">{loading ? 'Loading…' : '—'}</p>
        )}
      </Card>

      <section className="space-y-3">
        <SectionTitle
          actions={
            <label className="flex items-center gap-2 text-sm text-secondary-600">
              Show open quotes
              <Switch
                checked={includeQuotes}
                onChange={(v) => {
                  setLoading(true);
                  setIncludeQuotes(v);
                }}
                aria-label="Show draft and sent quotes below current cost"
              />
            </label>
          }
        >
          Draft / sent quotes below current cost
        </SectionTitle>
        {includeQuotes ? (
          <Table
            columns={quoteColumns}
            data={report?.quotes ?? []}
            keyExtractor={(q) => q.uuid}
            isLoading={loading}
            emptyMessage="No draft or sent quotes have a line below current cost"
            caption="Quotes below current cost"
          />
        ) : (
          <p className="text-sm text-secondary-500">Turn on to check draft and sent quotes against today&apos;s costs.</p>
        )}
      </section>
    </div>
  );
}

export default function ShopBelowCostPage() {
  return (
    <ProtectedPage module="shop" title="Below cost">
      <BelowCostContent />
    </ProtectedPage>
  );
}
