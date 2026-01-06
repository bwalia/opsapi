'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Plus, Search, Trash2, Edit, Package } from 'lucide-react';
import { Button, Input, Table, Badge, Pagination, Card, ConfirmDialog } from '@/components/ui';
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
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Products</h1>
          <p className="text-secondary-500 mt-1">Manage your product catalog</p>
        </div>
        {canCreate('products') && (
          <Button leftIcon={<Plus className="w-4 h-4" />}>Add Product</Button>
        )}
      </div>

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
            className="px-4 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
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
    </div>
  );
}

export default function ProductsPage() {
  return (
    <ProtectedPage module="products" title="Products">
      <ProductsPageContent />
    </ProtectedPage>
  );
}
