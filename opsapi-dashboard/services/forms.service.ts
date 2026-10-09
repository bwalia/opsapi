import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Forms API client (lapis/routes/forms.lua, docs/FORMS.md). The server is the
 * authority: every save goes through its normalize(), which adds and locks the
 * contact fields a form's targets need, so the builder always renders what the
 * server returns rather than what it sent.
 */

export type FieldType =
  | 'short_text' | 'long_text' | 'email' | 'phone' | 'url' | 'number' | 'date' | 'time'
  | 'single_select' | 'radio' | 'multi_select' | 'boolean' | 'rating' | 'consent'
  | 'name' | 'address' | 'file_upload' | 'hidden' | 'heading' | 'paragraph' | 'page_break';

export type LogicOp = 'eq' | 'neq' | 'in' | 'not_in' | 'gt' | 'lt' | 'filled' | 'empty' | 'contains';

export interface LogicRule {
  /** Answer key of a question above this one. */
  field: string;
  op: LogicOp;
  value?: string | number | boolean | string[];
}

export interface FieldLogic {
  match: 'all' | 'any';
  rules: LogicRule[];
}

export type MapsTo = 'phone' | 'company' | 'job_title' | 'address' | 'notes' | 'marketing_consent';

export interface FieldOption {
  value: string;
  label: string;
}

export interface FormField {
  key?: string;
  type: FieldType;
  label: string;
  help?: string;
  placeholder?: string;
  required?: boolean;
  width?: 'full' | 'half';
  options?: FieldOption[];
  validation?: {
    min_length?: number; max_length?: number; min?: number | string; max?: number | string;
    integer?: boolean; min_selected?: number; max_selected?: number;
  };
  scale?: 5 | 10;
  text?: string;
  /** File questions: how many files, the size limit, and which kinds. */
  max_files?: number;
  max_size_mb?: number;
  accept?: 'images' | 'documents' | 'any';
  param?: string;
  maps_to?: MapsTo;
  /** Set by the server: a contact field a target needs. Locked in the builder. */
  system?: 'contact.name' | 'contact.email';
  /** Show this field only when these rules hold (questions above it). */
  logic?: FieldLogic;
}

export type TargetType = 'customer' | 'lead' | 'user';

export interface FormTarget {
  type: TargetType;
  role?: string;
}

export interface FormSettings {
  success_message?: string;
  redirect_url?: string;
  close_at?: string;
  max_submissions?: number;
  closed_message?: string;
  notify_emails?: string[];
  auto_reply?: { enabled: boolean; subject?: string; body?: string };
  retention_days?: number;
  theme?: { primary_color?: string; background?: string; logo_url?: string; submit_label?: string; hide_branding?: boolean };
  /** The workspace's Turnstile check on this form. */
  captcha?: boolean;
  /** In-app notification to the creator and notify addresses that are members (default on). */
  notify_in_app?: boolean;
  /** Post each response to this chat channel of the workspace. */
  chat_channel_uuid?: string;
}

export type FormStatus = 'draft' | 'published' | 'closed' | 'archived';

export interface FormSummary {
  uuid: string;
  public_id: string;
  title: string;
  description?: string;
  status: FormStatus;
  question_count: number;
  submission_count: number;
  last_submission_at?: string;
  published_version?: number;
  published_at?: string;
  has_unpublished_changes: boolean;
  share_url?: string;
  share_path: string;
  /** The workspace's connected custom domain, if any: links use it. */
  share_domain?: string;
  targets: FormTarget[];
  created_at: string;
  updated_at: string;
}

export interface Form extends FormSummary {
  schema: { fields: FormField[] };
  settings: FormSettings;
  /** Answer keys of the published version: these never change. */
  published_keys: string[];
  /** Where emails go out from: the workspace's own SMTP, the platform's, or nowhere. */
  email_via?: 'workspace' | 'platform' | 'none';
  /** Whether this workspace's plan may hide "Powered by OpsAPI" (no plan may, for now). */
  can_hide_branding?: boolean;
}

export interface TargetOption {
  key: TargetType;
  label: string;
  description: string;
  requires: string[];
  allowed: boolean;
  permission: string;
  roles?: { name: string; label: string }[];
}

export interface FormTemplate {
  key: string;
  title: string;
  description: string;
  targets: TargetType[];
  question_count: number;
}

export interface SubmissionLink {
  target: TargetType;
  outcome: 'created' | 'matched' | 'invited' | 'failed';
  entity_type?: 'customer' | 'lead' | 'user' | 'invitation';
  entity_uuid?: string;
  error_code?: string;
  record?: { name?: string; email?: string; status?: string; expires_at?: string };
  missing?: boolean;
}

export type SubmissionStatus = 'complete' | 'needs_attention' | 'spam';

export interface Submission {
  uuid: string;
  status: SubmissionStatus;
  respondent_email?: string;
  answers: Record<string, unknown>;
  version: number;
  links: SubmissionLink[];
  utm?: Record<string, string>;
  referrer?: string;
  page_url?: string;
  spam_reason?: string;
  duration_ms?: number;
  created_at: string;
  processed_at?: string;
  /** Only on a single response: the fields of the version it answered. */
  fields?: FormField[];
}

export interface Column {
  key: string;
  label: string;
  type: FieldType;
  options?: FieldOption[];
  scale?: number;
}

export interface FormInput {
  title?: string;
  description?: string;
  template?: string;
  fields?: FormField[];
  targets?: FormTarget[];
  settings?: FormSettings;
  expected_updated_at?: string;
}

export interface Analytics {
  days: number;
  totals: { views: number; starts: number; responses: number; conversion?: number; completion?: number; avg_seconds?: number };
  series: { day: string; views: number; starts: number; responses: number }[];
  funnel: { step: number; reached: number }[];
  sources: { source: string; responses: number }[];
}

export interface ResponseSummary {
  responses: number;
  fields: { key: string; label: string; type: FieldType; answered: number; counts?: Record<string, number>;
    average?: number; min?: number; max?: number }[];
  summary?: string;
  summary_error?: string;
}

export interface GeneratedForm {
  title: string;
  description?: string;
  schema: { fields: FormField[] };
  targets: FormTarget[];
  dropped: number;
}

export interface RecordResponse {
  uuid: string;
  status: SubmissionStatus;
  created_at: string;
  outcome: SubmissionLink['outcome'];
  form_uuid: string;
  form_title: string;
  answers: { label: string; value: string }[];
}

export interface WorkspaceFormsSettings {
  turnstile: { site_key?: string; has_secret: boolean };
}

/** The workspace's custom domain for form links. */
export interface FormDomain {
  /** Custom domains are set up on this platform. */
  available: boolean;
  target?: string;
  domain?: string;
  status?: 'pending' | 'active';
  last_error?: string;
  checked_at?: string;
  verified_at?: string;
  records?: { type: 'CNAME' | 'A' | 'TXT'; name: string; value: string }[];
}

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;
const BASE = '/api/v2/forms';

function unwrap<T>(response: { data: unknown }): T {
  return (response.data as { data: T }).data;
}

export const formsService = {
  async list(params: { status?: string; q?: string; cursor?: string; limit?: number } = {}) {
    const res = await apiClient.get(`${BASE}${buildQueryString(params)}`);
    const body = res.data as { data: FormSummary[]; meta?: { next_cursor?: string } };
    return { items: body.data ?? [], nextCursor: body.meta?.next_cursor };
  },
  async get(uuid: string): Promise<Form> {
    return unwrap<Form>(await apiClient.get(`${BASE}/${uuid}`));
  },
  async create(input: FormInput): Promise<Form> {
    return unwrap<Form>(await apiClient.post(BASE, input, JSON_BODY));
  },
  async update(uuid: string, input: FormInput): Promise<Form> {
    return unwrap<Form>(await apiClient.put(`${BASE}/${uuid}`, input, JSON_BODY));
  },
  async remove(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/${uuid}`);
  },
  async publish(uuid: string): Promise<Form> {
    return unwrap<Form>(await apiClient.post(`${BASE}/${uuid}/publish`, {}, JSON_BODY));
  },
  async setOpen(uuid: string, open: boolean): Promise<Form> {
    return unwrap<Form>(await apiClient.post(`${BASE}/${uuid}/${open ? 'reopen' : 'close'}`, {}, JSON_BODY));
  },
  async duplicate(uuid: string): Promise<Form> {
    return unwrap<Form>(await apiClient.post(`${BASE}/${uuid}/duplicate`, {}, JSON_BODY));
  },
  async targets(): Promise<TargetOption[]> {
    return unwrap<TargetOption[]>(await apiClient.get(`${BASE}/targets`));
  },
  async templates(): Promise<FormTemplate[]> {
    return unwrap<FormTemplate[]>(await apiClient.get(`${BASE}/templates`));
  },
  async submissions(
    uuid: string,
    params: { status?: string; from?: string; to?: string; q?: string; cursor?: string; limit?: number } = {}
  ) {
    const res = await apiClient.get(`${BASE}/${uuid}/submissions${buildQueryString(params)}`);
    const body = res.data as { data: Submission[]; meta: { next_cursor?: string; columns: Column[] } };
    return { items: body.data ?? [], nextCursor: body.meta?.next_cursor, columns: body.meta?.columns ?? [] };
  },
  async submission(uuid: string, sid: string): Promise<Submission> {
    return unwrap<Submission>(await apiClient.get(`${BASE}/${uuid}/submissions/${sid}`));
  },
  async setSubmissionStatus(uuid: string, sid: string, status: 'spam' | 'complete'): Promise<Submission> {
    return unwrap<Submission>(await apiClient.put(`${BASE}/${uuid}/submissions/${sid}`, { status }, JSON_BODY));
  },
  async retry(uuid: string, sid: string): Promise<Submission> {
    return unwrap<Submission>(await apiClient.post(`${BASE}/${uuid}/submissions/${sid}/retry`, {}, JSON_BODY));
  },
  async removeSubmission(uuid: string, sid: string): Promise<void> {
    await apiClient.delete(`${BASE}/${uuid}/submissions/${sid}`);
  },
  async fileLink(uuid: string, sid: string, fileId: string): Promise<string> {
    return unwrap<{ url: string }>(await apiClient.get(`${BASE}/${uuid}/submissions/${sid}/files/${fileId}`)).url;
  },
  async analytics(uuid: string, days = 30): Promise<Analytics> {
    return unwrap<Analytics>(await apiClient.get(`${BASE}/${uuid}/analytics?days=${days}`));
  },
  async summary(uuid: string): Promise<ResponseSummary> {
    return unwrap<ResponseSummary>(await apiClient.post(`${BASE}/${uuid}/summary`, {}, JSON_BODY));
  },
  async generate(prompt: string): Promise<GeneratedForm> {
    return unwrap<GeneratedForm>(await apiClient.post(`${BASE}/generate`, { prompt }, JSON_BODY));
  },
  async forRecord(entityType: 'customer' | 'lead' | 'user' | 'invitation', entityUuid: string): Promise<RecordResponse[]> {
    return unwrap<RecordResponse[]>(await apiClient.get(
      `${BASE}/responses?entity_type=${entityType}&entity_uuid=${encodeURIComponent(entityUuid)}`));
  },
  async workspaceSettings(): Promise<WorkspaceFormsSettings> {
    return unwrap<WorkspaceFormsSettings>(await apiClient.get(`${BASE}/workspace-settings`));
  },
  async saveWorkspaceSettings(input: { turnstile: { site_key?: string; secret?: string } }): Promise<WorkspaceFormsSettings> {
    return unwrap<WorkspaceFormsSettings>(await apiClient.put(`${BASE}/workspace-settings`, input, JSON_BODY));
  },
  async domain(): Promise<FormDomain> {
    return unwrap<FormDomain>(await apiClient.get(`${BASE}/domain`));
  },
  async saveDomain(domain: string): Promise<FormDomain> {
    return unwrap<FormDomain>(await apiClient.put(`${BASE}/domain`, { domain }, JSON_BODY));
  },
  async checkDomain(): Promise<FormDomain> {
    return unwrap<FormDomain>(await apiClient.post(`${BASE}/domain/check`, {}, JSON_BODY));
  },
  async removeDomain(): Promise<FormDomain> {
    return unwrap<FormDomain>(await apiClient.delete(`${BASE}/domain`));
  },
  async exportCsv(uuid: string, params: { status?: string; from?: string; to?: string; q?: string } = {}) {
    const res = await apiClient.get(`${BASE}/${uuid}/export${buildQueryString(params)}`, { responseType: 'blob' });
    const cd = String(res.headers['content-disposition'] || '');
    const filename = /filename="([^"]+)"/.exec(cd)?.[1] || 'responses.csv';
    return { blob: res.data as Blob, filename };
  },
};

/** The public link for a form: on the workspace's custom domain, else on this dashboard. */
export function shareUrl(form: Pick<FormSummary, 'share_url' | 'share_path' | 'share_domain'>): string {
  if (form.share_domain) return `https://${form.share_domain}${form.share_path}`;
  if (typeof window !== 'undefined') return window.location.origin + form.share_path;
  return form.share_url || form.share_path;
}

/** A Postgres timestamp ("2026-10-09 14:04:42.4+00") as a Date (browsers reject the short "+00" offset). */
export function parseTs(v?: string | null): Date | null {
  if (!v) return null;
  const d = new Date(v.replace(' ', 'T').replace(/([+-]\d\d)$/, '$1:00'));
  return Number.isNaN(d.getTime()) ? null : d;
}
