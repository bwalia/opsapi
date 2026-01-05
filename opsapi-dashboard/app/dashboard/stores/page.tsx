'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Plus, Search, Trash2, Edit, Store as StoreIcon, MapPin, Phone, Mail } from 'lucide-react';
import { Button, Input, Table, Badge, Pagination, Card, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { storesService } from '@/services';
import { formatDate } from '@/lib/utils';
import type { Store, TableColumn, PaginatedResponse } from '@/types';
import toast from 'react-hot-toast';

function StoresPageContent() {
  const [stores, setStores] = useState<Store[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [storeToDelete, setStoreToDelete] = useState<Store | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchStores = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<Store> = await storesService.getStores({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
      });

      // Only update state if this is still the latest fetch
      if (fetchId === fetchIdRef.current) {
        setStores(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch stores:', error);
        toast.error('Failed to load stores');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection]);

  useEffect(() => {
    fetchStores();
  }, [fetchStores]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortColumn(column);
      setSortDirection('asc');
    }
    setCurrentPage(1);
  };

  const handleDeleteClick = (store: Store) => {
    setStoreToDelete(store);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!storeToDelete) return;

    setIsDeleting(true);
    try {
      await storesService.deleteStore(storeToDelete.uuid);
      toast.success('Store deleted successfully');
      fetchStores();
    } catch (error) {
      toast.error('Failed to delete store');
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setStoreToDelete(null);
    }
  };

  const formatLocation = (store: Store): string => {
    const parts = [store.city, store.state, store.country].filter(Boolean);
    return parts.join(', ') || 'No location';
  };

  const columns: TableColumn<Store>[] = [
    {
      key: 'name',
      header: 'Store',
      sortable: true,
      render: (store) => (
        <div className="flex items-center gap-3">
          {store.logo_url ? (
            <img
              src={store.logo_url}
              alt={store.name}
              className="w-12 h-12 rounded-lg object-cover border border-secondary-200"
            />
          ) : (
            <div className="w-12 h-12 gradient-primary rounded-lg flex items-center justify-center shadow-md shadow-primary-500/25">
              <StoreIcon className="w-6 h-6 text-white" />
            </div>
          )}
          <div>
            <p className="font-medium text-secondary-900">{store.name}</p>
            {store.description && (
              <p className="text-xs text-secondary-500 line-clamp-1 max-w-[200px]">
                {store.description}
              </p>
            )}
          </div>
        </div>
      ),
    },
    {
      key: 'location',
      header: 'Location',
      render: (store) => (
        <div className="flex items-center gap-2 text-secondary-600">
          <MapPin className="w-4 h-4 text-secondary-400" />
          <span className="text-sm">{formatLocation(store)}</span>
        </div>
      ),
    },
    {
      key: 'contact',
      header: 'Contact',
      render: (store) => (
        <div className="space-y-1">
          {store.email && (
            <div className="flex items-center gap-2 text-sm text-secondary-600">
              <Mail className="w-3.5 h-3.5 text-secondary-400" />
              <span className="truncate max-w-[150px]">{store.email}</span>
            </div>
          )}
          {store.phone && (
            <div className="flex items-center gap-2 text-sm text-secondary-600">
              <Phone className="w-3.5 h-3.5 text-secondary-400" />
              <span>{store.phone}</span>
            </div>
          )}
          {!store.email && !store.phone && (
            <span className="text-sm text-secondary-400">No contact info</span>
          )}
        </div>
      ),
    },
    {
      key: 'is_active',
      header: 'Status',
      render: (store) => <Badge size="sm" status={store.is_active ? 'active' : 'inactive'} />,
    },
    {
      key: 'created_at',
      header: 'Created',
      sortable: true,
      render: (store) => (
        <span className="text-sm text-secondary-600">{formatDate(store.created_at)}</span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (store) => (
        <div className="flex items-center gap-2">
          <button
            onClick={(e) => {
              e.stopPropagation();
              window.location.href = `/dashboard/stores/${store.uuid}`;
            }}
            className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
          >
            <Edit className="w-4 h-4" />
          </button>
          <button
            onClick={(e) => {
              e.stopPropagation();
              handleDeleteClick(store);
            }}
            className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ];

  const filteredStores = React.useMemo(() => {
    let result = stores;

    if (searchQuery) {
      const query = searchQuery.toLowerCase();
      result = result.filter(
        (store) =>
          store.name?.toLowerCase().includes(query) ||
          store.email?.toLowerCase().includes(query) ||
          store.city?.toLowerCase().includes(query)
      );
    }

    if (statusFilter) {
      const isActive = statusFilter === 'active';
      result = result.filter((store) => store.is_active === isActive);
    }

    return result;
  }, [stores, searchQuery, statusFilter]);

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Stores</h1>
          <p className="text-secondary-500 mt-1">Manage your store locations</p>
        </div>
        <Button leftIcon={<Plus className="w-4 h-4" />}>Add Store</Button>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search stores..."
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
            <option value="inactive">Inactive</option>
          </select>
        </div>
      </Card>

      {/* Stores Table */}
      <div>
        <Table
          columns={columns}
          data={filteredStores}
          keyExtractor={(store) => store.uuid}
          onRowClick={(store) => {
            window.location.href = `/dashboard/stores/${store.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No stores found"
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
        title="Delete Store"
        message={`Are you sure you want to delete "${storeToDelete?.name}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />
    </div>
  );
}

export default function StoresPage() {
  return (
    <ProtectedPage module="stores" title="Stores">
      <StoresPageContent />
    </ProtectedPage>
  );
}
