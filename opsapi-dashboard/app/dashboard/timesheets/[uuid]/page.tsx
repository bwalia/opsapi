'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Clock,
  DollarSign,
  CheckCircle,
  XCircle,
  Send,
  Edit,
  Trash2,
  Plus,
  RotateCcw,
  AlertTriangle,
  RefreshCw,
  FileText,
  Loader2,
} from 'lucide-react';
import { Card, Badge, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  timesheetsService,
  type Timesheet,
  type TimesheetEntry,
  type CreateEntryData,
  type UpdateEntryData,
} from '@/services/timesheets.service';
import { formatDate } from '@/lib/utils';
import toast from 'react-hot-toast';

// ============================================
// Add Entry Modal
// ============================================

interface AddEntryModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
  timesheetUuid: string;
  editEntry?: TimesheetEntry | null;
}

const AddEntryModal: React.FC<AddEntryModalProps> = ({ isOpen, onClose, onSaved, timesheetUuid, editEntry }) => {
  const [date, setDate] = useState('');
  const [hours, setHours] = useState('');
  const [description, setDescription] = useState('');
  const [projectReference, setProjectReference] = useState('');
  const [isBillable, setIsBillable] = useState(true);
  const [category, setCategory] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  useEffect(() => {
    if (editEntry) {
      setDate(editEntry.date?.split('T')[0] || '');
      setHours(String(editEntry.hours || ''));
      setDescription(editEntry.description || '');
      setProjectReference(editEntry.project_reference || '');
      setIsBillable(editEntry.is_billable ?? true);
      setCategory(editEntry.category || '');
    } else {
      setDate('');
      setHours('');
      setDescription('');
      setProjectReference('');
      setIsBillable(true);
      setCategory('');
    }
  }, [editEntry, isOpen]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!date || !hours) {
      toast.error('Date and hours are required');
      return;
    }

    const parsedHours = parseFloat(hours);
    if (isNaN(parsedHours) || parsedHours <= 0) {
      toast.error('Hours must be a positive number');
      return;
    }

    setIsSubmitting(true);
    try {
      if (editEntry) {
        const data: UpdateEntryData = {
          date,
          hours: parsedHours,
          description: description || undefined,
          project_reference: projectReference || undefined,
          is_billable: isBillable,
          category: category || undefined,
        };
        await timesheetsService.updateEntry(editEntry.uuid, data);
        toast.success('Entry updated successfully');
      } else {
        const data: CreateEntryData = {
          date,
          hours: parsedHours,
          description: description || undefined,
          project_reference: projectReference || undefined,
          is_billable: isBillable,
          category: category || undefined,
        };
        await timesheetsService.addEntry(timesheetUuid, data);
        toast.success('Entry added successfully');
      }
      onClose();
      onSaved();
    } catch (error) {
      console.error('Failed to save entry:', error);
      toast.error(editEntry ? 'Failed to update entry' : 'Failed to add entry');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={editEntry ? 'Edit Time Entry' : 'Add Time Entry'}>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Date</label>
            <input
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              required
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Hours</label>
            <input
              type="number"
              step="0.25"
              min="0.25"
              value={hours}
              onChange={(e) => setHours(e.target.value)}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              placeholder="0.00"
              required
            />
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={3}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white resize-none"
            placeholder="What did you work on?"
          />
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Project Reference</label>
            <input
              type="text"
              value={projectReference}
              onChange={(e) => setProjectReference(e.target.value)}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              placeholder="e.g., PROJ-001"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Category</label>
            <input
              type="text"
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              placeholder="e.g., Development"
            />
          </div>
        </div>

        <div className="flex items-center gap-2">
          <input
            type="checkbox"
            id="is_billable"
            checked={isBillable}
            onChange={(e) => setIsBillable(e.target.checked)}
            className="w-4 h-4 text-primary-600 border-secondary-300 rounded focus:ring-primary-500"
          />
          <label htmlFor="is_billable" className="text-sm font-medium text-secondary-700">
            Billable
          </label>
        </div>

        <div className="flex justify-end gap-3 pt-2">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 transition-colors"
          >
            {isSubmitting ? 'Saving...' : editEntry ? 'Update Entry' : 'Add Entry'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================
// Reject Modal (for managers viewing detail)
// ============================================

interface RejectModalProps {
  isOpen: boolean;
  onClose: () => void;
  onRejected: () => void;
  timesheetUuid: string;
}

const RejectModal: React.FC<RejectModalProps> = ({ isOpen, onClose, onRejected, timesheetUuid }) => {
  const [reason, setReason] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!reason.trim()) {
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
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white resize-none"
            placeholder="Please explain why this timesheet is being rejected..."
            required
          />
        </div>
        <div className="flex justify-end gap-3 pt-2">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
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
// Main Timesheet Detail Content
// ============================================

function TimesheetDetailContent() {
  const params = useParams();
  const router = useRouter();
  const uuid = params.uuid as string;

  const [timesheet, setTimesheet] = useState<Timesheet | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isActioning, setIsActioning] = useState(false);

  // Modals
  const [isEntryModalOpen, setIsEntryModalOpen] = useState(false);
  const [editEntry, setEditEntry] = useState<TimesheetEntry | null>(null);
  const [isRejectModalOpen, setIsRejectModalOpen] = useState(false);

  // ============================================
  // Fetch Timesheet
  // ============================================

  const fetchTimesheet = useCallback(async () => {
    setIsLoading(true);
    try {
      const data = await timesheetsService.getTimesheet(uuid);
      setTimesheet(data);
    } catch (error) {
      console.error('Failed to fetch timesheet:', error);
      toast.error('Failed to load timesheet');
    } finally {
      setIsLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    fetchTimesheet();
  }, [fetchTimesheet]);

  // ============================================
  // Workflow Actions
  // ============================================

  const handleSubmit = useCallback(async () => {
    setIsActioning(true);
    try {
      await timesheetsService.submitTimesheet(uuid);
      toast.success('Timesheet submitted for approval');
      fetchTimesheet();
    } catch (error) {
      console.error('Failed to submit timesheet:', error);
      toast.error('Failed to submit timesheet');
    } finally {
      setIsActioning(false);
    }
  }, [uuid, fetchTimesheet]);

  const handleApprove = useCallback(async () => {
    setIsActioning(true);
    try {
      await timesheetsService.approveTimesheet(uuid);
      toast.success('Timesheet approved');
      fetchTimesheet();
    } catch (error) {
      console.error('Failed to approve timesheet:', error);
      toast.error('Failed to approve timesheet');
    } finally {
      setIsActioning(false);
    }
  }, [uuid, fetchTimesheet]);

  const handleReopen = useCallback(async () => {
    setIsActioning(true);
    try {
      await timesheetsService.reopenTimesheet(uuid);
      toast.success('Timesheet reopened');
      fetchTimesheet();
    } catch (error) {
      console.error('Failed to reopen timesheet:', error);
      toast.error('Failed to reopen timesheet');
    } finally {
      setIsActioning(false);
    }
  }, [uuid, fetchTimesheet]);

  const handleDelete = useCallback(async () => {
    if (!confirm('Are you sure you want to delete this timesheet? This action cannot be undone.')) {
      return;
    }

    setIsActioning(true);
    try {
      await timesheetsService.deleteTimesheet(uuid);
      toast.success('Timesheet deleted');
      router.push('/dashboard/timesheets');
    } catch (error) {
      console.error('Failed to delete timesheet:', error);
      toast.error('Failed to delete timesheet');
    } finally {
      setIsActioning(false);
    }
  }, [uuid, router]);

  // ============================================
  // Entry Actions
  // ============================================

  const handleEditEntry = useCallback((entry: TimesheetEntry) => {
    setEditEntry(entry);
    setIsEntryModalOpen(true);
  }, []);

  const handleDeleteEntry = useCallback(async (entryUuid: string) => {
    if (!confirm('Are you sure you want to delete this entry?')) {
      return;
    }

    try {
      await timesheetsService.deleteEntry(entryUuid);
      toast.success('Entry deleted');
      fetchTimesheet();
    } catch (error) {
      console.error('Failed to delete entry:', error);
      toast.error('Failed to delete entry');
    }
  }, [fetchTimesheet]);

  // ============================================
  // Computed Values
  // ============================================

  const entries = timesheet?.entries || [];
  const isDraft = timesheet?.status === 'draft';
  const isSubmitted = timesheet?.status === 'submitted';
  const isApproved = timesheet?.status === 'approved';
  const isRejected = timesheet?.status === 'rejected';

  // Summary by project
  const summaryByProject = entries.reduce<Record<string, number>>((acc, entry) => {
    const key = entry.project_reference || 'No Project';
    acc[key] = (acc[key] || 0) + (entry.hours || 0);
    return acc;
  }, {});

  // Summary by category
  const summaryByCategory = entries.reduce<Record<string, number>>((acc, entry) => {
    const key = entry.category || 'Uncategorized';
    acc[key] = (acc[key] || 0) + (entry.hours || 0);
    return acc;
  }, {});

  // ============================================
  // Loading State
  // ============================================

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-[400px]">
        <div className="flex items-center gap-3 text-secondary-500">
          <Loader2 className="w-6 h-6 animate-spin" />
          <span>Loading timesheet...</span>
        </div>
      </div>
    );
  }

  if (!timesheet) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[400px] text-secondary-500">
        <AlertTriangle className="w-12 h-12 mb-4" />
        <p className="text-lg font-medium">Timesheet not found</p>
        <button
          onClick={() => router.push('/dashboard/timesheets')}
          className="mt-4 px-4 py-2 text-sm font-medium text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
        >
          Back to Timesheets
        </button>
      </div>
    );
  }

  // ============================================
  // Render
  // ============================================

  return (
    <div className="space-y-6">
      {/* Back Button & Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <button
            onClick={() => router.push('/dashboard/timesheets')}
            className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-bold text-secondary-900">
                {formatDate(timesheet.period_start)} - {formatDate(timesheet.period_end)}
              </h1>
              <Badge size="md" status={timesheet.status} />
            </div>
            <p className="text-secondary-500 mt-1">
              {timesheet.notes || 'No description'}
            </p>
          </div>
        </div>
        <button
          onClick={fetchTimesheet}
          className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
        >
          <RefreshCw className="w-4 h-4" />
          Refresh
        </button>
      </div>

      {/* Summary Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-secondary-500">Total Hours</p>
              <p className="text-2xl font-bold text-secondary-900 mt-1">
                {timesheet.total_hours?.toFixed(1) || '0.0'}
              </p>
            </div>
            <div className="w-12 h-12 rounded-xl flex items-center justify-center bg-primary-50 text-primary-600">
              <Clock className="w-6 h-6" />
            </div>
          </div>
        </div>
        <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-secondary-500">Billable Hours</p>
              <p className="text-2xl font-bold text-secondary-900 mt-1">
                {timesheet.billable_hours?.toFixed(1) || '0.0'}
              </p>
            </div>
            <div className="w-12 h-12 rounded-xl flex items-center justify-center bg-green-50 text-green-600">
              <DollarSign className="w-6 h-6" />
            </div>
          </div>
        </div>
        <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-secondary-500">Entries</p>
              <p className="text-2xl font-bold text-secondary-900 mt-1">{entries.length}</p>
            </div>
            <div className="w-12 h-12 rounded-xl flex items-center justify-center bg-blue-50 text-blue-600">
              <FileText className="w-6 h-6" />
            </div>
          </div>
        </div>
        <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-secondary-500">Status</p>
              <div className="mt-2">
                <Badge size="md" status={timesheet.status} />
              </div>
            </div>
            <div className="w-12 h-12 rounded-xl flex items-center justify-center bg-secondary-50 text-secondary-600">
              <CheckCircle className="w-6 h-6" />
            </div>
          </div>
        </div>
      </div>

      {/* Rejection Reason */}
      {isRejected && timesheet.rejection_reason && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-4">
          <div className="flex items-start gap-3">
            <XCircle className="w-5 h-5 text-red-600 mt-0.5 flex-shrink-0" />
            <div>
              <h4 className="font-medium text-red-900">Rejection Reason</h4>
              <p className="text-sm text-red-700 mt-1">{timesheet.rejection_reason}</p>
            </div>
          </div>
        </div>
      )}

      {/* Workflow Actions */}
      <Card padding="md">
        <div className="flex items-center justify-between">
          <h3 className="font-medium text-secondary-900">Actions</h3>
          <div className="flex items-center gap-3">
            {isDraft && (
              <>
                <button
                  onClick={() => {
                    setEditEntry(null);
                    setIsEntryModalOpen(true);
                  }}
                  className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
                >
                  <Plus className="w-4 h-4" />
                  Add Entry
                </button>
                <button
                  onClick={handleSubmit}
                  disabled={isActioning}
                  className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 transition-colors"
                >
                  <Send className="w-4 h-4" />
                  Submit for Approval
                </button>
                <button
                  onClick={handleDelete}
                  disabled={isActioning}
                  className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-red-600 bg-white border border-red-300 rounded-lg hover:bg-red-50 disabled:opacity-50 transition-colors"
                >
                  <Trash2 className="w-4 h-4" />
                  Delete
                </button>
              </>
            )}

            {isSubmitted && (
              <>
                <div className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-blue-600 bg-blue-50 rounded-lg">
                  <Clock className="w-4 h-4" />
                  Pending Approval
                </div>
                <button
                  onClick={handleApprove}
                  disabled={isActioning}
                  className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-green-600 rounded-lg hover:bg-green-700 disabled:opacity-50 transition-colors"
                >
                  <CheckCircle className="w-4 h-4" />
                  Approve
                </button>
                <button
                  onClick={() => setIsRejectModalOpen(true)}
                  disabled={isActioning}
                  className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-red-600 bg-white border border-red-300 rounded-lg hover:bg-red-50 disabled:opacity-50 transition-colors"
                >
                  <XCircle className="w-4 h-4" />
                  Reject
                </button>
              </>
            )}

            {isApproved && (
              <div className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-green-600 bg-green-50 rounded-lg">
                <CheckCircle className="w-4 h-4" />
                Approved
                {timesheet.approved_at && (
                  <span className="text-green-500 ml-1">on {formatDate(timesheet.approved_at)}</span>
                )}
              </div>
            )}

            {isRejected && (
              <button
                onClick={handleReopen}
                disabled={isActioning}
                className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-amber-600 rounded-lg hover:bg-amber-700 disabled:opacity-50 transition-colors"
              >
                <RotateCcw className="w-4 h-4" />
                Reopen
              </button>
            )}
          </div>
        </div>
      </Card>

      {/* Time Entries Table */}
      <Card padding="none">
        <div className="px-5 py-4 border-b border-secondary-200 flex items-center justify-between">
          <h3 className="font-medium text-secondary-900">Time Entries</h3>
          {isDraft && (
            <button
              onClick={() => {
                setEditEntry(null);
                setIsEntryModalOpen(true);
              }}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
            >
              <Plus className="w-4 h-4" />
              Add Entry
            </button>
          )}
        </div>

        {entries.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-12 text-secondary-500">
            <FileText className="w-10 h-10 mb-3" />
            <p className="text-sm font-medium">No time entries yet</p>
            {isDraft && (
              <button
                onClick={() => {
                  setEditEntry(null);
                  setIsEntryModalOpen(true);
                }}
                className="mt-3 px-4 py-2 text-sm font-medium text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
              >
                Add your first entry
              </button>
            )}
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-secondary-50">
                <tr>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Date</th>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Description</th>
                  <th className="text-right px-5 py-3 text-secondary-600 font-medium">Hours</th>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Project</th>
                  <th className="text-left px-5 py-3 text-secondary-600 font-medium">Category</th>
                  <th className="text-center px-5 py-3 text-secondary-600 font-medium">Billable</th>
                  {isDraft && (
                    <th className="text-right px-5 py-3 text-secondary-600 font-medium">Actions</th>
                  )}
                </tr>
              </thead>
              <tbody className="divide-y divide-secondary-200">
                {entries.map((entry) => (
                  <tr key={entry.uuid} className="hover:bg-secondary-50 transition-colors">
                    <td className="px-5 py-3 text-secondary-900 whitespace-nowrap">
                      {formatDate(entry.date)}
                    </td>
                    <td className="px-5 py-3 text-secondary-700 max-w-xs truncate">
                      {entry.description || '-'}
                    </td>
                    <td className="px-5 py-3 text-right font-semibold text-secondary-900">
                      {entry.hours?.toFixed(2)}
                    </td>
                    <td className="px-5 py-3 text-secondary-700">
                      {entry.project_reference || '-'}
                    </td>
                    <td className="px-5 py-3 text-secondary-700">
                      {entry.category || '-'}
                    </td>
                    <td className="px-5 py-3 text-center">
                      {entry.is_billable ? (
                        <span className="inline-flex items-center px-2 py-0.5 text-xs font-medium rounded-full bg-green-100 text-green-700">
                          Yes
                        </span>
                      ) : (
                        <span className="inline-flex items-center px-2 py-0.5 text-xs font-medium rounded-full bg-secondary-100 text-secondary-600">
                          No
                        </span>
                      )}
                    </td>
                    {isDraft && (
                      <td className="px-5 py-3 text-right">
                        <div className="flex items-center justify-end gap-1">
                          <button
                            onClick={() => handleEditEntry(entry)}
                            className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
                            title="Edit Entry"
                          >
                            <Edit className="w-4 h-4" />
                          </button>
                          <button
                            onClick={() => handleDeleteEntry(entry.uuid)}
                            className="p-1.5 text-secondary-500 hover:text-red-500 hover:bg-red-50 rounded-lg transition-colors"
                            title="Delete Entry"
                          >
                            <Trash2 className="w-4 h-4" />
                          </button>
                        </div>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {/* Summary Section */}
      {entries.length > 0 && (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* By Project */}
          <Card padding="md">
            <h3 className="font-medium text-secondary-900 mb-4">Hours by Project</h3>
            <div className="space-y-3">
              {Object.entries(summaryByProject).map(([project, hours]) => (
                <div key={project} className="flex items-center justify-between">
                  <span className="text-sm text-secondary-700">{project}</span>
                  <span className="text-sm font-semibold text-secondary-900">{hours.toFixed(1)}h</span>
                </div>
              ))}
            </div>
          </Card>

          {/* By Category */}
          <Card padding="md">
            <h3 className="font-medium text-secondary-900 mb-4">Hours by Category</h3>
            <div className="space-y-3">
              {Object.entries(summaryByCategory).map(([category, hours]) => (
                <div key={category} className="flex items-center justify-between">
                  <span className="text-sm text-secondary-700">{category}</span>
                  <span className="text-sm font-semibold text-secondary-900">{hours.toFixed(1)}h</span>
                </div>
              ))}
            </div>
          </Card>
        </div>
      )}

      {/* Add/Edit Entry Modal */}
      <AddEntryModal
        isOpen={isEntryModalOpen}
        onClose={() => {
          setIsEntryModalOpen(false);
          setEditEntry(null);
        }}
        onSaved={fetchTimesheet}
        timesheetUuid={uuid}
        editEntry={editEntry}
      />

      {/* Reject Modal */}
      <RejectModal
        isOpen={isRejectModalOpen}
        onClose={() => setIsRejectModalOpen(false)}
        onRejected={fetchTimesheet}
        timesheetUuid={uuid}
      />
    </div>
  );
}

export default function TimesheetDetailPage() {
  return (
    <ProtectedPage module="timesheets" title="Timesheet Details">
      <TimesheetDetailContent />
    </ProtectedPage>
  );
}
