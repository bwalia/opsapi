'use client';

import React, { memo } from 'react';
import { Building2, Crown, ArrowLeft, Edit, Settings, MoreVertical } from 'lucide-react';
import { Button, Badge } from '@/components/ui';
import { cn } from '@/lib/utils';
import Link from 'next/link';
import type { Namespace, NamespaceStatus, NamespacePlan } from '@/types';

export interface NamespaceHeaderProps {
  namespace: Namespace;
  onEdit?: () => void;
  onSettings?: () => void;
  isLoading?: boolean;
}

const STATUS_CONFIG: Record<NamespaceStatus, { variant: 'success' | 'warning' | 'error' | 'default'; label: string }> = {
  active: { variant: 'success', label: 'Active' },
  pending: { variant: 'warning', label: 'Pending' },
  suspended: { variant: 'error', label: 'Suspended' },
  archived: { variant: 'default', label: 'Archived' },
};

const PLAN_CONFIG: Record<NamespacePlan, { color: string; label: string }> = {
  free: { color: 'bg-secondary-100 text-secondary-700 border-secondary-200', label: 'Free' },
  starter: { color: 'bg-info-100 text-info-700 border-info-200', label: 'Starter' },
  professional: { color: 'bg-primary-100 text-primary-700 border-primary-200', label: 'Professional' },
  enterprise: { color: 'bg-warning-100 text-warning-700 border-warning-200', label: 'Enterprise' },
};

const NamespaceHeader: React.FC<NamespaceHeaderProps> = memo(function NamespaceHeader({
  namespace,
  onEdit,
  onSettings,
  isLoading,
}) {
  const statusConfig = STATUS_CONFIG[namespace.status] || STATUS_CONFIG.active;
  const planConfig = PLAN_CONFIG[namespace.plan] || PLAN_CONFIG.free;
  const isSystemNamespace = namespace.slug === 'system' || namespace.slug === 'default';

  if (isLoading) {
    return (
      <div className="bg-white rounded-xl border border-secondary-200 p-6 animate-pulse">
        <div className="flex items-center gap-4">
          <div className="w-16 h-16 rounded-xl bg-secondary-200" />
          <div className="flex-1 space-y-2">
            <div className="h-6 bg-secondary-200 rounded w-48" />
            <div className="h-4 bg-secondary-200 rounded w-32" />
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
      {/* Banner */}
      <div
        className={cn(
          "h-24 bg-gradient-to-r from-primary-500 to-primary-600",
          namespace.banner_url && "bg-cover bg-center"
        )}
        style={namespace.banner_url ? { backgroundImage: `url(${namespace.banner_url})` } : undefined}
      />

      {/* Content */}
      <div className="px-6 pb-6">
        {/* Back button and logo row */}
        <div className="flex items-start justify-between -mt-10">
          <div className="flex items-end gap-4">
            {/* Logo */}
            <div className="w-20 h-20 rounded-xl bg-white border-4 border-white shadow-md flex items-center justify-center overflow-hidden">
              {namespace.logo_url ? (
                <img
                  src={namespace.logo_url}
                  alt={namespace.name}
                  className="w-full h-full object-cover"
                />
              ) : (
                <div className="w-full h-full bg-primary-100 flex items-center justify-center">
                  <Building2 className="w-8 h-8 text-primary-600" />
                </div>
              )}
            </div>
          </div>

          {/* Actions */}
          <div className="flex items-center gap-2 pt-12">
            <Link href="/dashboard/namespaces">
              <Button variant="ghost" size="sm" leftIcon={<ArrowLeft className="w-4 h-4" />}>
                Back to List
              </Button>
            </Link>
            {onEdit && (
              <Button
                variant="outline"
                size="sm"
                leftIcon={<Edit className="w-4 h-4" />}
                onClick={onEdit}
              >
                Edit
              </Button>
            )}
            {onSettings && (
              <Button
                variant="outline"
                size="sm"
                leftIcon={<Settings className="w-4 h-4" />}
                onClick={onSettings}
              >
                Settings
              </Button>
            )}
          </div>
        </div>

        {/* Namespace Info */}
        <div className="mt-4">
          <div className="flex items-center gap-3">
            <h1 className="text-2xl font-bold text-secondary-900">{namespace.name}</h1>
            {isSystemNamespace && (
              <span title="System Namespace">
                <Crown className="w-5 h-5 text-warning-500" />
              </span>
            )}
            <Badge variant={statusConfig.variant}>{statusConfig.label}</Badge>
            <span className={cn('px-2 py-0.5 rounded text-xs font-medium border', planConfig.color)}>
              {planConfig.label}
            </span>
          </div>
          <p className="text-sm text-secondary-500 mt-1">@{namespace.slug}</p>
          {namespace.description && (
            <p className="text-secondary-600 mt-3">{namespace.description}</p>
          )}
          {namespace.domain && (
            <p className="text-sm text-primary-600 mt-2">
              <a href={`https://${namespace.domain}`} target="_blank" rel="noopener noreferrer" className="hover:underline">
                {namespace.domain}
              </a>
            </p>
          )}
        </div>
      </div>
    </div>
  );
});

export default NamespaceHeader;
