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
      <div className="bg-surface-elevated border border-secondary-200 px-4 py-3 rounded-lg shadow-lg">
        <p className="text-sm font-medium text-secondary-500">{label}</p>
        <p className="text-lg font-bold mt-1 text-secondary-900">{formatCurrency(payload[0].value)}</p>
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

// Empty state — a polished placeholder instead of a bare void.
const ChartEmpty = memo(function ChartEmpty() {
  return (
    <div className="flex flex-col items-center justify-center h-full text-center px-6">
      <div className="w-12 h-12 rounded-xl bg-secondary-100 flex items-center justify-center mb-3">
        <BarChart3 className="w-6 h-6 text-secondary-400" />
      </div>
      <p className="text-sm font-medium text-secondary-700">No revenue yet</p>
      <p className="text-xs text-secondary-500 mt-1 max-w-[260px]">
        Revenue trends will appear here once orders start coming in.
      </p>
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
          <div className="w-9 h-9 rounded-lg bg-primary-500/10 text-primary-600 flex items-center justify-center">
            <BarChart3 className="w-[18px] h-[18px]" />
          </div>
          <div>
            <h3 className="text-base font-semibold text-secondary-900">Revenue Overview</h3>
            <p className="text-[13px] text-secondary-500">Monthly revenue trends</p>
          </div>
        </div>
      </div>

      <div className="p-6 h-[320px]">
        {data.length === 0 ? (
          <ChartEmpty />
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <AreaChart data={data} margin={chartMargin}>
              {/* Colors reference CSS variables so the chart adapts to the
                  active theme (light/dark) and accent preset automatically. */}
              <defs>
                <linearGradient id="colorRevenue" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="var(--color-primary-500)" stopOpacity={0.25} />
                  <stop offset="95%" stopColor="var(--color-primary-500)" stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--color-secondary-200)" vertical={false} />
              <XAxis
                dataKey="month"
                axisLine={false}
                tickLine={false}
                tick={{ fill: 'var(--color-secondary-500)', fontSize: 12 }}
              />
              <YAxis
                axisLine={false}
                tickLine={false}
                tick={{ fill: 'var(--color-secondary-500)', fontSize: 12 }}
                tickFormatter={yAxisFormatter}
              />
              <Tooltip content={<CustomTooltip />} cursor={{ stroke: 'var(--color-secondary-300)' }} />
              <Area
                type="monotone"
                dataKey="revenue"
                stroke="var(--color-primary-500)"
                strokeWidth={2.5}
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
