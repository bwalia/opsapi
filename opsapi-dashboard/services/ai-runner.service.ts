/**
 * AI Runs (OpsAPI plugin projects/ai-runner) — typed client for the dashboard pages.
 * Contract: docs/AI_RUNNER.md §22.3, §23.3, §24, §25, §26 and §27 (user API, session JWT). Requests go through apiClient
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
  /** Phase 4 health check on the machine: false = takes no work (logged out, locked). Missing = available. */
  available?: boolean;
  unavailable_reason?: string | null;
}
export interface RunnerRepo {
  path: string;
  remote?: string;
  branch?: string;
  dirty?: boolean;
}
/**
 * Who may start runs on a runner (§25.1). owner: its owner and AI-run managers; everyone: anyone who may start runs;
 * listed: owner, managers, plus these users and these kanban projects (uuids).
 */
export type RunnerAccessMode = 'owner' | 'everyone' | 'listed';
export interface RunnerAccess {
  mode: RunnerAccessMode;
  users?: string[];
  projects?: string[];
}
/** §27.1: a runner runs tasks and reports sessions; a source only reports sessions (it can't claim runs). */
export type ConnectionKind = 'runner' | 'source';
/**
 * §27.2: what a connection reports, narrowing what its machine owner allows (inventory_roots). Empty = everything
 * the owner allows.
 */
export interface ReportFilter {
  folders: string[];
  exclude_folders: string[];
  tools: string[];
}
export interface Runner {
  uuid: string;
  name: string;
  status: RunnerStatus;
  /** Missing on connections registered before §27: a runner. */
  kind?: ConnectionKind;
  report_filter?: Partial<ReportFilter> | null;
  host?: string | null;
  os?: string | null;
  version?: string | null;
  labels?: string[] | Record<string, unknown> | null;
  capabilities?: { max_concurrency?: number; profiles?: RunnerProfile[] } | null;
  repos?: RunnerRepo[] | null;
  last_heartbeat_at?: string | null;
  created_at?: string;
  /** Only shown to ai_runners.manage. */
  access?: RunnerAccess | null;
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
  /** false: "Allow for this run" is not offered (a chained or redirected command, §25.2). */
  rememberable?: boolean;
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

/** GET /sessions (§24.4): one session a runner reported, across the workspace's runners. */
export interface MachineSession {
  key?: string;
  runner?: { uuid: string; name?: string; status?: string } | null;
  tool?: string | null;
  status?: string | null;
  cwd?: string | null;
  branch?: string | null;
  managed?: boolean;
  run?: { uuid: string; task_title?: string | null; task_number?: number | null } | null;
  /** §26: the task created for a session started by hand, once tracking picked it up. */
  task?: { uuid: string; task_number?: number | null; title?: string | null; project_uuid?: string | null } | null;
  prompt_preview?: string | null;
  updated_at?: string | null;
  seen_at?: string | null;
}
export interface SessionFilters {
  runner_uuid?: string;
  busy?: boolean;
  page?: number;
  per_page?: number;
}

/** An open run on a task whose title is close to this one (§24.2). */
export interface SimilarRun {
  run_uuid: string;
  task_uuid?: string;
  task_number?: number | null;
  task_title?: string | null;
  status?: string;
  requested_by_name?: string | null;
  similarity?: number;
}
/** Open-run caps and today's agent tokens; a max/limit of 0 means none. */
export interface Limits {
  user_open: number;
  user_max: number;
  workspace_open: number;
  workspace_max: number;
  tokens_today: number;
  daily_token_limit: number;
}
export interface Conflicts {
  open_run?: (Partial<Run> & { uuid?: string }) | null;
  folder_lock?: { run_uuid?: string; since?: string; holder?: string; message?: string } | null;
  busy_session?: Partial<RunnerSession> & { message?: string } | null;
  /** Not a block: starting anyway needs confirm_similar. */
  similar?: SimilarRun[] | null;
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
  limits?: Limits | null;
}
export interface StartInput {
  runner_uuid: string;
  profile: string;
  model?: string;
  repo_path: string;
  prompt?: string;
  output_mode?: OutputMode;
  /** The user saw the similar open runs and starts anyway. */
  confirm_similar?: boolean;
}

export interface ApprovalPolicy {
  deciders: 'requester' | 'managers' | 'requester_or_managers';
  /** Owners and admins of the task's project count as managers too (§25.1). */
  project_admins_decide: boolean;
  require_start_approval: boolean;
  permission_timeout_minutes: number;
  input_timeout_minutes: number;
}
/** Limits and safeguards (§24.1); 0 = no cap / no limit. */
export interface Guards {
  /** 0.1–1.0 */
  similar_threshold: number;
  max_open_runs_per_user: number;
  max_open_runs_per_workspace: number;
  daily_token_limit: number;
  retention_days: number;
}
/** A kanban task status (task automation moves a run's task to one). */
export type KanbanStatus = 'open' | 'in_progress' | 'blocked' | 'review' | 'completed' | 'cancelled';
/** §27.4: move the run's task when a run starts / succeeds; column is a column name, null = leave it where it is. */
export interface TaskMove {
  enabled: boolean;
  status: KanbanStatus;
  column: string | null;
}
/**
 * §26: a busy session started by hand on a runner becomes an unassigned task in this project — the default target
 * when no routing rule matches (§27.3), plus the §27.4 tunables.
 */
export interface SessionTracking {
  enabled: boolean;
  /** A kanban project of the workspace; required when enabled. */
  project_uuid: string | null;
  /** A column name on the project's first board; null = its first column. */
  column: string | null;
  status: 'todo' | 'in_progress';
  /** Tell managers about each new task. */
  notify: boolean;
  /** A tracked session nobody reports for this long has ended (1–1440). */
  gone_after_minutes: number;
  /** New tasks one heartbeat may create (1–100, and at most the platform's cap); the rest wait for the next. */
  max_new_per_heartbeat: number;
  /** Session statuses that don't count as busy. */
  idle_statuses: string[];
  /** tool → the name {{tool_label}} and default titles use. */
  tool_labels: Record<string, string>;
}
/** §27.4: added to the built-in safety list and redaction; the built-in rules can't be removed. */
export interface Safety {
  /** Command prefixes or globs runners deny, like their built-in safety list. */
  extra_denied_commands: string[];
  /** Regular expressions the server masks, like its built-in secret patterns. */
  extra_redactions: string[];
}
export interface Settings {
  output_mode: OutputMode;
  pr_draft: boolean;
  pr_base: string;
  max_run_minutes: number;
  /** on_start / on_success (§27.4); the old booleans are still read when they are missing. */
  task_automation: { on_start: TaskMove; on_success: TaskMove; in_progress_on_start?: boolean; review_on_success?: boolean };
  approval_policy: ApprovalPolicy;
  guards: Guards;
  session_tracking: SessionTracking;
  safety: Safety;
  /** §27.5: the platform's current upper bounds (read-only; GET only). */
  limits?: SettingsLimits;
}

export interface SettingsLimits {
  max_run_minutes: number;
  max_new_per_heartbeat: number;
  guards: { max_open_runs_per_user: number; max_open_runs_per_workspace: number; daily_token_limit: number; retention_days: number };
}

/** §27.3: which sessions a routing rule applies to; an empty list matches any. */
export interface TrackRuleMatch {
  runner_uuids: string[];
  tools: string[];
  folder_globs: string[];
  branch_globs: string[];
  prompt_keywords: string[];
}
export type TrackNotify = 'managers' | 'assignees' | 'none' | 'users';
export type TaskPriority = 'critical' | 'high' | 'medium' | 'low' | 'none';
/** What happens to a matching session: a task (where, for whom, titled how, who hears) or nothing. */
export interface TrackRuleAction {
  type: 'create_task' | 'ignore';
  project_uuid: string | null;
  column: string | null;
  status: 'todo' | 'in_progress';
  priority: TaskPriority | null;
  /** Empty = unassigned. */
  assignee_uuids: string[];
  /** Empty = the default title / description (§26.3). */
  title_template: string;
  description_template: string;
  notify: TrackNotify;
  notify_user_uuids: string[];
}
/** Rules are ordered per workspace; the first enabled one that matches wins. */
export interface TrackRule {
  uuid: string;
  /** Optional, for people ("" = none). */
  name?: string;
  position?: number;
  enabled: boolean;
  match: TrackRuleMatch;
  action: TrackRuleAction;
}
export type TrackRuleInput = Omit<TrackRule, 'uuid' | 'position'>;
/** A sample session for the rule tester (as a heartbeat reports one). */
export interface SampleSession {
  tool?: string;
  cwd?: string;
  branch?: string;
  first_prompt?: string;
  runner_uuid?: string;
}
/** POST /track-rules/test: the rule that matched (null = none: the workspace default applies), and the task it makes. */
export interface TrackRuleTest {
  rule: TrackRule | null;
  action: TrackRuleAction | null;
  title: string | null;
  description: string | null;
}

/** §27.5: platform-wide timings and limits — numbers, and the workspace guards' upper bounds under guard_max. */
export type PlatformValues = Record<string, number | Record<string, number>>;
export type Bounds = { min: number; max: number };
export interface PlatformSettings {
  values: PlatformValues;
  /** As the server checks them; may be missing from an older server. */
  defaults: PlatformValues;
  bounds: Record<string, Bounds | Record<string, Bounds>>;
  updated_at?: string | null;
  /** Where task links point ("" = the deployment's FRONTEND_URL, given as dashboardUrlFallback). */
  dashboardUrl: string;
  dashboardUrlFallback: string;
}
function platform(d: Record<string, unknown>): PlatformSettings {
  const { defaults, bounds, updated_at, dashboard_url, dashboard_url_fallback, ...rest } = d || {};
  // Every number, and objects of numbers (guard_max); not updated_by.
  const values = Object.fromEntries(Object.entries(rest).filter(([, x]) => typeof x === 'number' || (!!x && typeof x === 'object')));
  return {
    values: values as PlatformValues, defaults: (defaults ?? {}) as PlatformValues,
    bounds: (bounds ?? {}) as PlatformSettings['bounds'], updated_at: updated_at as string | null,
    dashboardUrl: typeof dashboard_url === 'string' ? dashboard_url : '',
    dashboardUrlFallback: typeof dashboard_url_fallback === 'string' ? dashboard_url_fallback : '',
  };
}

/** GET /overview (§24.5): numbers for managers. */
export interface Overview {
  runs_by_status: Record<string, number>;
  queue_depth: number;
  runners: { online: number; offline: number; paused: number };
  tokens_today: number;
  cost_today: number;
  runs_7d: { succeeded: number; failed: number; cancelled: number; lost: number };
  /** null when nothing was decided in the last 7 days. */
  avg_permission_wait_s_7d: number | null;
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
  const said = errorMessage(body);
  // §25.1: the runner's access list doesn't include the caller (start, preview, retry).
  if (status === 403 && /use this runner/i.test(said || '')) {
    return { status, code, message: "You can't use this runner. Choose another one, or ask an AI-run manager to give you access to it (Runners → Access)." };
  }
  return { status, code, conflict: body.conflict, message: said || fallback[status] || 'The request failed.' };
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

function paged<T>(res: Envelope<T[]>, f: { page?: number; per_page?: number }): Page<T> {
  const items = list<T>(res.data);
  const total = Number(res.meta?.total ?? items.length);
  const perPage = Number(res.meta?.per_page ?? f.per_page ?? (items.length || 1));
  return {
    items,
    page: Number(res.meta?.page ?? f.page ?? 1),
    total,
    totalPages: Number(res.meta?.total_pages ?? Math.max(1, Math.ceil(total / perPage))),
  };
}

// Idempotency-Key per start attempt: retrying the same request after it got no answer reuses the
// key (the server replays its first answer); any answer from the server ends the attempt.
const pendingStarts = new Map<string, { body: string; key: string }>();

export const aiRunner = {
  // Runners
  listRunners: async () => list<Runner>((await get<Runner[]>('/runners')).data),
  registerRunner: (name: string, kind: ConnectionKind = 'runner') =>
    send<{ runner: Runner; token: string }>('post', '/runners', { name, kind }),
  rotateToken: (uuid: string) => send<{ token: string; runner?: Runner }>('post', `/runners/${id(uuid)}/rotate-token`),
  pauseRunner: (uuid: string) => send<Runner>('post', `/runners/${id(uuid)}/pause`),
  resumeRunner: (uuid: string) => send<Runner>('post', `/runners/${id(uuid)}/resume`),
  revokeRunner: (uuid: string) => send<unknown>('delete', `/runners/${id(uuid)}`),
  setRunnerAccess: (uuid: string, access: RunnerAccess) => send<Runner>('put', `/runners/${id(uuid)}/access`, access),
  setReportFilter: (uuid: string, f: ReportFilter) => send<Runner>('put', `/runners/${id(uuid)}`, { report_filter: f }),
  runnerSessions: async (uuid: string) => list<RunnerSession>((await get<RunnerSession[]>(`/runners/${id(uuid)}/sessions`)).data),
  /** Phase 4: every session of every runner (Machines page). */
  sessions: async (f: SessionFilters = {}): Promise<Page<MachineSession>> =>
    paged<MachineSession>(await get<MachineSession[]>(`/sessions${buildQueryString({ ...f, busy: f.busy ? 1 : undefined })}`), f),
  overview: async () => (await get<Overview>('/overview')).data,

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
  listRuns: async (f: RunFilters = {}): Promise<Page<Run>> =>
    paged<Run>(await get<Run[]>(`/runs${buildQueryString({ ...f, mine: f.mine ? 1 : undefined })}`), f),
  /**
   * GET /runs/:uuid — accepts `{ run, events, … }` or the run with those fields inline. Usage totals are the
   * run's own columns, or a `usage` object.
   */
  getRun: async (uuid: string): Promise<RunDetail> => {
    const d = (await get<Record<string, unknown>>(`/runs/${id(uuid)}`)).data;
    const run = ((d.run as Run) ?? d) as Run;
    const field = (k: string) => d[k] ?? (run as unknown as Record<string, unknown>)[k];
    const usage = field('usage') as Partial<Usage> | undefined;
    const u = { ...run, ...usage };
    const turns = [...list<RunTurn>(field('turns'))].sort((a, b) => a.seq - b.seq);
    // Inlined, the turn list takes the name of the run's turn count: then count the agent's turns.
    const turnCount = usage?.turns ?? (Array.isArray(run.turns) ? turns.filter((t) => t.role === 'assistant').length : run.turns);
    return {
      run: { ...run, task: (d.task as RunTask) ?? run.task, runner: (d.runner as Runner) ?? run.runner },
      events: [...list<RunEvent>(field('events'))].sort((a, b) => a.seq - b.seq),
      requests: list<RunRequest>(field('requests')),
      turns,
      usage: {
        tokens_in: num(u.tokens_in), tokens_out: num(u.tokens_out), cache_read: num(u.cache_read),
        cache_write: num(u.cache_write), cost_estimate: num(u.cost_estimate), turns: num(turnCount),
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

  // §27.3 routing rules for sessions started by hand (ai_runs_settings.manage), in order.
  listTrackRules: async () => list<TrackRule>((await get<TrackRule[]>('/track-rules')).data),
  createTrackRule: (r: TrackRuleInput) => send<TrackRule>('post', '/track-rules', r),
  updateTrackRule: (uuid: string, r: Partial<TrackRuleInput>) => send<TrackRule>('put', `/track-rules/${id(uuid)}`, r),
  deleteTrackRule: (uuid: string) => send<unknown>('delete', `/track-rules/${id(uuid)}`),
  orderTrackRules: (uuids: string[]) => send<TrackRule[]>('post', '/track-rules/order', { uuids }),
  testTrackRules: (session: SampleSession) => send<TrackRuleTest>('post', '/track-rules/test', { session }),

  // §27.5 platform settings (platform admins only).
  getPlatformSettings: async () => platform((await get<Record<string, unknown>>('/platform/settings')).data),
  /** Only the keys given change. */
  savePlatformSettings: async (v: PlatformValues, dashboardUrl?: string) =>
    platform(await send<Record<string, unknown>>('put', '/platform/settings', dashboardUrl === undefined ? v : { ...v, dashboard_url: dashboardUrl })),
};

export default aiRunner;
