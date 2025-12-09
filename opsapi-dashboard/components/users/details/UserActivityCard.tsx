'use client';

import React, { memo } from 'react';
import { Activity, LogIn, UserPlus, Settings, Package } from 'lucide-react';
import { Card } from '@/components/ui';
import { formatDate } from '@/lib/utils';
import type { User } from '@/types';

export interface UserActivityCardProps {
  user: User;
  isLoading?: boolean;
}

interface ActivityItem {
  id: string;
  type: 'login' | 'signup' | 'update' | 'order';
  title: string;
  timestamp: string;
  icon: React.ReactNode;
  iconBg: string;
}

const UserActivityCard: React.FC<UserActivityCardProps> = memo(function UserActivityCard({
  user,
  isLoading,
}) {
  if (isLoading) {
    return (
      <Card className="p-6 animate-pulse">
        <div className="h-5 bg-secondary-200 rounded w-32 mb-6" />
        <div className="space-y-4">
          {[1, 2, 3].map((i) => (
            <div key={i} className="flex items-start gap-3">
              <div className="w-8 h-8 rounded-full bg-secondary-200" />
              <div className="flex-1 space-y-1">
                <div className="h-4 bg-secondary-200 rounded w-40" />
                <div className="h-3 bg-secondary-200 rounded w-24" />
              </div>
            </div>
          ))}
        </div>
      </Card>
    );
  }

  // Generate activity items based on user data
  const activities: ActivityItem[] = [];

  // Account created
  if (user.created_at) {
    activities.push({
      id: 'created',
      type: 'signup',
      title: 'Account created',
      timestamp: user.created_at,
      icon: <UserPlus className="w-4 h-4 text-success-600" />,
      iconBg: 'bg-success-100',
    });
  }

  // Profile updated (if different from created)
  if (user.updated_at && user.updated_at !== user.created_at) {
    activities.push({
      id: 'updated',
      type: 'update',
      title: 'Profile updated',
      timestamp: user.updated_at,
      icon: <Settings className="w-4 h-4 text-info-600" />,
      iconBg: 'bg-info-100',
    });
  }

  // Sort by timestamp descending
  activities.sort((a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime());

  return (
    <Card className="p-6">
      <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
        Recent Activity
      </h3>

      {activities.length === 0 ? (
        <div className="text-center py-6 text-secondary-500">
          <Activity className="w-10 h-10 mx-auto mb-2 text-secondary-300" />
          <p className="text-sm">No recent activity</p>
        </div>
      ) : (
        <div className="relative">
          {/* Timeline line */}
          <div className="absolute left-4 top-0 bottom-0 w-px bg-secondary-200" />

          <div className="space-y-4">
            {activities.map((activity, index) => (
              <div key={activity.id} className="relative flex items-start gap-3 pl-0">
                {/* Icon */}
                <div
                  className={`w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0 z-10 ${activity.iconBg}`}
                >
                  {activity.icon}
                </div>

                {/* Content */}
                <div className="flex-1 min-w-0 pt-0.5">
                  <p className="text-sm text-secondary-900">{activity.title}</p>
                  <p className="text-xs text-secondary-500 mt-0.5">
                    {formatDate(activity.timestamp)}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </Card>
  );
});

export default UserActivityCard;
