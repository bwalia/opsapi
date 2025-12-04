'use client';

import React, { memo } from 'react';
import {
  Activity,
  UserPlus,
  Store,
  ShoppingCart,
  Package,
  Settings,
  Shield,
  Clock,
} from 'lucide-react';
import { Card } from '@/components/ui';
import { formatRelativeTime, cn } from '@/lib/utils';
import type { Namespace } from '@/types';

export interface NamespaceActivityCardProps {
  namespace: Namespace;
  activities?: ActivityItem[];
  isLoading?: boolean;
}

export interface ActivityItem {
  id: string;
  type: 'member_joined' | 'member_left' | 'store_created' | 'order_placed' | 'product_added' | 'settings_updated' | 'role_changed';
  description: string;
  user?: {
    name: string;
    email?: string;
  };
  timestamp: string;
  metadata?: Record<string, unknown>;
}

const ACTIVITY_ICONS: Record<string, React.FC<{ className?: string }>> = {
  member_joined: UserPlus,
  member_left: UserPlus,
  store_created: Store,
  order_placed: ShoppingCart,
  product_added: Package,
  settings_updated: Settings,
  role_changed: Shield,
};

const ACTIVITY_COLORS: Record<string, { icon: string; bg: string }> = {
  member_joined: { icon: 'text-success-600', bg: 'bg-success-100' },
  member_left: { icon: 'text-error-600', bg: 'bg-error-100' },
  store_created: { icon: 'text-primary-600', bg: 'bg-primary-100' },
  order_placed: { icon: 'text-warning-600', bg: 'bg-warning-100' },
  product_added: { icon: 'text-info-600', bg: 'bg-info-100' },
  settings_updated: { icon: 'text-secondary-600', bg: 'bg-secondary-100' },
  role_changed: { icon: 'text-purple-600', bg: 'bg-purple-100' },
};

interface ActivityRowProps {
  activity: ActivityItem;
}

const ActivityRow: React.FC<ActivityRowProps> = memo(function ActivityRow({ activity }) {
  const Icon = ACTIVITY_ICONS[activity.type] || Activity;
  const colors = ACTIVITY_COLORS[activity.type] || { icon: 'text-secondary-600', bg: 'bg-secondary-100' };

  return (
    <div className="flex items-start gap-3 py-3 border-b border-secondary-100 last:border-b-0">
      <div className={cn('w-8 h-8 rounded-lg flex items-center justify-center flex-shrink-0', colors.bg)}>
        <Icon className={cn('w-4 h-4', colors.icon)} />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm text-secondary-900">{activity.description}</p>
        {activity.user && (
          <p className="text-xs text-secondary-500 mt-0.5">
            by {activity.user.name}
          </p>
        )}
      </div>
      <div className="flex items-center gap-1 text-xs text-secondary-400 flex-shrink-0">
        <Clock className="w-3 h-3" />
        <span>{formatRelativeTime(activity.timestamp)}</span>
      </div>
    </div>
  );
});

const LoadingSkeleton = memo(function LoadingSkeleton() {
  return (
    <Card className="p-6">
      <div className="animate-pulse space-y-4">
        <div className="h-5 bg-secondary-200 rounded w-32" />
        {[1, 2, 3, 4].map((i) => (
          <div key={i} className="flex items-start gap-3 py-3">
            <div className="w-8 h-8 rounded-lg bg-secondary-200" />
            <div className="flex-1 space-y-2">
              <div className="h-4 bg-secondary-200 rounded w-3/4" />
              <div className="h-3 bg-secondary-200 rounded w-24" />
            </div>
          </div>
        ))}
      </div>
    </Card>
  );
});

const EmptyState = memo(function EmptyState() {
  return (
    <div className="text-center py-8">
      <Activity className="w-12 h-12 text-secondary-300 mx-auto mb-3" />
      <p className="text-secondary-500 text-sm">No recent activity</p>
      <p className="text-secondary-400 text-xs mt-1">
        Activity will appear here when members take actions
      </p>
    </div>
  );
});

// Generate mock activities for demo purposes
// In production, this would come from an API
const generateMockActivities = (namespace: Namespace): ActivityItem[] => {
  const now = new Date();
  return [
    {
      id: '1',
      type: 'member_joined',
      description: 'New member joined the namespace',
      user: { name: 'John Doe', email: 'john@example.com' },
      timestamp: new Date(now.getTime() - 1000 * 60 * 30).toISOString(), // 30 mins ago
    },
    {
      id: '2',
      type: 'store_created',
      description: 'New store "Fresh Produce" was created',
      user: { name: 'Jane Smith' },
      timestamp: new Date(now.getTime() - 1000 * 60 * 60 * 2).toISOString(), // 2 hours ago
    },
    {
      id: '3',
      type: 'order_placed',
      description: 'Order #1234 was placed for $125.00',
      timestamp: new Date(now.getTime() - 1000 * 60 * 60 * 5).toISOString(), // 5 hours ago
    },
    {
      id: '4',
      type: 'settings_updated',
      description: 'Namespace settings were updated',
      user: { name: 'Admin User' },
      timestamp: new Date(now.getTime() - 1000 * 60 * 60 * 24).toISOString(), // 1 day ago
    },
  ];
};

const NamespaceActivityCard: React.FC<NamespaceActivityCardProps> = memo(function NamespaceActivityCard({
  namespace,
  activities: providedActivities,
  isLoading,
}) {
  if (isLoading) {
    return <LoadingSkeleton />;
  }

  // Use provided activities or generate mock ones for demo
  const activities = providedActivities || generateMockActivities(namespace);

  return (
    <Card className="p-6">
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-2">
          <Activity className="w-5 h-5 text-secondary-500" />
          <h2 className="text-lg font-semibold text-secondary-900">Recent Activity</h2>
        </div>
        <span className="text-xs text-secondary-400">Last 7 days</span>
      </div>

      {activities.length === 0 ? (
        <EmptyState />
      ) : (
        <div className="divide-y divide-secondary-100">
          {activities.map((activity) => (
            <ActivityRow key={activity.id} activity={activity} />
          ))}
        </div>
      )}
    </Card>
  );
});

export default NamespaceActivityCard;
