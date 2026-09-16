'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Plus, Search, Trash2, Edit, Package } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Input, Textarea, Table, Badge, Pagination, Card, ConfirmDialog, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { productsService } from '@/services';
import { formatDate, formatCurrency } from '@/lib/utils';
import type { StoreProduct, TableColumn, PaginatedResponse } from '@/types';
import toast from 'react-hot-toast';

function ProductsPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [products, setProducts] = useState<StoreProduct[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [productToDelete, setProductToDelete] = useState<StoreProduct | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [createOpen, setCreateOpen] = useState(false);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchProducts = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<StoreProduct> = await productsService.getStoreProducts({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
        status: statusFilter as 'active' | 'draft' | 'archived' | undefined,
      });

      // Only update state if this is still the latest fetch
      if (fetchId === fetchIdRef.current) {
        setProducts(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch products:', error);
        toast.error('Failed to load products');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection, statusFilter]);

  useEffect(() => {
    fetchProducts();
  }, [fetchProducts]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortColumn(column);
      setSortDirection('asc');
    }
    setCurrentPage(1);
  };

  const handleDeleteClick = (product: StoreProduct) => {
    setProductToDelete(product);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!productToDelete) return;

    setIsDeleting(true);
    try {
      await productsService.deleteStoreProduct(productToDelete.uuid);
      toast.success('Product deleted successfully');
      fetchProducts();
    } catch (error) {
      toast.error('Failed to delete product');
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setProductToDelete(null);
    }
  };

  const columns: TableColumn<StoreProduct>[] = [
    {
      key: 'name',
      header: 'Product',
      sortable: true,
      render: (product) => (
        <div className="flex items-center gap-3">
          {product.thumbnail_url ? (
            <img
              src={product.thumbnail_url}
              alt={product.name}
              className="w-12 h-12 rounded-lg object-cover border border-secondary-200"
            />
          ) : (
            <div className="w-12 h-12 bg-secondary-100 rounded-lg flex items-center justify-center">
              <Package className="w-6 h-6 text-secondary-400" />
            </div>
          )}
          <div>
            <p className="font-medium text-secondary-900">{product.name}</p>
            {product.sku && <p className="text-xs text-secondary-500">SKU: {product.sku}</p>}
          </div>
        </div>
      ),
    },
    {
      key: 'price',
      header: 'Price',
      sortable: true,
      render: (product) => (
        <div>
          <p className="font-semibold text-secondary-900">{formatCurrency(product.price)}</p>
          {product.compare_at_price && product.compare_at_price > product.price && (
            <p className="text-xs text-secondary-400 line-through">
              {formatCurrency(product.compare_at_price)}
            </p>
          )}
        </div>
      ),
    },
    {
      key: 'quantity',
      header: 'Stock',
      sortable: true,
      render: (product) => (
        <span
          className={
            product.quantity <= 0
              ? 'text-error-600 font-semibold'
              : product.quantity < 10
              ? 'text-warning-600 font-semibold'
              : 'text-secondary-900'
          }
        >
          {product.quantity}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (product) => <Badge size="sm" status={product.status} />,
    },
    {
      key: 'created_at',
      header: 'Created',
      sortable: true,
      render: (product) => (
        <span className="text-sm text-secondary-600">{formatDate(product.created_at)}</span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (product) => (
        <div className="flex items-center gap-2">
          {canUpdate('products') && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                window.location.href = `/dashboard/products/${product.uuid}`;
              }}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
            >
              <Edit className="w-4 h-4" />
            </button>
          )}
          {canDelete('products') && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                handleDeleteClick(product);
              }}
              className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  const filteredProducts = searchQuery
    ? products.filter(
        (product) =>
          product.name?.toLowerCase().includes(searchQuery.toLowerCase()) ||
          product.sku?.toLowerCase().includes(searchQuery.toLowerCase())
      )
    : products;

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <PageHeader
        title="Products"
        description="Manage your product catalog"
        icon={<Package className="h-5 w-5" />}
        actions={
          canCreate('products') ? (
            <Button leftIcon={<Plus className="w-4 h-4" />} onClick={() => setCreateOpen(true)}>
              Add Product
            </Button>
          ) : undefined
        }
      />

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search products..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>

          <select
            value={statusFilter}
            onChange={(e) => {
              setStatusFilter(e.target.value);
              setCurrentPage(1);
            }}
            className="px-4 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface"
          >
            <option value="">All Status</option>
            <option value="active">Active</option>
            <option value="draft">Draft</option>
            <option value="archived">Archived</option>
          </select>
        </div>
      </Card>

      {/* Products Table */}
      <div>
        <Table
          columns={columns}
          data={filteredProducts}
          keyExtractor={(product) => product.uuid}
          onRowClick={(product) => {
            window.location.href = `/dashboard/products/${product.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No products found"
        />

        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={perPage}
          onPageChange={setCurrentPage}
        />
      </div>

      {/* Delete Confirmation Dialog */}
      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleDeleteConfirm}
        title="Delete Product"
        message={`Are you sure you want to delete "${productToDelete?.name}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />

      <CreateProductModal isOpen={createOpen} onClose={() => setCreateOpen(false)} onCreated={fetchProducts} />
    </div>
  );
}

/** Add a serviceable item to the catalog. Mirrors the detail page's edit payload. */
function CreateProductModal({ isOpen, onClose, onCreated }: { isOpen: boolean; onClose: () => void; onCreated: () => void }) {
  const empty = {
    name: '', sku: '', price: '', cost_price: '', inventory_quantity: '',
    low_stock_threshold: '', short_description: '', description: '',
  };
  const [form, setForm] = useState(empty);
  const [saving, setSaving] = useState(false);
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm((f) => ({ ...f, [k]: e.target.value }));

  // Reset the form each time the modal opens.
  useEffect(() => {
    if (isOpen) setForm(empty);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.name.trim()) {
      toast.error('Name is required');
      return;
    }
    if (!form.price || Number(form.price) <= 0) {
      toast.error('Price must be greater than 0');
      return;
    }
    setSaving(true);
    try {
      const payload: Record<string, unknown> = {
        name: form.name.trim(),
        sku: form.sku.trim(),
        price: form.price.trim(),
        compare_price: 'null',
        cost_price: form.cost_price.trim() || '0',
        inventory_quantity: form.inventory_quantity.trim() || '0',
        low_stock_threshold: form.low_stock_threshold.trim() || '0',
        short_description: form.short_description.trim(),
        description: form.description.trim(),
        is_active: true,
        is_featured: false,
      };
      await productsService.createStoreProduct(payload);
      toast.success('Product created');
      onCreated();
      onClose();
    } catch {
      toast.error('Failed to create product');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Add product" description="Add a serviceable item to the catalog" size="2xl">
      {isOpen && (
        <form onSubmit={submit} className="space-y-4">
          <Input label="Name *" value={form.name} onChange={set('name')} placeholder="e.g. Daikin FTXM50 Air Conditioner" autoFocus />
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Input label="SKU" value={form.sku} onChange={set('sku')} placeholder="e.g. DAIKIN-FTXM50" />
            <Input label="Price *" value={form.price} onChange={set('price')} inputMode="decimal" placeholder="0.00" />
            <Input label="Cost price" value={form.cost_price} onChange={set('cost_price')} inputMode="decimal" placeholder="0.00" />
            <div className="grid grid-cols-2 gap-2">
              <Input label="Stock qty" value={form.inventory_quantity} onChange={set('inventory_quantity')} inputMode="numeric" />
              <Input label="Low stock at" value={form.low_stock_threshold} onChange={set('low_stock_threshold')} inputMode="numeric" />
            </div>
          </div>
          <Input label="Short description" value={form.short_description} onChange={set('short_description')} placeholder="One-line summary" />
          <Textarea label="Description" value={form.description} onChange={set('description')} rows={3} />
          <div className="flex justify-end gap-2 -mx-5 sm:-mx-6 px-5 sm:px-6 pt-4 mt-1 border-t border-secondary-200">
            <Button type="button" variant="ghost" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" isLoading={saving}>
              Create product
            </Button>
          </div>
        </form>
      )}
    </Modal>
  );
}

export default function ProductsPage() {
  return (
    <ProtectedPage module="products" title="Products">
      <ProductsPageContent />
    </ProtectedPage>
  );
}
