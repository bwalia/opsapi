'use client';

import React, { useState, useEffect, useRef, useCallback } from 'react';
import { Users, ShoppingCart, Package, Store, DollarSign } from 'lucide-react';
import { StatsCard, RecentOrdersTable, OrdersChart, HealthStatus } from '@/components/dashboard';
import { dashboardService } from '@/services';
import { formatCurrency } from '@/lib/utils';
import type { DashboardStats, HealthStatus as HealthStatusType } from '@/types';

export default function DashboardPage() {
  const [stats, setStats] = useState<DashboardStats | null>(null);
  const [health, setHealth] = useState<HealthStatusType | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const hasFetched = useRef(false);

  const fetchData = useCallback(async (force = false) => {
    // Prevent duplicate fetches unless forced (manual refresh)
    if (hasFetched.current && !force) return;
    hasFetched.current = true;

    setIsLoading(true);
    try {
      const [statsData, healthData] = await Promise.all([
        dashboardService.getDashboardStats(),
        dashboardService.getHealthStatus(true),
      ]);
      setStats(statsData);
      setHealth(healthData);
    } catch (error) {
      console.error('Failed to fetch dashboard data:', error);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const statsCards = [
    {
      title: 'Total Users',
      value: stats?.totalUsers || 0,
      icon: <Users className="w-6 h-6" />,
      trend: { value: 12, isPositive: true },
      description: 'vs last month',
    },
    {
      title: 'Total Orders',
      value: stats?.totalOrders || 0,
      icon: <ShoppingCart className="w-6 h-6" />,
      trend: { value: 8, isPositive: true },
      description: 'vs last month',
    },
    {
      title: 'Total Products',
      value: stats?.totalProducts || 0,
      icon: <Package className="w-6 h-6" />,
      trend: { value: 5, isPositive: true },
      description: 'vs last month',
    },
    {
      title: 'Total Stores',
      value: stats?.totalStores || 0,
      icon: <Store className="w-6 h-6" />,
      trend: { value: 3, isPositive: true },
      description: 'vs last month',
    },
    {
      title: 'Total Revenue',
      value: formatCurrency(stats?.totalRevenue || 0),
      icon: <DollarSign className="w-6 h-6" />,
      trend: { value: 15, isPositive: true },
      description: 'vs last month',
    },
  ];

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div>
        <h1 className="text-2xl font-bold text-secondary-900">Dashboard</h1>
        <p className="text-secondary-500 mt-1">
          Welcome back! Here&apos;s what&apos;s happening with your business.
        </p>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5 gap-6">
        {statsCards.map((card) => (
          <StatsCard
            key={card.title}
            title={card.title}
            value={card.value}
            icon={card.icon}
            trend={card.trend}
            description={card.description}
          />
        ))}
      </div>

      {/* Charts and Tables */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Revenue Chart */}
        <div className="lg:col-span-2">
          <OrdersChart data={stats?.revenueByMonth || []} isLoading={isLoading} />
        </div>

        {/* Health Status */}
        <HealthStatus health={health} isLoading={isLoading} onRefresh={() => fetchData(true)} />
      </div>

      {/* Recent Orders */}
      <div className="grid grid-cols-1 gap-6">
        <RecentOrdersTable orders={stats?.recentOrders || []} isLoading={isLoading} />
      </div>
    </div>
  );
}
