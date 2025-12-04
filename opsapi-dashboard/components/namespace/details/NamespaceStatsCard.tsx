'use client';

import React, { memo } from 'react';
import { Users, Store, ShoppingCart, Package, DollarSign, UserCheck, TrendingUp } from 'lucide-react';
import { Card } from '@/components/ui';
import { cn, formatCurrency } from '@/lib/utils';
import type { NamespaceStats, Namespace } from '@/types';

export interface NamespaceStatsCardProps {
  namespace: Namespace;
  stats: NamespaceStats | null;
  isLoading?: boolean;
}

interface StatItemProps {
  icon: React.FC<{ className?: string }>;
  label: string;
  value: string | number;
  iconColor: string;
  bgColor: string;
  subValue?: string;
}

const StatItem: React.FC<StatItemProps> = memo(function StatItem({
  icon: Icon,
  label,
  value,
  iconColor,
  bgColor,
  subValue
}) {
  return (
    <div className="flex items-center gap-3">
      <div className={cn('w-10 h-10 rounded-lg flex items-center justify-center', bgColor)}>
        <Icon className={cn('w-5 h-5', iconColor)} />
      </div>
      <div>
        <p className="text-sm text-secondary-500">{label}</p>
        <p className="text-lg font-semibold text-secondary-900">{value}</p>
        {subValue && <p className="text-xs text-secondary-400">{subValue}</p>}
      </div>
    </div>
  );
});

const LoadingSkeleton = memo(function LoadingSkeleton() {
  return (
    <Card className="p-6">
      <div className="animate-pulse space-y-6">
        <div className="h-5 bg-secondary-200 rounded w-32" />
        <div className="grid grid-cols-2 md:grid-cols-3 gap-6">
          {[1, 2, 3, 4, 5, 6].map((i) => (
            <div key={i} className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-lg bg-secondary-200" />
              <div className="space-y-2">
                <div className="h-3 bg-secondary-200 rounded w-16" />
                <div className="h-5 bg-secondary-200 rounded w-12" />
              </div>
            </div>
          ))}
        </div>
      </div>
    </Card>
  );
});

const NamespaceStatsCard: React.FC<NamespaceStatsCardProps> = memo(function NamespaceStatsCard({
  namespace,
  stats,
  isLoading,
}) {
  if (isLoading) {
    return <LoadingSkeleton />;
  }

  const statItems: StatItemProps[] = [
    {
      icon: Users,
      label: 'Members',
      value: stats?.total_members ?? namespace.member_count ?? 0,
      iconColor: 'text-primary-600',
      bgColor: 'bg-primary-100',
      subValue: `Max: ${namespace.max_users}`,
    },
    {
      icon: Store,
      label: 'Stores',
      value: stats?.total_stores ?? namespace.store_count ?? 0,
      iconColor: 'text-success-600',
      bgColor: 'bg-success-100',
      subValue: `Max: ${namespace.max_stores}`,
    },
    {
      icon: Package,
      label: 'Products',
      value: stats?.total_products ?? 0,
      iconColor: 'text-info-600',
      bgColor: 'bg-info-100',
    },
    {
      icon: ShoppingCart,
      label: 'Orders',
      value: stats?.total_orders ?? 0,
      iconColor: 'text-warning-600',
      bgColor: 'bg-warning-100',
    },
    {
      icon: UserCheck,
      label: 'Customers',
      value: stats?.total_customers ?? 0,
      iconColor: 'text-purple-600',
      bgColor: 'bg-purple-100',
    },
    {
      icon: DollarSign,
      label: 'Revenue',
      value: formatCurrency(stats?.total_revenue ?? 0),
      iconColor: 'text-emerald-600',
      bgColor: 'bg-emerald-100',
    },
  ];

  return (
    <Card className="p-6">
      <div className="flex items-center justify-between mb-6">
        <h2 className="text-lg font-semibold text-secondary-900">Statistics</h2>
        <div className="flex items-center gap-1 text-sm text-success-600">
          <TrendingUp className="w-4 h-4" />
          <span>Active</span>
        </div>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-3 gap-6">
        {statItems.map((item) => (
          <StatItem key={item.label} {...item} />
        ))}
      </div>
    </Card>
  );
});

export default NamespaceStatsCard;
