'use client';

import React, { memo, useMemo } from 'react';
import { Badge, Card } from '@/components/ui';
import { formatDate, formatCurrency, getFullName } from '@/lib/utils';
import type { Order } from '@/types';
import { ShoppingCart, Loader2 } from 'lucide-react';

interface RecentOrdersTableProps {
  orders: Order[];
  isLoading?: boolean;
}

// Memoized order row component
const OrderRow = memo(function OrderRow({ order }: { order: Order }) {
  return (
    <tr className="hover:bg-secondary-50 transition-colors cursor-pointer">
      <td className="px-6 py-4">
        <div>
          <p className="text-sm font-medium text-secondary-900">
            #{order.order_number || order.uuid.slice(0, 8)}
          </p>
          <p className="text-xs text-secondary-500">{formatDate(order.created_at)}</p>
        </div>
      </td>
      <td className="px-6 py-4">
        <p className="text-sm text-secondary-900">
          {order.customer
            ? getFullName(order.customer.first_name, order.customer.last_name)
            : 'Guest'}
        </p>
      </td>
      <td className="px-6 py-4">
        <Badge size="sm" status={order.status} />
      </td>
      <td className="px-6 py-4">
        <Badge size="sm" status={order.payment_status} />
      </td>
      <td className="px-6 py-4 text-right">
        <p className="text-sm font-semibold text-secondary-900">
          {formatCurrency(order.total)}
        </p>
      </td>
    </tr>
  );
});

const RecentOrdersTable: React.FC<RecentOrdersTableProps> = memo(function RecentOrdersTable({
  orders,
  isLoading,
}) {
  // Memoize the sliced orders
  const displayOrders = useMemo(() => orders.slice(0, 5), [orders]);

  if (isLoading) {
    return (
      <Card padding="none" className="overflow-hidden">
        <div className="px-6 py-4 border-b border-secondary-200 bg-secondary-50">
          <h3 className="text-lg font-semibold text-secondary-900">Recent Orders</h3>
        </div>
        <div className="flex items-center justify-center py-12">
          <Loader2 className="w-8 h-8 text-primary-500 animate-spin" />
        </div>
      </Card>
    );
  }

  return (
    <Card padding="none" className="overflow-hidden">
      <div className="px-6 py-4 border-b border-secondary-200 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center shadow-md shadow-primary-500/25">
            <ShoppingCart className="w-5 h-5 text-white" />
          </div>
          <div>
            <h3 className="text-lg font-semibold text-secondary-900">Recent Orders</h3>
            <p className="text-sm text-secondary-500">Latest transactions</p>
          </div>
        </div>
        <a
          href="/dashboard/orders"
          className="text-sm font-medium text-primary-500 hover:text-primary-600"
        >
          View all
        </a>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full">
          <thead>
            <tr className="bg-secondary-50 border-b border-secondary-200">
              <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">
                Order
              </th>
              <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">
                Customer
              </th>
              <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">
                Status
              </th>
              <th className="px-6 py-3 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">
                Payment
              </th>
              <th className="px-6 py-3 text-right text-xs font-semibold text-secondary-600 uppercase tracking-wider">
                Amount
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-secondary-100">
            {displayOrders.length === 0 ? (
              <tr>
                <td colSpan={5} className="px-6 py-8 text-center text-secondary-500">
                  No recent orders
                </td>
              </tr>
            ) : (
              displayOrders.map((order) => <OrderRow key={order.uuid} order={order} />)
            )}
          </tbody>
        </table>
      </div>
    </Card>
  );
});

export default RecentOrdersTable;
