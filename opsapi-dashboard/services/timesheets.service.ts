import apiClient, { buildQueryString, toFormData } from '@/lib/api-client';

// ============================================
// Request Parameter Types
// ============================================

export interface TimesheetListParams {
  page?: number;
  per_page?: number;
  status?: TimesheetStatus | 'all';
}

export interface ApprovalQueueParams {
  page?: number;
  per_page?: number;
  status?: string;
}

export interface TimesheetSummaryParams {
  date_from?: string;
  date_to?: string;
  user_uuid?: string;
}

export interface CreateTimesheetData {
  // Either a single work date (preferred) or an explicit period range.
  work_date?: string;
  period_start?: string;
  period_end?: string;
  // Customer this work was for (ecommerce customers.uuid). Resolved server-side
  // to customer_id + client_name snapshot.
  customer_uuid?: string;
  client_name?: string;
  // Task the work belongs to (kanban task.uuid). Resolved server-side to the
  // task title + parent project.
  task_uuid?: string;
  task?: string;
  // Single-session timing — hours are computed server-side from these.
  start_time?: string;
  end_time?: string;
  // Billing.
  is_billable?: boolean;
  hourly_rate?: number;
  notes?: string;
}

export interface UpdateTimesheetData {
  work_date?: string;
  period_start?: string;
  period_end?: string;
  customer_uuid?: string;
  client_name?: string;
  task_uuid?: string;
  task?: string;
  start_time?: string;
  end_time?: string;
  is_billable?: boolean;
  hourly_rate?: number;
  notes?: string;
}

// Lookup option shapes for the searchable dropdowns (namespace-scoped).
export interface CustomerOption {
  uuid: string;
  first_name?: string;
  last_name?: string;
  email?: string;
}

export interface TaskOption {
  task_uuid: string;
  title: string;
  project_uuid?: string;
  project_name?: string;
}

export interface CreateEntryData {
  date: string;
  hours: number;
  description?: string;
  project_reference?: string;
  is_billable?: boolean;
  category?: string;
}

export interface UpdateEntryData {
  date?: string;
  hours?: number;
  description?: string;
  project_reference?: string;
  is_billable?: boolean;
  category?: string;
}

// ============================================
// Response Types
// ============================================

export type TimesheetStatus = 'draft' | 'submitted' | 'approved' | 'rejected' | 'void';

export interface TimesheetEntry {
  uuid: string;
  timesheet_uuid: string;
  date: string;
  hours: number;
  description: string;
  project_reference?: string;
  is_billable: boolean;
  category?: string;
  created_at: string;
  updated_at: string;
}

export interface Timesheet {
  uuid: string;
  user_uuid: string;
  period_start: string;
  period_end: string;
  status: TimesheetStatus;
  total_hours: number;
  billable_hours: number;
  // Client-work fields (enriched timesheet model)
  customer_id?: number | null;
  customer_uuid?: string | null;
  client_name?: string | null;
  task?: string | null;
  task_uuid?: string | null;
  project_uuid?: string | null;
  project_name?: string | null;
  work_date?: string | null;
  start_time?: string | null;
  end_time?: string | null;
  hourly_rate?: number | string | null;
  is_billable?: boolean;
  notes?: string;
  submitted_at?: string;
  approved_at?: string;
  rejected_at?: string;
  rejection_reason?: string;
  approval_comments?: string;
  entries?: TimesheetEntry[];
  user?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
  };
  created_at: string;
  updated_at: string;
}

export interface TimesheetsResponse {
  data: Timesheet[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
  has_next: boolean;
  has_prev: boolean;
}

export interface TimesheetSummaryResponse {
  total_hours: number;
  billable_hours: number;
  pending_count: number;
  approved_count: number;
  by_project: { project_reference: string; hours: number }[];
  by_category: { category: string; hours: number }[];
}

// ============================================
// Timesheets Service
// ============================================

export const timesheetsService = {
  /**
   * Get timesheets with pagination and filters
   */
  async getTimesheets(params: TimesheetListParams = {}): Promise<TimesheetsResponse> {
    const queryParams: Record<string, unknown> = {};
    if (params.page) queryParams.page = params.page;
    if (params.per_page) queryParams.per_page = params.per_page;
    if (params.status && params.status !== 'all') queryParams.status = params.status;

    const queryString = buildQueryString(queryParams);
    const response = await apiClient.get(`/api/v2/timesheets${queryString}`);

    // Backend shape: { success, data: { data: [...], meta: { total, page, per_page, total_pages } } }
    // Unwrap the {success,data} envelope, then read the inner list + meta.
    const body = response.data?.data ?? response.data;
    const data: Timesheet[] = Array.isArray(body?.data)
      ? body.data
      : Array.isArray(body)
        ? body
        : [];
    const meta = body?.meta ?? {};
    const page = meta.page ?? params.page ?? 1;
    const perPage = meta.per_page ?? params.per_page ?? 10;
    const totalPages = meta.total_pages ?? 0;

    return {
      data,
      total: meta.total ?? data.length,
      page,
      per_page: perPage,
      total_pages: totalPages,
      has_next: page < totalPages,
      has_prev: page > 1,
    };
  },

  /**
   * Namespace-scoped customer lookup for the create/edit dropdown.
   */
  async lookupCustomers(q?: string): Promise<CustomerOption[]> {
    const qs = q ? `?q=${encodeURIComponent(q)}` : '';
    const response = await apiClient.get(`/api/v2/timesheets/lookups/customers${qs}`);
    const data = response.data?.data ?? response.data;
    return Array.isArray(data) ? data : [];
  },

  /**
   * Namespace-scoped task lookup (kanban tasks + their project).
   */
  async lookupTasks(q?: string): Promise<TaskOption[]> {
    const qs = q ? `?q=${encodeURIComponent(q)}` : '';
    const response = await apiClient.get(`/api/v2/timesheets/lookups/tasks${qs}`);
    const data = response.data?.data ?? response.data;
    return Array.isArray(data) ? data : [];
  },

  /**
   * Get single timesheet with entries
   */
  async getTimesheet(uuid: string): Promise<Timesheet> {
    const response = await apiClient.get(`/api/v2/timesheets/${uuid}`);
    return response.data?.data || response.data;
  },

  /**
   * Create a new timesheet
   */
  async createTimesheet(data: CreateTimesheetData): Promise<Timesheet> {
    const response = await apiClient.post(
      '/api/v2/timesheets',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data?.data || response.data;
  },

  /**
   * Update a timesheet
   */
  async updateTimesheet(uuid: string, data: UpdateTimesheetData): Promise<Timesheet> {
    const response = await apiClient.put(
      `/api/v2/timesheets/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data?.data || response.data;
  },

  /**
   * Delete a timesheet
   */
  async deleteTimesheet(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/timesheets/${uuid}`);
  },

  /**
   * Submit a timesheet for approval
   */
  async submitTimesheet(uuid: string): Promise<Timesheet> {
    const response = await apiClient.post(`/api/v2/timesheets/${uuid}/submit`);
    return response.data?.data || response.data;
  },

  /**
   * Approve a timesheet (manager action)
   */
  async approveTimesheet(uuid: string, comments?: string): Promise<Timesheet> {
    const data: Record<string, unknown> = {};
    if (comments) data.comments = comments;

    const response = await apiClient.post(
      `/api/v2/timesheets/${uuid}/approve`,
      Object.keys(data).length > 0 ? toFormData(data) : undefined
    );
    return response.data?.data || response.data;
  },

  /**
   * Reject a timesheet (manager action)
   */
  async rejectTimesheet(uuid: string, reason: string): Promise<Timesheet> {
    const response = await apiClient.post(
      `/api/v2/timesheets/${uuid}/reject`,
      toFormData({ reason })
    );
    return response.data?.data || response.data;
  },

  /**
   * Reopen a rejected timesheet
   */
  async reopenTimesheet(uuid: string): Promise<Timesheet> {
    const response = await apiClient.post(`/api/v2/timesheets/${uuid}/reopen`);
    return response.data?.data || response.data;
  },

  /**
   * Get approval queue for managers
   */
  async getApprovalQueue(params: ApprovalQueueParams = {}): Promise<TimesheetsResponse> {
    const queryParams: Record<string, unknown> = {};
    if (params.page) queryParams.page = params.page;
    if (params.per_page) queryParams.per_page = params.per_page;
    if (params.status) queryParams.status = params.status;

    const queryString = buildQueryString(queryParams);
    const response = await apiClient.get(`/api/v2/timesheets/approval-queue${queryString}`);

    const data = Array.isArray(response.data?.data) ? response.data.data : [];

    return {
      data,
      total: response.data?.total || 0,
      page: response.data?.page || params.page || 1,
      per_page: response.data?.per_page || params.per_page || 10,
      total_pages: response.data?.total_pages || 0,
      has_next: response.data?.has_next || false,
      has_prev: response.data?.has_prev || false,
    };
  },

  /**
   * Add a time entry to a timesheet
   */
  async addEntry(timesheetUuid: string, data: CreateEntryData): Promise<TimesheetEntry> {
    const response = await apiClient.post(
      `/api/v2/timesheets/${timesheetUuid}/entries`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data?.data || response.data;
  },

  /**
   * Update a time entry
   */
  async updateEntry(entryUuid: string, data: UpdateEntryData): Promise<TimesheetEntry> {
    const response = await apiClient.put(
      `/api/v2/timesheets/entries/${entryUuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data?.data || response.data;
  },

  /**
   * Delete a time entry
   */
  async deleteEntry(entryUuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/timesheets/entries/${entryUuid}`);
  },

  /**
   * Get timesheet summary/stats
   */
  async getSummary(params: TimesheetSummaryParams = {}): Promise<TimesheetSummaryResponse> {
    const queryString = buildQueryString(params as Record<string, unknown>);
    const response = await apiClient.get(`/api/v2/timesheets/summary${queryString}`);
    return response.data?.data || response.data;
  },
};

export default timesheetsService;
