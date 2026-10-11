/**
 * Property PA (OpsAPI plugin projects/property-pa) — typed client for the PA screens.
 * Contract: /openapi.json (PropertyPa* schemas) and docs/property-pa/02-week1-brain.md.
 * Requests go through apiClient (auth + workspace headers).
 */
import apiClient, { buildQueryString } from '@/lib/api-client';

const BASE = '/api/v2/property-pa';
const JSON_HDR = { headers: { 'Content-Type': 'application/json' } };

export type FactSource = 'human' | 'ai' | 'import' | 'integration';

export interface Fact {
  value: unknown;
  is_inferred: boolean;
  confirmed: boolean;
  source: FactSource;
  confidence?: number | string | null;
}

export interface NextAction {
  task_uuid: string;
  title: string;
  reason?: string | null;
  pd_status: string;
  due_at?: string | null;
  overdue?: boolean;
  owner_user_uuid?: string | null;
  opportunity_uuid?: string | null;
  created_from_interaction_uuid?: string | null;
}

export interface Opportunity {
  uuid: string;
  kind: 'sell' | 'buy';
  title: string;
  status: string;
  person_uuid?: string | null;
  person_name?: string | null;
  property_uuid?: string | null;
  property_address?: string | null;
  property_postcode?: string | null;
  owner_user_uuid?: string | null;
  motivation?: string | null;
  expectation_price?: number | string | null;
  our_position?: string | null;
  temperature?: 'hot' | 'warm' | 'cold' | null;
  decision_makers?: { name?: string; role?: string }[];
  primary_concern?: string | null;
  last_meaningful_contact_at?: string | null;
  next_action_at?: string | null;
  updated_at?: string;
  facts?: Record<string, Fact>;
  offers?: { uuid: string; amount: number | string; response: string; made_at: string; conditions?: string | null }[];
  events?: { uuid: string; kind: string; at: string; title: string; done: boolean }[];
  next_actions?: NextAction[];
  pending_updates?: ProposedUpdate[];
}

export interface Interaction {
  uuid: string;
  channel: string;
  direction: string;
  subject?: string | null;
  raw_text?: string | null;
  transcript?: string | null;
  summary?: string | null;
  at?: string;
  person_uuid?: string | null;
  opportunity_uuid?: string | null;
  owner_user_uuid?: string | null;
}

export type ProposalStatus = 'proposed' | 'confirmed' | 'corrected' | 'rejected';

export interface ProposedUpdate {
  uuid: string;
  target_table: string;
  target_uuid?: string | null;
  field: string;
  old_value?: unknown;
  new_value?: unknown;
  confidence?: number | string | null;
  is_inferred: boolean;
  material: boolean;
  source_quote?: string | null;
  source_interaction_uuid?: string | null;
  status: ProposalStatus;
  decided_by_user_uuid?: string | null;
  model?: string | null;
  prompt_version?: string | null;
}

export interface SheetRow extends ProposedUpdate {
  label: string;
  kind: 'stated' | 'inferred' | 'proposed';
  kind_label: string;
  owner?: { user_uuid?: string | null; name?: string | null };
}

export interface CaptureSheet {
  interaction: Interaction;
  author?: string | null;
  run?: { uuid: string; status: 'running' | 'succeeded' | 'failed'; model?: string | null; prompt_version?: string | null; error?: string | null } | null;
  proposals: SheetRow[];
  counts: { proposed: number; confirmed: number; corrected: number; rejected: number; material: number };
}

export interface Decision {
  uuid: string;
  action: 'confirm' | 'correct' | 'reject';
  value?: unknown;
}

export interface TimelineItem {
  kind: 'interaction' | 'event' | 'offer' | 'next_action' | 'change';
  at: string;
  uuid: string;
  title: string;
  detail?: unknown;
  sub_kind?: string | null;
  direction?: string | null;
  source?: string | null;
  by_user_uuid?: string | null;
}

export interface Change {
  uuid: string;
  field: string;
  value: unknown;
  action: 'set' | 'create' | 'correct' | 'clear';
  source: FactSource;
  source_ref?: string | null;
  confidence?: number | string | null;
  is_inferred: boolean;
  confirmed_by_user_uuid?: string | null;
  confirmed_at?: string | null;
  model?: string | null;
  prompt_version?: string | null;
  run_ref?: string | null;
  superseded_by?: string | null;
  created_at: string;
}

export interface PersonHit {
  uuid: string;
  first_name: string;
  last_name?: string | null;
  email?: string | null;
  mobile?: string | null;
  opportunity_uuid?: string | null;
  opportunity_title?: string | null;
  property_address?: string | null;
}

type Env<T> = { data: T; meta?: { page?: number; per_page?: number; total?: number } };

export const paService = {
  async opportunities(params: { status?: string; kind?: string; mine?: boolean; per_page?: number } = {}) {
    const q = buildQueryString({ ...params, mine: params.mine ? 'true' : undefined } as Record<string, unknown>);
    return (await apiClient.get<Env<Opportunity[]>>(`${BASE}/opportunities${q}`)).data;
  },
  async opportunity(id: string) {
    return (await apiClient.get<Env<Opportunity>>(`${BASE}/opportunities/${id}`)).data.data;
  },
  async timeline(id: string) {
    return (await apiClient.get<Env<TimelineItem[]>>(`${BASE}/opportunities/${id}/timeline`)).data.data;
  },
  async history(table: string, id: string, field?: string) {
    const q = field ? `?field=${encodeURIComponent(field)}` : '';
    return (await apiClient.get<Env<Change[]>>(`${BASE}/history/${table}/${id}${q}`)).data.data;
  },
  async people(q: string) {
    return (await apiClient.get<Env<PersonHit[]>>(`${BASE}/people?q=${encodeURIComponent(q)}`)).data.data;
  },
  async startCapture(body: { text: string; channel?: 'voice' | 'note' | 'call'; opportunity_uuid?: string }) {
    return (
      await apiClient.post<Env<{ interaction: Interaction; pa: { run_uuid?: string; status?: string; error?: string } }>>(
        `${BASE}/captures/start`, body, JSON_HDR,
      )
    ).data.data;
  },
  async sheet(interactionId: string) {
    return (await apiClient.get<Env<CaptureSheet>>(`${BASE}/interactions/${interactionId}/capture`)).data.data;
  },
  async decide(interactionId: string, decisions: Decision[], confirmRest: boolean) {
    return (
      await apiClient.post<Env<{ results: { uuid: string; ok: boolean; error?: string }[]; sheet: CaptureSheet }>>(
        `${BASE}/interactions/${interactionId}/decide`, { decisions, confirm_rest: confirmRest }, JSON_HDR,
      )
    ).data.data;
  },
};

export default paService;
