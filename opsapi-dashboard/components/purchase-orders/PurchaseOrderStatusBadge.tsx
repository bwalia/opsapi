'use client';

import React from 'react';
import type { PurchaseOrderStatus } from '@/services/purchase-orders.service';

const CONFIG: Record<PurchaseOrderStatus, { label: string; classes: string }> = {
  draft: { label: 'Draft', classes: 'bg-gray-100 text-gray-700' },
  sent: { label: 'Sent', classes: 'bg-blue-100 text-blue-700' },
  acknowledged: { label: 'Acknowledged', classes: 'bg-indigo-100 text-indigo-700' },
  partially_received: { label: 'Partially Received', classes: 'bg-yellow-100 text-yellow-700' },
  received: { label: 'Received', classes: 'bg-green-100 text-green-700' },
  billed: { label: 'Billed', classes: 'bg-emerald-100 text-emerald-800' },
  cancelled: { label: 'Cancelled', classes: 'bg-gray-100 text-gray-500' },
};

export const PurchaseOrderStatusBadge: React.FC<{ status: PurchaseOrderStatus }> = ({ status }) => {
  const { label, classes } = CONFIG[status] || { label: status, classes: 'bg-gray-100 text-gray-700' };
  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${classes}`}>
      {label}
    </span>
  );
};

export default PurchaseOrderStatusBadge;
