'use client';

import React from 'react';
import { Package } from 'lucide-react';
import { Badge, Modal } from '@/components/ui';
import { formatDate, formatCurrency, getFullName } from '@/lib/utils';
import type { Order } from '@/types';

/** An online-store (Stores & Products) order, opened from Sales Orders. */
export interface OrderDetailsModalProps {
  order: Order | null;
  isOpen: boolean;
  onClose: () => void;
  isAdmin: boolean;
}

export const StoreOrderDetailsModal: React.FC<OrderDetailsModalProps> = ({ order, isOpen, onClose, isAdmin }) => {
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
                  {order.items.map((item) => {
                    // The API sends price / total / product_title (orderitems); older shapes used the other names.
                    const raw = item as typeof item & { price?: number | string; total?: number | string; product_title?: string };
                    return (
                      <tr key={item.uuid}>
                        <td className="px-4 py-3 text-secondary-900">{item.product_name || raw.product_title || 'Product'}</td>
                        <td className="px-4 py-3 text-center text-secondary-600">{item.quantity}</td>
                        <td className="px-4 py-3 text-right text-secondary-600">
                          {formatCurrency(Number(item.unit_price ?? raw.price ?? 0), order.currency)}
                        </td>
                        <td className="px-4 py-3 text-right font-medium text-secondary-900">
                          {formatCurrency(Number(item.total_price ?? raw.total ?? 0), order.currency)}
                        </td>
                      </tr>
                    );
                  })}
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
              <span className="text-primary-600">{formatCurrency(Number(order.total ?? (order as typeof order & { total_amount?: number | string }).total_amount ?? 0), order.currency)}</span>
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
