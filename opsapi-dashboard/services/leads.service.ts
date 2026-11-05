/**
 * Lead pipeline API (lapis/routes/crm-leads.lua, lapis/routes/crm-partners.lua).
 * docs/plans/LEAD_TO_CASH_PIPELINE.md
 *
 * Every write sends JSON. Errors keep the server's plain message, code and
 * per-field messages so forms can show them next to the field (leadError()).
 */
import apiClient from '@/lib/api-client';

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;

export type LeadStage = 'new' | 'contacting' | 'qualified' | 'meeting' | 'converted' | 'nurture' | 'lost';
export const OPEN_STAGES: LeadStage[] = ['new', 'contacting', 'qualified', 'meeting'];
export const ALL_STAGES: LeadStage[] = ['new', 'contacting', 'qualified', 'meeting', 'converted', 'nurture', 'lost'];

export type CallOutcome = 'connected' | 'no_answer' | 'voicemail' | 'wrong_number' | 'callback' | 'not_interested';
export type NextAction =
  | 'call_now' | 'call' | 'email' | 'book_meeting' | 'qualify' | 'send_quote' | 'refer_to_partner' | 'nurture' | 'disqualify';

export interface LeadResearch {
  low?: number | null;
  high?: number | null;
  typical?: number | null;
  currency?: string;
  unit_or_total?: 'total' | 'per_unit';
  notes?: string | null;
  basis?: string;
  sources?: { url: string; title: string }[];
  searches?: string[];
  suggestions?: string | null;
  hidden?: boolean;
  message?: string;
}

export interface LeadAnalysisResult {
  summary: string | null;
  wants: string | null;
  intent: string;
  urgency: 'low' | 'medium' | 'high';
  deadline: string | null;
  estimated_value: number | null;
  value_low: number | null;
  value_high: number | null;
  value_basis: string | null;
  value_source?: 'web_search' | 'ai_knowledge';
  score: number | null;
  score_reasons: string[];
  flags: { spam: boolean; vulnerable: boolean; existing_customer: boolean; out_of_scope: boolean };
  next_best_action: { action: NextAction; label: string; reason: string | null; when: string };
  partner_suggestions: { partner_uuid: string; partner_name: string; fit: number | null; reason: string | null }[];
  questions: string[];
  first_reply: { channel: 'email' | 'whatsapp' | 'phone'; subject: string | null; body: string | null };
  research?: LeadResearch;
  research_skipped?: string;
}

export interface LeadAnalysis {
  uuid: string;
  status: 'pending' | 'running' | 'done' | 'failed' | 'skipped';
  trigger: string;
  result: LeadAnalysisResult | null;
  error: string | null;
  provider_name: string | null;
  model: string | null;
  finished_at: string | null;
  created_at: string;
}

export interface Meeting {
  uuid: string;
  subject: string;
  description: string | null;
  status: 'planned' | 'completed' | 'cancelled';
  outcome: string | null;
  starts_at: string;
  ends_at: string;
  duration_minutes: number;
  location: string | null;
  meeting_url: string | null;
  attendees: { email: string; name?: string | null; role: 'lead' | 'staff' | 'guest' }[];
  type: 'video' | 'phone' | 'in_person' | 'viewing';
  type_label: string;
  ics_sequence: number;
  invite: { enabled: boolean; sent_sequence: number | null; up_to_date: boolean; error: string | null };
  lead_uuid: string;
}

export type ReferralStatus =
  | 'draft' | 'sent' | 'accepted' | 'declined' | 'won' | 'lost' | 'commission_invoiced' | 'commission_paid' | 'cancelled';

export interface Referral {
  uuid: string;
  status: ReferralStatus;
  status_label: string;
  deal_value: number | null;
  currency: string | null;
  commission_type: 'percent' | 'fixed';
  commission_value: number;
  commission_amount: number | null;
  message: string | null;
  consent_confirmed: boolean;
  partner_reference: string | null;
  partner_notes: string | null;
  ai_reason: string | null;
  sent_at: string | null;
  responded_at: string | null;
  won_at: string | null;
  created_at: string;
  partner_name: string;
  partner_uuid: string;
  referral_email: string | null;
  deal_uuid: string | null;
  deal_name: string | null;
  lead_uuid: string | null;
  invoice_uuid: string | null;
  invoice_number: string | null;
  invoice_status: string | null;
}

export interface Lead {
  id?: number;
  uuid: string;
  first_name: string;
  last_name: string | null;
  email: string | null;
  phone: string | null;
  company_name: string | null;
  job_title: string | null;
  source: string | null;
  channel: string | null;
  campaign: string | null;
  notes: string | null;
  priority: string | null;
  status: LeadStage;
  stage: LeadStage;
  stage_label: string;
  is_open: boolean;
  owner_user_uuid: string | null;
  owner_name: string | null;
  owner_email: string | null;
  assigned_at: string | null;
  stage_changed_at: string | null;
  next_action_type: string | null;
  next_action_at: string | null;
  next_action_note: string | null;
  first_contacted_at: string | null;
  last_contacted_at: string | null;
  contact_attempts: number;
  estimated_value: number | string | null;
  currency: string | null;
  expected_close_date: string | null;
  nurture_until: string | null;
  lost_reason: string | null;
  qualification: Record<string, string>;
  ai_status: string | null;
  ai_score: number | null;
  ai_summary: string | null;
  ai_analysed_at: string | null;
  metadata: Record<string, unknown>;
  created_at: string;
  updated_at: string;
  converted_at: string | null;
  converted_deal_uuid?: string | null;
  converted_deal_name?: string | null;
  converted_deal_value?: number | string | null;
  converted_contact_uuid?: string | null;
  analysis?: LeadAnalysis | null;
  meetings?: Meeting[];
  referrals?: Referral[];
  permissions?: { can_work: boolean; is_manager: boolean; can_assign_any: boolean; can_convert: boolean };
  call_outcomes?: Record<CallOutcome, string>;
}

export interface BoardCard {
  uuid: string;
  first_name: string;
  last_name: string | null;
  email: string | null;
  phone: string | null;
  company_name: string | null;
  source: string | null;
  status: LeadStage;
  owner_user_uuid: string | null;
  owner_name: string | null;
  estimated_value: number | string | null;
  currency: string | null;
  ai_score: number | null;
  ai_summary: string | null;
  ai_status: string | null;
  next_action_type: string | null;
  next_action_at: string | null;
  stage_changed_at: string | null;
  created_at: string;
  contact_attempts: number;
  priority: string | null;
}

export interface BoardColumn {
  key: LeadStage;
  label: string;
  count: number;
  value: number;
  overdue: number;
  open: boolean;
  leads: BoardCard[];
}

/** Totals over every lead you can see (GET /leads/stats). */
export interface LeadStats {
  new_leads: number | string;
  contacting_leads: number | string;
  qualified_leads: number | string;
  meeting_leads: number | string;
  overdue_leads: number | string;
  open_value: number | string;
  currency: string;
}

export interface Board {
  stages: BoardColumn[];
  currency: string;
  recent_days: number;
}

export interface Funnel {
  from: string;
  to: string;
  total: number;
  steps: { key: LeadStage; label: string; reached: number; pct_of_total: number; pct_of_previous: number | null;
    median_minutes_from_created: number | null }[];
  open: number;
  lost: number;
  nurture: number;
  speed_to_lead: { median_minutes: number | null; target_minutes: number; within_target_pct: number | null; contacted: number };
  by_source: { source: string; leads: number; converted: number; lost: number }[];
  lost_reasons: { reason: string; leads: number }[];
  money: { open_value: number; deal_value: number; won_value: number };
  currency: string;
}

export interface StepItem {
  uuid: string;
  first_name: string;
  last_name: string | null;
  company_name: string | null;
  status: LeadStage;
  next_action_type: string | null;
  next_action_at: string;
  next_action_note: string | null;
  ai_score: number | null;
  phone: string | null;
  email: string | null;
}

export interface MySteps {
  overdue: StepItem[];
  today: StepItem[];
  meetings: { uuid: string; subject: string; starts_at: string; ends_at: string; location: string | null;
    meeting_url: string | null; lead_uuid: string; first_name: string; last_name: string | null; company_name: string | null }[];
  unassigned: number;
  is_manager: boolean;
}

export interface TimelineItem {
  kind: 'created' | 'stage' | 'activity' | 'analysis' | 'referral' | 'converted';
  at: string;
  title: string;
  detail?: string | null;
  by?: string | null;
  type?: string;
  status?: string;
  outcome?: string | null;
  outcome_label?: string | null;
  activity_uuid?: string;
  due_at?: string;
  from?: string;
  to?: string;
  meeting_url?: string | null;
  location?: string | null;
}

export interface TeamMember {
  uuid: string;
  name: string;
  email: string;
  is_manager: boolean;
}

export interface LeadSettings {
  first_response_minutes: number;
  working_hours: { timezone: string; start: string; end: string; days: number[] };
  attempt_plan_hours: number[];
  escalate_after_minutes: number;
  auto_assign: boolean;
  round_robin_user_uuids: string[];
  manager_user_uuids: string[];
  ai_enabled: boolean;
  ai_provider_uuid: string | null;
  ai_daily_cost_usd: number;
  ai_hot_score: number;
  currency: string;
  qualification_questions: { key: string; label: string }[];
  lost_reasons: string[];
  stage_labels: Partial<Record<LeadStage, string>> | [];
  public_captcha: boolean;
  meeting: { default_minutes: number; default_link: string; send_invites: boolean; lead_reminder_hours: number;
    staff_reminder_minutes: number };
}

export interface SettingsBundle {
  settings: LeadSettings;
  stage_labels: Record<LeadStage, string>;
  stages: LeadStage[];
  call_outcomes: Record<CallOutcome, string>;
  meeting_types: Record<string, string>;
  ai_providers: { uuid: string; name: string; provider_type: string; is_local: boolean; enabled: boolean }[];
  web_research: boolean;
  can_edit: boolean;
}

export interface AssignmentRule {
  uuid: string;
  name: string;
  position: number;
  conditions: { sources?: string[]; channels?: string[]; campaigns?: string[]; keywords?: string[] };
  assignee_user_uuid: string | null;
  pool: string[];
  enabled: boolean;
}

export interface Partner {
  uuid: string;
  account_uuid: string;
  name: string;
  website: string | null;
  categories: string[];
  offering: string | null;
  regions: string[];
  referral_email: string | null;
  referral_contact_name: string | null;
  commission_type: 'percent' | 'fixed';
  commission_value: number | string;
  currency: string | null;
  terms: string | null;
  active: boolean;
  referrals: number;
  won: number;
  commission_paid: number;
  referral_list?: Referral[];
}

export interface ConvertResult {
  lead_uuid: string;
  contact_uuid: string;
  account_uuid: string | null;
  deal_uuid: string;
  deal_name: string;
  deal_value: number;
  currency: string;
  stage: string;
  lead: Lead;
}

/** A failed request: the server's words, code and field messages. */
export class LeadApiError extends Error {
  status: number;
  code?: string;
  fields?: Record<string, string>;
  constructor(message: string, status: number, code?: string, fields?: Record<string, string>) {
    super(message);
    this.status = status;
    this.code = code;
    this.fields = fields;
  }
}

export function leadError(e: unknown): LeadApiError {
  if (e instanceof LeadApiError) return e;
  const err = e as { response?: { status?: number; data?: Record<string, unknown> }; message?: string };
  const data = err?.response?.data ?? {};
  const raw = data.error;
  const message =
    (typeof raw === 'string' && raw) ||
    (raw && typeof raw === 'object' && typeof (raw as { message?: unknown }).message === 'string'
      ? (raw as { message: string }).message
      : '') ||
    (err?.response ? 'Something went wrong. Please try again.' : "Can't reach the server. Check your connection.");
  return new LeadApiError(message, err?.response?.status ?? 0, data.code as string | undefined,
    data.fields as Record<string, string> | undefined);
}

async function call<T>(p: Promise<{ data: { data?: T; meta?: unknown } }>): Promise<T> {
  try {
    const res = await p;
    return res.data.data as T;
  } catch (e) {
    throw leadError(e);
  }
}

const L = '/api/v2/crm/leads';

export interface LeadListQuery {
  stage?: string;
  owner?: 'me' | 'unassigned' | string;
  due?: 'overdue' | 'today';
  hot?: boolean;
  source?: string;
  search?: string;
  sort?: 'next_action' | 'newest' | 'oldest' | 'score' | 'value' | 'stage_changed';
  page?: number;
  per_page?: number;
}

function qs(params: Record<string, unknown>): string {
  const s = new URLSearchParams();
  Object.entries(params).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== '' && v !== false) s.set(k, String(v));
  });
  const out = s.toString();
  return out ? `?${out}` : '';
}

export const leadsService = {
  async list(q: LeadListQuery = {}): Promise<{ items: Lead[]; total: number; page: number; total_pages: number }> {
    try {
      const res = await apiClient.get(`${L}${qs(q as Record<string, unknown>)}`);
      const meta = res.data?.meta ?? {};
      return { items: res.data?.data ?? [], total: meta.total ?? 0, page: meta.page ?? 1, total_pages: meta.total_pages ?? 1 };
    } catch (e) {
      throw leadError(e);
    }
  },
  board: (q: { owner?: 'me'; recent_days?: number; per_stage?: number } = {}) =>
    call<Board>(apiClient.get(`${L}/board${qs(q)}`)),
  funnel: (from?: string, to?: string) => call<Funnel>(apiClient.get(`${L}/funnel${qs({ from, to })}`)),
  mySteps: () => call<MySteps>(apiClient.get(`${L}/my-steps`)),
  stats: () => call<LeadStats>(apiClient.get(`${L}/stats`)),
  team: () => call<TeamMember[]>(apiClient.get(`${L}/team`)),
  get: (uuid: string) => call<Lead>(apiClient.get(`${L}/${uuid}`)),
  timeline: (uuid: string) => call<TimelineItem[]>(apiClient.get(`${L}/${uuid}/timeline`)),
  create: (body: Record<string, unknown>) => call<Lead>(apiClient.post(L, body, JSON_BODY)),
  update: (uuid: string, body: Record<string, unknown>) => call<Lead>(apiClient.put(`${L}/${uuid}`, body, JSON_BODY)),
  remove: (uuid: string) => call<unknown>(apiClient.delete(`${L}/${uuid}`)),
  move: (uuid: string, stage: LeadStage, extra: { reason?: string; nurture_until?: string } = {}) =>
    call<Lead>(apiClient.post(`${L}/${uuid}/stage`, { stage, ...extra }, JSON_BODY)),
  assign: (uuid: string, owner_user_uuid: string | null) =>
    call<Lead>(apiClient.post(`${L}/${uuid}/assign`, { owner_user_uuid }, JSON_BODY)),
  logCall: (uuid: string, body: { outcome: CallOutcome; notes?: string; duration_minutes?: number; next_at?: string;
    lost_reason?: string }) =>
    call<{ lead: Lead; next_step: unknown; suggestion?: { action: string; message: string } }>(
      apiClient.post(`${L}/${uuid}/calls`, body, JSON_BODY)),
  planStep: (uuid: string, body: { type: string; due_at: string; note?: string; subject?: string }) =>
    call<Lead>(apiClient.post(`${L}/${uuid}/steps`, body, JSON_BODY)),
  finishStep: (uuid: string, activityUuid: string, status: 'completed' | 'cancelled', note?: string) =>
    call<Lead>(apiClient.post(`${L}/${uuid}/steps/${activityUuid}`, { status, note }, JSON_BODY)),
  qualify: (uuid: string, body: { answers?: Record<string, string | null>; estimated_value?: number | null;
    currency?: string; expected_close_date?: string | null; move?: boolean }) =>
    call<Lead>(apiClient.post(`${L}/${uuid}/qualify`, body, JSON_BODY)),
  analyse: (uuid: string) => call<{ queued: boolean; message: string }>(apiClient.post(`${L}/${uuid}/analyse`, {}, JSON_BODY)),
  convert: (uuid: string, body: { name?: string; value?: number; currency?: string; expected_close_date?: string }) =>
    call<ConvertResult>(apiClient.post(`${L}/${uuid}/convert`, body, JSON_BODY)),
  bookMeeting: (uuid: string, body: Record<string, unknown>) =>
    call<Meeting>(apiClient.post(`${L}/${uuid}/meetings`, body, JSON_BODY)),
  updateMeeting: (meetingUuid: string, body: Record<string, unknown>) =>
    call<Meeting>(apiClient.put(`/api/v2/crm/meetings/${meetingUuid}`, body, JSON_BODY)),
  cancelMeeting: (meetingUuid: string, reason?: string) =>
    call<Meeting>(apiClient.post(`/api/v2/crm/meetings/${meetingUuid}/cancel`, { reason }, JSON_BODY)),
  meetingOutcome: (meetingUuid: string, outcome: 'held' | 'no_show', notes?: string) =>
    call<Meeting>(apiClient.post(`/api/v2/crm/meetings/${meetingUuid}/outcome`, { outcome, notes }, JSON_BODY)),
  settings: () => call<SettingsBundle>(apiClient.get(`${L}/settings`)),
  saveSettings: (patch: Partial<LeadSettings>) => call<LeadSettings>(apiClient.put(`${L}/settings`, patch, JSON_BODY)),
  rules: () => call<AssignmentRule[]>(apiClient.get(`${L}/assignment-rules`)),
  createRule: (body: Partial<AssignmentRule>) => call<{ uuid: string }>(apiClient.post(`${L}/assignment-rules`, body, JSON_BODY)),
  updateRule: (uuid: string, body: Partial<AssignmentRule>) =>
    call<{ uuid: string }>(apiClient.put(`${L}/assignment-rules/${uuid}`, body, JSON_BODY)),
  deleteRule: (uuid: string) => call<unknown>(apiClient.delete(`${L}/assignment-rules/${uuid}`)),

  // Partners and referrals
  partners: (q: { search?: string; active?: 'all' } = {}) => call<Partner[]>(apiClient.get(`/api/v2/crm/partners${qs(q)}`)),
  partner: (uuid: string) => call<Partner>(apiClient.get(`/api/v2/crm/partners/${uuid}`)),
  savePartner: (body: Record<string, unknown>, uuid?: string) =>
    call<Partner>(uuid ? apiClient.put(`/api/v2/crm/partners/${uuid}`, body, JSON_BODY)
      : apiClient.post('/api/v2/crm/partners', body, JSON_BODY)),
  referrals: (q: { status?: string; partner_uuid?: string } = {}) =>
    call<Referral[]>(apiClient.get(`/api/v2/crm/referrals${qs(q)}`)),
  refer: (body: { lead_uuid?: string; deal_uuid?: string; partner_uuid: string; deal_value?: number;
    commission_type?: 'percent' | 'fixed'; commission_value?: number; message?: string; share_contact?: boolean;
    consent_confirmed?: boolean; ai_reason?: string; send?: boolean }) =>
    call<Referral>(apiClient.post('/api/v2/crm/referrals', body, JSON_BODY)),
  moveReferral: (uuid: string, body: { status: ReferralStatus; deal_value?: number; partner_reference?: string; notes?: string }) =>
    call<Referral>(apiClient.post(`/api/v2/crm/referrals/${uuid}/status`, body, JSON_BODY)),
  resendReferral: (uuid: string) => call<Referral>(apiClient.post(`/api/v2/crm/referrals/${uuid}/send`, {}, JSON_BODY)),
  invoiceReferral: (uuid: string, body: { tax_rate?: number; payment_terms_days?: number } = {}) =>
    call<{ referral: Referral; invoice_uuid: string }>(apiClient.post(`/api/v2/crm/referrals/${uuid}/invoice`, body, JSON_BODY)),
};
