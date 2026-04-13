'use client';

import React, { memo, useMemo, useCallback } from 'react';
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts';
import { Card } from '@/components/ui';
import { formatCurrency } from '@/lib/utils';
import { BarChart3, Loader2 } from 'lucide-react';

interface OrdersChartProps {
  data: { month: string; revenue: number }[];
  isLoading?: boolean;
}

// Custom tooltip component - memoized
const CustomTooltip = memo(function CustomTooltip({
  active,
  payload,
  label,
}: {
  active?: boolean;
  payload?: Array<{ value: number }>;
  label?: string;
}) {
  if (active && payload && payload.length) {
    return (
      <div className="bg-secondary-900 text-white px-4 py-3 rounded-lg shadow-lg">
        <p className="text-sm font-medium">{label}</p>
        <p className="text-lg font-bold mt-1">{formatCurrency(payload[0].value)}</p>
      </div>
    );
  }
  return null;
});

// Loading state component
const ChartLoading = memo(function ChartLoading() {
  return (
    <Card padding="none" className="h-[400px]">
      <div className="px-6 py-4 border-b border-secondary-200">
        <h3 className="text-lg font-semibold text-secondary-900">Revenue Overview</h3>
      </div>
      <div className="flex items-center justify-center h-[320px]">
        <Loader2 className="w-8 h-8 text-primary-500 animate-spin" />
      </div>
    </Card>
  );
});

// Empty state component
const ChartEmpty = memo(function ChartEmpty() {
  return (
    <div className="flex items-center justify-center h-full text-secondary-500">
      No data available
    </div>
  );
});

const OrdersChart: React.FC<OrdersChartProps> = memo(function OrdersChart({
  data,
  isLoading,
}) {
  // Memoize the Y-axis formatter
  const yAxisFormatter = useCallback((value: number) => `$${value / 1000}k`, []);

  // Memoize chart configuration
  const chartMargin = useMemo(() => ({ top: 10, right: 10, left: 0, bottom: 0 }), []);

  if (isLoading) {
    return <ChartLoading />;
  }

  return (
    <Card padding="none" className="h-[400px]">
      <div className="px-6 py-4 border-b border-secondary-200 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center shadow-md shadow-primary-500/25">
            <BarChart3 className="w-5 h-5 text-white" />
          </div>
          <div>
            <h3 className="text-lg font-semibold text-secondary-900">Revenue Overview</h3>
            <p className="text-sm text-secondary-500">Monthly revenue trends</p>
          </div>
        </div>
      </div>

      <div className="p-6 h-[320px]">
        {data.length === 0 ? (
          <ChartEmpty />
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <AreaChart data={data} margin={chartMargin}>
              <defs>
                <linearGradient id="colorRevenue" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="#ff004e" stopOpacity={0.3} />
                  <stop offset="95%" stopColor="#ff004e" stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" vertical={false} />
              <XAxis
                dataKey="month"
                axisLine={false}
                tickLine={false}
                tick={{ fill: '#64748b', fontSize: 12 }}
              />
              <YAxis
                axisLine={false}
                tickLine={false}
                tick={{ fill: '#64748b', fontSize: 12 }}
                tickFormatter={yAxisFormatter}
              />
              <Tooltip content={<CustomTooltip />} />
              <Area
                type="monotone"
                dataKey="revenue"
                stroke="#ff004e"
                strokeWidth={3}
                fillOpacity={1}
                fill="url(#colorRevenue)"
              />
            </AreaChart>
          </ResponsiveContainer>
        )}
      </div>
    </Card>
  );
});

export default OrdersChart;
