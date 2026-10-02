'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { Edit, Package, Plus, Search, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, ConfirmDialog, Input, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { FilterSelect, Money, PriceVerifiedBadge, ProductStatusBadge, SHOP_MODULE, ShopThumb } from '@/components/shop/shared';
import { extractApiError } from '@/lib/utils';
import { humanize } from '@/lib/shop';
import {
  SHOP_PRODUCT_STATUSES,
  SHOP_PRODUCT_TYPES,
  type ShopProductListItem,
  type ShopProductStatus,
  type ShopProductType,
  type TableColumn,
} from '@/types';

const PER_PAGE = 25;

function ProductsContent() {
  const router = useRouter();
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [rows, setRows] = useState<ShopProductListItem[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [status, setStatus] = useState<ShopProductStatus | ''>('');
  const [type, setType] = useState<ShopProductType | ''>('');
  const [lowStock, setLowStock] = useState(false);
  const [page, setPage] = useState(1);
  const [toDelete, setToDelete] = useState<ShopProductListItem | null>(null);
  const [deleting, setDeleting] = useState(false);
  const fetchId = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setQ(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  const load = useCallback(async () => {
    const id = ++fetchId.current;
    setLoading(true);
    try {
      const res = await shopService.getProducts({
        q: q || undefined,
        status,
        type,
        low_stock: lowStock,
        limit: PER_PAGE,
        offset: (page - 1) * PER_PAGE,
      });
      if (id !== fetchId.current) return;
      setRows(res.data);
      setTotal(res.meta.total);
    } catch (err) {
      if (id === fetchId.current) toast.error(extractApiError(err, 'Failed to load products'));
    } finally {
      if (id === fetchId.current) setLoading(false);
    }
  }, [q, status, type, lowStock, page]);

  useEffect(() => {
    load();
  }, [load]);

  const confirmDelete = async () => {
    if (!toDelete) return;
    setDeleting(true);
    try {
      const res = await shopService.deleteProduct(toDelete.uuid);
      toast.success(res?.archived ? 'Product archived (referenced by orders/quotes)' : 'Product deleted');
      load();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to delete product'));
    } finally {
      setDeleting(false);
      setToDelete(null);
    }
  };

  const columns: TableColumn<ShopProductListItem>[] = [
    {
      key: 'name',
      header: 'Product',
      render: (p) => (
        <div className="flex items-center gap-3">
          <ShopThumb
            src={p.images?.[0]}
            className="h-11 w-11 rounded-lg border border-secondary-200 object-cover"
            fallback={
              <div className="flex h-11 w-11 items-center justify-center rounded-lg bg-secondary-100">
                <Package className="h-5 w-5 text-secondary-400" />
              </div>
            }
          />
          <div className="min-w-0">
            <p className="truncate font-medium text-secondary-900">{p.name}</p>
            <p className="text-xs text-secondary-500">
              {p.sku}
              {p.brand ? ` · ${p.brand}` : ''}
              {p.category?.name ? ` · ${p.category.name}` : ''}
            </p>
          </div>
        </div>
      ),
    },
    {
      key: 'product_type',
      header: 'Type',
      render: (p) => (
        <div className="space-y-1">
          <p className="text-sm">{humanize(p.product_type)}</p>
          {p.price_mode !== 'fixed' && (
            <Badge size="sm" variant={p.price_mode === 'quote_only' ? 'warning' : 'info'}>{humanize(p.price_mode)}</Badge>
          )}
        </div>
      ),
    },
    {
      key: 'price',
      header: 'Price (ex VAT)',
      render: (p) =>
        p.price_mode === 'quote_only' && !p.base_price_minor ? (
          <span className="text-sm text-secondary-500">On quote</span>
        ) : (
          <Money minor={p.from_price_minor ?? p.base_price_minor} currency={p.currency} vatRate={p.vat_rate ?? 0.2} />
        ),
    },
    {
      key: 'stock',
      header: 'Stock',
      render: (p) => {
        const available = p.availability?.qty_available ?? (p.stock_qty ?? 0) - (p.held ?? 0);
        const low = available <= (p.low_stock_threshold ?? 0);
        return (
          <div className="space-y-0.5">
            <p className={low ? 'font-semibold text-error-600 tabular-nums' : 'tabular-nums'}>
              {available}
              {p.held ? <span className="ml-1 text-xs font-normal text-secondary-500">({p.held} held)</span> : null}
            </p>
            {low && <p className="text-xs text-secondary-500">{p.allow_backorder ? `Backorder · ${p.lead_time_days ?? p.availability?.lead_time_days ?? '?'}d` : 'Low stock'}</p>}
          </div>
        );
      },
    },
    { key: 'price_verified', header: 'Price', render: (p) => <PriceVerifiedBadge verified={!!p.price_verified} /> },
    { key: 'status', header: 'Status', render: (p) => <ProductStatusBadge status={p.status} /> },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (p) => (
        <div className="flex items-center gap-1">
          {canUpdate(SHOP_MODULE) && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                router.push(`/dashboard/shop/products/${p.uuid}`);
              }}
              className="rounded-lg p-1.5 text-secondary-500 hover:bg-primary-50 hover:text-primary-500"
              aria-label={`Edit ${p.name}`}
            >
              <Edit className="h-4 w-4" />
            </button>
          )}
          {canDelete(SHOP_MODULE) && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                setToDelete(p);
              }}
              className="rounded-lg p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-500"
              aria-label={`Delete ${p.name}`}
            >
              <Trash2 className="h-4 w-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Shop products"
        description="Catalogue, configurable systems, options and compatibility rules"
        icon={<Package className="h-5 w-5" />}
        actions={
          canCreate(SHOP_MODULE) ? (
            <Link href="/dashboard/shop/products/new">
              <Button leftIcon={<Plus className="h-4 w-4" />}>New product</Button>
            </Link>
          ) : undefined
        }
      />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input
              placeholder="Search name, SKU, brand…"
              aria-label="Search products"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              leftIcon={<Search className="h-4 w-4" />}
            />
          </div>
          <FilterSelect
            aria-label="Status"
            value={status}
            onChange={(e) => {
              setStatus(e.target.value as ShopProductStatus | '');
              setPage(1);
            }}
          >
            <option value="">All statuses</option>
            {SHOP_PRODUCT_STATUSES.map((s) => (
              <option key={s} value={s}>{humanize(s)}</option>
            ))}
          </FilterSelect>
          <FilterSelect
            aria-label="Type"
            value={type}
            onChange={(e) => {
              setType(e.target.value as ShopProductType | '');
              setPage(1);
            }}
          >
            <option value="">All types</option>
            {SHOP_PRODUCT_TYPES.map((t) => (
              <option key={t} value={t}>{humanize(t)}</option>
            ))}
          </FilterSelect>
          <label className="flex items-center gap-2 text-sm text-secondary-700">
            <input
              type="checkbox"
              checked={lowStock}
              onChange={(e) => {
                setLowStock(e.target.checked);
                setPage(1);
              }}
              className="h-4 w-4 rounded border-secondary-300 text-primary-600"
            />
            Low stock only
          </label>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(p) => p.uuid}
          onRowClick={(p) => router.push(`/dashboard/shop/products/${p.uuid}`)}
          isLoading={loading}
          emptyMessage="No products found"
          caption="Shop products"
        />
        <Pagination
          currentPage={page}
          totalPages={Math.max(1, Math.ceil(total / PER_PAGE))}
          totalItems={total}
          perPage={PER_PAGE}
          onPageChange={setPage}
        />
      </div>

      <ConfirmDialog
        isOpen={!!toDelete}
        onClose={() => setToDelete(null)}
        onConfirm={confirmDelete}
        title="Delete product"
        message={`Delete "${toDelete?.name}"? Products referenced by carts, quotes or orders are archived instead.`}
        confirmText="Delete / archive"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function ShopProductsPage() {
  return (
    <ProtectedPage module="shop" title="Shop Products">
      <ProductsContent />
    </ProtectedPage>
  );
}
