'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  History,
  Eye,
  Edit2,
  Share2,
  Trash2,
  Plus,
  Key,
  Lock,
  Unlock,
  RefreshCw,
  Download,
  Filter,
  Loader2,
  AlertCircle,
  Calendar,
} from 'lucide-react';
import { Button, Select, Card, Pagination, Badge } from '@/components/ui';
import { vaultService } from '@/services/vault.service';
import type { VaultAccessLog, VaultAccessLogParams, VaultAccessLogAction } from '@/types';
import { format, formatDistanceToNow, subDays, startOfDay, endOfDay } from 'date-fns';
import { cn } from '@/lib/utils';

interface VaultAccessLogsProps {
  onClose?: () => void;
}

type BadgeVariant = 'default' | 'success' | 'warning' | 'error' | 'info' | 'secondary';

const ACTION_CONFIG: Record<
  string,
  { icon: React.ElementType; label: string; color: BadgeVariant }
> = {
  create: { icon: Plus, label: 'Created', color: 'success' },
  read: { icon: Eye, label: 'Viewed', color: 'info' },
  update: { icon: Edit2, label: 'Updated', color: 'warning' },
  delete: { icon: Trash2, label: 'Deleted', color: 'error' },
  share: { icon: Share2, label: 'Shared', color: 'info' },
  revoke: { icon: Lock, label: 'Revoked', color: 'secondary' },
  vault_unlock: { icon: Unlock, label: 'Vault Unlocked', color: 'success' },
  vault_lock: { icon: Lock, label: 'Vault Locked', color: 'secondary' },
  vault_create: { icon: Key, label: 'Vault Created', color: 'info' },
  key_change: { icon: RefreshCw, label: 'Key Changed', color: 'warning' },
};

const DATE_RANGES = [
  { value: 'today', label: 'Today' },
  { value: '7d', label: 'Last 7 days' },
  { value: '30d', label: 'Last 30 days' },
  { value: '90d', label: 'Last 90 days' },
  { value: 'all', label: 'All time' },
];

const ACTION_FILTERS = [
  { value: '', label: 'All actions' },
  { value: 'create', label: 'Create' },
  { value: 'read', label: 'Read' },
  { value: 'update', label: 'Update' },
  { value: 'delete', label: 'Delete' },
  { value: 'share', label: 'Share' },
  { value: 'revoke', label: 'Revoke' },
];

const VaultAccessLogs: React.FC<VaultAccessLogsProps> = ({ onClose }) => {
  const [logs, setLogs] = useState<VaultAccessLog[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [dateRange, setDateRange] = useState('7d');
  const [actionFilter, setActionFilter] = useState('');
  const perPage = 20;

  const calculateDateRange = useCallback((): { start_date?: string; end_date?: string } => {
    const now = new Date();
    const endDate = endOfDay(now).toISOString();

    switch (dateRange) {
      case 'today':
        return {
          start_date: startOfDay(now).toISOString(),
          end_date: endDate,
        };
      case '7d':
        return {
          start_date: startOfDay(subDays(now, 7)).toISOString(),
          end_date: endDate,
        };
      case '30d':
        return {
          start_date: startOfDay(subDays(now, 30)).toISOString(),
          end_date: endDate,
        };
      case '90d':
        return {
          start_date: startOfDay(subDays(now, 90)).toISOString(),
          end_date: endDate,
        };
      default:
        return {};
    }
  }, [dateRange]);

  const loadLogs = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    try {
      const { start_date, end_date } = calculateDateRange();
      const params: VaultAccessLogParams = {
        page,
        perPage,
        action: (actionFilter || undefined) as VaultAccessLogAction | undefined,
        start_date,
        end_date,
      };

      const response = await vaultService.getAccessLogs(params);
      setLogs(response.logs || []);
      setTotalItems(response.total || 0);
      setTotalPages(Math.ceil((response.total || 0) / perPage));
    } catch (err) {
      const error = err as Error;
      setError(error.message || 'Failed to load access logs');
      setLogs([]);
    } finally {
      setIsLoading(false);
    }
  }, [page, actionFilter, calculateDateRange]);

  useEffect(() => {
    loadLogs();
  }, [loadLogs]);

  const handleExport = () => {
    const csvContent = [
      ['Date', 'Action', 'Resource', 'Details', 'IP Address'].join(','),
      ...logs.map((log) =>
        [
          format(new Date(log.created_at), 'yyyy-MM-dd HH:mm:ss'),
          log.action,
          log.resource_type || '',
          log.details || '',
          log.ip_address || '',
        ]
          .map((field) => `"${String(field).replace(/"/g, '""')}"`)
          .join(',')
      ),
    ].join('\n');

    const blob = new Blob([csvContent], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `vault-logs-${format(new Date(), 'yyyy-MM-dd')}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const getActionConfig = (action: string) => {
    return ACTION_CONFIG[action] || { icon: History, label: action, color: 'secondary' };
  };

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="flex items-center justify-between mb-4">
        <div>
          <h2 className="text-xl font-bold text-secondary-900">Access Logs</h2>
          <p className="text-sm text-secondary-500">
            Track all activity in your vault
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="sm" onClick={handleExport}>
            <Download className="w-4 h-4 mr-2" />
            Export
          </Button>
          <Button variant="ghost" size="sm" onClick={loadLogs}>
            <RefreshCw className="w-4 h-4" />
          </Button>
        </div>
      </div>

      {/* Filters */}
      <div className="flex items-center gap-4 mb-4">
        <div className="flex items-center gap-2">
          <Calendar className="w-4 h-4 text-secondary-400" />
          <Select
            value={dateRange}
            onChange={(e) => {
              setDateRange(e.target.value);
              setPage(1);
            }}
            className="w-40"
          >
            {DATE_RANGES.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </Select>
        </div>
        <div className="flex items-center gap-2">
          <Filter className="w-4 h-4 text-secondary-400" />
          <Select
            value={actionFilter}
            onChange={(e) => {
              setActionFilter(e.target.value);
              setPage(1);
            }}
            className="w-40"
          >
            {ACTION_FILTERS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </Select>
        </div>
        {totalItems > 0 && (
          <span className="text-sm text-secondary-500">
            {totalItems} log{totalItems !== 1 ? 's' : ''}
          </span>
        )}
      </div>

      {/* Logs List */}
      <div className="flex-1 overflow-y-auto">
        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="w-8 h-8 text-primary-500 animate-spin" />
          </div>
        ) : error ? (
          <Card className="p-8 text-center">
            <AlertCircle className="w-10 h-10 text-error-500 mx-auto mb-3" />
            <p className="text-secondary-900 font-medium mb-1">Failed to load logs</p>
            <p className="text-sm text-secondary-500 mb-4">{error}</p>
            <Button variant="ghost" onClick={loadLogs}>
              Try Again
            </Button>
          </Card>
        ) : logs.length === 0 ? (
          <Card className="p-12 text-center">
            <History className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
            <h3 className="text-lg font-medium text-secondary-900 mb-2">
              No activity logs
            </h3>
            <p className="text-secondary-500">
              {actionFilter || dateRange !== 'all'
                ? 'No logs match your current filters'
                : 'Activity in your vault will appear here'}
            </p>
          </Card>
        ) : (
          <div className="space-y-2">
            {logs.map((log) => {
              const config = getActionConfig(log.action);
              const ActionIcon = config.icon;

              return (
                <Card key={log.id} className="p-4">
                  <div className="flex items-start gap-4">
                    <div
                      className={cn(
                        'p-2 rounded-lg flex-shrink-0',
                        `bg-${config.color}-100`
                      )}
                    >
                      <ActionIcon
                        className={cn('w-4 h-4', `text-${config.color}-600`)}
                      />
                    </div>

                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 mb-1">
                        <Badge
                          variant={config.color}
                          size="sm"
                        >
                          {config.label}
                        </Badge>
                        {log.resource_type && (
                          <span className="text-sm text-secondary-500">
                            {log.resource_type}
                          </span>
                        )}
                      </div>

                      {log.details && (
                        <p className="text-sm text-secondary-700 mb-1">
                          {log.details}
                        </p>
                      )}

                      {log.secret_name && (
                        <p className="text-sm text-secondary-900 font-medium">
                          Secret: {log.secret_name}
                        </p>
                      )}

                      <div className="flex items-center gap-4 text-xs text-secondary-400 mt-2">
                        <span title={format(new Date(log.created_at), 'PPpp')}>
                          {formatDistanceToNow(new Date(log.created_at), {
                            addSuffix: true,
                          })}
                        </span>
                        {log.ip_address && <span>IP: {log.ip_address}</span>}
                        {log.user_agent && (
                          <span className="truncate max-w-[200px]" title={log.user_agent}>
                            {log.user_agent}
                          </span>
                        )}
                      </div>
                    </div>

                    <div className="text-xs text-secondary-400 flex-shrink-0">
                      {format(new Date(log.created_at), 'MMM d, h:mm a')}
                    </div>
                  </div>
                </Card>
              );
            })}
          </div>
        )}
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="mt-4 pt-4 border-t border-secondary-200">
          <Pagination
            currentPage={page}
            totalPages={totalPages}
            totalItems={totalItems}
            perPage={perPage}
            onPageChange={setPage}
          />
        </div>
      )}

      {/* Close button if in modal */}
      {onClose && (
        <div className="mt-4 pt-4 border-t border-secondary-200 flex justify-end">
          <Button variant="ghost" onClick={onClose}>
            Close
          </Button>
        </div>
      )}
    </div>
  );
};

export default VaultAccessLogs;
