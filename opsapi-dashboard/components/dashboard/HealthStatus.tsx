'use client';

import React from 'react';
import { Card } from '@/components/ui';
import { cn } from '@/lib/utils';
import { CheckCircle, AlertCircle, XCircle, RefreshCw, Activity, Loader2 } from 'lucide-react';
import type { HealthStatus as HealthStatusType } from '@/types';

interface HealthStatusProps {
  health: HealthStatusType | null;
  isLoading?: boolean;
  onRefresh?: () => void;
}

const HealthStatus: React.FC<HealthStatusProps> = ({ health, isLoading, onRefresh }) => {
  const getStatusIcon = (status: string) => {
    switch (status) {
      case 'healthy':
      case 'ok':
        return <CheckCircle className="w-5 h-5 text-success-500" />;
      case 'degraded':
        return <AlertCircle className="w-5 h-5 text-warning-500" />;
      default:
        return <XCircle className="w-5 h-5 text-error-500" />;
    }
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'healthy':
      case 'ok':
        return 'bg-success-500/10 text-success-600 border-success-200';
      case 'degraded':
        return 'bg-warning-500/10 text-warning-600 border-warning-200';
      default:
        return 'bg-error-500/10 text-error-600 border-error-200';
    }
  };

  if (isLoading || !health) {
    return (
      <Card className="h-full">
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center shadow-md shadow-primary-500/25">
              <Activity className="w-5 h-5 text-white" />
            </div>
            <div>
              <h3 className="text-lg font-semibold text-secondary-900">System Health</h3>
              <p className="text-sm text-secondary-500">Service status</p>
            </div>
          </div>
        </div>
        <div className="flex items-center justify-center py-8">
          <Loader2 className="w-8 h-8 text-primary-500 animate-spin" />
        </div>
      </Card>
    );
  }

  return (
    <Card className="h-full">
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center shadow-md shadow-primary-500/25">
            <Activity className="w-5 h-5 text-white" />
          </div>
          <div>
            <h3 className="text-lg font-semibold text-secondary-900">System Health</h3>
            <p className="text-sm text-secondary-500">Service status</p>
          </div>
        </div>
        {onRefresh && (
          <button
            onClick={onRefresh}
            className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
          >
            <RefreshCw className="w-5 h-5" />
          </button>
        )}
      </div>

      {/* Overall Status */}
      <div
        className={cn(
          'flex items-center justify-between p-4 rounded-xl border mb-4',
          getStatusColor(health.status)
        )}
      >
        <div className="flex items-center gap-3">
          {getStatusIcon(health.status)}
          <div>
            <p className="font-semibold capitalize">{health.status}</p>
            <p className="text-xs opacity-75">Overall system status</p>
          </div>
        </div>
      </div>

      {/* Service Checks */}
      {health.checks && (
        <div className="space-y-3">
          <p className="text-sm font-medium text-secondary-600">Services</p>

          {health.checks.database && (
            <div className="flex items-center justify-between p-3 bg-secondary-50 rounded-lg">
              <div className="flex items-center gap-3">
                {getStatusIcon(health.checks.database.status)}
                <span className="text-sm font-medium text-secondary-700">Database</span>
              </div>
              {health.checks.database.latency_ms && (
                <span className="text-xs text-secondary-500">
                  {health.checks.database.latency_ms}ms
                </span>
              )}
            </div>
          )}

          {health.checks.redis && (
            <div className="flex items-center justify-between p-3 bg-secondary-50 rounded-lg">
              <div className="flex items-center gap-3">
                {getStatusIcon(health.checks.redis.status)}
                <span className="text-sm font-medium text-secondary-700">Redis Cache</span>
              </div>
              {health.checks.redis.latency_ms && (
                <span className="text-xs text-secondary-500">
                  {health.checks.redis.latency_ms}ms
                </span>
              )}
            </div>
          )}

          {health.checks.minio && (
            <div className="flex items-center justify-between p-3 bg-secondary-50 rounded-lg">
              <div className="flex items-center gap-3">
                {getStatusIcon(health.checks.minio.status)}
                <span className="text-sm font-medium text-secondary-700">Object Storage</span>
              </div>
            </div>
          )}
        </div>
      )}

      {health.uptime && (
        <div className="mt-4 pt-4 border-t border-secondary-200">
          <p className="text-xs text-secondary-500">
            Uptime: {Math.floor(health.uptime / 3600)}h {Math.floor((health.uptime % 3600) / 60)}m
          </p>
        </div>
      )}
    </Card>
  );
};

export default HealthStatus;
