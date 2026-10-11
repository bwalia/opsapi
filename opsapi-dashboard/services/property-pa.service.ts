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

export interface Signal {
  key: string;
  weight: number;
  text: string;
  ref?: string | null;
}

export interface TodayCard {
  rank: number;
  score: number;
  opportunity_uuid: string;
  title: string;
  kind: string;
  person_name?: string | null;
  property_address?: string | null;
  why_now: string;
  action: string;
  objective: string;
  minutes: number;
  signals: Signal[];
  next_action?: { task_uuid: string; title: string; due_at?: string | null } | null;
}

export interface Today {
  cards: TodayCard[];
  weights: Record<string, number>;
  budget?: { minutes: number; used: number; fits: TodayCard[]; waits: { opportunity_uuid: string; title: string; minutes: number }[] };
}

export interface Why {
  rank: number;
  of: number;
  score: number;
  signals: Signal[];
  weights: Record<string, number>;
  action: string;
  objective: string;
  explanation: string;
}

export interface BriefLine {
  text: string;
  ref: string;
  label?: string;
  is_inferred?: boolean;
}

export interface Rule {
  key: string;
  version: number;
  scope: string;
  title: string;
  rule: string;
  ref: string;
}

export interface PrepareBrief {
  opportunity_uuid: string;
  title: string;
  person_name?: string | null;
  snapshot: BriefLine[];
  last_interaction?: (BriefLine & { at?: string; channel?: string }) | null;
  price: BriefLine[];
  decision_makers: BriefLine[];
  promises: (BriefLine & { at?: string })[];
  objections: BriefLine[];
  unknowns: string[];
  questions: { field: string; question: string }[];
  playbook: Rule[];
  objective: string;
  recommended_action: string;
  why_now: Signal[];
}

export interface Coaching {
  known: BriefLine[];
  assumed: BriefLine[];
  questions: string[];
  playbook: Rule[];
  next_step: string;
  never: string;
}

export interface Knowledge {
  uuid: string;
  key: string;
  domain: string;
  scope: 'personal' | 'team' | 'company';
  status: 'draft' | 'approved' | 'retired';
  current_version: number;
  title?: string | null;
  rule?: string | null;
  rationale?: string | null;
  triggers?: string[];
  approved_by_user_uuid?: string | null;
  approved_at?: string | null;
}

export interface PendingKnowledge {
  uuid: string;
  key: string;
  scope: string;
  version: number;
  title: string;
  rule: string;
  rationale?: string | null;
  triggers?: string[];
  proposed_by_ai: boolean;
  created_at: string;
}

export type PaMode = 'today' | 'prepare' | 'capture' | 'coach' | 'ask' | 'handoff' | 'manager_today' | 'teach';

export interface PaRun {
  uuid: string;
  status: 'running' | 'succeeded' | 'failed';
  model?: string | null;
  prompt_version?: string | null;
  error?: string | null;
  output?: {
    grounded: boolean;
    contract_ok?: boolean;
    answer?: string | null;
    withheld?: string | null;
    sources?: { type: string; id: string; label?: string }[];
    unknowns?: string[];
    inferences?: string[];
    needs_human?: boolean;
  } | null;
}

export interface Handoff {
  uuid: string;
  question: string;
  pa_recommendation?: string | null;
  context?: Record<string, unknown> | null;
  opportunity_uuid?: string | null;
  opportunity_title?: string | null;
  from_name?: string | null;
  reply?: string | null;
  status?: string;
  created_at: string;
}

export interface RefItem {
  opportunity_uuid?: string;
  uuid?: string;
  title: string;
  text?: string;
  ref?: string;
  owner_name?: string | null;
  days?: number;
  score?: number;
  why_now?: string | null;
  action?: string;
  due_at?: string;
  name?: string;
  money_at_risk?: number | string;
}

export interface ManagerToday {
  handoffs: Handoff[];
  unusual_negotiations: RefItem[];
  relationship_risks: RefItem[];
  overdue_actions: RefItem[];
  deal_risks: RefItem[];
  top_opportunities: RefItem[];
  open_opportunities: number;
  handled: number;
  summary: string;
}

export interface Metrics {
  days: number;
  capture: { captures: number; proposals: number; waiting: number; confirmed: number; corrected: number; rejected: number;
    accepted_as_proposed: number | null; correction_rate: number | null; rejection_rate: number | null; median_seconds_to_confirm: number | null };
  answers: { runs: number; succeeded: number; failed: number; grounded: number; withheld: number; grounded_rate: number | null;
    p50_seconds: number | null; p90_seconds: number | null };
  follow_through: { next_actions_open: number; next_actions_overdue: number; next_actions_done: number; opportunities_gone_quiet: number };
  handoffs: { total: number; waiting: number; median_seconds_to_reply: number | null };
}

export interface StatusCheck {
  key: string;
  ok: boolean;
  text: string;
  fix: string;
  optional?: boolean;
}

export interface AuditRow extends Change {
  target_table: string;
  target_uuid: string;
  source_interaction_uuid?: string | null;
  confirmed_by_name?: string | null;
  superseded: boolean;
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
  async today(minutes?: number) {
    return (await apiClient.get<Env<Today>>(`${BASE}/today${minutes ? `?minutes=${minutes}` : ''}`)).data.data;
  },
  async why(id: string) {
    return (await apiClient.get<Env<Why>>(`${BASE}/today/why/${id}`)).data.data;
  },
  async prepare(id: string) {
    return (await apiClient.get<Env<PrepareBrief>>(`${BASE}/prepare/${id}`)).data.data;
  },
  async coach(id: string, situation?: string) {
    const q = situation ? `?situation=${encodeURIComponent(situation)}` : '';
    return (await apiClient.get<Env<Coaching>>(`${BASE}/coach/${id}${q}`)).data.data;
  },
  async knowledge(params: { q?: string; status?: string } = {}) {
    return (await apiClient.get<Env<Knowledge[]>>(`${BASE}/knowledge${buildQueryString(params)}`)).data.data;
  },
  async pendingKnowledge() {
    return (await apiClient.get<Env<PendingKnowledge[]>>(`${BASE}/knowledge/pending`)).data.data;
  },
  async decideKnowledge(id: string, version: number, approve: boolean) {
    return (await apiClient.post<Env<Knowledge>>(`${BASE}/knowledge/${id}/versions/${version}/${approve ? 'approve' : 'reject'}`, {}, JSON_HDR)).data.data;
  },
  async retireKnowledge(id: string) {
    return (await apiClient.post<Env<Knowledge>>(`${BASE}/knowledge/${id}/retire`, {}, JSON_HDR)).data.data;
  },
  async teach(body: { statement: string; title?: string; scope?: 'personal' | 'team' | 'company'; domain?: string; triggers?: string[]; rationale?: string; approve?: boolean }) {
    return (await apiClient.post<Env<Knowledge & { version?: number }>>(`${BASE}/knowledge/teach`, body, JSON_HDR)).data.data;
  },
  async ask(body: { message: string; mode?: PaMode; opportunity_uuid?: string }) {
    return (await apiClient.post<Env<PaRun>>(`${BASE}/ask`, body, JSON_HDR)).data.data;
  },
  async run(id: string) {
    return (await apiClient.get<Env<PaRun>>(`${BASE}/ask/${id}`)).data.data;
  },
  async managerToday() {
    return (await apiClient.get<Env<ManagerToday>>(`${BASE}/manager/today`)).data.data;
  },
  async metrics(days = 30) {
    return (await apiClient.get<Env<Metrics>>(`${BASE}/metrics?days=${days}`)).data.data;
  },
  async status() {
    return (await apiClient.get<Env<{ ready: boolean; checks: StatusCheck[]; limits: Record<string, number> }>>(`${BASE}/status`)).data.data;
  },
  async audit(params: { target_uuid?: string; per_page?: number } = {}) {
    return (await apiClient.get<Env<AuditRow[]>>(`${BASE}/audit${buildQueryString(params)}`)).data.data;
  },
  async handoff(body: { to_user_uuid: string; question: string; opportunity_uuid?: string; pa_recommendation?: string; context?: Record<string, unknown> }) {
    return (await apiClient.post<Env<Handoff>>(`${BASE}/handoffs`, body, JSON_HDR)).data.data;
  },
  async reply(id: string, reply: string, decision?: string) {
    return (await apiClient.post<Env<Handoff>>(`${BASE}/handoffs/${id}/reply`, { reply, decision }, JSON_HDR)).data.data;
  },
  async importMail() {
    return (await apiClient.post<Env<{ imported: number; considered: number }>>(`${BASE}/integrations/mail/import`, {}, JSON_HDR)).data.data;
  },
  async syncGhl() {
    return (await apiClient.post<Env<{ created: number; updated: number; unchanged: number }>>(`${BASE}/integrations/ghl/sync`, {}, JSON_HDR)).data.data;
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
