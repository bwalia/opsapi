'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Search,
  Eye,
  Package,
  Filter,
  Calendar,
  Store,
  TrendingUp,
  Clock,
  CheckCircle,
  Truck,
  RefreshCw,
  X,
  ChevronDown,
} from 'lucide-react';
import { Input, Table, Badge, Pagination, Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { ordersService, type OrderFilters, type OrderStats, type StoreOption } from '@/services/orders.service';
import { formatDate, formatCurrency, getFullName } from '@/lib/utils';
import type { Order, TableColumn, OrderStatus, PaymentStatus } from '@/types';
import { useAuthStore } from '@/store/auth.store';
import toast from 'react-hot-toast';

// Stats card component
interface StatCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  trend?: { value: number; isPositive: boolean };
  color: 'primary' | 'success' | 'warning' | 'danger' | 'info';
}

const StatCard: React.FC<StatCardProps> = ({ title, value, icon, color }) => {
  const colorClasses = {
    primary: 'bg-primary-50 text-primary-600',
    success: 'bg-green-50 text-green-600',
    warning: 'bg-amber-50 text-amber-600',
    danger: 'bg-red-50 text-red-600',
    info: 'bg-blue-50 text-blue-600',
  };

  return (
    <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-secondary-500">{title}</p>
          <p className="text-2xl font-bold text-secondary-900 mt-1">{value}</p>
        </div>
        <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${colorClasses[color]}`}>
          {icon}
        </div>
      </div>
    </div>
  );
};

// Order status options
const ORDER_STATUS_OPTIONS: { value: OrderStatus | 'all'; label: string }[] = [
  { value: 'all', label: 'All Status' },
  { value: 'pending', label: 'Pending' },
  { value: 'confirmed', label: 'Confirmed' },
  { value: 'processing', label: 'Processing' },
  { value: 'ready_for_pickup', label: 'Ready for Pickup' },
  { value: 'out_for_delivery', label: 'Out for Delivery' },
  { value: 'delivered', label: 'Delivered' },
  { value: 'cancelled', label: 'Cancelled' },
  { value: 'refunded', label: 'Refunded' },
];

// Payment status options
const PAYMENT_STATUS_OPTIONS: { value: PaymentStatus | 'all'; label: string }[] = [
  { value: 'all', label: 'All Payment' },
  { value: 'pending', label: 'Pending' },
  { value: 'paid', label: 'Paid' },
  { value: 'failed', label: 'Failed' },
  { value: 'refunded', label: 'Refunded' },
];

// Order Details Modal Component
interface OrderDetailsModalProps {
  order: Order | null;
  isOpen: boolean;
  onClose: () => void;
  isAdmin: boolean;
}

const OrderDetailsModal: React.FC<OrderDetailsModalProps> = ({ order, isOpen, onClose, isAdmin }) => {
  if (!order) return null;

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={`Order #${order.order_number || order.uuid.slice(0, 8)}`}>
      <div className="space-y-6">
        {/* Order Header */}
        <div className="flex items-center justify-between pb-4 border-b border-secondary-200">
          <div className="flex items-center gap-3">
            <div className="w-12 h-12 bg-primary-100 rounded-xl flex items-center justify-center">
              <Package className="w-6 h-6 text-primary-600" />
            </div>
            <div>
              <h3 className="font-semibold text-secondary-900">
                #{order.order_number || order.uuid.slice(0, 8)}
              </h3>
              <p className="text-sm text-secondary-500">{formatDate(order.created_at)}</p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Badge size="md" status={order.status} />
            <Badge size="md" status={order.payment_status} />
          </div>
        </div>

        {/* Customer Info */}
        <div className="bg-secondary-50 rounded-lg p-4">
          <h4 className="font-medium text-secondary-900 mb-3">Customer Information</h4>
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <span className="text-secondary-500">Name:</span>
              <span className="ml-2 text-secondary-900 font-medium">
                {order.customer ? getFullName(order.customer.first_name, order.customer.last_name) : 'Guest'}
              </span>
            </div>
            {order.customer?.email && (
              <div>
                <span className="text-secondary-500">Email:</span>
                <span className="ml-2 text-secondary-900">{order.customer.email}</span>
              </div>
            )}
            {order.customer?.phone && (
              <div>
                <span className="text-secondary-500">Phone:</span>
                <span className="ml-2 text-secondary-900">{order.customer.phone}</span>
              </div>
            )}
          </div>
        </div>

        {/* Seller Info (Admin Only) */}
        {isAdmin && order.seller && (
          <div className="bg-blue-50 rounded-lg p-4">
            <h4 className="font-medium text-blue-900 mb-3">Seller Information</h4>
            <div className="grid grid-cols-2 gap-4 text-sm">
              <div>
                <span className="text-blue-600">Name:</span>
                <span className="ml-2 text-blue-900 font-medium">{order.seller.full_name || 'N/A'}</span>
              </div>
              {order.seller.email && (
                <div>
                  <span className="text-blue-600">Email:</span>
                  <span className="ml-2 text-blue-900">{order.seller.email}</span>
                </div>
              )}
            </div>
          </div>
        )}

        {/* Store Info */}
        {order.store && (
          <div className="bg-secondary-50 rounded-lg p-4">
            <h4 className="font-medium text-secondary-900 mb-3">Store Information</h4>
            <div className="grid grid-cols-2 gap-4 text-sm">
              <div>
                <span className="text-secondary-500">Store:</span>
                <span className="ml-2 text-secondary-900 font-medium">{order.store.name}</span>
              </div>
              {order.store.email && (
                <div>
                  <span className="text-secondary-500">Contact:</span>
                  <span className="ml-2 text-secondary-900">{order.store.email}</span>
                </div>
              )}
            </div>
          </div>
        )}

        {/* Order Items */}
        {order.items && order.items.length > 0 && (
          <div>
            <h4 className="font-medium text-secondary-900 mb-3">Order Items</h4>
            <div className="border border-secondary-200 rounded-lg overflow-hidden">
              <table className="w-full text-sm">
                <thead className="bg-secondary-50">
                  <tr>
                    <th className="text-left px-4 py-3 text-secondary-600 font-medium">Product</th>
                    <th className="text-center px-4 py-3 text-secondary-600 font-medium">Qty</th>
                    <th className="text-right px-4 py-3 text-secondary-600 font-medium">Price</th>
                    <th className="text-right px-4 py-3 text-secondary-600 font-medium">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-secondary-200">
                  {order.items.map((item) => (
                    <tr key={item.uuid}>
                      <td className="px-4 py-3 text-secondary-900">{item.product_name || 'Product'}</td>
                      <td className="px-4 py-3 text-center text-secondary-600">{item.quantity}</td>
                      <td className="px-4 py-3 text-right text-secondary-600">
                        {formatCurrency(item.unit_price)}
                      </td>
                      <td className="px-4 py-3 text-right font-medium text-secondary-900">
                        {formatCurrency(item.total_price)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {/* Order Summary */}
        <div className="bg-secondary-50 rounded-lg p-4">
          <h4 className="font-medium text-secondary-900 mb-3">Order Summary</h4>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-secondary-500">Subtotal</span>
              <span className="text-secondary-900">{formatCurrency(order.subtotal)}</span>
            </div>
            {order.tax_amount !== undefined && order.tax_amount > 0 && (
              <div className="flex justify-between">
                <span className="text-secondary-500">Tax</span>
                <span className="text-secondary-900">{formatCurrency(order.tax_amount)}</span>
              </div>
            )}
            {order.shipping_amount !== undefined && order.shipping_amount > 0 && (
              <div className="flex justify-between">
                <span className="text-secondary-500">Shipping</span>
                <span className="text-secondary-900">{formatCurrency(order.shipping_amount)}</span>
              </div>
            )}
            {order.discount_amount !== undefined && order.discount_amount > 0 && (
              <div className="flex justify-between text-green-600">
                <span>Discount</span>
                <span>-{formatCurrency(order.discount_amount)}</span>
              </div>
            )}
            <div className="flex justify-between pt-2 border-t border-secondary-300 font-semibold">
              <span className="text-secondary-900">Total</span>
              <span className="text-primary-600">{formatCurrency(order.total)}</span>
            </div>
          </div>
        </div>

        {/* Addresses */}
        {(order.shipping_address || order.billing_address) && (
          <div className="grid grid-cols-2 gap-4">
            {order.shipping_address && (
              <div className="bg-secondary-50 rounded-lg p-4">
                <h4 className="font-medium text-secondary-900 mb-2">Shipping Address</h4>
                <p className="text-sm text-secondary-600 whitespace-pre-line">{order.shipping_address}</p>
              </div>
            )}
            {order.billing_address && (
              <div className="bg-secondary-50 rounded-lg p-4">
                <h4 className="font-medium text-secondary-900 mb-2">Billing Address</h4>
                <p className="text-sm text-secondary-600 whitespace-pre-line">{order.billing_address}</p>
              </div>
            )}
          </div>
        )}

        {/* Notes */}
        {order.notes && (
          <div className="bg-amber-50 rounded-lg p-4">
            <h4 className="font-medium text-amber-900 mb-2">Order Notes</h4>
            <p className="text-sm text-amber-700">{order.notes}</p>
          </div>
        )}
      </div>
    </Modal>
  );
};

function OrdersPageContent() {
  // State
  const [orders, setOrders] = useState<Order[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [userRole, setUserRole] = useState<string | null>(null);
  const [stats, setStats] = useState<OrderStats | null>(null);
  const [stores, setStores] = useState<StoreOption[]>([]);
  const [selectedOrder, setSelectedOrder] = useState<Order | null>(null);
  const [isModalOpen, setIsModalOpen] = useState(false);

  // Filters
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<OrderStatus | 'all'>('all');
  const [paymentFilter, setPaymentFilter] = useState<PaymentStatus | 'all'>('all');
  const [storeFilter, setStoreFilter] = useState<string>('all');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [showFilters, setShowFilters] = useState(false);

  // Pagination & Sorting
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState<string>('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const perPage = 10;

  // Refs
  const fetchIdRef = useRef(0);
  const searchTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  // Auth store
  const { user } = useAuthStore();

  // Check if user is admin
  const isAdmin = useMemo(() => {
    if (userRole === 'administrative') return true;
    if (user?.roles?.some((r) => r.role_name === 'administrative')) return true;
    return false;
  }, [userRole, user]);

  // Fetch orders with debounced search
  const fetchOrders = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const filters: OrderFilters = {
        page: currentPage,
        perPage,
        orderBy: sortColumn as OrderFilters['orderBy'],
        orderDir: sortDirection,
      };

      if (searchQuery.trim()) filters.search = searchQuery.trim();
      if (statusFilter !== 'all') filters.status = statusFilter;
      if (paymentFilter !== 'all') filters.paymentStatus = paymentFilter;
      if (storeFilter !== 'all') filters.storeUuid = storeFilter;
      if (dateFrom) filters.dateFrom = dateFrom;
      if (dateTo) filters.dateTo = dateTo;

      const response = await ordersService.getOrders(filters);

      if (fetchId === fetchIdRef.current) {
        setOrders(response.data);
        setTotalPages(response.total_pages);
        setTotalItems(response.total);
        if (response.user_role) {
          setUserRole(response.user_role);
        }
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch orders:', error);
        toast.error('Failed to load orders');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection, searchQuery, statusFilter, paymentFilter, storeFilter, dateFrom, dateTo]);

  // Fetch stats and stores on mount
  useEffect(() => {
    const loadInitialData = async () => {
      try {
        const [statsData, storesData] = await Promise.all([
          ordersService.getOrderStats(),
          ordersService.getStores(),
        ]);
        setStats(statsData);
        setStores(storesData);
      } catch (error) {
        console.error('Failed to load initial data:', error);
      }
    };
    loadInitialData();
  }, []);

  // Fetch orders when filters change
  useEffect(() => {
    fetchOrders();
  }, [fetchOrders]);

  // Debounced search handler
  const handleSearchChange = useCallback((value: string) => {
    setSearchQuery(value);
    if (searchTimeoutRef.current) {
      clearTimeout(searchTimeoutRef.current);
    }
    searchTimeoutRef.current = setTimeout(() => {
      setCurrentPage(1);
    }, 300);
  }, []);

  // Sort handler
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

  // View order details
  const handleViewOrder = useCallback(async (order: Order) => {
    try {
      const fullOrder = await ordersService.getOrder(order.uuid);
      setSelectedOrder(fullOrder);
      setIsModalOpen(true);
    } catch (error) {
      console.error('Failed to load order details:', error);
      toast.error('Failed to load order details');
    }
  }, []);

  // Clear all filters
  const clearFilters = useCallback(() => {
    setSearchQuery('');
    setStatusFilter('all');
    setPaymentFilter('all');
    setStoreFilter('all');
    setDateFrom('');
    setDateTo('');
    setCurrentPage(1);
  }, []);

  // Check if any filters are active
  const hasActiveFilters = useMemo(() => {
    return (
      searchQuery.trim() !== '' ||
      statusFilter !== 'all' ||
      paymentFilter !== 'all' ||
      storeFilter !== 'all' ||
      dateFrom !== '' ||
      dateTo !== ''
    );
  }, [searchQuery, statusFilter, paymentFilter, storeFilter, dateFrom, dateTo]);

  // Table columns
  const columns: TableColumn<Order>[] = useMemo(() => {
    const baseColumns: TableColumn<Order>[] = [
      {
        key: 'order_number',
        header: 'Order',
        sortable: true,
        render: (order) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-secondary-100 rounded-lg flex items-center justify-center">
              <Package className="w-5 h-5 text-secondary-500" />
            </div>
            <div>
              <p className="font-medium text-secondary-900">
                #{order.order_number || order.uuid.slice(0, 8)}
              </p>
              <p className="text-xs text-secondary-500">{formatDate(order.created_at)}</p>
            </div>
          </div>
        ),
      },
      {
        key: 'customer',
        header: 'Customer',
        render: (order) => (
          <div>
            <p className="text-sm font-medium text-secondary-900">
              {order.customer
                ? getFullName(order.customer.first_name, order.customer.last_name)
                : 'Guest Customer'}
            </p>
            {order.customer?.email && (
              <p className="text-xs text-secondary-500">{order.customer.email}</p>
            )}
          </div>
        ),
      },
    ];

    // Add store column for admin with seller info
    if (isAdmin) {
      baseColumns.push({
        key: 'store',
        header: 'Store / Seller',
        render: (order) => (
          <div>
            <p className="text-sm font-medium text-secondary-900">
              {order.store?.name || 'N/A'}
            </p>
            {order.seller && (
              <p className="text-xs text-blue-600">
                {order.seller.full_name || order.seller.email || 'Unknown Seller'}
              </p>
            )}
          </div>
        ),
      });
    } else {
      // Show just store name for sellers
      baseColumns.push({
        key: 'store',
        header: 'Store',
        render: (order) => (
          <span className="text-sm text-secondary-700">{order.store?.name || 'N/A'}</span>
        ),
      });
    }

    baseColumns.push(
      {
        key: 'status',
        header: 'Status',
        render: (order) => <Badge size="sm" status={order.status} />,
      },
      {
        key: 'payment_status',
        header: 'Payment',
        render: (order) => <Badge size="sm" status={order.payment_status} />,
      },
      {
        key: 'total',
        header: 'Total',
        sortable: true,
        render: (order) => (
          <span className="font-semibold text-secondary-900">{formatCurrency(order.total)}</span>
        ),
      },
      {
        key: 'actions',
        header: '',
        width: 'w-16',
        render: (order) => (
          <button
            onClick={(e) => {
              e.stopPropagation();
              handleViewOrder(order);
            }}
            className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
            title="View Order Details"
          >
            <Eye className="w-4 h-4" />
          </button>
        ),
      }
    );

    return baseColumns;
  }, [isAdmin, handleViewOrder]);

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Orders</h1>
          <p className="text-secondary-500 mt-1">
            {isAdmin ? 'Manage all orders across the platform' : 'Manage your store orders'}
          </p>
        </div>
        <button
          onClick={() => fetchOrders()}
          className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
        >
          <RefreshCw className={`w-4 h-4 ${isLoading ? 'animate-spin' : ''}`} />
          Refresh
        </button>
      </div>

      {/* Stats Cards */}
      {stats && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4">
          <StatCard
            title="Total Orders"
            value={stats.total_orders}
            icon={<Package className="w-6 h-6" />}
            color="primary"
          />
          <StatCard
            title="Pending"
            value={stats.pending_orders}
            icon={<Clock className="w-6 h-6" />}
            color="warning"
          />
          <StatCard
            title="Processing"
            value={stats.processing_orders}
            icon={<Truck className="w-6 h-6" />}
            color="info"
          />
          <StatCard
            title="Delivered"
            value={stats.delivered_orders}
            icon={<CheckCircle className="w-6 h-6" />}
            color="success"
          />
          <StatCard
            title="Revenue"
            value={formatCurrency(stats.total_revenue)}
            icon={<TrendingUp className="w-6 h-6" />}
            color="primary"
          />
        </div>
      )}

      {/* Filters */}
      <Card padding="md">
        <div className="space-y-4">
          {/* Primary Filter Row */}
          <div className="flex flex-wrap items-center gap-4">
            {/* Search */}
            <div className="flex-1 min-w-[250px] max-w-md">
              <Input
                placeholder="Search by order #, customer name, email..."
                value={searchQuery}
                onChange={(e) => handleSearchChange(e.target.value)}
                leftIcon={<Search className="w-4 h-4" />}
              />
            </div>

            {/* Status Filter */}
            <div className="relative">
              <select
                value={statusFilter}
                onChange={(e) => {
                  setStatusFilter(e.target.value as OrderStatus | 'all');
                  setCurrentPage(1);
                }}
                className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer"
              >
                {ORDER_STATUS_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>

            {/* Payment Filter */}
            <div className="relative">
              <select
                value={paymentFilter}
                onChange={(e) => {
                  setPaymentFilter(e.target.value as PaymentStatus | 'all');
                  setCurrentPage(1);
                }}
                className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer"
              >
                {PAYMENT_STATUS_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>

            {/* Toggle Advanced Filters */}
            <button
              onClick={() => setShowFilters(!showFilters)}
              className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium rounded-lg transition-colors ${
                showFilters || hasActiveFilters
                  ? 'bg-primary-50 text-primary-600 border border-primary-200'
                  : 'text-secondary-700 bg-white border border-secondary-300 hover:bg-secondary-50'
              }`}
            >
              <Filter className="w-4 h-4" />
              Filters
              {hasActiveFilters && (
                <span className="w-2 h-2 bg-primary-500 rounded-full" />
              )}
            </button>

            {/* Clear Filters */}
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

          {/* Advanced Filters Row */}
          {showFilters && (
            <div className="flex flex-wrap items-center gap-4 pt-4 border-t border-secondary-200">
              {/* Store Filter (Admin only or show user's stores) */}
              {stores.length > 0 && (
                <div className="flex items-center gap-2">
                  <Store className="w-4 h-4 text-secondary-400" />
                  <div className="relative">
                    <select
                      value={storeFilter}
                      onChange={(e) => {
                        setStoreFilter(e.target.value);
                        setCurrentPage(1);
                      }}
                      className="appearance-none px-4 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer min-w-[180px]"
                    >
                      <option value="all">All Stores</option>
                      {stores.map((store) => (
                        <option key={store.uuid} value={store.uuid}>
                          {store.name}
                          {isAdmin && store.owner_name && ` (${store.owner_name})`}
                        </option>
                      ))}
                    </select>
                    <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
                  </div>
                </div>
              )}

              {/* Date Range */}
              <div className="flex items-center gap-2">
                <Calendar className="w-4 h-4 text-secondary-400" />
                <input
                  type="date"
                  value={dateFrom}
                  onChange={(e) => {
                    setDateFrom(e.target.value);
                    setCurrentPage(1);
                  }}
                  className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
                  placeholder="From"
                />
                <span className="text-secondary-400">to</span>
                <input
                  type="date"
                  value={dateTo}
                  onChange={(e) => {
                    setDateTo(e.target.value);
                    setCurrentPage(1);
                  }}
                  className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
                  placeholder="To"
                />
              </div>
            </div>
          )}
        </div>
      </Card>

      {/* Orders Table */}
      <div>
        <Table
          columns={columns}
          data={orders}
          keyExtractor={(order) => order.uuid}
          onRowClick={handleViewOrder}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage={
            hasActiveFilters
              ? 'No orders match your filters. Try adjusting your search criteria.'
              : 'No orders found.'
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

      {/* Order Details Modal */}
      <OrderDetailsModal
        order={selectedOrder}
        isOpen={isModalOpen}
        onClose={() => {
          setIsModalOpen(false);
          setSelectedOrder(null);
        }}
        isAdmin={isAdmin}
      />
    </div>
  );
}

export default function OrdersPage() {
  return (
    <ProtectedPage module="orders" title="Orders">
      <OrdersPageContent />
    </ProtectedPage>
  );
}
