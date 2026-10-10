'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import {
  Search,
  ClipboardCheck,
  Filter,
  Truck,
  AlertTriangle,
  Receipt,
  CheckCircle,
  RefreshCw,
  X,
  ChevronDown,
  Plus,
  Calendar,
} from 'lucide-react';
import { Input, Table, Pagination, Card, SearchableSelect } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { PurchaseOrderStatusBadge } from '@/components/purchase-orders/PurchaseOrderStatusBadge';
import { PurchaseOrderFormModal } from '@/components/purchase-orders/PurchaseOrderFormModal';
import {
  purchaseOrdersService,
  PURCHASE_ORDER_STATUSES,
  type PurchaseOrder,
  type PurchaseOrderFilters,
  type PurchaseOrderStats,
  type PurchaseOrderStatus,
} from '@/services/purchase-orders.service';
import { kanbanService } from '@/services/kanban.service';
import { formatDate, formatCurrency } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const filterInputClass =
  'px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface';

interface StatCardProps {
  title: string;
  value: string | number;
  hint?: string;
  icon: React.ReactNode;
  color: 'primary' | 'success' | 'warning' | 'danger' | 'info';
}

const StatCard: React.FC<StatCardProps> = ({ title, value, hint, icon, color }) => {
  const colorClasses = {
    primary: 'bg-primary-50 text-primary-600',
    success: 'bg-green-50 text-green-600',
    warning: 'bg-amber-50 text-amber-600',
    danger: 'bg-red-50 text-red-600',
    info: 'bg-blue-50 text-blue-600',
  };
  return (
    <div className="bg-surface rounded-xl border border-secondary-200 p-5 shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-secondary-500">{title}</p>
          <p className="text-2xl font-bold text-secondary-900 mt-1">{value}</p>
          {hint && <p className="text-xs text-secondary-500 mt-1">{hint}</p>}
        </div>
        <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${colorClasses[color]}`}>{icon}</div>
      </div>
    </div>
  );
};

const STATUS_OPTIONS: { value: PurchaseOrderStatus | 'all'; label: string }[] = [
  { value: 'all', label: 'All Status' },
  ...PURCHASE_ORDER_STATUSES,
];

const OPEN_STATUSES: PurchaseOrderStatus[] = ['sent', 'acknowledged', 'partially_received'];

function PurchaseOrdersPageContent() {
  const router = useRouter();

  const [purchaseOrders, setPurchaseOrders] = useState<PurchaseOrder[]>([]);
  const [stats, setStats] = useState<PurchaseOrderStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isCreateOpen, setIsCreateOpen] = useState(false);

  // Filters
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState<PurchaseOrderStatus | 'all'>('all');
  const [supplierFilter, setSupplierFilter] = useState('');
  const [debouncedSupplier, setDebouncedSupplier] = useState('');
  const [projectFilter, setProjectFilter] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [showFilters, setShowFilters] = useState(false);
  const [projectOptions, setProjectOptions] = useState<{ value: string; label: string }[] | null>(null);

  // Pagination & sorting
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState<string>('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const perPage = 10;

  const fetchIdRef = useRef(0);

  // Debounce the free-text inputs so typing doesn't fire a request per key.
  useEffect(() => {
    const t = setTimeout(() => {
      setDebouncedSearch(searchQuery.trim());
      setDebouncedSupplier(supplierFilter.trim());
      setCurrentPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery, supplierFilter]);

  const fetchPurchaseOrders = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const filters: PurchaseOrderFilters = {
        page: currentPage,
        perPage,
        orderBy: sortColumn as PurchaseOrderFilters['orderBy'],
        orderDir: sortDirection,
      };
      if (debouncedSearch) filters.search = debouncedSearch;
      if (statusFilter !== 'all') filters.status = statusFilter;
      if (debouncedSupplier) filters.supplier = debouncedSupplier;
      if (projectFilter) filters.projectUuid = projectFilter;
      if (dateFrom) filters.dateFrom = dateFrom;
      if (dateTo) filters.dateTo = dateTo;

      const response = await purchaseOrdersService.getPurchaseOrders(filters);
      if (fetchId === fetchIdRef.current) {
        setPurchaseOrders(response.data);
        setTotalPages(response.total_pages);
        setTotalItems(response.total);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch purchase orders:', error);
        toast.error('Failed to load purchase orders');
      }
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [currentPage, sortColumn, sortDirection, debouncedSearch, statusFilter, debouncedSupplier, projectFilter, dateFrom, dateTo]);

  const loadStats = useCallback(() => {
    purchaseOrdersService
      .getStats()
      .then(setStats)
      .catch((error) => console.error('Failed to load purchase order stats:', error));
  }, []);

  useEffect(() => {
    loadStats();
  }, [loadStats]);

  useEffect(() => {
    fetchPurchaseOrders();
  }, [fetchPurchaseOrders]);

  // Project filter options (hidden when the projects module isn't available).
  useEffect(() => {
    let cancelled = false;
    kanbanService
      .getProjects({ perPage: 100 })
      .then((r) => !cancelled && setProjectOptions((r?.data || []).map((p) => ({ value: p.uuid, label: p.name }))))
      .catch(() => !cancelled && setProjectOptions(null));
    return () => {
      cancelled = true;
    };
  }, []);

  const handleSort = useCallback((column: string) => {
    setSortColumn((prev) => {
      if (prev === column) {
        setSortDirection((d) => (d === 'asc' ? 'desc' : 'asc'));
        return column;
      }
      setSortDirection('asc');
      return column;
    });
    setCurrentPage(1);
  }, []);

  const clearFilters = useCallback(() => {
    setSearchQuery('');
    setStatusFilter('all');
    setSupplierFilter('');
    setProjectFilter('');
    setDateFrom('');
    setDateTo('');
    setCurrentPage(1);
  }, []);

  const hasActiveFilters =
    searchQuery.trim() !== '' ||
    statusFilter !== 'all' ||
    supplierFilter.trim() !== '' ||
    projectFilter !== '' ||
    dateFrom !== '' ||
    dateTo !== '';

  const today = new Date().toISOString().slice(0, 10);

  const columns: TableColumn<PurchaseOrder>[] = useMemo(
    () => [
      {
        key: 'po_number',
        header: 'PO #',
        sortable: true,
        render: (po) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-secondary-100 rounded-lg flex items-center justify-center">
              <ClipboardCheck className="w-5 h-5 text-secondary-500" />
            </div>
            <div>
              <p className="font-medium text-secondary-900">{po.po_number}</p>
              {po.reference && <p className="text-xs text-secondary-500">{po.reference}</p>}
            </div>
          </div>
        ),
      },
      {
        key: 'supplier_name',
        header: 'Supplier',
        sortable: true,
        render: (po) => (
          <div>
            <p className="text-sm font-medium text-secondary-900">{po.supplier_name}</p>
            {po.supplier_email && <p className="text-xs text-secondary-500">{po.supplier_email}</p>}
          </div>
        ),
      },
      {
        key: 'status',
        header: 'Status',
        sortable: true,
        render: (po) => <PurchaseOrderStatusBadge status={po.status} />,
      },
      {
        key: 'issue_date',
        header: 'Issued',
        sortable: true,
        render: (po) => <span className="text-sm text-secondary-700">{formatDate(po.issue_date)}</span>,
      },
      {
        key: 'expected_date',
        header: 'Expected',
        sortable: true,
        render: (po) => {
          const late = !!po.expected_date && po.expected_date.slice(0, 10) < today && OPEN_STATUSES.includes(po.status);
          return (
            <span className={`text-sm ${late ? 'text-red-600 font-medium' : 'text-secondary-700'}`}>
              {po.expected_date ? formatDate(po.expected_date) : '-'}
            </span>
          );
        },
      },
      {
        key: 'total',
        header: 'Total',
        sortable: true,
        render: (po) => (
          <span className="font-semibold text-secondary-900">{formatCurrency(po.total, po.currency, 'en-GB')}</span>
        ),
      },
    ],
    [today]
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Purchase Orders"
        description="Raise, send and track orders to builders and merchants"
        icon={<ClipboardCheck className="h-5 w-5" />}
        actions={
          <>
            <button
              onClick={() => {
                fetchPurchaseOrders();
                loadStats();
              }}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
            >
              <RefreshCw className={`w-4 h-4 ${isLoading ? 'animate-spin' : ''}`} />
              Refresh
            </button>
            <button
              onClick={() => setIsCreateOpen(true)}
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors"
            >
              <Plus className="w-4 h-4" />
              New Purchase Order
            </button>
          </>
        }
      />

      {stats && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <StatCard
            title="Open"
            value={formatCurrency(stats.open_value, 'GBP', 'en-GB')}
            hint={`${stats.open_count} awaiting delivery`}
            icon={<Truck className="w-6 h-6" />}
            color="info"
          />
          <StatCard
            title="Overdue Deliveries"
            value={stats.overdue_count}
            hint="Expected date has passed"
            icon={<AlertTriangle className="w-6 h-6" />}
            color="danger"
          />
          <StatCard
            title="To Bill"
            value={formatCurrency(stats.to_bill_value, 'GBP', 'en-GB')}
            hint={`${stats.to_bill_count} received, not billed`}
            icon={<Receipt className="w-6 h-6" />}
            color="warning"
          />
          <StatCard
            title="Billed"
            value={formatCurrency(stats.billed_value, 'GBP', 'en-GB')}
            hint={`${stats.total_count} purchase orders in total`}
            icon={<CheckCircle className="w-6 h-6" />}
            color="success"
          />
        </div>
      )}

      <Card padding="md">
        <div className="space-y-4">
          <div className="flex flex-wrap items-center gap-4">
            <div className="flex-1 min-w-[250px] max-w-md">
              <Input
                placeholder="Search by PO #, supplier, reference..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                leftIcon={<Search className="w-4 h-4" />}
              />
            </div>

            <div className="relative">
              <select
                value={statusFilter}
                onChange={(e) => {
                  setStatusFilter(e.target.value as PurchaseOrderStatus | 'all');
                  setCurrentPage(1);
                }}
                aria-label="Filter by status"
                className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer"
              >
                {STATUS_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>

            <button
              onClick={() => setShowFilters(!showFilters)}
              className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium rounded-lg transition-colors ${
                showFilters || hasActiveFilters
                  ? 'bg-primary-50 text-primary-600 border border-primary-200'
                  : 'text-secondary-700 bg-surface border border-secondary-300 hover:bg-secondary-50'
              }`}
            >
              <Filter className="w-4 h-4" />
              Filters
              {hasActiveFilters && <span className="w-2 h-2 bg-primary-500 rounded-full" />}
            </button>

            {hasActiveFilters && (
              <button
                onClick={clearFilters}
                className="flex items-center gap-1 px-3 py-2.5 text-sm text-red-600 hover:bg-red-50 rounded-lg transition-colors"
              >
                <X className="w-4 h-4" />
                Clear
              </button>
            )}
          </div>

          {showFilters && (
            <div className="flex flex-wrap items-end gap-4 pt-4 border-t border-secondary-200">
              <div>
                <label className="block text-xs font-medium text-secondary-500 mb-1">Supplier</label>
                <input
                  type="text"
                  value={supplierFilter}
                  onChange={(e) => setSupplierFilter(e.target.value)}
                  className={filterInputClass}
                  placeholder="Supplier name or email"
                />
              </div>
              {projectOptions !== null && (
                <div className="min-w-[220px]">
                  <SearchableSelect
                    label="Project"
                    options={projectOptions}
                    value={projectFilter}
                    onChange={(v) => {
                      setProjectFilter(v);
                      setCurrentPage(1);
                    }}
                    placeholder="Any project"
                    clearable
                  />
                </div>
              )}
              <div>
                <label className="block text-xs font-medium text-secondary-500 mb-1">Issued between</label>
                <div className="flex items-center gap-2">
                  <Calendar className="w-4 h-4 text-secondary-400" />
                  <input
                    type="date"
                    value={dateFrom}
                    onChange={(e) => {
                      setDateFrom(e.target.value);
                      setCurrentPage(1);
                    }}
                    className={filterInputClass}
                    aria-label="Issued from"
                  />
                  <span className="text-secondary-400">to</span>
                  <input
                    type="date"
                    value={dateTo}
                    onChange={(e) => {
                      setDateTo(e.target.value);
                      setCurrentPage(1);
                    }}
                    className={filterInputClass}
                    aria-label="Issued to"
                  />
                </div>
              </div>
            </div>
          )}
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={purchaseOrders}
          keyExtractor={(po) => po.uuid}
          onRowClick={(po) => router.push(`/dashboard/purchase-orders/${po.uuid}`)}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage={
            hasActiveFilters
              ? 'No purchase orders match your filters.'
              : 'No purchase orders yet. Raise your first one to get started.'
          }
        />
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={perPage}
          onPageChange={setCurrentPage}
        />
      </div>

      <PurchaseOrderFormModal
        isOpen={isCreateOpen}
        onClose={() => setIsCreateOpen(false)}
        onSaved={(po) => router.push(`/dashboard/purchase-orders/${po.uuid}`)}
      />
    </div>
  );
}

export default function PurchaseOrdersPage() {
  return (
    <ProtectedPage module="purchase_orders" title="Purchase Orders">
      <PurchaseOrdersPageContent />
    </ProtectedPage>
  );
}
