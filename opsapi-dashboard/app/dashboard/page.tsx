'use client';

import React, { useMemo, useCallback } from 'react';
import { Users, ShoppingCart, Package, Store, DollarSign } from 'lucide-react';
import { StatsCard, RecentOrdersTable, OrdersChart, HealthStatus } from '@/components/dashboard';
import { PendingInvitationsBanner } from '@/components/namespace/invitations';
import { dashboardService } from '@/services';
import { formatCurrency } from '@/lib/utils';
import { useDataFetch } from '@/hooks';
import type { DashboardStats, HealthStatus as HealthStatusType } from '@/types';

// Static icons - defined outside component to prevent recreation
const STAT_ICONS = {
  users: <Users className="w-6 h-6" />,
  orders: <ShoppingCart className="w-6 h-6" />,
  products: <Package className="w-6 h-6" />,
  stores: <Store className="w-6 h-6" />,
  revenue: <DollarSign className="w-6 h-6" />,
} as const;

// Fetch function defined outside component to maintain referential equality
const fetchDashboardData = async () => {
  const [stats, health] = await Promise.all([
    dashboardService.getDashboardStats(),
    dashboardService.getHealthStatus(true),
  ]);
  return { stats, health };
};

export default function DashboardPage() {
  // Single data fetch for all dashboard data using custom hook
  const { data, isLoading, refetch } = useDataFetch<{
    stats: DashboardStats;
    health: HealthStatusType;
  }>(fetchDashboardData, []);

  // Memoize stats and health data extraction
  const stats = useMemo(() => data?.stats ?? null, [data?.stats]);
  const health = useMemo(() => data?.health ?? null, [data?.health]);

  // Memoize stats cards configuration
  const statsCards = useMemo(
    () => [
      {
        id: 'users',
        title: 'Total Users',
        value: stats?.totalUsers || 0,
        icon: STAT_ICONS.users,
        trend: { value: 12, isPositive: true },
        description: 'vs last month',
      },
      {
        id: 'orders',
        title: 'Total Orders',
        value: stats?.totalOrders || 0,
        icon: STAT_ICONS.orders,
        trend: { value: 8, isPositive: true },
        description: 'vs last month',
      },
      {
        id: 'products',
        title: 'Total Products',
        value: stats?.totalProducts || 0,
        icon: STAT_ICONS.products,
        trend: { value: 5, isPositive: true },
        description: 'vs last month',
      },
      {
        id: 'stores',
        title: 'Total Stores',
        value: stats?.totalStores || 0,
        icon: STAT_ICONS.stores,
        trend: { value: 3, isPositive: true },
        description: 'vs last month',
      },
      {
        id: 'revenue',
        title: 'Total Revenue',
        value: formatCurrency(stats?.totalRevenue || 0),
        icon: STAT_ICONS.revenue,
        trend: { value: 15, isPositive: true },
        description: 'vs last month',
      },
    ],
    [stats]
  );

  // Memoize chart data
  const chartData = useMemo(() => stats?.revenueByMonth || [], [stats?.revenueByMonth]);

  // Memoize recent orders
  const recentOrders = useMemo(() => stats?.recentOrders || [], [stats?.recentOrders]);

  // Memoize refresh handler to prevent inline function recreation
  const handleRefresh = useCallback(() => {
    refetch();
  }, [refetch]);

  return (
    <div className="space-y-5 sm:space-y-6">
      {/* Pending Invitations Banner */}
      <PendingInvitationsBanner />

      {/* Hero header — brand gradient welcome */}
      <div className="relative overflow-hidden rounded-2xl gradient-primary text-white p-6 sm:p-8 shadow-lg shadow-primary-500/20">
        <div className="pointer-events-none absolute -top-16 -right-10 w-72 h-72 rounded-full bg-white/10 blur-3xl" />
        <div className="pointer-events-none absolute -bottom-24 -left-12 w-72 h-72 rounded-full bg-black/10 blur-3xl" />
        <div className="relative flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 className="text-2xl sm:text-3xl font-bold tracking-tight">Welcome back 👋</h1>
            <p className="text-white/85 mt-1.5 text-sm sm:text-base max-w-xl">
              Here&apos;s what&apos;s happening with your business today.
            </p>
          </div>
          <div className="flex items-center gap-2 text-xs sm:text-sm">
            <span className="inline-flex items-center gap-2 rounded-full bg-white/15 backdrop-blur-sm px-3 py-1.5 font-medium ring-1 ring-white/20">
              <span className="w-2 h-2 rounded-full bg-emerald-300 animate-pulse" />
              {health?.status === 'healthy' ? 'All systems operational' : 'Live overview'}
            </span>
          </div>
        </div>
      </div>

      {/* Stats Cards - Responsive grid */}
      <div className="grid grid-cols-2 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-3 sm:gap-4 lg:gap-6">
        {statsCards.map((card) => (
          <StatsCard
            key={card.id}
            title={card.title}
            value={card.value}
            icon={card.icon}
            trend={card.trend}
            description={card.description}
            isLoading={isLoading}
          />
        ))}
      </div>

      {/* Charts and Health Status — equal-height columns on desktop, health scrolls internally */}
      <div className="grid grid-cols-1 xl:grid-cols-3 gap-4 sm:gap-6 xl:h-[480px]">
        {/* Revenue Chart - Full width on mobile/tablet, 2/3 on desktop */}
        <div className="xl:col-span-2 order-2 xl:order-1 min-h-0">
          <OrdersChart data={chartData} isLoading={isLoading} />
        </div>

        {/* Health Status - Full width on mobile/tablet, 1/3 on desktop */}
        <div className="order-1 xl:order-2 min-h-0">
          <HealthStatus health={health} isLoading={isLoading} onRefresh={handleRefresh} />
        </div>
      </div>

      {/* Recent Orders */}
      <div>
        <RecentOrdersTable orders={recentOrders} isLoading={isLoading} />
      </div>
    </div>
  );
}
