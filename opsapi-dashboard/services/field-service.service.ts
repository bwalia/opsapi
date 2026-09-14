import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Field Service API client — service jobs, job phases, engineer site visits,
 * customer sites and job types. Backed by lapis/routes/field-service-*.lua.
 *
 * Timestamps: the backend stores every fs_* timestamp as naive UTC
 * ("2026-09-12 08:00:00"). Parse them with `parseFsDate` and send schedule
 * values through `toApiDateTime` (ISO-8601 UTC).
 */

// The field-service routes read JSON bodies (RequestParser.parse_request).
const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;
const BASE = '/api/v2/field-service';

// ============================================================
// Date helpers
// ============================================================

/** Parse a naive-UTC backend timestamp (or date) into a Date. */
export function parseFsDate(value?: string | null): Date | null {
  if (!value) return null;
  let s = String(value).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    // Plain DATE column — treat as a local calendar date.
    const [y, m, d] = s.split('-').map(Number);
    return new Date(y, m - 1, d);
  }
  s = s.replace(' ', 'T');
  // NOW()-stamped columns carry microseconds; ECMAScript only guarantees ms.
  s = s.replace(/(\.\d{3})\d+/, '$1');
  if (!/(Z|[+-]\d{2}:?\d{2})$/.test(s)) s += 'Z';
  const d = new Date(s);
  return isNaN(d.getTime()) ? null : d;
}

/** Convert a `<input type="datetime-local">` value to an ISO-8601 UTC string. */
export function toApiDateTime(localValue?: string | null): string | undefined {
  if (!localValue) return undefined;
  const d = new Date(localValue);
  return isNaN(d.getTime()) ? undefined : d.toISOString();
}

/** Convert a backend timestamp into a `<input type="datetime-local">` value. */
export function toLocalInputValue(value?: string | null): string {
  const d = parseFsDate(value);
  if (!d) return '';
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** Format a backend timestamp for display in the viewer's local time. */
export function formatFsDateTime(value?: string | null, opts?: Intl.DateTimeFormatOptions): string {
  const d = parseFsDate(value);
  if (!d) return '—';
  return d.toLocaleString(undefined, opts ?? { dateStyle: 'medium', timeStyle: 'short' });
}

export function formatFsDate(value?: string | null): string {
  const d = parseFsDate(value);
  if (!d) return '—';
  return d.toLocaleDateString(undefined, { dateStyle: 'medium' });
}

export function formatFsTime(value?: string | null): string {
  const d = parseFsDate(value);
  if (!d) return '—';
  return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

// ============================================================
// Types
// ============================================================

export type JobStatus = 'draft' | 'scheduled' | 'in_progress' | 'on_hold' | 'completed' | 'cancelled';
export type JobPriority = 'low' | 'normal' | 'high' | 'urgent';
export type PhaseStatus = 'pending' | 'in_progress' | 'blocked' | 'completed' | 'skipped';
export type VisitStatus = 'scheduled' | 'en_route' | 'on_site' | 'completed' | 'cancelled' | 'no_access';
export type JobItemType = 'part' | 'material' | 'labour' | 'expense' | 'other';

export interface FsJob {
  uuid: string;
  job_number: string;
  title: string;
  description?: string | null;
  status: JobStatus;
  priority: JobPriority;
  service_manager_uuid?: string | null;
  service_manager_name?: string | null;
  customer_reference?: string | null;
  due_date?: string | null;
  estimated_hours?: number | null;
  hourly_rate?: number | null;
  currency: string;
  started_at?: string | null;
  completed_at?: string | null;
  cancelled_reason?: string | null;
  invoiced_at?: string | null;
  notes?: string | null;
  created_by_uuid?: string | null;
  created_at: string;
  updated_at: string;
  job_type_uuid?: string | null;
  job_type_name?: string | null;
  job_type_color?: string | null;
  job_type_hourly_rate?: number | null;
  customer_uuid?: string | null;
  customer_name?: string | null;
  customer_email?: string | null;
  customer_phone?: string | null;
  product_uuid?: string | null;
  product_name?: string | null;
  product_sku?: string | null;
  product_ref?: string | null;
  service_address?: string | null;
  service_postcode?: string | null;
  invoice_uuid?: string | null;
  invoice_number?: string | null;
  invoice_status?: string | null;
  invoice_total?: number | null;
  phase_count: number;
  phases_done: number;
  current_phase_name?: string | null;
  visit_count: number;
  next_visit_at?: string | null;
}

export interface ChecklistItem {
  label: string;
  done: boolean;
  done_at?: string | null;
  done_by?: string | null;
}

export interface FsPhase {
  uuid: string;
  template_uuid?: string | null;
  name: string;
  description?: string | null;
  sort_order: number;
  status: PhaseStatus;
  requires_visit: boolean;
  requires_signoff: boolean;
  estimated_hours?: number | null;
  checklist: ChecklistItem[];
  started_at?: string | null;
  completed_at?: string | null;
  completed_by_uuid?: string | null;
  completed_by_name?: string | null;
  signed_off_at?: string | null;
  signoff_name?: string | null;
  notes?: string | null;
  visit_count: number;
  logged_hours: number;
}

export interface FsVisit {
  uuid: string;
  engineer_user_uuid?: string | null;
  /** Currency of the parent job (for pricing parts on the visit page). */
  job_currency?: string | null;
  engineer_name?: string | null;
  engineer_email?: string | null;
  status: VisitStatus;
  scheduled_start: string;
  scheduled_end?: string | null;
  checked_in_at?: string | null;
  checked_out_at?: string | null;
  check_in_lat?: number | null;
  check_in_lng?: number | null;
  check_out_lat?: number | null;
  check_out_lng?: number | null;
  instructions?: string | null;
  work_summary?: string | null;
  labour_hours?: number | null;
  is_billable: boolean;
  hourly_rate?: number | null;
  effective_hourly_rate?: number | null;
  customer_signoff_name?: string | null;
  customer_signed_at?: string | null;
  follow_up_required: boolean;
  follow_up_notes?: string | null;
  cancelled_reason?: string | null;
  timesheet_uuid?: string | null;
  invoiced: boolean;
  created_by_uuid?: string | null;
  created_at: string;
  updated_at: string;
  job_uuid: string;
  job_number: string;
  job_title: string;
  job_status: JobStatus;
  job_priority: JobPriority;
  phase_uuid?: string | null;
  phase_name?: string | null;
  phase_status?: PhaseStatus | null;
  customer_uuid?: string | null;
  customer_name?: string | null;
  customer_phone?: string | null;
  product_uuid?: string | null;
  product_name?: string | null;
  product_sku?: string | null;
  product_ref?: string | null;
  service_address?: string | null;
  service_postcode?: string | null;
}

export type ItemApprovalStatus = 'pending' | 'approved' | 'rejected';

export interface FsJobItem {
  uuid: string;
  item_type: JobItemType;
  description: string;
  quantity: number;
  unit_price: number;
  tax_rate: number;
  line_total: number;
  is_billable: boolean;
  invoiced: boolean;
  approval_status: ItemApprovalStatus;
  approved_at?: string | null;
  rejection_reason?: string | null;
  part_uuid?: string | null;
  part_name?: string | null;
  visit_uuid?: string | null;
  phase_uuid?: string | null;
  phase_name?: string | null;
  created_by_uuid?: string | null;
  created_by_name?: string | null;
  created_at: string;
}

export interface FsVisitDetail extends FsVisit {
  phase?: FsPhase | null;
  items: FsJobItem[];
}

export interface FsActivity {
  uuid: string;
  action: string;
  message?: string | null;
  metadata?: Record<string, unknown> | null;
  actor_uuid?: string | null;
  actor_name?: string | null;
  created_at: string;
}

export interface FsJobTotals {
  labour_hours: number;
  billable_hours: number;
  labour_value: number;
  items_value: number;
  uninvoiced_value: number;
  open_visits: number;
  missing_rate: boolean;
}

export interface FsJobDetail extends FsJob {
  phases: FsPhase[];
  visits: FsVisit[];
  items: FsJobItem[];
  activity: FsActivity[];
  totals: FsJobTotals;
  allowed_transitions: JobStatus[];
}

export interface FsPhaseTemplate {
  uuid: string;
  name: string;
  description?: string | null;
  sort_order: number;
  requires_visit: boolean;
  requires_signoff: boolean;
  estimated_hours?: number | null;
  checklist: string[];
}

export interface FsJobType {
  uuid: string;
  name: string;
  description?: string | null;
  color?: string | null;
  default_hourly_rate?: number | null;
  is_active: boolean;
  phase_count?: number;
  job_count?: number;
  phases?: FsPhaseTemplate[];
  created_at: string;
  updated_at: string;
}

export interface FsEngineer {
  uuid: string;
  email: string;
  name: string;
  open_visits: number;
}

export interface FsStats {
  open_jobs: number;
  draft_jobs: number;
  scheduled_jobs: number;
  in_progress_jobs: number;
  on_hold_jobs: number;
  completed_this_month: number;
  overdue_jobs: number;
  awaiting_invoice: number;
  visits_today: number;
  engineers_on_site: number;
  unassigned_visits: number;
  follow_ups: number;
}

export interface FsInvoiceLine {
  source: 'visit' | 'item';
  source_uuid: string;
  description: string;
  quantity: number;
  unit_price: number;
  tax_rate: number;
  net: number;
  tax: number;
  total: number;
  missing_rate?: boolean;
}

export interface FsInvoicePreview {
  currency: string;
  lines: FsInvoiceLine[];
  subtotal: number;
  tax_amount: number;
  total: number;
  missing_rate: boolean;
  can_invoice: boolean;
}

export interface FsInvoiceResult {
  invoice_uuid: string;
  invoice_number: string;
  status: string;
  total_amount: number;
  currency: string;
  line_count: number;
}

export interface FsConflict {
  uuid: string;
  scheduled_start: string;
  scheduled_end?: string | null;
  job_number: string;
  job_title: string;
}

export interface FsVisitMutation {
  visit: FsVisitDetail;
  conflicts: FsConflict[];
  warnings?: string[];
}

export interface FsCheckOutResult {
  visit: FsVisitDetail;
  warnings: string[];
}

export interface FsPageMeta {
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

export interface FsPaginated<T> {
  data: T[];
  meta: FsPageMeta;
}

export interface FsJobListParams {
  status?: string;
  priority?: string;
  customer_uuid?: string;
  product_uuid?: string;
  job_type_uuid?: string;
  manager_uuid?: string;
  engineer_uuid?: string;
  overdue?: boolean;
  uninvoiced?: boolean;
  search?: string;
  page?: number;
  per_page?: number;
  order_by?: string;
  order_dir?: 'asc' | 'desc';
}

export interface FsVisitListParams {
  mine?: boolean;
  engineer_uuid?: string;
  job_uuid?: string;
  status?: string;
  from?: string;
  to?: string;
  follow_up?: boolean;
  search?: string;
  page?: number;
  per_page?: number;
  order_dir?: 'asc' | 'desc';
}

export interface FsEmployee {
  uuid: string;
  user_uuid: string;
  user_name?: string | null;
  user_email?: string | null;
  employee_code?: string | null;
  job_title?: string | null;
  is_engineer: boolean;
  is_active: boolean;
  phone?: string | null;
  email?: string | null;
  region?: string | null;
  skills: string[];
  hourly_cost_rate?: number | null;
  metadata?: Record<string, unknown> | null;
  created_at: string;
  updated_at: string;
}

export interface FsEmployeeListParams {
  is_engineer?: boolean;
  is_active?: boolean;
  search?: string;
  page?: number;
  per_page?: number;
}

export type RequestStatus =
  | 'new' | 'triaged' | 'assigned' | 'in_progress' | 'on_hold' | 'resolved' | 'closed' | 'rejected' | 'duplicate';
export type RequestChannel = 'phone' | 'app' | 'email' | 'portal' | 'web' | 'other';

export interface FsServiceRequest {
  uuid: string;
  request_number: string;
  title: string;
  description?: string | null;
  fault_category?: string | null;
  channel: RequestChannel;
  reported_by?: string | null;
  priority: JobPriority;
  status: RequestStatus;
  customer_uuid?: string | null;
  customer_name?: string | null;
  customer_email?: string | null;
  customer_phone?: string | null;
  product_uuid?: string | null;
  product_name?: string | null;
  product_sku?: string | null;
  product_ref?: string | null;
  service_address?: string | null;
  service_postcode?: string | null;
  assigned_manager_uuid?: string | null;
  assigned_manager_name?: string | null;
  sla_response_due_at?: string | null;
  sla_resolve_due_at?: string | null;
  first_response_at?: string | null;
  resolved_at?: string | null;
  closed_at?: string | null;
  resolution_notes?: string | null;
  response_overdue?: boolean;
  resolve_overdue?: boolean;
  sla_breached?: boolean;
  metadata?: Record<string, unknown> | null;
  created_at: string;
  updated_at: string;
}

export interface FsRequestJob {
  uuid: string;
  job_number: string;
  title: string;
  status: JobStatus;
  priority: JobPriority;
  created_at: string;
  visit_count: number;
  invoice_number?: string | null;
  invoice_status?: string | null;
}

export interface FsRequestTotals {
  job_count: number;
  open_jobs: number;
  visit_count: number;
  labour_hours: number;
  invoiced_total: number;
}

export interface FsServiceRequestDetail extends FsServiceRequest {
  jobs: FsRequestJob[];
  totals: FsRequestTotals;
  allowed_transitions: RequestStatus[];
}

export interface FsConvertResult {
  job_uuid: string;
  job_number: string;
  request: FsServiceRequestDetail;
}

export interface FsRequestListParams {
  status?: string;
  priority?: string;
  customer_uuid?: string;
  product_uuid?: string;
  manager_uuid?: string;
  sla?: string;
  search?: string;
  page?: number;
  per_page?: number;
}

export interface FsPart {
  uuid: string;
  sku?: string | null;
  name: string;
  description?: string | null;
  category?: string | null;
  unit_cost?: number | null;
  unit_price?: number | null;
  tax_rate: number;
  stock_quantity?: number | null;
  reorder_level?: number | null;
  is_active: boolean;
  metadata?: Record<string, unknown> | null;
  created_at: string;
  updated_at: string;
}

export interface FsPartListParams {
  category?: string;
  is_active?: boolean;
  include_inactive?: boolean;
  search?: string;
  page?: number;
  per_page?: number;
}

export type FsPayload = Record<string, unknown>;

// ============================================================
// Response helpers
// ============================================================

function unwrap<T>(response: { data: unknown }): T {
  const body = response.data as { data?: T };
  return (body?.data ?? body) as T;
}

function paginated<T>(response: { data: unknown }): FsPaginated<T> {
  const body = response.data as { data?: T[]; meta?: FsPageMeta };
  return {
    data: Array.isArray(body?.data) ? body.data : [],
    meta: body?.meta ?? { total: 0, page: 1, per_page: 20, total_pages: 0 },
  };
}

function qs(params: object): string {
  const q: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null || v === '' || v === 'all') continue;
    q[k] = typeof v === 'boolean' ? (v ? 'true' : undefined) : v;
  }
  return buildQueryString(q);
}

// ============================================================
// Service
// ============================================================

export const fieldService = {
  // ---------------- Stats & lookups ----------------
  async getStats(): Promise<FsStats> {
    return unwrap<FsStats>(await apiClient.get(`${BASE}/stats`));
  },

  async getEngineers(search?: string): Promise<FsEngineer[]> {
    return unwrap<FsEngineer[]>(await apiClient.get(`${BASE}/engineers${qs({ search })}`)) || [];
  },

  // ---------------- Job types & phase templates ----------------
  async getJobTypes(opts: { includeInactive?: boolean; withPhases?: boolean } = {}): Promise<FsJobType[]> {
    const q = qs({ include_inactive: opts.includeInactive, with_phases: opts.withPhases });
    return unwrap<FsJobType[]>(await apiClient.get(`${BASE}/job-types${q}`)) || [];
  },

  async getJobType(uuid: string): Promise<FsJobType> {
    return unwrap<FsJobType>(await apiClient.get(`${BASE}/job-types/${uuid}`));
  },

  async createJobType(data: FsPayload): Promise<FsJobType> {
    return unwrap<FsJobType>(await apiClient.post(`${BASE}/job-types`, data, JSON_BODY));
  },

  async updateJobType(uuid: string, data: FsPayload): Promise<FsJobType> {
    return unwrap<FsJobType>(await apiClient.put(`${BASE}/job-types/${uuid}`, data, JSON_BODY));
  },

  async deleteJobType(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/job-types/${uuid}`);
  },

  async addPhaseTemplate(jobTypeUuid: string, data: FsPayload): Promise<FsPhaseTemplate> {
    return unwrap<FsPhaseTemplate>(await apiClient.post(`${BASE}/job-types/${jobTypeUuid}/phases`, data, JSON_BODY));
  },

  async reorderPhaseTemplates(jobTypeUuid: string, order: string[]): Promise<FsPhaseTemplate[]> {
    return unwrap<FsPhaseTemplate[]>(
      await apiClient.put(`${BASE}/job-types/${jobTypeUuid}/phases/reorder`, { order }, JSON_BODY)
    );
  },

  async updatePhaseTemplate(uuid: string, data: FsPayload): Promise<FsPhaseTemplate> {
    return unwrap<FsPhaseTemplate>(await apiClient.put(`${BASE}/phase-templates/${uuid}`, data, JSON_BODY));
  },

  async deletePhaseTemplate(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/phase-templates/${uuid}`);
  },

  // ---------------- Employees ----------------
  async getEmployees(params: FsEmployeeListParams = {}): Promise<FsPaginated<FsEmployee>> {
    // qs() drops boolean false, so stringify the flag filters — otherwise
    // "inactive only" (is_active=false) would send nothing and return all.
    const q: Record<string, unknown> = { ...params };
    if (typeof params.is_engineer === 'boolean') q.is_engineer = String(params.is_engineer);
    if (typeof params.is_active === 'boolean') q.is_active = String(params.is_active);
    return paginated<FsEmployee>(await apiClient.get(`${BASE}/employees${qs(q)}`));
  },

  async getEmployee(uuid: string): Promise<FsEmployee> {
    return unwrap<FsEmployee>(await apiClient.get(`${BASE}/employees/${uuid}`));
  },

  async createEmployee(data: FsPayload): Promise<FsEmployee> {
    return unwrap<FsEmployee>(await apiClient.post(`${BASE}/employees`, data, JSON_BODY));
  },

  async updateEmployee(uuid: string, data: FsPayload): Promise<FsEmployee> {
    return unwrap<FsEmployee>(await apiClient.put(`${BASE}/employees/${uuid}`, data, JSON_BODY));
  },

  async deleteEmployee(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/employees/${uuid}`);
  },

  // ---------------- Service requests (complaints) ----------------
  async getRequests(params: FsRequestListParams = {}): Promise<FsPaginated<FsServiceRequest>> {
    return paginated<FsServiceRequest>(await apiClient.get(`${BASE}/service-requests${qs(params)}`));
  },

  async getRequest(uuid: string): Promise<FsServiceRequestDetail> {
    return unwrap<FsServiceRequestDetail>(await apiClient.get(`${BASE}/service-requests/${uuid}`));
  },

  async createRequest(data: FsPayload): Promise<FsServiceRequestDetail> {
    return unwrap<FsServiceRequestDetail>(await apiClient.post(`${BASE}/service-requests`, data, JSON_BODY));
  },

  async updateRequest(uuid: string, data: FsPayload): Promise<FsServiceRequestDetail> {
    return unwrap<FsServiceRequestDetail>(await apiClient.put(`${BASE}/service-requests/${uuid}`, data, JSON_BODY));
  },

  async setRequestStatus(
    uuid: string,
    status: RequestStatus,
    opts: { resolution_notes?: string } = {}
  ): Promise<FsServiceRequestDetail> {
    return unwrap<FsServiceRequestDetail>(
      await apiClient.post(`${BASE}/service-requests/${uuid}/status`, { status, ...opts }, JSON_BODY)
    );
  },

  async assignRequest(uuid: string, managerUuid: string): Promise<FsServiceRequestDetail> {
    return unwrap<FsServiceRequestDetail>(
      await apiClient.post(`${BASE}/service-requests/${uuid}/assign`, { manager_uuid: managerUuid }, JSON_BODY)
    );
  },

  async convertRequestToJob(uuid: string, data: FsPayload = {}): Promise<FsConvertResult> {
    return unwrap<FsConvertResult>(
      await apiClient.post(`${BASE}/service-requests/${uuid}/convert-to-job`, data, JSON_BODY)
    );
  },

  async deleteRequest(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/service-requests/${uuid}`);
  },

  // ---------------- Parts catalog ----------------
  async getParts(params: FsPartListParams = {}): Promise<FsPaginated<FsPart>> {
    // qs() drops boolean false, so stringify the flags.
    const q: Record<string, unknown> = { ...params };
    if (typeof params.is_active === 'boolean') q.is_active = String(params.is_active);
    if (typeof params.include_inactive === 'boolean') q.include_inactive = String(params.include_inactive);
    return paginated<FsPart>(await apiClient.get(`${BASE}/parts${qs(q)}`));
  },

  async getPart(uuid: string): Promise<FsPart> {
    return unwrap<FsPart>(await apiClient.get(`${BASE}/parts/${uuid}`));
  },

  async createPart(data: FsPayload): Promise<FsPart> {
    return unwrap<FsPart>(await apiClient.post(`${BASE}/parts`, data, JSON_BODY));
  },

  async updatePart(uuid: string, data: FsPayload): Promise<FsPart> {
    return unwrap<FsPart>(await apiClient.put(`${BASE}/parts/${uuid}`, data, JSON_BODY));
  },

  async deletePart(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/parts/${uuid}`);
  },

  // ---------------- Jobs ----------------
  async getJobs(params: FsJobListParams = {}): Promise<FsPaginated<FsJob>> {
    return paginated<FsJob>(await apiClient.get(`${BASE}/jobs${qs(params)}`));
  },

  async getJob(uuid: string): Promise<FsJobDetail> {
    return unwrap<FsJobDetail>(await apiClient.get(`${BASE}/jobs/${uuid}`));
  },

  async createJob(data: FsPayload): Promise<FsJobDetail> {
    return unwrap<FsJobDetail>(await apiClient.post(`${BASE}/jobs`, data, JSON_BODY));
  },

  async updateJob(uuid: string, data: FsPayload): Promise<FsJobDetail> {
    return unwrap<FsJobDetail>(await apiClient.put(`${BASE}/jobs/${uuid}`, data, JSON_BODY));
  },

  async deleteJob(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/jobs/${uuid}`);
  },

  async setJobStatus(
    uuid: string,
    status: JobStatus,
    opts: { reason?: string; force?: boolean } = {}
  ): Promise<FsJobDetail> {
    return unwrap<FsJobDetail>(
      await apiClient.post(`${BASE}/jobs/${uuid}/status`, { status, ...opts }, JSON_BODY)
    );
  },

  // ---------------- Phases ----------------
  async addPhase(jobUuid: string, data: FsPayload): Promise<FsPhase> {
    return unwrap<FsPhase>(await apiClient.post(`${BASE}/jobs/${jobUuid}/phases`, data, JSON_BODY));
  },

  async reorderPhases(jobUuid: string, order: string[]): Promise<FsPhase[]> {
    return unwrap<FsPhase[]>(await apiClient.put(`${BASE}/jobs/${jobUuid}/phases/reorder`, { order }, JSON_BODY));
  },

  async updatePhase(uuid: string, data: FsPayload): Promise<FsPhase> {
    return unwrap<FsPhase>(await apiClient.put(`${BASE}/job-phases/${uuid}`, data, JSON_BODY));
  },

  async deletePhase(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/job-phases/${uuid}`);
  },

  async setPhaseStatus(
    uuid: string,
    status: PhaseStatus,
    opts: { signoff_name?: string; force?: boolean; notes?: string } = {}
  ): Promise<FsPhase> {
    return unwrap<FsPhase>(await apiClient.post(`${BASE}/job-phases/${uuid}/status`, { status, ...opts }, JSON_BODY));
  },

  async setChecklistItem(phaseUuid: string, index: number, done: boolean): Promise<FsPhase> {
    return unwrap<FsPhase>(
      await apiClient.post(`${BASE}/job-phases/${phaseUuid}/checklist/${index}`, { done }, JSON_BODY)
    );
  },

  // ---------------- Items ----------------
  async addItem(jobUuid: string, data: FsPayload): Promise<FsJobItem> {
    return unwrap<FsJobItem>(await apiClient.post(`${BASE}/jobs/${jobUuid}/items`, data, JSON_BODY));
  },

  async updateItem(uuid: string, data: FsPayload): Promise<FsJobItem> {
    return unwrap<FsJobItem>(await apiClient.put(`${BASE}/job-items/${uuid}`, data, JSON_BODY));
  },

  async deleteItem(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/job-items/${uuid}`);
  },

  async approveItem(uuid: string): Promise<FsJobItem> {
    return unwrap<FsJobItem>(await apiClient.post(`${BASE}/job-items/${uuid}/approve`, {}, JSON_BODY));
  },

  async rejectItem(uuid: string, reason?: string): Promise<FsJobItem> {
    return unwrap<FsJobItem>(await apiClient.post(`${BASE}/job-items/${uuid}/reject`, { reason }, JSON_BODY));
  },

  // ---------------- Invoicing ----------------
  async getInvoicePreview(
    jobUuid: string,
    opts: { hourly_rate?: number; labour_tax_rate?: number } = {}
  ): Promise<FsInvoicePreview> {
    return unwrap<FsInvoicePreview>(await apiClient.get(`${BASE}/jobs/${jobUuid}/invoice-preview${qs(opts)}`));
  },

  async createInvoice(
    jobUuid: string,
    opts: { hourly_rate?: number; labour_tax_rate?: number; due_date?: string; notes?: string } = {}
  ): Promise<FsInvoiceResult> {
    return unwrap<FsInvoiceResult>(await apiClient.post(`${BASE}/jobs/${jobUuid}/invoice`, opts, JSON_BODY));
  },

  // ---------------- Visits ----------------
  async getVisits(params: FsVisitListParams = {}): Promise<FsPaginated<FsVisit>> {
    return paginated<FsVisit>(await apiClient.get(`${BASE}/visits${qs(params)}`));
  },

  async getVisit(uuid: string): Promise<FsVisitDetail> {
    return unwrap<FsVisitDetail>(await apiClient.get(`${BASE}/visits/${uuid}`));
  },

  async createVisit(jobUuid: string, data: FsPayload): Promise<FsVisitMutation> {
    return unwrap<FsVisitMutation>(await apiClient.post(`${BASE}/jobs/${jobUuid}/visits`, data, JSON_BODY));
  },

  async updateVisit(uuid: string, data: FsPayload): Promise<FsVisitMutation> {
    return unwrap<FsVisitMutation>(await apiClient.put(`${BASE}/visits/${uuid}`, data, JSON_BODY));
  },

  async deleteVisit(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/visits/${uuid}`);
  },

  async markEnRoute(uuid: string): Promise<FsVisitDetail> {
    return unwrap<FsVisitDetail>(await apiClient.post(`${BASE}/visits/${uuid}/en-route`, {}, JSON_BODY));
  },

  async checkIn(uuid: string, coords?: { latitude: number; longitude: number }): Promise<FsVisitDetail> {
    return unwrap<FsVisitDetail>(await apiClient.post(`${BASE}/visits/${uuid}/check-in`, coords ?? {}, JSON_BODY));
  },

  async checkOut(uuid: string, data: FsPayload): Promise<FsCheckOutResult> {
    return unwrap<FsCheckOutResult>(await apiClient.post(`${BASE}/visits/${uuid}/check-out`, data, JSON_BODY));
  },

  async markNoAccess(uuid: string, reason: string): Promise<FsVisitDetail> {
    return unwrap<FsVisitDetail>(await apiClient.post(`${BASE}/visits/${uuid}/no-access`, { reason }, JSON_BODY));
  },

  async cancelVisit(uuid: string, reason?: string): Promise<FsVisitDetail> {
    return unwrap<FsVisitDetail>(await apiClient.post(`${BASE}/visits/${uuid}/cancel`, { reason }, JSON_BODY));
  },

  async logTimesheet(uuid: string): Promise<{ timesheet_uuid: string; hours: number }> {
    return unwrap(await apiClient.post(`${BASE}/visits/${uuid}/log-timesheet`, {}, JSON_BODY));
  },
};

export default fieldService;
