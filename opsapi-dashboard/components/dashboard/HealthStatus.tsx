'use client';

import React, { memo, useMemo, useCallback, useState } from 'react';
import { Card } from '@/components/ui';
import { cn, formatBytes } from '@/lib/utils';
import {
  CheckCircle,
  AlertCircle,
  XCircle,
  RefreshCw,
  Activity,
  Loader2,
  Database,
  Server,
  HardDrive,
  Cpu,
  Clock,
  ChevronDown,
  ChevronUp,
  Users,
  ShoppingCart,
  Store,
  Zap,
  MemoryStick,
  Timer,
  FileCheck,
  Wifi,
} from 'lucide-react';
import type { HealthStatus as HealthStatusType, HealthCheck, HealthCheckDetails } from '@/types';

interface HealthStatusProps {
  health: HealthStatusType | null;
  isLoading?: boolean;
  onRefresh?: () => void;
}

// Status icon helper
const getStatusIcon = (status: string, size: string = 'w-4 h-4') => {
  switch (status) {
    case 'healthy':
    case 'ok':
      return <CheckCircle className={`${size} text-success-500`} />;
    case 'degraded':
      return <AlertCircle className={`${size} text-warning-500`} />;
    default:
      return <XCircle className={`${size} text-error-500`} />;
  }
};

// Status color helper
const getStatusBadgeClass = (status: string) => {
  switch (status) {
    case 'healthy':
    case 'ok':
      return 'bg-success-100 text-success-700 border-success-200';
    case 'degraded':
      return 'bg-warning-100 text-warning-700 border-warning-200';
    default:
      return 'bg-error-100 text-error-700 border-error-200';
  }
};

// Service icon helper
const getServiceIcon = (name: string) => {
  const iconClass = 'w-5 h-5';
  switch (name.toLowerCase()) {
    case 'database':
      return <Database className={iconClass} />;
    case 'redis':
      return <Server className={iconClass} />;
    case 'filesystem':
      return <HardDrive className={iconClass} />;
    case 'system':
      return <Cpu className={iconClass} />;
    case 'migrations':
      return <FileCheck className={iconClass} />;
    default:
      return <Server className={iconClass} />;
  }
};

// Format service name
const formatServiceName = (name: string) => {
  return name.charAt(0).toUpperCase() + name.slice(1).replace(/_/g, ' ');
};

// Format uptime
const formatUptime = (seconds: number): string => {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);

  if (days > 0) {
    return `${days}d ${hours}h ${minutes}m`;
  }
  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  return `${minutes}m`;
};

// Detail row component
const DetailRow = memo(function DetailRow({
  icon,
  label,
  value,
  valueClass,
}: {
  icon: React.ReactNode;
  label: string;
  value: string | number;
  valueClass?: string;
}) {
  return (
    <div className="flex items-center justify-between py-1.5">
      <div className="flex items-center gap-2 text-secondary-500">
        {icon}
        <span className="text-xs">{label}</span>
      </div>
      <span className={cn('text-xs font-medium text-secondary-700', valueClass)}>{value}</span>
    </div>
  );
});

// Database details component
const DatabaseDetails = memo(function DatabaseDetails({ details }: { details: HealthCheckDetails }) {
  return (
    <div className="space-y-1 pt-2 border-t border-secondary-100">
      {details.total_users !== undefined && (
        <DetailRow
          icon={<Users className="w-3.5 h-3.5" />}
          label="Total Users"
          value={details.total_users}
        />
      )}
      {details.total_orders !== undefined && (
        <DetailRow
          icon={<ShoppingCart className="w-3.5 h-3.5" />}
          label="Total Orders"
          value={details.total_orders}
        />
      )}
      {details.total_stores !== undefined && (
        <DetailRow
          icon={<Store className="w-3.5 h-3.5" />}
          label="Total Stores"
          value={details.total_stores}
        />
      )}
      {details.database_size_bytes !== undefined && (
        <DetailRow
          icon={<HardDrive className="w-3.5 h-3.5" />}
          label="Database Size"
          value={formatBytes(details.database_size_bytes)}
        />
      )}
      {details.connected !== undefined && (
        <DetailRow
          icon={<Wifi className="w-3.5 h-3.5" />}
          label="Connection"
          value={details.connected ? 'Connected' : 'Disconnected'}
          valueClass={details.connected ? 'text-success-600' : 'text-error-600'}
        />
      )}
      {details.server_time && (
        <DetailRow
          icon={<Clock className="w-3.5 h-3.5" />}
          label="Server Time"
          value={new Date(details.server_time).toLocaleTimeString()}
        />
      )}
    </div>
  );
});

// System details component
const SystemDetails = memo(function SystemDetails({ details }: { details: HealthCheckDetails }) {
  return (
    <div className="space-y-1 pt-2 border-t border-secondary-100">
      {details.uptime_seconds !== undefined && (
        <DetailRow
          icon={<Timer className="w-3.5 h-3.5" />}
          label="Uptime"
          value={formatUptime(details.uptime_seconds)}
        />
      )}
      {details.memory_usage_mb !== undefined && (
        <DetailRow
          icon={<MemoryStick className="w-3.5 h-3.5" />}
          label="Memory Usage"
          value={`${details.memory_usage_mb} MB`}
        />
      )}
      {details.worker_count !== undefined && (
        <DetailRow
          icon={<Zap className="w-3.5 h-3.5" />}
          label="Worker Count"
          value={details.worker_count}
        />
      )}
      {details.worker_pid !== undefined && (
        <DetailRow
          icon={<Cpu className="w-3.5 h-3.5" />}
          label="Worker PID"
          value={details.worker_pid}
        />
      )}
    </div>
  );
});

// Migrations details component
const MigrationsDetails = memo(function MigrationsDetails({
  details,
}: {
  details: HealthCheckDetails;
}) {
  return (
    <div className="space-y-1 pt-2 border-t border-secondary-100">
      {details.migrations_applied !== undefined && (
        <DetailRow
          icon={<FileCheck className="w-3.5 h-3.5" />}
          label="Migrations Applied"
          value={details.migrations_applied}
        />
      )}
      {details.migrations_table_exists !== undefined && (
        <DetailRow
          icon={<Database className="w-3.5 h-3.5" />}
          label="Migrations Table"
          value={details.migrations_table_exists ? 'Exists' : 'Missing'}
          valueClass={details.migrations_table_exists ? 'text-success-600' : 'text-error-600'}
        />
      )}
    </div>
  );
});

// Filesystem details component
const FilesystemDetails = memo(function FilesystemDetails({
  details,
}: {
  details: HealthCheckDetails;
}) {
  return (
    <div className="space-y-1 pt-2 border-t border-secondary-100">
      {details.writable !== undefined && (
        <DetailRow
          icon={<HardDrive className="w-3.5 h-3.5" />}
          label="Writable"
          value={details.writable ? 'Yes' : 'No'}
          valueClass={details.writable ? 'text-success-600' : 'text-error-600'}
        />
      )}
      {details.readable !== undefined && (
        <DetailRow
          icon={<HardDrive className="w-3.5 h-3.5" />}
          label="Readable"
          value={details.readable ? 'Yes' : 'No'}
          valueClass={details.readable ? 'text-success-600' : 'text-error-600'}
        />
      )}
      {details.test_passed !== undefined && (
        <DetailRow
          icon={<CheckCircle className="w-3.5 h-3.5" />}
          label="Test Status"
          value={details.test_passed ? 'Passed' : 'Failed'}
          valueClass={details.test_passed ? 'text-success-600' : 'text-error-600'}
        />
      )}
    </div>
  );
});

// Redis details component
const RedisDetails = memo(function RedisDetails({ details }: { details: HealthCheckDetails }) {
  return (
    <div className="space-y-1 pt-2 border-t border-secondary-100">
      <DetailRow
        icon={<Wifi className="w-3.5 h-3.5" />}
        label="Connection"
        value={details.connected ? 'Connected' : 'Disconnected'}
        valueClass={details.connected ? 'text-success-600' : 'text-error-600'}
      />
    </div>
  );
});

// Service check card component - expandable
const ServiceCheckCard = memo(function ServiceCheckCard({ check }: { check: HealthCheck }) {
  const [isExpanded, setIsExpanded] = useState(true);
  const hasDetails = check.details && Object.keys(check.details).length > 0;

  const toggleExpand = useCallback(() => {
    if (hasDetails) {
      setIsExpanded((prev) => !prev);
    }
  }, [hasDetails]);

  const renderDetails = () => {
    if (!check.details) return null;

    switch (check.name.toLowerCase()) {
      case 'database':
        return <DatabaseDetails details={check.details} />;
      case 'system':
        return <SystemDetails details={check.details} />;
      case 'migrations':
        return <MigrationsDetails details={check.details} />;
      case 'filesystem':
        return <FilesystemDetails details={check.details} />;
      case 'redis':
        return <RedisDetails details={check.details} />;
      default:
        return null;
    }
  };

  return (
    <div className="bg-white border border-secondary-200 rounded-lg overflow-hidden">
      {/* Header */}
      <button
        onClick={toggleExpand}
        className={cn(
          'w-full flex items-center justify-between p-3 transition-colors',
          hasDetails && 'hover:bg-secondary-50 cursor-pointer',
          !hasDetails && 'cursor-default'
        )}
        disabled={!hasDetails}
      >
        <div className="flex items-center gap-3">
          <div
            className={cn(
              'w-9 h-9 rounded-lg flex items-center justify-center',
              check.status === 'healthy'
                ? 'bg-success-100 text-success-600'
                : check.status === 'degraded'
                  ? 'bg-warning-100 text-warning-600'
                  : 'bg-error-100 text-error-600'
            )}
          >
            {getServiceIcon(check.name)}
          </div>
          <div className="text-left">
            <p className="text-sm font-medium text-secondary-900">
              {formatServiceName(check.name)}
            </p>
            {check.error && (
              <p className="text-xs text-error-500 truncate max-w-[150px] sm:max-w-[200px]" title={check.error}>
                {check.error.split(':').slice(-1)[0].trim()}
              </p>
            )}
          </div>
        </div>

        <div className="flex items-center gap-2">
          {check.response_time_ms !== undefined && check.response_time_ms > 0 && (
            <span className="text-xs text-secondary-500 hidden sm:inline">
              {check.response_time_ms}ms
            </span>
          )}
          <span
            className={cn(
              'px-2 py-0.5 text-xs font-medium rounded-full border capitalize',
              getStatusBadgeClass(check.status)
            )}
          >
            {check.status}
          </span>
          {hasDetails && (
            <div className="text-secondary-400">
              {isExpanded ? (
                <ChevronUp className="w-4 h-4" />
              ) : (
                <ChevronDown className="w-4 h-4" />
              )}
            </div>
          )}
        </div>
      </button>

      {/* Expandable Details */}
      {hasDetails && isExpanded && (
        <div className="px-3 pb-3 bg-secondary-50">{renderDetails()}</div>
      )}
    </div>
  );
});

// Loading state component
const HealthStatusLoading = memo(function HealthStatusLoading() {
  return (
    <Card className="h-full">
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center shadow-md shadow-primary-500/25">
            <Activity className="w-5 h-5 text-white" />
          </div>
          <div>
            <h3 className="text-lg font-semibold text-secondary-900">System Health</h3>
            <p className="text-sm text-secondary-500">Checking services...</p>
          </div>
        </div>
      </div>
      <div className="flex items-center justify-center py-12">
        <Loader2 className="w-8 h-8 text-primary-500 animate-spin" />
      </div>
    </Card>
  );
});

const HealthStatus: React.FC<HealthStatusProps> = memo(function HealthStatus({
  health,
  isLoading,
  onRefresh,
}) {
  // Memoize refresh handler
  const handleRefresh = useCallback(() => {
    onRefresh?.();
  }, [onRefresh]);

  // Get overall status color
  const statusColorClass = useMemo(() => {
    if (!health) return '';
    switch (health.status) {
      case 'healthy':
        return 'bg-success-500/10 text-success-600 border-success-200';
      case 'degraded':
        return 'bg-warning-500/10 text-warning-600 border-warning-200';
      default:
        return 'bg-error-500/10 text-error-600 border-error-200';
    }
  }, [health]);

  if (isLoading || !health) {
    return <HealthStatusLoading />;
  }

  return (
    <Card className="h-full flex flex-col">
      {/* Header */}
      <div className="flex items-center justify-between mb-4 flex-shrink-0">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center shadow-md shadow-primary-500/25">
            <Activity className="w-5 h-5 text-white" />
          </div>
          <div>
            <h3 className="text-lg font-semibold text-secondary-900">System Health</h3>
            <p className="text-sm text-secondary-500">
              {health.version && `v${health.version}`}
              {health.environment && ` • ${health.environment}`}
            </p>
          </div>
        </div>
        {onRefresh && (
          <button
            onClick={handleRefresh}
            className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
            aria-label="Refresh health status"
          >
            <RefreshCw className="w-5 h-5" />
          </button>
        )}
      </div>

      {/* Overall Status Badge */}
      <div
        className={cn(
          'flex items-center justify-between p-3 rounded-xl border mb-4 flex-shrink-0',
          statusColorClass
        )}
      >
        <div className="flex items-center gap-2">
          {getStatusIcon(health.status, 'w-5 h-5')}
          <span className="font-semibold capitalize">{health.status}</span>
        </div>
        <span className="text-xs opacity-75">
          {health.total_checks} services • {health.total_response_time_ms}ms
        </span>
      </div>

      {/* Service Checks - Scrollable */}
      <div className="flex-1 overflow-y-auto space-y-2 min-h-0">
        {health.checks?.map((check) => (
          <ServiceCheckCard key={check.name} check={check} />
        ))}
      </div>

      {/* Footer */}
      {health.timestamp_iso && (
        <div className="mt-4 pt-3 border-t border-secondary-200 flex-shrink-0">
          <p className="text-xs text-secondary-500 text-center">
            Last checked: {new Date(health.timestamp_iso).toLocaleString()}
          </p>
        </div>
      )}
    </Card>
  );
});

export default HealthStatus;
