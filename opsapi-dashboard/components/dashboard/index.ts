import dynamic from 'next/dynamic';
import { Loader2 } from 'lucide-react';
import React from 'react';

export { default as StatsCard } from './StatsCard';
export { default as RecentOrdersTable } from './RecentOrdersTable';
export { default as HealthStatus } from './HealthStatus';

// Lazy load OrdersChart since recharts is a heavy library (~200KB)
// This prevents recharts from being included in the initial bundle
export const OrdersChart = dynamic(() => import('./OrdersChart'), {
  loading: () => (
    React.createElement('div', {
      className: 'h-[400px] bg-white rounded-xl border border-secondary-200 flex items-center justify-center'
    }, React.createElement(Loader2, { className: 'w-8 h-8 text-primary-500 animate-spin' }))
  ),
  ssr: false, // Disable SSR for chart component (recharts doesn't support SSR well)
});
