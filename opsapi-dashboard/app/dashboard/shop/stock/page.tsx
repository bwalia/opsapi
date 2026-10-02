'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { Boxes, History, Minus, Plus, RefreshCw, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { MovementsDrawer, SHOP_MODULE, ShopLoading, StockAdjustModal, type StockTarget } from '@/components/shop/shared';
import { cn, extractApiError } from '@/lib/utils';
import type { ShopStockRow } from '@/types/shop';

const rowLabel = (r: ShopStockRow) =>
  r.kind === 'option'
    ? `${r.product_name} › ${r.group_name ? `${r.group_name}: ` : ''}${r.option_name ?? r.option_code ?? ''}`
    : r.product_name;

function StockContent() {
  const { canUpdate } = usePermissions();
  const [rows, setRows] = useState<ShopStockRow[] | null>(null);
  const [lowOnly, setLowOnly] = useState(false);
  const [kind, setKind] = useState<'all' | 'product' | 'option'>('all');
  const [search, setSearch] = useState('');
  const [version, setVersion] = useState(0);
  const [adjust, setAdjust] = useState<{ target: StockTarget; delta: number } | null>(null);
  const [history, setHistory] = useState<StockTarget | null>(null);

  const reload = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let active = true;
    shopService
      .getStock({ low_only: lowOnly })
      .then((r) => active && setRows(r))
      .catch((err) => {
        if (!active) return;
        setRows([]);
        toast.error(extractApiError(err, 'Failed to load stock'));
      });
    return () => {
      active = false;
    };
  }, [lowOnly, version]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (rows ?? []).filter(
      (r) =>
        (kind === 'all' || r.kind === kind) &&
        (!q || rowLabel(r).toLowerCase().includes(q) || (r.sku ?? '').toLowerCase().includes(q))
    );
  }, [rows, search, kind]);

  const lowCount = (rows ?? []).filter((r) => r.is_low ?? r.available <= r.low_stock_threshold).length;
  const target = (r: ShopStockRow): StockTarget => ({ kind: r.kind, uuid: r.uuid, label: rowLabel(r), current: r.stock_qty });

  return (
    <div className="space-y-6">
      <PageHeader
        title="Stock"
        description="Products and tracked options — on hand, held by pending checkouts, and available"
        icon={<Boxes className="h-5 w-5" />}
        actions={
          <Button variant="ghost" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={reload}>
            Refresh
          </Button>
        }
      />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input placeholder="Search item or SKU…" aria-label="Search stock" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <div className="inline-flex rounded-lg border border-secondary-300 p-0.5" role="group" aria-label="Item kind">
            {(['all', 'product', 'option'] as const).map((k) => (
              <button
                key={k}
                type="button"
                onClick={() => setKind(k)}
                aria-pressed={kind === k}
                className={cn(
                  'rounded-md px-3 py-1.5 text-sm font-medium transition-colors',
                  kind === k ? 'bg-primary-500 text-white' : 'text-secondary-600 hover:bg-secondary-100'
                )}
              >
                {k === 'all' ? 'All' : k === 'product' ? 'Products' : 'Options'}
              </button>
            ))}
          </div>
          <label className="flex items-center gap-2 text-sm text-secondary-700">
            <input type="checkbox" checked={lowOnly} onChange={(e) => setLowOnly(e.target.checked)} className="h-4 w-4 rounded border-secondary-300 text-primary-600" />
            Low stock only
          </label>
          {rows && !lowOnly && lowCount > 0 && <Badge variant="warning">{lowCount} low</Badge>}
        </div>
      </Card>

      {rows === null ? (
        <ShopLoading label="Loading stock sheet…" />
      ) : (
        <div className="overflow-hidden rounded-xl border border-secondary-200 bg-surface">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <caption className="sr-only">Stock sheet</caption>
              <thead>
                <tr className="border-b border-secondary-200 bg-secondary-50 text-left text-xs font-semibold uppercase tracking-wider text-secondary-600">
                  <th scope="col" className="px-6 py-3">Item</th>
                  <th scope="col" className="px-4 py-3 text-right">On hand</th>
                  <th scope="col" className="px-4 py-3 text-right">Held</th>
                  <th scope="col" className="px-4 py-3 text-right">Available</th>
                  <th scope="col" className="px-4 py-3 text-right">Low at</th>
                  <th scope="col" className="px-6 py-3 text-right">Adjust</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-secondary-100">
                {filtered.length === 0 ? (
                  <tr>
                    <td colSpan={6} className="px-6 py-12 text-center text-secondary-500">
                      {lowOnly ? 'Nothing is low on stock.' : 'No stock items.'}
                    </td>
                  </tr>
                ) : (
                  filtered.map((r) => {
                    const low = r.is_low ?? r.available <= r.low_stock_threshold;
                    return (
                      <tr key={`${r.kind}:${r.uuid}`} className="hover:bg-secondary-50">
                        <td className="px-6 py-3">
                          <div className="flex items-center gap-2">
                            <Badge size="sm" variant={r.kind === 'product' ? 'default' : 'info'}>{r.kind === 'product' ? 'Product' : 'Option'}</Badge>
                            <div className="min-w-0">
                              {r.product_uuid || r.kind === 'product' ? (
                                <Link
                                  href={`/dashboard/shop/products/${r.product_uuid ?? r.uuid}`}
                                  className="font-medium text-secondary-900 hover:text-primary-600 hover:underline"
                                >
                                  {r.product_name}
                                </Link>
                              ) : (
                                <span className="font-medium text-secondary-900">{r.product_name}</span>
                              )}
                              {r.kind === 'option' && (
                                <p className="text-xs text-secondary-600">
                                  {r.group_name ? `${r.group_name}: ` : ''}
                                  {r.option_name ?? r.option_code}
                                </p>
                              )}
                              {r.sku && <p className="text-xs text-secondary-400">{r.sku}</p>}
                            </div>
                          </div>
                        </td>
                        <td className="px-4 py-3 text-right tabular-nums">{r.stock_qty}</td>
                        <td className="px-4 py-3 text-right tabular-nums text-secondary-600">{r.held || 0}</td>
                        <td className={cn('px-4 py-3 text-right font-semibold tabular-nums', low ? 'text-error-600' : 'text-secondary-900')}>
                          {r.available}
                          {low && r.allow_backorder && <span className="block text-xs font-normal text-secondary-500">backorder</span>}
                        </td>
                        <td className="px-4 py-3 text-right tabular-nums text-secondary-600">{r.low_stock_threshold}</td>
                        <td className="px-6 py-3">
                          <div className="flex items-center justify-end gap-1">
                            {canUpdate(SHOP_MODULE) && (
                              <>
                                <button
                                  type="button"
                                  onClick={() => setAdjust({ target: target(r), delta: -1 })}
                                  className="rounded-lg border border-secondary-300 p-1.5 text-secondary-600 hover:border-error-300 hover:bg-error-50 hover:text-error-600"
                                  aria-label={`Decrease stock of ${rowLabel(r)}`}
                                >
                                  <Minus className="h-4 w-4" />
                                </button>
                                <button
                                  type="button"
                                  onClick={() => setAdjust({ target: target(r), delta: 1 })}
                                  className="rounded-lg border border-secondary-300 p-1.5 text-secondary-600 hover:border-success-300 hover:bg-success-50 hover:text-success-600"
                                  aria-label={`Increase stock of ${rowLabel(r)}`}
                                >
                                  <Plus className="h-4 w-4" />
                                </button>
                              </>
                            )}
                            <button
                              type="button"
                              onClick={() => setHistory(target(r))}
                              className="rounded-lg p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-secondary-800"
                              aria-label={`Movement history of ${rowLabel(r)}`}
                              title="Movement history"
                            >
                              <History className="h-4 w-4" />
                            </button>
                          </div>
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <StockAdjustModal target={adjust?.target ?? null} initialDelta={adjust?.delta ?? 1} onClose={() => setAdjust(null)} onDone={reload} />
      <MovementsDrawer target={history} onClose={() => setHistory(null)} />
    </div>
  );
}

export default function ShopStockPage() {
  return (
    <ProtectedPage module="shop" title="Shop Stock">
      <StockContent />
    </ProtectedPage>
  );
}
