'use client';

import React, { memo } from 'react';
import { Settings, Globe, Calendar, Clock, Shield, Hash, Users, Store } from 'lucide-react';
import { Card, Badge } from '@/components/ui';
import { formatDate, cn } from '@/lib/utils';
import type { Namespace, NamespacePlan } from '@/types';

export interface NamespaceSettingsCardProps {
  namespace: Namespace;
  isLoading?: boolean;
}

interface SettingRowProps {
  icon: React.FC<{ className?: string }>;
  label: string;
  value: React.ReactNode;
  iconColor?: string;
}

const SettingRow: React.FC<SettingRowProps> = memo(function SettingRow({
  icon: Icon,
  label,
  value,
  iconColor = 'text-secondary-400',
}) {
  return (
    <div className="flex items-center justify-between py-3 border-b border-secondary-100 last:border-b-0">
      <div className="flex items-center gap-3">
        <Icon className={cn('w-4 h-4', iconColor)} />
        <span className="text-sm text-secondary-600">{label}</span>
      </div>
      <div className="text-sm font-medium text-secondary-900">{value}</div>
    </div>
  );
});

const PLAN_CONFIG: Record<NamespacePlan, { color: string; label: string }> = {
  free: { color: 'bg-secondary-100 text-secondary-700', label: 'Free' },
  starter: { color: 'bg-info-100 text-info-700', label: 'Starter' },
  professional: { color: 'bg-primary-100 text-primary-700', label: 'Professional' },
  enterprise: { color: 'bg-warning-100 text-warning-700', label: 'Enterprise' },
};

const LoadingSkeleton = memo(function LoadingSkeleton() {
  return (
    <Card className="p-6">
      <div className="animate-pulse space-y-4">
        <div className="h-5 bg-secondary-200 rounded w-32" />
        {[1, 2, 3, 4, 5].map((i) => (
          <div key={i} className="flex items-center justify-between py-3">
            <div className="flex items-center gap-3">
              <div className="w-4 h-4 bg-secondary-200 rounded" />
              <div className="h-4 bg-secondary-200 rounded w-24" />
            </div>
            <div className="h-4 bg-secondary-200 rounded w-32" />
          </div>
        ))}
      </div>
    </Card>
  );
});

const NamespaceSettingsCard: React.FC<NamespaceSettingsCardProps> = memo(function NamespaceSettingsCard({
  namespace,
  isLoading,
}) {
  if (isLoading) {
    return <LoadingSkeleton />;
  }

  const planConfig = PLAN_CONFIG[namespace.plan] || PLAN_CONFIG.free;

  return (
    <Card className="p-6">
      <div className="flex items-center gap-2 mb-4">
        <Settings className="w-5 h-5 text-secondary-500" />
        <h2 className="text-lg font-semibold text-secondary-900">Configuration</h2>
      </div>

      <div className="divide-y divide-secondary-100">
        <SettingRow
          icon={Hash}
          label="UUID"
          value={
            <code className="text-xs bg-secondary-100 px-2 py-0.5 rounded font-mono">
              {namespace.uuid.slice(0, 8)}...
            </code>
          }
        />
        <SettingRow
          icon={Shield}
          label="Plan"
          value={
            <span className={cn('px-2 py-0.5 rounded text-xs font-medium', planConfig.color)}>
              {planConfig.label}
            </span>
          }
          iconColor="text-primary-500"
        />
        <SettingRow
          icon={Users}
          label="Max Users"
          value={namespace.max_users.toLocaleString()}
          iconColor="text-info-500"
        />
        <SettingRow
          icon={Store}
          label="Max Stores"
          value={namespace.max_stores.toLocaleString()}
          iconColor="text-success-500"
        />
        {namespace.domain && (
          <SettingRow
            icon={Globe}
            label="Domain"
            value={
              <a
                href={`https://${namespace.domain}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-primary-600 hover:underline"
              >
                {namespace.domain}
              </a>
            }
            iconColor="text-purple-500"
          />
        )}
        <SettingRow
          icon={Calendar}
          label="Created"
          value={formatDate(namespace.created_at)}
          iconColor="text-secondary-400"
        />
        <SettingRow
          icon={Clock}
          label="Last Updated"
          value={formatDate(namespace.updated_at)}
          iconColor="text-secondary-400"
        />
      </div>
    </Card>
  );
});

export default NamespaceSettingsCard;
