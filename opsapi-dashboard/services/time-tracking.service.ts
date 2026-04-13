import { apiClient, buildQueryString, toFormData } from '@/lib/api-client';
import type {
  TimeEntry,
  RunningTimer,
  TimesheetSummary,
  TimeReportByUser,
  CreateTimeEntryDto,
  UpdateTimeEntryDto,
  PaginationParams,
} from '@/types';

// ============================================
// Request Parameter Types
// ============================================

interface TimeEntryListParams extends PaginationParams {
  task_uuid?: string;
  project_uuid?: string;
  user_uuid?: string;
  date_from?: string;
  date_to?: string;
  is_billable?: boolean;
  status?: 'pending' | 'approved' | 'rejected';
}

interface TimesheetParams {
  user_uuid?: string;
  date_from: string;
  date_to: string;
  project_uuid?: string;
}

interface TimeReportParams {
  project_uuid?: string;
  date_from: string;
  date_to: string;
  group_by?: 'user' | 'task' | 'project' | 'date';
}

// ============================================
// Response Types
// ============================================

interface ApiDataResponse<T> {
  data: T;
  message?: string;
}

interface ApiListResponse<T> {
  data: T[];
  total: number;
  page: number;
  per_page: number;
}

// ============================================
// Time Tracking Service
// ============================================

/**
 * Time Tracking Service
 * Handles all time tracking related API calls for the kanban system
 *
 * FEATURES:
 * - Start/stop timers
 * - Manual time entries
 * - Timesheet views
 * - Time reports and analytics
 * - Billable hours tracking
 * - Time approval workflow
 */
export const timeTrackingService = {
  // ============================================
  // Timer Operations
  // ============================================

  /**
   * Start a timer for a task
   */
  async startTimer(taskUuid: string, description?: string): Promise<RunningTimer> {
    const data: Record<string, unknown> = { task_uuid: taskUuid };
    if (description) data.description = description;

    const response = await apiClient.post<ApiDataResponse<RunningTimer>>(
      '/api/v2/kanban/time-tracking/start',
      toFormData(data)
    );
    return response.data.data;
  },

  /**
   * Stop the current running timer
   */
  async stopTimer(): Promise<TimeEntry> {
    const response = await apiClient.post<ApiDataResponse<TimeEntry>>(
      '/api/v2/kanban/time-tracking/stop'
    );
    return response.data.data;
  },

  /**
   * Get the current running timer (if any)
   */
  async getRunningTimer(): Promise<RunningTimer | null> {
    const response = await apiClient.get<ApiDataResponse<RunningTimer | null>>(
      '/api/v2/kanban/time-tracking/current'
    );
    return response.data.data;
  },

  /**
   * Discard the current running timer without saving
   */
  async discardTimer(): Promise<void> {
    await apiClient.delete('/api/v2/kanban/time-tracking/current');
  },

  // ============================================
  // Time Entry Operations
  // ============================================

  /**
   * Get time entries with filters
   */
  async getTimeEntries(params?: TimeEntryListParams): Promise<ApiListResponse<TimeEntry>> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
      task_uuid: params?.task_uuid,
      project_uuid: params?.project_uuid,
      user_uuid: params?.user_uuid,
      date_from: params?.date_from,
      date_to: params?.date_to,
      is_billable: params?.is_billable,
      status: params?.status,
    });
    const response = await apiClient.get<ApiListResponse<TimeEntry>>(
      `/api/v2/kanban/time-tracking/entries${queryString}`
    );
    return response.data;
  },

  /**
   * Get a single time entry
   */
  async getTimeEntry(uuid: string): Promise<TimeEntry> {
    const response = await apiClient.get<ApiDataResponse<TimeEntry>>(
      `/api/v2/kanban/time-tracking/entries/${uuid}`
    );
    return response.data.data;
  },

  /**
   * Create a manual time entry
   */
  async createTimeEntry(data: CreateTimeEntryDto): Promise<TimeEntry> {
    const response = await apiClient.post<ApiDataResponse<TimeEntry>>(
      '/api/v2/kanban/time-tracking/entries',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a time entry
   */
  async updateTimeEntry(uuid: string, data: UpdateTimeEntryDto): Promise<TimeEntry> {
    const response = await apiClient.put<ApiDataResponse<TimeEntry>>(
      `/api/v2/kanban/time-tracking/entries/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a time entry
   */
  async deleteTimeEntry(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/time-tracking/entries/${uuid}`);
  },

  // ============================================
  // Approval Workflow
  // ============================================

  /**
   * Submit time entries for approval
   */
  async submitForApproval(entryUuids: string[]): Promise<{ count: number }> {
    const response = await apiClient.post<ApiDataResponse<{ count: number }>>(
      '/api/v2/kanban/time-tracking/submit',
      toFormData({ entry_uuids: JSON.stringify(entryUuids) })
    );
    return response.data.data;
  },

  /**
   * Approve time entries (manager action)
   */
  async approveEntries(entryUuids: string[]): Promise<{ count: number }> {
    const response = await apiClient.post<ApiDataResponse<{ count: number }>>(
      '/api/v2/kanban/time-tracking/approve',
      toFormData({ entry_uuids: JSON.stringify(entryUuids) })
    );
    return response.data.data;
  },

  /**
   * Reject time entries (manager action)
   */
  async rejectEntries(entryUuids: string[], reason?: string): Promise<{ count: number }> {
    const data: Record<string, unknown> = { entry_uuids: JSON.stringify(entryUuids) };
    if (reason) data.rejection_reason = reason;

    const response = await apiClient.post<ApiDataResponse<{ count: number }>>(
      '/api/v2/kanban/time-tracking/reject',
      toFormData(data)
    );
    return response.data.data;
  },

  // ============================================
  // Timesheet Operations
  // ============================================

  /**
   * Get timesheet summary for a date range
   */
  async getTimesheet(params: TimesheetParams): Promise<TimesheetSummary> {
    const queryString = buildQueryString({
      user_uuid: params.user_uuid,
      date_from: params.date_from,
      date_to: params.date_to,
      project_uuid: params.project_uuid,
    });
    const response = await apiClient.get<ApiDataResponse<TimesheetSummary>>(
      `/api/v2/kanban/time-tracking/timesheet${queryString}`
    );
    return response.data.data;
  },

  /**
   * Get my timesheet (current user)
   */
  async getMyTimesheet(dateFrom: string, dateTo: string): Promise<TimesheetSummary> {
    const queryString = buildQueryString({ date_from: dateFrom, date_to: dateTo });
    const response = await apiClient.get<ApiDataResponse<TimesheetSummary>>(
      `/api/v2/kanban/time-tracking/my-timesheet${queryString}`
    );
    return response.data.data;
  },

  // ============================================
  // Reports
  // ============================================

  /**
   * Get time report by user
   */
  async getTimeReportByUser(params: TimeReportParams): Promise<TimeReportByUser[]> {
    const queryString = buildQueryString({
      project_uuid: params.project_uuid,
      date_from: params.date_from,
      date_to: params.date_to,
      group_by: params.group_by,
    });
    const response = await apiClient.get<ApiDataResponse<TimeReportByUser[]>>(
      `/api/v2/kanban/time-tracking/reports/by-user${queryString}`
    );
    return response.data.data;
  },

  /**
   * Get time entries for a specific task
   */
  async getTaskTimeEntries(taskUuid: string): Promise<TimeEntry[]> {
    const response = await apiClient.get<ApiListResponse<TimeEntry>>(
      `/api/v2/kanban/tasks/${taskUuid}/time-entries`
    );
    return response.data.data;
  },

  /**
   * Get total time logged for a task
   */
  async getTaskTotalTime(taskUuid: string): Promise<{ total_minutes: number; billable_minutes: number }> {
    const response = await apiClient.get<ApiDataResponse<{ total_minutes: number; billable_minutes: number }>>(
      `/api/v2/kanban/tasks/${taskUuid}/time-total`
    );
    return response.data.data;
  },
};

// ============================================
// Helper Functions
// ============================================

/**
 * Format duration in minutes to human-readable string
 */
export function formatDuration(minutes: number): string {
  if (minutes < 1) return '0m';

  const hours = Math.floor(minutes / 60);
  const mins = Math.round(minutes % 60);

  if (hours === 0) return `${mins}m`;
  if (mins === 0) return `${hours}h`;
  return `${hours}h ${mins}m`;
}

/**
 * Format duration for display with hours and minutes
 */
export function formatDurationLong(minutes: number): string {
  const hours = Math.floor(minutes / 60);
  const mins = Math.round(minutes % 60);

  if (hours === 0) return `${mins} minute${mins !== 1 ? 's' : ''}`;
  if (mins === 0) return `${hours} hour${hours !== 1 ? 's' : ''}`;
  return `${hours} hour${hours !== 1 ? 's' : ''} ${mins} minute${mins !== 1 ? 's' : ''}`;
}

/**
 * Format timer display (HH:MM:SS)
 */
export function formatTimerDisplay(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;

  return [
    hours.toString().padStart(2, '0'),
    minutes.toString().padStart(2, '0'),
    secs.toString().padStart(2, '0'),
  ].join(':');
}

/**
 * Calculate elapsed time in seconds from start time
 */
export function calculateElapsedSeconds(startTime: string): number {
  const start = new Date(startTime);
  const now = new Date();
  return Math.floor((now.getTime() - start.getTime()) / 1000);
}

/**
 * Get status color for time entry
 */
export function getTimeEntryStatusColor(status: string): string {
  const colors: Record<string, string> = {
    pending: 'bg-yellow-100 text-yellow-700',
    approved: 'bg-green-100 text-green-700',
    rejected: 'bg-red-100 text-red-700',
    draft: 'bg-gray-100 text-gray-600',
  };
  return colors[status] || colors.draft;
}

/**
 * Format hourly rate for display
 */
export function formatHourlyRate(rate: number, currency: string = 'USD'): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: currency,
  }).format(rate);
}

/**
 * Calculate billable amount
 */
export function calculateBillableAmount(minutes: number, hourlyRate: number): number {
  return (minutes / 60) * hourlyRate;
}

/**
 * Format date for timesheet display
 */
export function formatTimesheetDate(dateString: string): string {
  const date = new Date(dateString);
  return date.toLocaleDateString('en-US', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  });
}

/**
 * Get week start and end dates
 */
export function getWeekDates(date: Date = new Date()): { start: string; end: string } {
  const start = new Date(date);
  const day = start.getDay();
  const diff = start.getDate() - day + (day === 0 ? -6 : 1); // Monday
  start.setDate(diff);
  start.setHours(0, 0, 0, 0);

  const end = new Date(start);
  end.setDate(start.getDate() + 6);
  end.setHours(23, 59, 59, 999);

  return {
    start: start.toISOString().split('T')[0],
    end: end.toISOString().split('T')[0],
  };
}

/**
 * Get month start and end dates
 */
export function getMonthDates(date: Date = new Date()): { start: string; end: string } {
  const start = new Date(date.getFullYear(), date.getMonth(), 1);
  const end = new Date(date.getFullYear(), date.getMonth() + 1, 0);

  return {
    start: start.toISOString().split('T')[0],
    end: end.toISOString().split('T')[0],
  };
}

export default timeTrackingService;
