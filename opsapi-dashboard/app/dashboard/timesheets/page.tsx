'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Clock,
  DollarSign,
  CheckCircle,
  AlertCircle,
  RefreshCw,
  Plus,
  Eye,
  ThumbsUp,
  ThumbsDown,
  ChevronDown,
  X,
  FileText,
} from 'lucide-react';
import { Input, Table, Badge, Pagination, Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  timesheetsService,
  type Timesheet,
  type TimesheetStatus,
  type TimesheetsResponse,
  type TimesheetSummaryResponse,
} from '@/services/timesheets.service';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';
import { useRouter } from 'next/navigation';

// ============================================
// Stats Card Component
// ============================================

interface StatCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  color: 'primary' | 'success' | 'warning' | 'danger' | 'info';
}

const StatCard: React.FC<StatCardProps> = ({ title, value, icon, color }) => {
  const colorClasses = {
    primary: 'bg-primary-50 text-primary-600',
    success: 'bg-green-50 text-green-600',
    warning: 'bg-amber-50 text-amber-600',
    danger: 'bg-red-50 text-red-600',
    info: 'bg-blue-50 text-blue-600',
  };

  return (
    <div className="bg-surface rounded-xl border border-secondary-200 p-5 shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-secondary-500">{title}</p>
          <p className="text-2xl font-bold text-secondary-900 mt-1">{value}</p>
        </div>
        <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${colorClasses[color]}`}>
          {icon}
        </div>
      </div>
    </div>
  );
};

// ============================================
// Status Filter Options
// ============================================

const TIMESHEET_STATUS_OPTIONS: { value: TimesheetStatus | 'all'; label: string }[] = [
  { value: 'all', label: 'All Status' },
  { value: 'draft', label: 'Draft' },
  { value: 'submitted', label: 'Submitted' },
  { value: 'approved', label: 'Approved' },
  { value: 'rejected', label: 'Rejected' },
  { value: 'void', label: 'Void' },
];

// ============================================
// Create Timesheet Modal
// ============================================

interface CreateTimesheetModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated: () => void;
}

const CreateTimesheetModal: React.FC<CreateTimesheetModalProps> = ({ isOpen, onClose, onCreated }) => {
  const [periodStart, setPeriodStart] = useState('');
  const [periodEnd, setPeriodEnd] = useState('');
  const [notes, setNotes] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!periodStart || !periodEnd) {
      toast.error('Please select both start and end dates');
      return;
    }

    setIsSubmitting(true);
    try {
      await timesheetsService.createTimesheet({
        period_start: periodStart,
        period_end: periodEnd,
        notes: notes || undefined,
      });
      toast.success('Timesheet created successfully');
      setPeriodStart('');
      setPeriodEnd('');
      setNotes('');
      onClose();
      onCreated();
    } catch (error) {
      console.error('Failed to create timesheet:', error);
      toast.error('Failed to create timesheet');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create Timesheet">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Period Start</label>
          <input
            type="date"
            value={periodStart}
            onChange={(e) => setPeriodStart(e.target.value)}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface"
            required
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Period End</label>
          <input
            type="date"
            value={periodEnd}
            onChange={(e) => setPeriodEnd(e.target.value)}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface"
            required
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Notes (optional)</label>
          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            rows={3}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface resize-none"
            placeholder="Add any notes about this timesheet..."
          />
        </div>
        <div className="flex justify-end gap-3 pt-2">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 transition-colors"
          >
            {isSubmitting ? 'Creating...' : 'Create Timesheet'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================
// Reject Timesheet Modal
// ============================================

interface RejectTimesheetModalProps {
  isOpen: boolean;
  onClose: () => void;
  onRejected: () => void;
  timesheetUuid: string | null;
}

const RejectTimesheetModal: React.FC<RejectTimesheetModalProps> = ({ isOpen, onClose, onRejected, timesheetUuid }) => {
  const [reason, setReason] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!timesheetUuid || !reason.trim()) {
      toast.error('Please provide a reason for rejection');
      return;
    }

    setIsSubmitting(true);
    try {
      await timesheetsService.rejectTimesheet(timesheetUuid, reason.trim());
      toast.success('Timesheet rejected');
      setReason('');
      onClose();
      onRejected();
    } catch (error) {
      console.error('Failed to reject timesheet:', error);
      toast.error('Failed to reject timesheet');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Reject Timesheet">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Reason for Rejection</label>
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={4}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface resize-none"
            placeholder="Please explain why this timesheet is being rejected..."
            required
          />
        </div>
        <div className="flex justify-end gap-3 pt-2">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting || !reason.trim()}
            className="px-4 py-2 text-sm font-medium text-white bg-red-600 rounded-lg hover:bg-red-700 disabled:opacity-50 transition-colors"
          >
            {isSubmitting ? 'Rejecting...' : 'Reject Timesheet'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================
// Main Timesheets Page Content
// ============================================

function TimesheetsPageContent() {
  const router = useRouter();

  // Tabs
  const [activeTab, setActiveTab] = useState<'my' | 'approval'>('my');

  // My Timesheets state
  const [timesheets, setTimesheets] = useState<Timesheet[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState<TimesheetStatus | 'all'>('all');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const perPage = 10;

  // Approval Queue state
  const [approvalQueue, setApprovalQueue] = useState<Timesheet[]>([]);
  const [isLoadingApproval, setIsLoadingApproval] = useState(false);
  const [approvalPage, setApprovalPage] = useState(1);
  const [approvalTotalPages, setApprovalTotalPages] = useState(1);
  const [approvalTotalItems, setApprovalTotalItems] = useState(0);

  // Summary stats
  const [summary, setSummary] = useState<TimesheetSummaryResponse | null>(null);

  // Modals
  const [isCreateModalOpen, setIsCreateModalOpen] = useState(false);
  const [isRejectModalOpen, setIsRejectModalOpen] = useState(false);
  const [rejectTimesheetUuid, setRejectTimesheetUuid] = useState<string | null>(null);

  // Refs
  const fetchIdRef = useRef(0);

  // ============================================
  // Fetch My Timesheets
  // ============================================

  const fetchTimesheets = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const response = await timesheetsService.getTimesheets({
        page: currentPage,
        per_page: perPage,
        status: statusFilter !== 'all' ? statusFilter : undefined,
      });

      if (fetchId === fetchIdRef.current) {
        setTimesheets(response.data);
        setTotalPages(response.total_pages);
        setTotalItems(response.total);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch timesheets:', error);
        toast.error('Failed to load timesheets');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, statusFilter]);

  // ============================================
  // Fetch Approval Queue
  // ============================================

  const fetchApprovalQueue = useCallback(async () => {
    setIsLoadingApproval(true);

    try {
      const response = await timesheetsService.getApprovalQueue({
        page: approvalPage,
        per_page: perPage,
      });

      setApprovalQueue(response.data);
      setApprovalTotalPages(response.total_pages);
      setApprovalTotalItems(response.total);
    } catch (error) {
      console.error('Failed to fetch approval queue:', error);
      toast.error('Failed to load approval queue');
    } finally {
      setIsLoadingApproval(false);
    }
  }, [approvalPage]);

  // ============================================
  // Fetch Summary
  // ============================================

  const fetchSummary = useCallback(async () => {
    try {
      const data = await timesheetsService.getSummary();
      setSummary(data);
    } catch (error) {
      console.error('Failed to load summary:', error);
    }
  }, []);

  // ============================================
  // Effects
  // ============================================

  useEffect(() => {
    fetchSummary();
  }, [fetchSummary]);

  useEffect(() => {
    if (activeTab === 'my') {
      fetchTimesheets();
    } else {
      fetchApprovalQueue();
    }
  }, [activeTab, fetchTimesheets, fetchApprovalQueue]);

  // ============================================
  // Handlers
  // ============================================

  const handleApprove = useCallback(async (uuid: string) => {
    try {
      await timesheetsService.approveTimesheet(uuid);
      toast.success('Timesheet approved');
      fetchApprovalQueue();
      fetchSummary();
    } catch (error) {
      console.error('Failed to approve timesheet:', error);
      toast.error('Failed to approve timesheet');
    }
  }, [fetchApprovalQueue, fetchSummary]);

  const handleRejectClick = useCallback((uuid: string) => {
    setRejectTimesheetUuid(uuid);
    setIsRejectModalOpen(true);
  }, []);

  const handleViewTimesheet = useCallback((timesheet: Timesheet) => {
    router.push(`/dashboard/timesheets/${timesheet.uuid}`);
  }, [router]);

  const handleRefresh = useCallback(() => {
    if (activeTab === 'my') {
      fetchTimesheets();
    } else {
      fetchApprovalQueue();
    }
    fetchSummary();
  }, [activeTab, fetchTimesheets, fetchApprovalQueue, fetchSummary]);

  // ============================================
  // Table Columns - My Timesheets
  // ============================================

  const myTimesheetsColumns: TableColumn<Timesheet>[] = useMemo(() => [
    {
      key: 'period',
      header: 'Period',
      render: (ts) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-secondary-100 rounded-lg flex items-center justify-center">
            <FileText className="w-5 h-5 text-secondary-500" />
          </div>
          <div>
            <p className="font-medium text-secondary-900">
              {formatDate(ts.period_start)} - {formatDate(ts.period_end)}
            </p>
            <p className="text-xs text-secondary-500">
              {ts.notes ? ts.notes.slice(0, 40) + (ts.notes.length > 40 ? '...' : '') : 'No notes'}
            </p>
          </div>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (ts) => <Badge size="sm" status={ts.status} />,
    },
    {
      key: 'total_hours',
      header: 'Total Hours',
      render: (ts) => (
        <span className="font-semibold text-secondary-900">{ts.total_hours?.toFixed(1) || '0.0'}</span>
      ),
    },
    {
      key: 'billable_hours',
      header: 'Billable Hours',
      render: (ts) => (
        <span className="text-secondary-700">{ts.billable_hours?.toFixed(1) || '0.0'}</span>
      ),
    },
    {
      key: 'submitted_at',
      header: 'Submitted',
      render: (ts) => (
        <span className="text-sm text-secondary-500">
          {ts.submitted_at ? formatDate(ts.submitted_at) : '-'}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-16',
      render: (ts) => (
        <button
          onClick={(e) => {
            e.stopPropagation();
            handleViewTimesheet(ts);
          }}
          className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
          title="View Timesheet"
        >
          <Eye className="w-4 h-4" />
        </button>
      ),
    },
  ], [handleViewTimesheet]);

  // ============================================
  // Table Columns - Approval Queue
  // ============================================

  const approvalColumns: TableColumn<Timesheet>[] = useMemo(() => [
    {
      key: 'user',
      header: 'User',
      render: (ts) => (
        <div>
          <p className="text-sm font-medium text-secondary-900">
            {ts.user ? `${ts.user.first_name} ${ts.user.last_name}` : 'Unknown'}
          </p>
          {ts.user?.email && (
            <p className="text-xs text-secondary-500">{ts.user.email}</p>
          )}
        </div>
      ),
    },
    {
      key: 'period',
      header: 'Period',
      render: (ts) => (
        <span className="text-sm text-secondary-900">
          {formatDate(ts.period_start)} - {formatDate(ts.period_end)}
        </span>
      ),
    },
    {
      key: 'total_hours',
      header: 'Total Hours',
      render: (ts) => (
        <span className="font-semibold text-secondary-900">{ts.total_hours?.toFixed(1) || '0.0'}</span>
      ),
    },
    {
      key: 'billable_hours',
      header: 'Billable Hours',
      render: (ts) => (
        <span className="text-secondary-700">{ts.billable_hours?.toFixed(1) || '0.0'}</span>
      ),
    },
    {
      key: 'submitted_at',
      header: 'Submitted At',
      render: (ts) => (
        <span className="text-sm text-secondary-500">
          {ts.submitted_at ? formatDate(ts.submitted_at) : '-'}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-32',
      render: (ts) => (
        <div className="flex items-center gap-1">
          <button
            onClick={(e) => {
              e.stopPropagation();
              handleApprove(ts.uuid);
            }}
            className="p-1.5 text-green-600 hover:bg-green-50 rounded-lg transition-colors"
            title="Approve"
          >
            <ThumbsUp className="w-4 h-4" />
          </button>
          <button
            onClick={(e) => {
              e.stopPropagation();
              handleRejectClick(ts.uuid);
            }}
            className="p-1.5 text-red-600 hover:bg-red-50 rounded-lg transition-colors"
            title="Reject"
          >
            <ThumbsDown className="w-4 h-4" />
          </button>
          <button
            onClick={(e) => {
              e.stopPropagation();
              handleViewTimesheet(ts);
            }}
            className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
            title="View Details"
          >
            <Eye className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ], [handleApprove, handleRejectClick, handleViewTimesheet]);

  // ============================================
  // Render
  // ============================================

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Timesheets</h1>
          <p className="text-secondary-500 mt-1">Track and manage your time entries</p>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={handleRefresh}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            <RefreshCw className={`w-4 h-4 ${isLoading || isLoadingApproval ? 'animate-spin' : ''}`} />
            Refresh
          </button>
          <button
            onClick={() => setIsCreateModalOpen(true)}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors"
          >
            <Plus className="w-4 h-4" />
            Create Timesheet
          </button>
        </div>
      </div>

      {/* Stats Cards */}
      {summary && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <StatCard
            title="Total Hours"
            value={summary.total_hours?.toFixed(1) || '0.0'}
            icon={<Clock className="w-6 h-6" />}
            color="primary"
          />
          <StatCard
            title="Billable Hours"
            value={summary.billable_hours?.toFixed(1) || '0.0'}
            icon={<DollarSign className="w-6 h-6" />}
            color="success"
          />
          <StatCard
            title="Pending Approval"
            value={summary.pending_count || 0}
            icon={<AlertCircle className="w-6 h-6" />}
            color="warning"
          />
          <StatCard
            title="Approved"
            value={summary.approved_count || 0}
            icon={<CheckCircle className="w-6 h-6" />}
            color="info"
          />
        </div>
      )}

      {/* Tabs */}
      <div className="border-b border-secondary-200">
        <nav className="flex gap-6">
          <button
            onClick={() => { setActiveTab('my'); setCurrentPage(1); }}
            className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'my'
                ? 'border-primary-500 text-primary-600'
                : 'border-transparent text-secondary-500 hover:text-secondary-700'
            }`}
          >
            My Timesheets
          </button>
          <button
            onClick={() => { setActiveTab('approval'); setApprovalPage(1); }}
            className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'approval'
                ? 'border-primary-500 text-primary-600'
                : 'border-transparent text-secondary-500 hover:text-secondary-700'
            }`}
          >
            Approval Queue
          </button>
        </nav>
      </div>

      {/* My Timesheets Tab */}
      {activeTab === 'my' && (
        <>
          {/* Status Filter */}
          <Card padding="md">
            <div className="flex flex-wrap items-center gap-4">
              <div className="relative">
                <select
                  value={statusFilter}
                  onChange={(e) => {
                    setStatusFilter(e.target.value as TimesheetStatus | 'all');
                    setCurrentPage(1);
                  }}
                  className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer"
                >
                  {TIMESHEET_STATUS_OPTIONS.map((opt) => (
                    <option key={opt.value} value={opt.value}>
                      {opt.label}
                    </option>
                  ))}
                </select>
                <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
              </div>

              {statusFilter !== 'all' && (
                <button
                  onClick={() => { setStatusFilter('all'); setCurrentPage(1); }}
                  className="flex items-center gap-1 px-3 py-2.5 text-sm text-red-600 hover:bg-red-50 rounded-lg transition-colors"
                >
                  <X className="w-4 h-4" />
                  Clear
                </button>
              )}
            </div>
          </Card>

          {/* Table */}
          <div>
            <Table
              columns={myTimesheetsColumns}
              data={timesheets}
              keyExtractor={(ts) => ts.uuid}
              onRowClick={handleViewTimesheet}
              isLoading={isLoading}
              emptyMessage={
                statusFilter !== 'all'
                  ? 'No timesheets match your filter. Try adjusting your criteria.'
                  : 'No timesheets found. Create your first timesheet to get started.'
              }
            />

            <Pagination
              currentPage={currentPage}
              totalPages={totalPages}
              totalItems={totalItems}
              perPage={perPage}
              onPageChange={setCurrentPage}
            />
          </div>
        </>
      )}

      {/* Approval Queue Tab */}
      {activeTab === 'approval' && (
        <div>
          <Table
            columns={approvalColumns}
            data={approvalQueue}
            keyExtractor={(ts) => ts.uuid}
            onRowClick={handleViewTimesheet}
            isLoading={isLoadingApproval}
            emptyMessage="No timesheets pending approval."
          />

          <Pagination
            currentPage={approvalPage}
            totalPages={approvalTotalPages}
            totalItems={approvalTotalItems}
            perPage={perPage}
            onPageChange={setApprovalPage}
          />
        </div>
      )}

      {/* Create Timesheet Modal */}
      <CreateTimesheetModal
        isOpen={isCreateModalOpen}
        onClose={() => setIsCreateModalOpen(false)}
        onCreated={() => {
          fetchTimesheets();
          fetchSummary();
        }}
      />

      {/* Reject Timesheet Modal */}
      <RejectTimesheetModal
        isOpen={isRejectModalOpen}
        onClose={() => {
          setIsRejectModalOpen(false);
          setRejectTimesheetUuid(null);
        }}
        onRejected={() => {
          fetchApprovalQueue();
          fetchSummary();
        }}
        timesheetUuid={rejectTimesheetUuid}
      />
    </div>
  );
}

export default function TimesheetsPage() {
  return (
    <ProtectedPage module="timesheets" title="Timesheets">
      <TimesheetsPageContent />
    </ProtectedPage>
  );
}
