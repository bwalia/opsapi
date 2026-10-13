'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { Scale } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { FilterSelect } from '@/components/shop/shared';
import { shopService } from '@/services/shop.service';
import { extractApiError, formatDate } from '@/lib/utils';
import { formatMoney, humanize } from '@/lib/shop';
import { SHOP_PRICE_CHANGE_STATUSES, type ShopPriceChange, type ShopPriceChangeStatus, type TableColumn } from '@/types';

const PER_PAGE = 50;

const VARIANT: Record<ShopPriceChangeStatus, 'warning' | 'success' | 'info' | 'error' | 'secondary'> = {
  pending: 'warning',
  applied: 'info',
  approved: 'success',
  rejected: 'error',
  superseded: 'secondary',
};

function ChangePct({ pct }: { pct: number | null }) {
  if (pct === null || pct === undefined) return <span className="text-secondary-500">first price</span>;
  const up = pct > 0;
  return (
    <span className={up ? 'font-medium text-error-600' : 'font-medium text-success-600'}>
      {up ? '+' : ''}
      {pct.toFixed(1)}%
    </span>
  );
}

function PriceChangesContent() {
  const [rows, setRows] = useState<ShopPriceChange[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState<ShopPriceChangeStatus | ''>('pending');
  const [page, setPage] = useState(1);
  const [busy, setBusy] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let active = true;
    shopService
      .getPriceChanges({ status, limit: PER_PAGE, offset: (page - 1) * PER_PAGE })
      .then((res) => {
        if (!active) return;
        setRows(res.data);
        setTotal(res.meta.total);
      })
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load price changes')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [status, page, reload]);

  const decide = useCallback(async (c: ShopPriceChange, approve: boolean) => {
    setBusy(c.uuid);
    try {
      await shopService.decidePriceChange(c.uuid, approve);
      toast.success(approve ? `${c.product_name} is now ${formatMoney(c.new_price_minor)} ex VAT` : `Kept ${c.product_name} at its current price`);
      setReload((n) => n + 1);
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to save the decision'));
    } finally {
      setBusy(null);
    }
  }, []);

  const columns: TableColumn<ShopPriceChange>[] = [
    {
      key: 'product',
      header: 'Product',
      render: (c) => (
        <div className="min-w-0">
          <p className="truncate text-secondary-900">{c.product_name}</p>
          <p className="font-mono text-xs text-secondary-500">
            {c.product_sku}
            {c.supplier_name ? ` · ${c.supplier_name} ${c.supplier_sku ?? ''}` : ''}
          </p>
        </div>
      ),
    },
    {
      key: 'price',
      header: 'Price (ex VAT)',
      render: (c) => (
        <div className="tabular-nums">
          <p>
            {formatMoney(c.old_price_minor)} → <strong>{formatMoney(c.new_price_minor)}</strong>
          </p>
          <p className="text-xs">
            <ChangePct pct={c.change_pct} />
          </p>
        </div>
      ),
    },
    {
      key: 'why',
      header: 'Why',
      render: (c) => (
        <p className="text-sm text-secondary-600 tabular-nums">
          Cost {formatMoney(c.cost_minor)} + {c.margin_pct}% margin
        </p>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (c) => (
        <div>
          <Badge variant={VARIANT[c.status]}>{humanize(c.status)}</Badge>
          <p className="mt-1 text-xs text-secondary-500">
            {c.decided_at ? `${formatDate(c.decided_at)}${c.decided_by ? ` · ${c.decided_by}` : ''}` : formatDate(c.created_at)}
          </p>
        </div>
      ),
    },
    {
      key: 'actions',
      header: '',
      render: (c) =>
        c.status === 'pending' ? (
          <div className="flex gap-2">
            <Button size="sm" onClick={() => decide(c, true)} isLoading={busy === c.uuid} disabled={!!busy}>
              Approve
            </Button>
            <Button size="sm" variant="ghost" onClick={() => decide(c, false)} disabled={!!busy}>
              Keep current
            </Button>
          </div>
        ) : null,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Price changes"
        description="Supplier-driven prices. Small changes apply automatically; bigger ones (and a product's first supplier price) wait here for you."
        icon={<Scale className="h-5 w-5" />}
      />
      <Card padding="md">
        <FilterSelect
          aria-label="Status"
          value={status}
          onChange={(e) => {
            setStatus(e.target.value as ShopPriceChangeStatus | '');
            setPage(1);
          }}
        >
          <option value="">All</option>
          {SHOP_PRICE_CHANGE_STATUSES.map((s) => (
            <option key={s} value={s}>
              {s === 'pending' ? 'Waiting for approval' : humanize(s)}
            </option>
          ))}
        </FilterSelect>
      </Card>
      <div>
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(c) => c.uuid}
          isLoading={loading}
          emptyMessage={status === 'pending' ? 'Nothing waiting for approval' : 'No price changes'}
          caption="Price changes"
        />
        <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil(total / PER_PAGE))} totalItems={total} perPage={PER_PAGE} onPageChange={setPage} />
      </div>
    </div>
  );
}

export default function ShopPriceChangesPage() {
  return (
    <ProtectedPage module="shop" title="Price changes">
      <PriceChangesContent />
    </ProtectedPage>
  );
}
