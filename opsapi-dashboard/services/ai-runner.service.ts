/**
 * AI Runs (OpsAPI plugin projects/ai-runner) — typed client for the dashboard pages.
 * Contract: docs/AI_RUNNER.md §22.3 and §23.3 (user API, session JWT). Requests go through apiClient
 * (auth + workspace headers). Writes carry `_replay: true` so they never sit in the offline
 * outbox: a run started or a token minted by a background replay later is worse than an error now.
 */
import { AxiosError } from 'axios';
import apiClient, { buildQueryString } from '@/lib/api-client';
import { errorMessage } from '@/lib/plugin-bridge';

const BASE = '/api/v2/ai-runner';
const WRITE = { headers: { 'Content-Type': 'application/json' }, _replay: true };

export type RunStatus =
  | 'pending_approval' | 'queued' | 'claimed' | 'starting' | 'running' | 'waiting_permission' | 'needs_input' | 'cancelling'
  | 'succeeded' | 'failed' | 'cancelled' | 'lost';
export const TERMINAL: RunStatus[] = ['succeeded', 'failed', 'cancelled', 'lost'];
export type OutputMode = 'pull_request' | 'branch' | 'local';
export type RunnerStatus = 'online' | 'offline' | 'paused' | 'revoked';

/** The agent's plan usage window, as the runner last saw it (Claude's rate_limit_info). */
export interface RateLimit {
  status?: string | null;
  /** ISO time, or epoch seconds as Claude reports it. */
  resets_at?: string | number | null;
  /** five_hour, seven_day, seven_day_opus, … */
  type?: string | null;
  /** 0–1 (or a percentage above 1). */
  utilization?: number | null;
}
export interface RunnerProfile {
  key: string;
  label?: string;
  approval?: 'none' | 'bridge' | 'unsupported';
  models?: string[];
  rate_limit?: RateLimit | null;
}
export interface RunnerRepo {
  path: string;
  remote?: string;
  branch?: string;
  dirty?: boolean;
}
export interface Runner {
  uuid: string;
  name: string;
  status: RunnerStatus;
  host?: string | null;
  os?: string | null;
  version?: string | null;
  labels?: string[] | Record<string, unknown> | null;
  capabilities?: { max_concurrency?: number; profiles?: RunnerProfile[] } | null;
  repos?: RunnerRepo[] | null;
  last_heartbeat_at?: string | null;
  created_at?: string;
}
export interface RunnerSession {
  key: string;
  tool?: string;
  status?: string;
  cwd?: string;
  branch?: string;
  session_id?: string;
  started_at?: string;
  updated_at?: string;
  prompt_preview?: string;
  managed?: boolean;
  run_uuid?: string | null;
}

export interface RunTask {
  uuid?: string;
  task_number?: number;
  number?: number;
  title?: string;
  url?: string;
  project_uuid?: string;
}
export interface Run {
  uuid: string;
  status: RunStatus;
  attempt?: number;
  task_uuid: string;
  project_uuid?: string;
  /** GET /runs/:uuid adds the task; lists may carry the snapshot taken at start. */
  task?: RunTask | null;
  task_snapshot?: RunTask | null;
  requested_by?: string | null;
  requester?: { uuid?: string; name?: string; email?: string } | null;
  requested_by_name?: string | null;
  runner_uuid?: string | null;
  runner?: Partial<Runner> | null;
  runner_name?: string | null;
  profile: string;
  model?: string | null;
  repo_path: string;
  base_branch?: string | null;
  work_branch?: string | null;
  previous_branch?: string | null;
  output_mode: OutputMode;
  prompt?: string;
  template_version?: number | null;
  created_at: string;
  started_at?: string | null;
  finished_at?: string | null;
  exit_code?: number | null;
  error_category?: string | null;
  error?: string | null;
  summary?: string | null;
  pr_url?: string | null;
  commit_sha?: string | null;
  /** Phase 3: the open needs_input question, usage totals, pending permission requests (lists). */
  question?: string | null;
  tokens_in?: number | null;
  tokens_out?: number | null;
  cache_read?: number | null;
  cache_write?: number | null;
  cost_estimate?: number | string | null;
  turns?: number | null;
  pending_requests?: number | null;
  approved_by?: string | null;
  approved_at?: string | null;
}
export type RequestStatus = 'pending' | 'allowed' | 'denied' | 'expired';
/** A permission request from the agent (ar_run_requests). */
export interface RunRequest {
  uuid: string;
  run_uuid?: string;
  request_id?: string;
  tool: string;
  /** Redacted tool input: Bash { command }, file tools { file_path }, … */
  input?: Record<string, unknown> | string | null;
  input_summary?: string | null;
  description?: string | null;
  blocked_path?: string | null;
  rule_key?: string | null;
  remember?: boolean;
  status: RequestStatus;
  reason?: string | null;
  decided_by?: string | null;
  decided_by_name?: string | null;
  decided_at?: string | null;
  expires_at?: string | null;
  created_at?: string;
}
/** One turn of the conversation: the agent's reply to a turn (with usage), or a person's message. */
export interface RunTurn {
  uuid: string;
  seq: number;
  role: 'user' | 'assistant';
  text?: string | null;
  author_user_uuid?: string | null;
  author_name?: string | null;
  /** user turns: queued until the runner picks them up. */
  status?: 'queued' | 'delivered';
  model?: string | null;
  tokens_in?: number | null;
  tokens_out?: number | null;
  cache_read?: number | null;
  cache_write?: number | null;
  cost_estimate?: number | string | null;
  needs_input?: boolean;
  at?: string;
  created_at?: string;
}
export interface Usage {
  tokens_in: number;
  tokens_out: number;
  cache_read: number;
  cache_write: number;
  cost_estimate: number;
  turns: number;
}
/** GET /waiting: what the caller may decide now. */
export type WaitingRequest = RunRequest & {
  run_uuid: string;
  run?: Partial<Run> | null;
  task?: RunTask | null;
  task_snapshot?: RunTask | null;
  task_title?: string | null;
  task_number?: number | null;
  project_uuid?: string | null;
  requested_by_name?: string | null;
};
export interface Waiting {
  requests: WaitingRequest[];
  approvals: Run[];
}
export interface RunEvent {
  seq: number;
  type: 'log' | 'progress' | 'tool' | 'usage' | string;
  text?: string | null;
  data?: unknown;
  at?: string;
}
export interface RunDetail {
  run: Run;
  events: RunEvent[];
  /** Newest first. */
  requests: RunRequest[];
  /** In order. */
  turns: RunTurn[];
  usage: Usage;
  /** May the caller decide this run's permission requests / approve its start / message the agent? */
  can_decide: boolean;
  can_approve: boolean;
  can_message: boolean;
}

export interface Conflicts {
  open_run?: (Partial<Run> & { uuid?: string }) | null;
  folder_lock?: { run_uuid?: string; since?: string; holder?: string; message?: string } | null;
  busy_session?: Partial<RunnerSession> & { message?: string } | null;
}
export interface Preview {
  prompt: string;
  template_version?: number;
  runners?: Runner[];
  default_repo_path?: string | null;
  output_mode: OutputMode;
  conflicts?: Conflicts;
  /** Server's decision: may this user edit the prompt before starting? */
  can_edit_prompt?: boolean;
  runner_uuid?: string | null;
  repo_path?: string | null;
  work_branch?: string | null;
  /** The run would wait for a manager's approval before it starts. */
  needs_approval?: boolean;
}
export interface StartInput {
  runner_uuid: string;
  profile: string;
  model?: string;
  repo_path: string;
  prompt?: string;
  output_mode?: OutputMode;
}

export interface ApprovalPolicy {
  deciders: 'requester' | 'managers' | 'requester_or_managers';
  require_start_approval: boolean;
  permission_timeout_minutes: number;
  input_timeout_minutes: number;
}
export interface Settings {
  output_mode: OutputMode;
  pr_draft: boolean;
  pr_base: string;
  max_run_minutes: number;
  task_automation: { in_progress_on_start: boolean; review_on_success: boolean };
  approval_policy: ApprovalPolicy;
}
export interface ProjectSettings {
  default_repo_paths: Record<string, string>;
  output_mode?: OutputMode | null;
  base_branch?: string | null;
}
export interface Template {
  body: string;
  version: number;
}

export interface Page<T> {
  items: T[];
  page: number;
  total: number;
  totalPages: number;
}
export interface RunFilters {
  status?: string;
  task_uuid?: string;
  runner_uuid?: string;
  mine?: boolean;
  page?: number;
  per_page?: number;
}

export interface AiError {
  status: number;
  message: string;
  code?: string;
  conflict?: unknown;
}

/** Any request error as { status, message } with a message a person can act on (never server internals). */
export function aiError(e: unknown): AiError {
  if (!(e instanceof AxiosError)) return { status: 0, message: 'Something went wrong. Try again.' };
  const status = e.response?.status ?? 0;
  const body = (e.response?.data ?? {}) as { code?: string; conflict?: unknown; error?: { code?: string } };
  const code = body.code || body.error?.code;
  if (!e.response) return { status: 0, message: "Can't reach the server. Check your connection and try again." };
  if (status >= 500) return { status, code, message: 'Something went wrong on the server. Try again in a moment.' };
  const fallback: Record<number, string> = {
    400: 'The request was not valid.',
    401: 'Your session has ended. Sign in again.',
    403: "You don't have permission to do that.",
    404: 'Not found. It may have been removed, or AI Runs is switched off here.',
    409: 'That clashes with something already running.',
    422: 'Some details are not valid. Check them and try again.',
    429: 'Too many requests. Wait a moment and try again.',
  };
  return { status, code, conflict: body.conflict, message: errorMessage(body) || fallback[status] || 'The request failed.' };
}
export const aiErrorText = (e: unknown) => aiError(e).message;

interface Envelope<T> {
  success: boolean;
  data: T;
  meta?: { page?: number; per_page?: number; total?: number; total_pages?: number };
}
const id = encodeURIComponent;

async function get<T>(path: string): Promise<Envelope<T>> {
  return (await apiClient.get<Envelope<T>>(BASE + path)).data;
}
async function send<T>(method: 'post' | 'put' | 'delete', path: string, body?: unknown, headers?: Record<string, string>): Promise<T> {
  const config = headers ? { ...WRITE, headers: { ...WRITE.headers, ...headers } } : WRITE;
  const res = method === 'delete'
    ? await apiClient.delete<Envelope<T>>(BASE + path, config)
    : await apiClient[method]<Envelope<T>>(BASE + path, body ?? {}, config);
  return res.data.data;
}
// An empty Lua table arrives as {} rather than [].
const list = <T>(v: unknown): T[] => (Array.isArray(v) ? (v as T[]) : []);
const num = (v: unknown) => Number(v) || 0;

// Idempotency-Key per start attempt: retrying the same request after it got no answer reuses the
// key (the server replays its first answer); any answer from the server ends the attempt.
const pendingStarts = new Map<string, { body: string; key: string }>();

export const aiRunner = {
  // Runners
  listRunners: async () => list<Runner>((await get<Runner[]>('/runners')).data),
  registerRunner: (name: string, labels?: string[]) =>
    send<{ runner: Runner; token: string }>('post', '/runners', { name, labels }),
  rotateToken: (uuid: string) => send<{ token: string; runner?: Runner }>('post', `/runners/${id(uuid)}/rotate-token`),
  pauseRunner: (uuid: string) => send<Runner>('post', `/runners/${id(uuid)}/pause`),
  resumeRunner: (uuid: string) => send<Runner>('post', `/runners/${id(uuid)}/resume`),
  revokeRunner: (uuid: string) => send<unknown>('delete', `/runners/${id(uuid)}`),
  runnerSessions: async (uuid: string) => list<RunnerSession>((await get<RunnerSession[]>(`/runners/${id(uuid)}/sessions`)).data),

  // Start a run on a task
  preview: (taskUuid: string, input: Partial<Pick<StartInput, 'runner_uuid' | 'profile' | 'repo_path'>> = {}) =>
    send<Preview>('post', `/tasks/${id(taskUuid)}/runs/preview`, input),
  start: async (taskUuid: string, input: StartInput): Promise<Run> => {
    const body = JSON.stringify(input);
    const prev = pendingStarts.get(taskUuid);
    const key = prev && prev.body === body ? prev.key : crypto.randomUUID();
    pendingStarts.set(taskUuid, { body, key });
    try {
      const run = await send<Run>('post', `/tasks/${id(taskUuid)}/runs`, input, { 'Idempotency-Key': key });
      pendingStarts.delete(taskUuid);
      return run;
    } catch (e) {
      if (e instanceof AxiosError && e.response) pendingStarts.delete(taskUuid);
      throw e;
    }
  },
  taskRuns: async (taskUuid: string) => list<Run>((await get<Run[]>(`/tasks/${id(taskUuid)}/runs`)).data),

  // Runs
  listRuns: async (f: RunFilters = {}): Promise<Page<Run>> => {
    const res = await get<Run[]>(`/runs${buildQueryString({ ...f, mine: f.mine ? 1 : undefined })}`);
    const items = list<Run>(res.data);
    const total = Number(res.meta?.total ?? items.length);
    const perPage = Number(res.meta?.per_page ?? f.per_page ?? (items.length || 1));
    return {
      items,
      page: Number(res.meta?.page ?? f.page ?? 1),
      total,
      totalPages: Number(res.meta?.total_pages ?? Math.max(1, Math.ceil(total / perPage))),
    };
  },
  /**
   * GET /runs/:uuid — accepts `{ run, events, … }` or the run with those fields inline. Usage totals are the
   * run's own columns, or a `usage` object.
   */
  getRun: async (uuid: string): Promise<RunDetail> => {
    const d = (await get<Record<string, unknown>>(`/runs/${id(uuid)}`)).data;
    const run = ((d.run as Run) ?? d) as Run;
    const field = (k: string) => d[k] ?? (run as unknown as Record<string, unknown>)[k];
    const u = { ...run, ...(field('usage') as Partial<Usage> | undefined) };
    return {
      run: { ...run, task: (d.task as RunTask) ?? run.task, runner: (d.runner as Runner) ?? run.runner },
      events: [...list<RunEvent>(field('events'))].sort((a, b) => a.seq - b.seq),
      requests: list<RunRequest>(field('requests')),
      turns: [...list<RunTurn>(field('turns'))].sort((a, b) => a.seq - b.seq),
      usage: {
        tokens_in: num(u.tokens_in), tokens_out: num(u.tokens_out), cache_read: num(u.cache_read),
        cache_write: num(u.cache_write), cost_estimate: num(u.cost_estimate), turns: num(u.turns),
      },
      can_decide: field('can_decide') === true,
      can_approve: field('can_approve') === true,
      can_message: field('can_message') === true,
    };
  },
  cancel: (uuid: string) => send<Run>('post', `/runs/${id(uuid)}/cancel`),
  retry: (uuid: string) => send<Run>('post', `/runs/${id(uuid)}/retry`),

  // Phase 3: permission requests, the conversation, start approvals (§23.3)
  waiting: async (): Promise<Waiting> => {
    const d = (await get<Partial<Waiting>>('/waiting')).data || {};
    return { requests: list<WaitingRequest>(d.requests), approvals: list<Run>(d.approvals) };
  },
  decide: (runUuid: string, reqUuid: string, decision: 'allow' | 'deny', opts: { reason?: string; remember?: boolean } = {}) =>
    send<RunRequest>('post', `/runs/${id(runUuid)}/requests/${id(reqUuid)}/decide`, { decision, ...opts }),
  sendMessage: (runUuid: string, text: string) => send<RunTurn>('post', `/runs/${id(runUuid)}/turns`, { text }),
  approve: (runUuid: string) => send<Run>('post', `/runs/${id(runUuid)}/approve`),
  reject: (runUuid: string, reason?: string) => send<Run>('post', `/runs/${id(runUuid)}/reject`, reason ? { reason } : {}),

  // Settings
  getSettings: async () => (await get<Settings>('/settings')).data,
  saveSettings: (s: Settings) => send<Settings>('put', '/settings', s),
  getProjectSettings: async (projectUuid: string) => (await get<ProjectSettings>(`/projects/${id(projectUuid)}/settings`)).data,
  saveProjectSettings: (projectUuid: string, s: ProjectSettings) => send<ProjectSettings>('put', `/projects/${id(projectUuid)}/settings`, s),
  getTemplate: async () => (await get<Template>('/template')).data,
  saveTemplate: (body: string) => send<Template>('put', '/template', { body }),
};

export default aiRunner;
