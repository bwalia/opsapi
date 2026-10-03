'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { AlertTriangle, LineChart, Plus, RefreshCw, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Modal, SearchableSelect } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { FilterSelect, SHOP_MODULE, ShopLoading } from '@/components/shop/shared';
import { MarketDrawer, safeRelative } from '@/components/shop/MarketDrawer';
import { cn, extractApiError } from '@/lib/utils';
import { formatMoney } from '@/lib/shop';
import type { SearchableSelectOption } from '@/components/ui';
import type { ShopMarketOverviewRow } from '@/types/shop';

type Freshness = 'all' | 'fresh' | 'stale';

function DiffCell({ pct }: { pct: number | null }) {
  if (pct === null) return <span className="text-secondary-400">—</span>;
  const abs = Math.abs(pct);
  return (
    <span
      className={cn(
        'font-medium tabular-nums',
        abs <= 5 ? 'text-success-600' : abs <= 15 ? 'text-warning-600' : 'text-error-600'
      )}
      title={pct > 0 ? 'Our price is above the market median' : 'Our price is below the market median'}
    >
      {pct > 0 ? '+' : ''}
      {pct.toFixed(1)}%
    </span>
  );
}

/** Pick any catalogue product (incl. ones without sources yet) to open its market drawer. */
function ProductPicker({ open, onClose, onPick }: { open: boolean; onClose: () => void; onPick: (uuid: string) => void }) {
  const [options, setOptions] = useState<SearchableSelectOption[] | null>(null);
  const [value, setValue] = useState('');

  useEffect(() => {
    if (!open || options) return;
    shopService
      .getProducts({ limit: 500 })
      .then((r) => setOptions(r.data.map((p) => ({ value: p.uuid, label: p.name, hint: p.sku }))))
      .catch((err) => {
        setOptions([]);
        toast.error(extractApiError(err, 'Failed to load products'));
      });
  }, [open, options]);

  return (
    <Modal isOpen={open} onClose={onClose} title="Add market source" description="Choose the catalogue product the source sells" size="md">
      <div className="space-y-4">
        {options === null ? (
          <ShopLoading label="Loading products…" />
        ) : (
          <SearchableSelect
            label="Product"
            options={options}
            value={value}
            onChange={setValue}
            placeholder="Select a product"
            searchPlaceholder="Search name or SKU…"
          />
        )}
        <div className="flex justify-end gap-2 border-t border-secondary-200 pt-4">
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={!value}
            onClick={() => {
              onPick(value);
              setValue('');
              onClose();
            }}
          >
            Continue
          </Button>
        </div>
      </div>
    </Modal>
  );
}

function MarketContent() {
  const { canCreate } = usePermissions();
  const [rows, setRows] = useState<ShopMarketOverviewRow[] | null>(null);
  const [search, setSearch] = useState('');
  const [freshness, setFreshness] = useState<Freshness>('all');
  const [diffGt, setDiffGt] = useState('');
  const [anomaliesOnly, setAnomaliesOnly] = useState(false);
  const [version, setVersion] = useState(0);
  const [open, setOpen] = useState<string | null>(null);
  const [picker, setPicker] = useState(false);

  const reload = useCallback(() => setVersion((v) => v + 1), []);
  const closeDrawer = useCallback(() => setOpen(null), []);

  useEffect(() => {
    let active = true;
    const diff = Number(diffGt);
    shopService
      .getMarketOverview({
        stale: freshness === 'all' ? undefined : freshness === 'stale',
        diff_gt: diffGt.trim() !== '' && Number.isFinite(diff) ? diff : undefined,
        anomalies: anomaliesOnly || undefined,
      })
      .then((r) => active && setRows(r))
      .catch((err) => {
        if (!active) return;
        setRows([]);
        toast.error(extractApiError(err, 'Failed to load market overview'));
      });
    return () => {
      active = false;
    };
  }, [freshness, diffGt, anomaliesOnly, version]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return rows ?? [];
    return (rows ?? []).filter(
      (r) => r.name.toLowerCase().includes(q) || r.sku.toLowerCase().includes(q) || (r.brand ?? '').toLowerCase().includes(q)
    );
  }, [rows, search]);

  const totals = useMemo(() => {
    const all = rows ?? [];
    return {
      stale: all.filter((r) => r.stale).length,
      anomalies: all.reduce((n, r) => n + (r.pending_anomalies || 0), 0),
      failing: all.reduce((n, r) => n + (r.failing_sources || 0), 0),
    };
  }, [rows]);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Market prices"
        description="Third-party prices and availability from pinned retailer pages — reference only, our catalogue stays authoritative"
        icon={<LineChart className="h-5 w-5" />}
        actions={
          <div className="flex items-center gap-2">
            <Button variant="ghost" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={reload}>
              Refresh
            </Button>
            {canCreate(SHOP_MODULE) && (
              <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setPicker(true)}>
                Add source
              </Button>
            )}
          </div>
        }
      />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input
              placeholder="Search product or SKU…"
              aria-label="Search products"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              leftIcon={<Search className="h-4 w-4" />}
            />
          </div>
          <FilterSelect value={freshness} onChange={(e) => setFreshness(e.target.value as Freshness)} aria-label="Freshness">
            <option value="all">All freshness</option>
            <option value="fresh">Fresh only</option>
            <option value="stale">Stale only</option>
          </FilterSelect>
          <div className="w-40">
            <Input
              placeholder="|diff| > %"
              aria-label="Minimum absolute difference from market median, percent"
              value={diffGt}
              onChange={(e) => setDiffGt(e.target.value.replace(/[^0-9.]/g, ''))}
              inputMode="decimal"
            />
          </div>
          <label className="flex items-center gap-2 text-sm text-secondary-700">
            <input
              type="checkbox"
              checked={anomaliesOnly}
              onChange={(e) => setAnomaliesOnly(e.target.checked)}
              className="h-4 w-4 rounded border-secondary-300 text-primary-600"
            />
            Pending anomalies only
          </label>
          <div className="ml-auto flex flex-wrap gap-2">
            {totals.anomalies > 0 && <Badge variant="warning">{totals.anomalies} anomalies</Badge>}
            {totals.stale > 0 && <Badge variant="secondary">{totals.stale} stale</Badge>}
            {totals.failing > 0 && <Badge variant="error">{totals.failing} failing sources</Badge>}
          </div>
        </div>
      </Card>

      {rows === null ? (
        <ShopLoading label="Loading market overview…" />
      ) : (
        <div className="overflow-hidden rounded-xl border border-secondary-200 bg-surface">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <caption className="sr-only">Our prices against market prices</caption>
              <thead>
                <tr className="border-b border-secondary-200 bg-secondary-50 text-left text-xs font-semibold uppercase tracking-wider text-secondary-600">
                  <th scope="col" className="px-6 py-3">Product</th>
                  <th scope="col" className="px-4 py-3 text-right">Our price</th>
                  <th scope="col" className="px-4 py-3 text-right">Market median</th>
                  <th scope="col" className="px-4 py-3 text-right">Market min</th>
                  <th scope="col" className="px-4 py-3 text-right">Diff</th>
                  <th scope="col" className="px-4 py-3 text-right">In stock</th>
                  <th scope="col" className="px-6 py-3">Freshness</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-secondary-100">
                {filtered.length === 0 ? (
                  <tr>
                    <td colSpan={7} className="px-6 py-12 text-center text-secondary-500">
                      {rows.length === 0
                        ? 'No market sources yet. Add a source to start tracking a product.'
                        : 'No products match these filters.'}
                    </td>
                  </tr>
                ) : (
                  filtered.map((r) => (
                    <tr
                      key={r.product_uuid}
                      className="cursor-pointer hover:bg-secondary-50"
                      onClick={() => setOpen(r.product_uuid)}
                    >
                      <td className="px-6 py-3">
                        <button
                          type="button"
                          className="text-left font-medium text-secondary-900 hover:text-primary-600 hover:underline"
                          onClick={(e) => {
                            e.stopPropagation();
                            setOpen(r.product_uuid);
                          }}
                        >
                          {r.name}
                        </button>
                        <p className="text-xs text-secondary-400">
                          {r.sku}
                          {r.status !== 'active' ? ` · ${r.status}` : ''}
                        </p>
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums">
                        {formatMoney(r.our_price_ex_vat_minor)}
                        {!r.price_verified && <span className="block text-xs text-warning-600">unverified</span>}
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums">{formatMoney(r.market_median_ex_vat_minor)}</td>
                      <td className="px-4 py-3 text-right tabular-nums text-secondary-600">{formatMoney(r.market_min_ex_vat_minor)}</td>
                      <td className="px-4 py-3 text-right">
                        <DiffCell pct={r.diff_pct} />
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums">
                        {r.in_stock_sources}
                        <span className="text-secondary-400"> / {r.total_sources}</span>
                      </td>
                      <td className="px-6 py-3">
                        <div className="flex flex-wrap items-center gap-1.5">
                          {r.stale ? <Badge size="sm" variant="secondary">Stale</Badge> : <Badge size="sm" variant="success">Fresh</Badge>}
                          {r.pending_anomalies > 0 && (
                            <Badge size="sm" variant="warning">
                              <AlertTriangle className="mr-1 inline h-3 w-3" aria-hidden="true" />
                              {r.pending_anomalies} anomal{r.pending_anomalies === 1 ? 'y' : 'ies'}
                            </Badge>
                          )}
                          {r.failing_sources > 0 && <Badge size="sm" variant="error">{r.failing_sources} failing</Badge>}
                        </div>
                        <p className="mt-0.5 text-xs text-secondary-400">
                          {r.freshest_at ? `Latest ${safeRelative(r.freshest_at)}` : 'No accepted data'}
                        </p>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}
      <p className="text-xs text-secondary-500">
        Prices are ex VAT. Median/min use accepted GBP observations from the last 7 days (latest per source). Diff = our
        price vs market median.
      </p>

      <ProductPicker open={picker} onClose={() => setPicker(false)} onPick={setOpen} />
      <MarketDrawer productUuid={open} onClose={closeDrawer} onChanged={reload} />
    </div>
  );
}

export default function ShopMarketPage() {
  return (
    <ProtectedPage module="shop" title="Shop Market Prices">
      <MarketContent />
    </ProtectedPage>
  );
}
