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
  account_uuid?: string | null;
  account_name?: string | null;
  account_email?: string | null;
  account_phone?: string | null;
  contact_uuid?: string | null;
  contact_name?: string | null;
  contact_email?: string | null;
  contact_phone?: string | null;
  site_uuid?: string | null;
  site_name?: string | null;
  site_address_line1?: string | null;
  site_address_line2?: string | null;
  site_city?: string | null;
  site_county?: string | null;
  site_postal_code?: string | null;
  site_country?: string | null;
  site_access_notes?: string | null;
  site_contact_name?: string | null;
  site_contact_phone?: string | null;
  site_latitude?: number | null;
  site_longitude?: number | null;
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
  account_uuid?: string | null;
  account_name?: string | null;
  site_uuid?: string | null;
  site_name?: string | null;
  site_address_line1?: string | null;
  site_address_line2?: string | null;
  site_city?: string | null;
  site_postal_code?: string | null;
  site_latitude?: number | null;
  site_longitude?: number | null;
  site_access_notes?: string | null;
  site_contact_name?: string | null;
  site_contact_phone?: string | null;
}

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

export interface FsSite {
  uuid: string;
  name: string;
  account_uuid?: string | null;
  account_name?: string | null;
  address_line1?: string | null;
  address_line2?: string | null;
  city?: string | null;
  county?: string | null;
  postal_code?: string | null;
  country?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  contact_name?: string | null;
  contact_phone?: string | null;
  contact_email?: string | null;
  access_notes?: string | null;
  job_count: number;
  created_at: string;
  updated_at: string;
}

export interface FsEngineer {
  uuid: string;
  email: string;
  name: string;
  open_visits: number;
}

export interface FsAccountLookup {
  uuid: string;
  name: string;
  email?: string | null;
  phone?: string | null;
  address_line1?: string | null;
  city?: string | null;
  postal_code?: string | null;
}

export interface FsContactLookup {
  uuid: string;
  first_name: string;
  last_name?: string | null;
  email?: string | null;
  phone?: string | null;
  account_uuid?: string | null;
  account_name?: string | null;
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
  account_uuid?: string;
  site_uuid?: string;
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

export interface FsSiteListParams {
  account_uuid?: string;
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

  async lookupAccounts(search?: string): Promise<FsAccountLookup[]> {
    return unwrap<FsAccountLookup[]>(await apiClient.get(`${BASE}/lookups/accounts${qs({ search })}`)) || [];
  },

  async lookupContacts(accountUuid?: string, search?: string): Promise<FsContactLookup[]> {
    return (
      unwrap<FsContactLookup[]>(
        await apiClient.get(`${BASE}/lookups/contacts${qs({ account_uuid: accountUuid, search })}`)
      ) || []
    );
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

  // ---------------- Sites ----------------
  async getSites(params: FsSiteListParams = {}): Promise<FsPaginated<FsSite>> {
    return paginated<FsSite>(await apiClient.get(`${BASE}/sites${qs(params)}`));
  },

  async getSite(uuid: string): Promise<FsSite> {
    return unwrap<FsSite>(await apiClient.get(`${BASE}/sites/${uuid}`));
  },

  async createSite(data: FsPayload): Promise<FsSite> {
    return unwrap<FsSite>(await apiClient.post(`${BASE}/sites`, data, JSON_BODY));
  },

  async updateSite(uuid: string, data: FsPayload): Promise<FsSite> {
    return unwrap<FsSite>(await apiClient.put(`${BASE}/sites/${uuid}`, data, JSON_BODY));
  },

  async deleteSite(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/sites/${uuid}`);
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
