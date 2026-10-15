import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Hiring (ATS + AI first-round interviews) — recruiter API client
 * (lapis/routes/ats.lua, docs/plans/PROMPT_ATS_INTERVIEWS.md).
 *
 * Everything a candidate wrote is untrusted: render it as text (React does),
 * never as HTML.
 */

export type Stage = 'applied' | 'screening' | 'interview' | 'review' | 'offer' | 'hired' | 'rejected' | 'withdrawn';
export const STAGES: Stage[] = ['applied', 'screening', 'interview', 'review', 'offer', 'hired', 'rejected', 'withdrawn'];
export const STAGE_LABEL: Record<Stage, string> = {
  applied: 'Applied', screening: 'Screening', interview: 'AI interview', review: 'Review', offer: 'Offer', hired: 'Hired',
  rejected: 'Rejected', withdrawn: 'Withdrawn',
};

export type Decision = 'advance' | 'hold' | 'decline';

export interface Meta { total: number; page: number; per_page: number; total_pages: number }

export interface Job {
  uuid: string; title: string; department?: string; location?: string; employment_type?: string; description?: string;
  status: 'draft' | 'open' | 'paused' | 'closed'; kit_uuid?: string; created_at: string; candidates: number; to_review: number;
}

export interface Application {
  uuid: string; stage: Stage; stage_changed_at: string; decision_reason?: string; decided_by?: string; decided_at?: string;
  job?: { uuid: string; title: string }; candidate?: { uuid: string; name: string; email?: string };
  latest_interview?: { uuid: string; state: string; evaluation_status: string; reviewed: boolean };
}

export interface Candidate {
  uuid: string; name: string; email?: string; phone?: string; reference?: string; source?: string; tags: string[];
  created_at: string; applications?: number | Application[];
  interviews?: { uuid: string; state: string; source: string; evaluation_status: string; reviewed: boolean; decision?: string;
    job_title: string; application_uuid: string; ended_at?: string }[];
  notes?: { uuid: string; body: string; author_name?: string; created_at: string }[];
}

export interface Anchors { '1': string; '3': string; '5': string }
export interface Competency { id: string; name: string; description: string; weight: number; source: string; anchors: Anchors }
export interface EligibilityQuestion { id: string; text: string; kind: 'yes_no' | 'choice' | 'text'; options: string[]; accepted: string[] }
export interface CoreQuestion { id: string; text: string; competency: string; kind: 'behavioural' | 'situational' }
export interface KitSettings {
  interviewer_name: string; minutes: number; max_follow_ups: number; seconds_per_answer: number; allow_voice: boolean;
  allow_pause: boolean; allowed_adjustments: string[]; next_steps: string; ratings_enabled: boolean;
  written_communication: boolean; retention_days: number;
}
export interface RoleKit {
  id?: string; format: number; version: number; title: string; organisation: string; summary: string; language: string;
  job_description: string; competencies: Competency[]; eligibility: EligibilityQuestion[]; questions: CoreQuestion[];
  company_facts: string; settings: KitSettings; warnings: string[]; approved_at?: string; approved_by?: string;
}
export interface KitIssue { severity: 'error' | 'warning'; message: string; subject?: string }
export interface KitSummary {
  uuid: string; title: string; version: number; approved_at?: string; approved_by?: string; source: string;
  job_uuid?: string; competencies: number; questions: number; updated_at: string; kit?: RoleKit; issues?: KitIssue[];
  model?: string;
}

export interface Turn { id: string; role: 'interviewer' | 'candidate' | 'system'; text: string; kind: string; question_id?: string; at?: string; input?: string }
export interface Flag { kind: string; detail: string; turn?: string; at?: string }
export interface Quote { turn: string; quote: string }
export interface CompetencyResult {
  id: string; evidence: Quote[]; level?: number; second_level?: number; agreed: boolean; reason: string; probe_next: string;
}
export interface Evaluation {
  competencies: CompetencyResult[]; injection: Quote[]; notes_for_reviewer: string; dropped_quotes: number; model: string;
  prompt_version: string; at?: string; source?: string;
}
export interface Review {
  reviewer: string; decision?: Decision; reason: string; note: string; levels: Record<string, number>; at: string; via?: string;
}
export interface InterviewSummary {
  uuid: string; state: string; source: string; evaluation_status: string; started_at?: string; ended_at?: string;
  created_at: string; decision?: Decision; reviewed: boolean; flag_count: number; candidate_uuid: string;
  candidate_name: string; job_uuid: string; job_title: string; application_uuid: string;
}
export interface InterviewDetail extends InterviewSummary {
  kit: RoleKit; kit_version: number; turns: Turn[]; flags: Flag[];
  eligibility: { id: string; text: string; answer?: string; meets?: boolean | null }[];
  adjustments: string[]; forwarded_questions: string[]; models: Record<string, string>; end_reason?: string;
  evaluation?: Evaluation; review?: Review; low_agreement: string[]; settings: AtsSettings; dashboard_url: string;
}

export interface Activation {
  active: boolean; status: string; source?: string; activated_at?: string; expires_at?: string; payment_failed_at?: string;
  checkout_available: boolean;
}
export interface AtsSettings {
  retention_days: number; ratings_enabled: boolean; decline_reasons: string[]; legal_notice: string; activation?: Activation;
}
export interface IntegrationToken {
  uuid: string; name: string; token_prefix: string; created_at: string; last_used_at?: string; revoked_at?: string; token?: string;
}
export interface FairnessReport {
  question: string; rows: { group: string; total: number; selected: number; rate: number; impact_ratio: number; warning: boolean }[];
  suppressed: number; min_group: number; questions: { id: string; label: string; options: string[] }[];
}
export interface Overview {
  open_jobs: number; candidates: number; to_review: number; in_progress: number; stages: Partial<Record<Stage, number>>;
  activation: Activation;
}
export interface ImportResult {
  interview_uuid: string; application_uuid: string; candidate_uuid: string; job_uuid: string; created: boolean; dashboard_url: string;
}

const BASE = '/api/v2/ats';
const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;

function unwrap<T>(response: { data: unknown }): T {
  return (response.data as { data: T }).data;
}
function paged<T>(response: { data: unknown }): { items: T[]; meta?: Meta } {
  const body = response.data as { data: T[]; meta?: Meta };
  return { items: body.data ?? [], meta: body.meta };
}

export const atsService = {
  overview: async () => unwrap<Overview>(await apiClient.get(`${BASE}/overview`)),

  jobs: async (params: { status?: string; q?: string; page?: number } = {}) =>
    paged<Job>(await apiClient.get(`${BASE}/jobs${buildQueryString(params)}`)),
  job: async (uuid: string) => unwrap<Job>(await apiClient.get(`${BASE}/jobs/${uuid}`)),
  createJob: async (input: Partial<Job>) => unwrap<Job>(await apiClient.post(`${BASE}/jobs`, input, JSON_BODY)),
  updateJob: async (uuid: string, input: Partial<Job>) => unwrap<Job>(await apiClient.put(`${BASE}/jobs/${uuid}`, input, JSON_BODY)),
  deleteJob: async (uuid: string) => unwrap<unknown>(await apiClient.delete(`${BASE}/jobs/${uuid}`)),
  pipeline: async (uuid: string) =>
    unwrap<{ stage: Stage; applications: Application[] }[]>(await apiClient.get(`${BASE}/jobs/${uuid}/pipeline`)),

  candidates: async (params: { q?: string; page?: number } = {}) =>
    paged<Candidate>(await apiClient.get(`${BASE}/candidates${buildQueryString(params)}`)),
  candidate: async (uuid: string) => unwrap<Candidate & { applications: Application[] }>(await apiClient.get(`${BASE}/candidates/${uuid}`)),
  createCandidate: async (input: { name: string; email?: string; phone?: string; reference?: string; job_uuid?: string }) =>
    unwrap<Candidate>(await apiClient.post(`${BASE}/candidates`, input, JSON_BODY)),
  updateCandidate: async (uuid: string, input: Partial<Candidate>) =>
    unwrap<Candidate>(await apiClient.put(`${BASE}/candidates/${uuid}`, input, JSON_BODY)),
  deleteCandidate: async (uuid: string) => unwrap<unknown>(await apiClient.delete(`${BASE}/candidates/${uuid}`)),
  exportCandidate: async (uuid: string) => unwrap<unknown>(await apiClient.get(`${BASE}/candidates/${uuid}/export`)),
  addNote: async (uuid: string, body: string, application_uuid?: string) =>
    unwrap<unknown>(await apiClient.post(`${BASE}/candidates/${uuid}/notes`, { body, application_uuid }, JSON_BODY)),

  addApplication: async (job_uuid: string, candidate_uuid: string) =>
    unwrap<Application>(await apiClient.post(`${BASE}/applications`, { job_uuid, candidate_uuid }, JSON_BODY)),
  moveStage: async (uuid: string, stage: Stage) =>
    unwrap<Application>(await apiClient.post(`${BASE}/applications/${uuid}/stage`, { stage }, JSON_BODY)),
  reject: async (uuid: string, reason: string) =>
    unwrap<Application>(await apiClient.post(`${BASE}/applications/${uuid}/reject`, { reason }, JSON_BODY)),

  kits: async (params: { approved?: boolean } = {}) =>
    unwrap<KitSummary[]>(await apiClient.get(`${BASE}/kits${buildQueryString({ approved: params.approved ? 'true' : undefined })}`)),
  kit: async (uuid: string) => unwrap<KitSummary>(await apiClient.get(`${BASE}/kits/${uuid}`)),
  createKit: async (input: { title: string; job_uuid?: string; kit?: Partial<RoleKit> }) =>
    unwrap<KitSummary>(await apiClient.post(`${BASE}/kits`, input, JSON_BODY)),
  generateKit: async (job_description: string, job_uuid?: string) =>
    unwrap<KitSummary>(await apiClient.post(`${BASE}/kits/generate`, { job_description, job_uuid }, JSON_BODY)),
  updateKit: async (uuid: string, kit: RoleKit) => unwrap<KitSummary>(await apiClient.put(`${BASE}/kits/${uuid}`, { kit }, JSON_BODY)),
  validateKit: async (kit: RoleKit) => unwrap<KitIssue[]>(await apiClient.post(`${BASE}/kits/validate`, { kit }, JSON_BODY)),
  approveKit: async (uuid: string) => unwrap<KitSummary>(await apiClient.post(`${BASE}/kits/${uuid}/approve`, {}, JSON_BODY)),
  deleteKit: async (uuid: string) => unwrap<unknown>(await apiClient.delete(`${BASE}/kits/${uuid}`)),

  interviews: async (params: { state?: string; to_review?: boolean; job_uuid?: string; page?: number } = {}) =>
    paged<InterviewSummary>(await apiClient.get(`${BASE}/interviews${buildQueryString({ ...params,
      to_review: params.to_review ? 'true' : undefined })}`)),
  interview: async (uuid: string) => unwrap<InterviewDetail>(await apiClient.get(`${BASE}/interviews/${uuid}`)),
  invite: async (application_uuid: string, kit_uuid?: string, expires_in_days = 7) =>
    unwrap<{ uuid: string; url: string; expires_at: string }>(
      await apiClient.post(`${BASE}/interviews`, { application_uuid, kit_uuid, expires_in_days }, JSON_BODY)),
  importFile: async (content: string) =>
    unwrap<ImportResult>(await apiClient.post(`${BASE}/interviews/import`, { content }, JSON_BODY)),
  evaluate: async (uuid: string) => unwrap<unknown>(await apiClient.post(`${BASE}/interviews/${uuid}/evaluate`, {}, JSON_BODY)),
  review: async (uuid: string, input: { levels: Record<string, number>; decision?: Decision; reason?: string; note?: string }) =>
    unwrap<InterviewDetail>(await apiClient.post(`${BASE}/interviews/${uuid}/review`, input, JSON_BODY)),
  revoke: async (uuid: string) => unwrap<unknown>(await apiClient.post(`${BASE}/interviews/${uuid}/revoke`, {}, JSON_BODY)),

  fairness: async (question: string, job_uuid?: string) =>
    unwrap<FairnessReport>(await apiClient.get(`${BASE}/reports/fairness${buildQueryString({ question, job_uuid })}`)),

  settings: async () => unwrap<AtsSettings>(await apiClient.get(`${BASE}/settings`)),
  updateSettings: async (input: Partial<AtsSettings>) => unwrap<AtsSettings>(await apiClient.put(`${BASE}/settings`, input, JSON_BODY)),
  tokens: async () => unwrap<IntegrationToken[]>(await apiClient.get(`${BASE}/settings/tokens`)),
  createToken: async (name: string) => unwrap<IntegrationToken>(await apiClient.post(`${BASE}/settings/tokens`, { name }, JSON_BODY)),
  revokeToken: async (uuid: string) => unwrap<unknown>(await apiClient.delete(`${BASE}/settings/tokens/${uuid}`)),
  checkout: async () => unwrap<{ checkout_url: string }>(await apiClient.post(`${BASE}/activation/checkout`, {}, JSON_BODY)),
};

/** "3 days ago" style, tolerant of Postgres timestamps. */
export function when(ts?: string | null): string {
  if (!ts) return '—';
  const d = new Date(ts.includes('T') ? ts : ts.replace(' ', 'T'));
  if (Number.isNaN(d.getTime())) return ts;
  return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}
