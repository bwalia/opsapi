'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Search,
  Filter,
  Calendar,
  ChevronDown,
  ChevronRight,
  Shield,
  Loader2,
} from 'lucide-react';
import { Card, CardHeader, CardContent, Badge, Select, Pagination } from '@/components/ui';
import { useNamespace } from '@/contexts/NamespaceContext';
import { namespaceService } from '@/services';
import { formatDateTime, formatRelativeTime, snakeToTitle } from '@/lib/utils';
import type { AuditLog } from '@/types';

const PER_PAGE = 20;

const ENTITY_TYPE_OPTIONS = [
  { value: '', label: 'All Entities' },
  { value: 'namespace_member', label: 'Members' },
  { value: 'namespace_role', label: 'Roles' },
  { value: 'namespace', label: 'Namespace' },
];

const ACTION_OPTIONS = [
  { value: '', label: 'All Actions' },
  { value: 'member.added', label: 'Member Added' },
  { value: 'member.role_changed', label: 'Member Role Changed' },
  { value: 'member.removed', label: 'Member Removed' },
  { value: 'role.created', label: 'Role Created' },
  { value: 'role.permissions_updated', label: 'Role Permissions Updated' },
  { value: 'role.deleted', label: 'Role Deleted' },
  { value: 'namespace.updated', label: 'Namespace Updated' },
  { value: 'namespace.ownership_transferred', label: 'Ownership Transferred' },
];

function getActionBadgeVariant(action: string): 'success' | 'error' | 'warning' | 'info' | 'default' {
  if (action.includes('added') || action.includes('created')) return 'success';
  if (action.includes('removed') || action.includes('deleted')) return 'error';
  if (action.includes('updated') || action.includes('changed') || action.includes('transferred')) return 'warning';
  return 'default';
}

function getEntityBadgeVariant(entityType: string): 'info' | 'warning' | 'default' | 'secondary' {
  if (entityType === 'namespace_member') return 'info';
  if (entityType === 'namespace_role') return 'warning';
  if (entityType === 'namespace') return 'default';
  return 'secondary';
}

function formatChanges(oldValues: Record<string, unknown> | null | undefined, newValues: Record<string, unknown> | null | undefined): string {
  if (!oldValues && !newValues) return '-';
  if (!oldValues && newValues) return 'Created';
  if (oldValues && !newValues) return 'Deleted';

  const changes: string[] = [];
  const allKeys = new Set([...Object.keys(oldValues || {}), ...Object.keys(newValues || {})]);
  for (const key of allKeys) {
    const oldVal = oldValues?.[key];
    const newVal = newValues?.[key];
    if (JSON.stringify(oldVal) !== JSON.stringify(newVal)) {
      changes.push(snakeToTitle(key));
    }
  }
  return changes.length > 0 ? changes.join(', ') : 'No changes';
}

export default function ReportsPage() {
  const { isNamespaceOwner, hasPermission } = useNamespace();
  const canView = isNamespaceOwner || hasPermission('reports', 'read') || hasPermission('namespace', 'read');

  const [logs, setLogs] = useState<AuditLog[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [expandedRow, setExpandedRow] = useState<string | null>(null);

  // Filters
  const [entityType, setEntityType] = useState('');
  const [action, setAction] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');

  // Pagination
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);

  const fetchIdRef = useRef(0);

  const fetchLogs = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const params: Record<string, unknown> = {
        page: currentPage,
        per_page: PER_PAGE,
      };
      if (entityType) params.entity_type = entityType;
      if (action) params.action = action;
      if (fromDate) params.from_date = fromDate;
      if (toDate) params.to_date = toDate;

      const result = await namespaceService.getAuditLogs(params as Parameters<typeof namespaceService.getAuditLogs>[0]);

      if (fetchId !== fetchIdRef.current) return;

      setLogs(result.data || []);
      setTotalPages(result.total_pages || 1);
      setTotalItems(result.total || 0);
    } catch {
      if (fetchId !== fetchIdRef.current) return;
      setLogs([]);
      setTotalPages(1);
      setTotalItems(0);
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, entityType, action, fromDate, toDate]);

  useEffect(() => {
    if (canView) {
      fetchLogs();
    }
  }, [fetchLogs, canView]);

  const handleFilterChange = useCallback(() => {
    setCurrentPage(1);
  }, []);

  if (!canView) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[400px] gap-3">
        <Shield className="w-12 h-12 text-secondary-300" />
        <h2 className="text-lg font-semibold text-secondary-700">Access Denied</h2>
        <p className="text-secondary-500 text-sm">You don&apos;t have permission to view reports.</p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-secondary-900">Audit Logs</h1>
        <p className="text-sm text-secondary-500 mt-1">
          Track all RBAC and namespace changes — role updates, member changes, and security events.
        </p>
      </div>

      {/* Filters */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2 text-sm font-medium text-secondary-700">
            <Filter className="w-4 h-4" />
            Filters
          </div>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            <div>
              <label className="block text-xs font-medium text-secondary-500 mb-1">Entity Type</label>
              <Select
                value={entityType}
                onChange={(e) => {
                  setEntityType(e.target.value);
                  handleFilterChange();
                }}
              >
                {ENTITY_TYPE_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </Select>
            </div>
            <div>
              <label className="block text-xs font-medium text-secondary-500 mb-1">Action</label>
              <Select
                value={action}
                onChange={(e) => {
                  setAction(e.target.value);
                  handleFilterChange();
                }}
              >
                {ACTION_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </Select>
            </div>
            <div>
              <label className="block text-xs font-medium text-secondary-500 mb-1">
                <span className="flex items-center gap-1"><Calendar className="w-3 h-3" /> From</span>
              </label>
              <input
                type="date"
                value={fromDate}
                onChange={(e) => {
                  setFromDate(e.target.value);
                  handleFilterChange();
                }}
                className="w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm text-secondary-900 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-secondary-500 mb-1">
                <span className="flex items-center gap-1"><Calendar className="w-3 h-3" /> To</span>
              </label>
              <input
                type="date"
                value={toDate}
                onChange={(e) => {
                  setToDate(e.target.value);
                  handleFilterChange();
                }}
                className="w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm text-secondary-900 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20"
              />
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Audit Log Table */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-secondary-700">
              {totalItems} {totalItems === 1 ? 'entry' : 'entries'}
            </span>
          </div>
        </CardHeader>
        <CardContent className="p-0">
          {isLoading ? (
            <div className="flex flex-col items-center justify-center py-16 gap-3">
              <Loader2 className="w-8 h-8 text-primary-500 animate-spin" />
              <p className="text-secondary-500 text-sm">Loading audit logs...</p>
            </div>
          ) : logs.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-16 gap-3">
              <Search className="w-10 h-10 text-secondary-300" />
              <p className="text-secondary-500 text-sm">No audit log entries found.</p>
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-secondary-200 bg-secondary-50/50">
                    <th className="w-8 px-4 py-3" />
                    <th className="text-left px-4 py-3 font-medium text-secondary-600">Time</th>
                    <th className="text-left px-4 py-3 font-medium text-secondary-600">User</th>
                    <th className="text-left px-4 py-3 font-medium text-secondary-600">Action</th>
                    <th className="text-left px-4 py-3 font-medium text-secondary-600">Entity</th>
                    <th className="text-left px-4 py-3 font-medium text-secondary-600">Changes</th>
                  </tr>
                </thead>
                <tbody>
                  {logs.map((log) => (
                    <React.Fragment key={log.id}>
                      <tr
                        className="border-b border-secondary-100 hover:bg-secondary-50/50 cursor-pointer transition-colors"
                        onClick={() => setExpandedRow(expandedRow === log.id ? null : log.id)}
                      >
                        <td className="px-4 py-3">
                          {(log.old_values || log.new_values) && (
                            expandedRow === log.id
                              ? <ChevronDown className="w-4 h-4 text-secondary-400" />
                              : <ChevronRight className="w-4 h-4 text-secondary-400" />
                          )}
                        </td>
                        <td className="px-4 py-3 whitespace-nowrap">
                          <div className="text-secondary-900">{formatDateTime(log.created_at)}</div>
                          <div className="text-xs text-secondary-400">{formatRelativeTime(log.created_at)}</div>
                        </td>
                        <td className="px-4 py-3">
                          <div className="text-secondary-900">
                            {log.user_first_name || log.user_last_name
                              ? `${log.user_first_name || ''} ${log.user_last_name || ''}`.trim()
                              : '-'}
                          </div>
                          {log.user_email && (
                            <div className="text-xs text-secondary-400">{log.user_email}</div>
                          )}
                        </td>
                        <td className="px-4 py-3">
                          <Badge variant={getActionBadgeVariant(log.action)} size="sm">
                            {snakeToTitle(log.action.replace('.', '_'))}
                          </Badge>
                        </td>
                        <td className="px-4 py-3">
                          <Badge variant={getEntityBadgeVariant(log.entity_type)} size="sm">
                            {snakeToTitle(log.entity_type)}
                          </Badge>
                          {log.entity_id && (
                            <div className="text-xs text-secondary-400 mt-0.5 font-mono truncate max-w-[120px]">
                              {log.entity_id}
                            </div>
                          )}
                        </td>
                        <td className="px-4 py-3 text-secondary-600 max-w-[200px] truncate">
                          {formatChanges(log.old_values, log.new_values)}
                        </td>
                      </tr>
                      {/* Expanded detail row */}
                      {expandedRow === log.id && (log.old_values || log.new_values) && (
                        <tr className="bg-secondary-50/80">
                          <td colSpan={6} className="px-6 py-4">
                            <div className="grid grid-cols-1 md:grid-cols-2 gap-4 text-xs">
                              {log.old_values && Object.keys(log.old_values).length > 0 && (
                                <div>
                                  <h4 className="font-medium text-secondary-600 mb-2">Previous Values</h4>
                                  <pre className="bg-surface rounded-lg border border-secondary-200 p-3 overflow-x-auto text-secondary-700 whitespace-pre-wrap break-all">
                                    {JSON.stringify(log.old_values, null, 2)}
                                  </pre>
                                </div>
                              )}
                              {log.new_values && Object.keys(log.new_values).length > 0 && (
                                <div>
                                  <h4 className="font-medium text-secondary-600 mb-2">New Values</h4>
                                  <pre className="bg-surface rounded-lg border border-secondary-200 p-3 overflow-x-auto text-secondary-700 whitespace-pre-wrap break-all">
                                    {JSON.stringify(log.new_values, null, 2)}
                                  </pre>
                                </div>
                              )}
                              {log.ip_address && (
                                <div className="md:col-span-2 flex gap-4 text-secondary-400">
                                  <span>IP: {log.ip_address}</span>
                                  {log.user_agent && <span className="truncate">UA: {log.user_agent}</span>}
                                </div>
                              )}
                            </div>
                          </td>
                        </tr>
                      )}
                    </React.Fragment>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Pagination */}
      {totalPages > 1 && (
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={PER_PAGE}
          onPageChange={setCurrentPage}
        />
      )}
    </div>
  );
}
