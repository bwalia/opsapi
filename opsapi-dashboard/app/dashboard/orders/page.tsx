'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Search, Eye, Package } from 'lucide-react';
import { Input, Table, Badge, Pagination, Card } from '@/components/ui';
import { ordersService } from '@/services';
import { formatDate, formatCurrency, getFullName } from '@/lib/utils';
import type { Order, TableColumn, PaginatedResponse, OrderStatus } from '@/types';
import toast from 'react-hot-toast';

export default function OrdersPage() {
  const [orders, setOrders] = useState<Order[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<OrderStatus | ''>('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchOrders = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<Order> = await ordersService.getOrders({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
        status: statusFilter || undefined,
      });

      // Only update state if this is still the latest fetch
      if (fetchId === fetchIdRef.current) {
        setOrders(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
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
  }, [currentPage, sortColumn, sortDirection, statusFilter]);

  useEffect(() => {
    fetchOrders();
  }, [fetchOrders]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortColumn(column);
      setSortDirection('asc');
    }
    setCurrentPage(1);
  };

  const columns: TableColumn<Order>[] = [
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
        <span className="text-sm text-secondary-700">
          {order.customer
            ? getFullName(order.customer.first_name, order.customer.last_name)
            : 'Guest Customer'}
        </span>
      ),
    },
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
            window.location.href = `/dashboard/orders/${order.uuid}`;
          }}
          className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
        >
          <Eye className="w-4 h-4" />
        </button>
      ),
    },
  ];

  const filteredOrders = searchQuery
    ? orders.filter(
        (order) =>
          order.order_number?.toLowerCase().includes(searchQuery.toLowerCase()) ||
          order.uuid.toLowerCase().includes(searchQuery.toLowerCase())
      )
    : orders;

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div>
        <h1 className="text-2xl font-bold text-secondary-900">Orders</h1>
        <p className="text-secondary-500 mt-1">Manage and track your orders</p>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search orders..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>

          <select
            value={statusFilter}
            onChange={(e) => {
              setStatusFilter(e.target.value as OrderStatus | '');
              setCurrentPage(1);
            }}
            className="px-4 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
          >
            <option value="">All Status</option>
            <option value="pending">Pending</option>
            <option value="confirmed">Confirmed</option>
            <option value="processing">Processing</option>
            <option value="delivered">Delivered</option>
            <option value="cancelled">Cancelled</option>
          </select>
        </div>
      </Card>

      {/* Orders Table */}
      <div>
        <Table
          columns={columns}
          data={filteredOrders}
          keyExtractor={(order) => order.uuid}
          onRowClick={(order) => {
            window.location.href = `/dashboard/orders/${order.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No orders found"
        />

        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={perPage}
          onPageChange={setCurrentPage}
        />
      </div>
    </div>
  );
}
