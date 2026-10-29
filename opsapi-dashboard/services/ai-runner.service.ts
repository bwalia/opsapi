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
  /** §28 built-in runner: "owner/name", or what "none" means. */
  label?: string;
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
/**
 * §27.1: a runner runs tasks and reports sessions; a source only reports sessions (it can't claim runs). §28: every
 * workspace also has one built-in runner, inside OpsAPI (no machine, no token).
 */
export type ConnectionKind = 'runner' | 'source' | 'builtin';
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
  executor_kind?: string | null;
  provider_uuid?: string | null;
  context_snapshot?: ContextSnapshot | null;
  conversation_summary?: string | null;
  jobshout_run_id?: string | null;
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
export interface SkillGitUrl {
  url: string;
  ref?: string | null;
  path?: string | null;
  label?: string | null;
}
export interface MdRef {
  path?: string | null;
  url?: string | null;
  label?: string | null;
}
export interface ContextSnapshot {
  target_repo_url?: string | null;
  base_branch?: string | null;
  skills_git_urls?: SkillGitUrl[];
  md_refs?: MdRef[];
  vault_configured?: boolean;
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
  context?: ContextSnapshot | null;
  project?: ProjectSettings | null;
  executor_kind?: string | null;
  allowed_executors?: string[];
  executor_locked?: boolean;
  can_change_executor?: boolean;
  /** Web terminals the person can work in themselves, and the prompt their agent starts with. */
  terminals?: TerminalOffer[];
  terminal_prompt?: string | null;
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
  executor_kind?: string;
  provider_uuid?: string;
  selected_skill_urls?: string[];
  selected_md?: string[];
}
export interface TaskWork {
  uuid: string;
  task_uuid: string;
  project_uuid: string;
  run_uuid?: string | null;
  status: string;
  executor_kind: string;
  provider_uuid?: string | null;
  prompt: string;
  context_snapshot?: ContextSnapshot;
  conversation_summary?: string | null;
  summary?: string | null;
  requested_by?: string | null;
  created_at: string;
  updated_at?: string;
}
export interface TaskPr {
  uuid: string;
  task_uuid: string;
  project_uuid: string;
  run_uuid?: string | null;
  repo: string;
  pr_url: string;
  pr_number?: number | null;
  state: string;
  review_status: 'pending' | 'approved' | 'changes_requested' | string;
  reviewed_by?: string | null;
  reviewed_at?: string | null;
  review_note?: string | null;
  created_at: string;
}
/** An agent people may pick for a web terminal; the terminal's own config says what it runs. */
export interface TerminalAgent {
  id: string;
  label: string;
  /** Works without stopping to ask (an id ending in _auto, or marked so): only AI runs managers can start it. */
  unattended?: boolean;
}
/** A web terminal connected to this workspace (docs/AI_RUNNER_WEB_TERMINAL.md). The secret is never listed. */
export interface WebTerminal {
  uuid: string;
  name: string;
  url: string;
  agents: TerminalAgent[];
  is_active: boolean;
  /** §8: power users may be signed in to it by Start with AI (the terminal's own config must allow them too). */
  autologin: boolean;
  secret_hint?: string | null;
  created_at?: string;
  updated_at?: string;
  /** §12: is the terminal in touch with OpsAPI? */
  connection?: TerminalConnection;
}
/**
 * §12: connected (called within 2 minutes) · lost (was in touch, not lately) · waiting (never called) · secret (it
 * calls with a different secret) · clock (right secret, clock more than 5 minutes off).
 */
export interface TerminalConnection {
  state: 'connected' | 'lost' | 'waiting' | 'secret' | 'clock';
  seen_secs_ago?: number | null;
  refused_secs_ago?: number;
}
/** §10: a key a manager issued someone for a terminal (only its public half is kept). */
/** A terminal the signed-in person holds a live key for: what they need to sign in to it. */
export interface MyTerminal {
  uuid: string;
  name: string;
  url: string;
  /** Start with AI can sign them in from a task after an emailed code. */
  autologin: boolean;
  terminal_user: string;
  expires_at: string;
}

export interface TerminalAccessKey {
  uuid: string;
  user_uuid: string;
  person_name: string | null;
  person_email: string | null;
  /** Who they are on the terminal. */
  terminal_user: string;
  fingerprint: string;
  created_at: string;
  created_by_name: string | null;
  expires_at: string;
  revoked_at: string | null;
  revoked_by_name: string | null;
  /** Suspended: signed out and kept out until a manager resumes the key. */
  suspended_at?: string | null;
  suspended_by_name?: string | null;
  /** left = left the workspace or was deactivated; replaced = a newer key was issued. */
  status: 'active' | 'suspended' | 'expired' | 'blocked' | 'replaced' | 'left';
}
export interface TerminalKeyPerson {
  uuid: string;
  name: string | null;
  email: string | null;
}
/** What Start with AI offers for a terminal: its agents and the folders used before for this project. */
export interface TerminalOffer {
  uuid: string;
  name: string;
  url: string;
  agents: TerminalAgent[];
  autologin?: boolean;
  default_path?: string | null;
  recent_paths: string[];
}
export interface TerminalSession {
  uuid: string;
  task_uuid: string;
  project_uuid: string;
  opened_by?: string | null;
  opened_by_name?: string | null;
  terminal_uuid?: string | null;
  terminal_name?: string | null;
  terminal_url: string;
  path?: string | null;
  agent?: string | null;
  agent_label?: string | null;
  terminal_user?: string | null;
  session_id?: string | null;
  repo_url?: string | null;
  /** §8: the person was signed in to the terminal by OpsAPI. */
  autologin?: boolean;
  /** §9: when the agent last reported (a pull request or a note). */
  reported_at?: string | null;
  /** launched (link not used yet) → active → ended; expired = the link was never used in time. */
  status: 'launched' | 'active' | 'ended' | 'expired' | string;
  started_at?: string | null;
  ended_at?: string | null;
  exit_code?: number | null;
  created_at: string;
  /** §11: the tab's work log, once the terminal reported it. */
  work_log?: { uuid: string; active_secs: number; prompts: number; tokens: number; cost_usd: number } | null;
}
/** §11: one terminal tab in the work log, with its totals. */
export interface WorkLogTab {
  uuid: string;
  tab_id: string;
  terminal_name: string | null;
  user_uuid: string | null;
  person_name: string | null;
  person_email: string | null;
  /** Who they were on the terminal (always known, even without an OpsAPI person). */
  terminal_user: string | null;
  /** key | opsapi_launch */
  via: string | null;
  ip: string | null;
  kind: string | null;
  cwd: string | null;
  agent: string | null;
  session_uuid: string | null;
  task_uuid: string | null;
  task_number: number | null;
  task_title: string | null;
  opened_at: string | null;
  closed_at: string | null;
  open: boolean;
  end_reason: string | null;
  exit_code: number | null;
  duration_secs: number;
  active_secs: number;
  input_bytes: number;
  output_bytes: number;
  prompts: number;
  requests: number;
  tool_calls: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  cost_usd: number;
  lines_added: number;
  lines_removed: number;
  commits: number;
  pull_requests: number;
  recording_parts: number;
  recording_bytes: number;
  /** When someone last typed in it, when the terminal last reported it, whether a browser shows it (newer terminals). */
  last_input_at?: string | null;
  seen_at?: string | null;
  attached?: boolean | null;
}
/** Someone working in a terminal right now: an open tab the terminal reported in the last 3 minutes. */
export interface WorkLogLive {
  uuid: string;
  user_uuid: string | null;
  person_name: string | null;
  person_email: string | null;
  terminal_user: string | null;
  terminal_uuid: string | null;
  terminal_name: string | null;
  task_uuid: string | null;
  task_number: number | null;
  task_title: string | null;
  project_uuid: string | null;
  cwd: string | null;
  agent: string | null;
  via: string | null;
  opened_at: string | null;
  last_input_at: string | null;
  /** Seconds since they last typed (null: nothing typed yet, or an older terminal). */
  idle_secs: number | null;
  seen_at: string | null;
  /** A browser shows the tab (false: it runs on with nobody looking). */
  attached: boolean | null;
  /** Their live key on that terminal (only for ai_runners.manage): what Suspend acts on. */
  key_uuid?: string | null;
}
export interface WorkLogOptions {
  terminals: { uuid: string; name: string }[];
  agents: TerminalAgent[];
}
/** user_prompt | api_request | api_error | tool_result | tool_decision | metric */
export interface WorkLogEvent {
  id: string;
  at: string;
  type: string;
  session: string | null;
  prompt_id: string | null;
  model: string | null;
  tool_name: string | null;
  success: boolean | null;
  input_tokens: number | null;
  output_tokens: number | null;
  cache_read_tokens: number | null;
  cache_write_tokens: number | null;
  cost_usd: number | null;
  duration_ms: number | null;
  /** The prompt, the command/file details or the error (blanked after text_days). */
  text: string | null;
  attrs: Record<string, string | number | boolean>;
}
export interface WorkLogDetail extends WorkLogTab {
  /** The timeline's first page (oldest first); events_next continues it (workLogEvents). */
  events: WorkLogEvent[];
  events_next?: string | null;
  recording: { part: number; final: boolean; bytes: number; created_at: string }[];
  text_days: number;
  recording_days: number;
}
export interface WorkLogPerson {
  user_uuid: string | null;
  person_name: string | null;
  person_email: string | null;
  terminal_user: string | null;
  tabs: number;
  active_secs: number;
  prompts: number;
  requests: number;
  tool_calls: number;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  lines_added: number;
  lines_removed: number;
  commits: number;
  pull_requests: number;
  last_seen: string | null;
}
export interface WorkLogFilters {
  user_uuid?: string;
  task_uuid?: string;
  from?: string;
  to?: string;
  terminal_uuid?: string;
  state?: 'open' | 'closed';
  agent?: string;
  /** Searches the person's name or email, the folder and the task title. */
  q?: string;
  page?: number;
  per_page?: number;
}
export interface WorkLogEventFilters {
  type?: string;
  q?: string;
  /** The previous page's `next`. */
  after?: string;
  per_page?: number;
}
export interface TerminalLaunch {
  terminal_uuid: string;
  path: string;
  agent: string;
  prompt?: string;
  /** §8: sign me in to the terminal (needs ai_terminal_autologin and a live step-up). */
  autologin?: boolean;
}
/** §8: may this person be signed in to web terminals automatically, and their emailed-code step-up (unix seconds). */
export interface TerminalAutologin {
  allowed: boolean;
  stepup: { verified_at: number; expires_at: number } | null;
}
export interface TaskWorkBundle {
  work: TaskWork | null;
  history: TaskWork[];
  pull_requests: TaskPr[];
  terminal_sessions?: TerminalSession[];
  project?: ProjectSettings | null;
  manager_links?: {
    task_url?: string | null;
    run_url?: string | null;
    pr_urls?: string[];
  } | null;
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
  task_automation: {
    on_start: TaskMove; on_success: TaskMove;
    /** Web terminal §9: when a pull request is reported for the task, and when GitHub says it merged. */
    on_pr_open: TaskMove; on_pr_merged: TaskMove;
    in_progress_on_start?: boolean; review_on_success?: boolean;
  };
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
  /** §28.3: the GitHub App the built-in runner works through (secrets: only whether they are set). */
  github: GithubApp;
}
export interface GithubApp {
  api_url: string;
  web_url: string;
  app_id: string;
  app_slug: string;
  client_id: string;
  has_client_secret: boolean;
  has_private_key: boolean;
  /** Give GitHub this as the App's callback URL and setup URL. */
  callback_url: string;
  default_api_url: string;
  default_web_url: string;
  configured: boolean;
}
/** What a save of the GitHub App sends: only the keys given change; "" clears one. Secrets are write-only. */
export type GithubAppInput = Partial<Pick<GithubApp, 'api_url' | 'web_url' | 'app_id' | 'app_slug' | 'client_id'>>
  & { client_secret?: string; private_key?: string };
const EMPTY_GITHUB: GithubApp = {
  api_url: '', web_url: '', app_id: '', app_slug: '', client_id: '', has_client_secret: false, has_private_key: false,
  callback_url: '', default_api_url: 'https://api.github.com', default_web_url: 'https://github.com', configured: false,
};
function platform(d: Record<string, unknown>): PlatformSettings {
  // github is its own section (never sent back with the numbers: that would clear the App).
  const { defaults, bounds, updated_at, dashboard_url, dashboard_url_fallback, github, ...rest } = d || {};
  // Every number, and objects of numbers (guard_max); not updated_by.
  const values = Object.fromEntries(Object.entries(rest).filter(([, x]) => typeof x === 'number' || (!!x && typeof x === 'object')));
  return {
    values: values as PlatformValues, defaults: (defaults ?? {}) as PlatformValues,
    bounds: (bounds ?? {}) as PlatformSettings['bounds'], updated_at: updated_at as string | null,
    dashboardUrl: typeof dashboard_url === 'string' ? dashboard_url : '',
    dashboardUrlFallback: typeof dashboard_url_fallback === 'string' ? dashboard_url_fallback : '',
    github: { ...EMPTY_GITHUB, ...(github && typeof github === 'object' ? github as Partial<GithubApp> : {}) },
  };
}

/** §28.3: a GitHub App installation this workspace connected. */
export interface GithubInstallation {
  uuid: string;
  installation_id: number;
  account_login: string | null;
  account_type: string | null;
  repository_selection: string | null;
  created_by_name: string | null;
  created_at: string;
}
export interface GithubStatus {
  /** The platform has a GitHub App set up. */
  configured: boolean;
  can_manage: boolean;
  /** GitHub's page to install the App (or change its repositories); managers only. */
  install_url: string | null;
  installations: GithubInstallation[];
  web_url: string;
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
  project_uuid?: string;
  default_repo_paths?: Record<string, string>;
  output_mode?: OutputMode | null;
  base_branch?: string | null;
  target_repo_url?: string | null;
  skills_git_urls?: SkillGitUrl[];
  md_refs?: MdRef[];
  vault_url?: string | null;
  vault_secret_path?: string | null;
  vault_mount_path?: string | null;
  vault_token_set?: boolean;
  vault_configured?: boolean;
  /** Write-only: send to save; never returned. */
  vault_token?: string | null;
  allowed_executors?: string[];
  executor_locked?: boolean;
  default_executor?: string | null;
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
  meta?: {
    page?: number; per_page?: number; total?: number; total_pages?: number; sees_everyone?: boolean;
    total_capped?: boolean; has_more?: boolean; can_suspend?: boolean; next?: string | null;
  };
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
  preview: (taskUuid: string, input: Partial<StartInput> = {}) =>
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
  taskWork: async (taskUuid: string): Promise<TaskWorkBundle> => {
    const d = (await get<Partial<TaskWorkBundle>>(`/tasks/${id(taskUuid)}/work`)).data || {};
    return {
      work: (d.work as TaskWork) || null,
      history: list<TaskWork>(d.history),
      pull_requests: list<TaskPr>(d.pull_requests),
      terminal_sessions: list<TerminalSession>(d.terminal_sessions),
      project: d.project ?? null,
      manager_links: d.manager_links ?? null,
    };
  },
  taskPrs: async (taskUuid: string) => list<TaskPr>((await get<TaskPr[]>(`/tasks/${id(taskUuid)}/prs`)).data),
  reviewPr: (taskUuid: string, prUuid: string, decision: 'approved' | 'changes_requested', note?: string) =>
    send<TaskPr>('post', `/tasks/${id(taskUuid)}/prs/${id(prUuid)}/review`, { decision, note }),
  /** Records the launch and returns the link that opens the terminal in the folder (valid 15 minutes; 2 with autologin). */
  launchTerminal: (taskUuid: string, input: TerminalLaunch) =>
    send<{ session: TerminalSession; launch_url: string }>('post', `/tasks/${id(taskUuid)}/terminal-sessions`, input),
  listTerminalSessions: async (taskUuid: string) =>
    list<TerminalSession>((await get<TerminalSession[]>(`/tasks/${id(taskUuid)}/terminal-sessions`)).data),

  // Auto sign-in step-up (§8): email a code, confirm it, remembered for 12 hours.
  terminalAutologin: async () => (await get<TerminalAutologin>('/terminal-autologin')).data,
  sendAutologinCode: () => send<{ sent: boolean }>('post', '/terminal-autologin/code'),
  verifyAutologinCode: (code: string) => send<TerminalAutologin>('post', '/terminal-autologin/verify', { code }),
  forgetAutologin: () => send<TerminalAutologin>('delete', '/terminal-autologin'),

  // Web terminals (ai_runners.manage); the secret comes back only when added or rotated.
  listTerminals: async () => list<WebTerminal>((await get<WebTerminal[]>('/terminals')).data),
  addTerminal: (body: { name: string; url: string; agents?: TerminalAgent[]; autologin?: boolean }) =>
    send<{ terminal: WebTerminal; secret: string }>('post', '/terminals', body),
  updateTerminal: (uuid: string, body: Partial<Pick<WebTerminal, 'name' | 'url' | 'agents' | 'is_active' | 'autologin'>>) =>
    send<WebTerminal>('put', `/terminals/${id(uuid)}`, body),
  rotateTerminalSecret: (uuid: string) =>
    send<{ terminal: WebTerminal; secret: string }>('post', `/terminals/${id(uuid)}/rotate-secret`),
  deleteTerminal: (uuid: string) => send<unknown>('delete', `/terminals/${id(uuid)}`),
  // §10: keys managers issue people for a terminal. The key pair is made in the browser (lib/ssh-key.ts).
  terminalKeys: async (uuid: string) =>
    (await get<{ keys: TerminalAccessKey[]; people: TerminalKeyPerson[] }>(`/terminals/${id(uuid)}/keys`)).data,
  issueTerminalKey: (uuid: string, body: { user_uuid: string; public_key: string }) =>
    send<TerminalAccessKey>('post', `/terminals/${id(uuid)}/keys`, body),
  blockTerminalKey: (uuid: string, keyUuid: string) =>
    send<{ blocked: boolean }>('post', `/terminals/${id(uuid)}/keys/${id(keyUuid)}/block`),
  /** Sign the person out now and keep them out until resumed (the same key works again after Resume). */
  suspendTerminalKey: (uuid: string, keyUuid: string) =>
    send<TerminalAccessKey>('post', `/terminals/${id(uuid)}/keys/${id(keyUuid)}/suspend`),
  resumeTerminalKey: (uuid: string, keyUuid: string) =>
    send<TerminalAccessKey>('post', `/terminals/${id(uuid)}/keys/${id(keyUuid)}/resume`),
  /** Anyone in the workspace: the terminals they hold a key for. */
  myTerminals: async () => (await get<MyTerminal[]>('/my-terminals')).data,

  // Work log (§11): everyone's with ai_terminal_worklogs.read, else only your own.
  workLog: async (f: WorkLogFilters = {}) => {
    const res = await get<WorkLogTab[]>(`/work-log${buildQueryString({ ...f })}`);
    return {
      ...paged<WorkLogTab>(res, f),
      seesEveryone: res.meta?.sees_everyone === true,
      /** More match than the total says (it counts up to 1000). */
      totalCapped: res.meta?.total_capped === true,
      hasMore: res.meta?.has_more === true,
    };
  },
  workLogOptions: async (): Promise<WorkLogOptions> => {
    const d = (await get<WorkLogOptions>('/work-log/options')).data;
    return { terminals: list(d?.terminals), agents: list(d?.agents) };
  },
  /** Who is working in a terminal right now (yours, or everyone's with "Web terminal work logs"). */
  workLogLive: async () => {
    const res = await get<WorkLogLive[]>('/work-log/live');
    return { items: list<WorkLogLive>(res.data), seesEveryone: res.meta?.sees_everyone === true,
      canSuspend: res.meta?.can_suspend === true };
  },
  workLogPeople: async (f: Pick<WorkLogFilters, 'from' | 'to'> = {}) =>
    list<WorkLogPerson>((await get<WorkLogPerson[]>(`/work-log/people${buildQueryString({ ...f })}`)).data),
  workLogTab: async (uuid: string) => {
    const d = (await get<WorkLogDetail>(`/work-log/tabs/${id(uuid)}`)).data;
    return { ...d, events: list<WorkLogEvent>(d?.events), recording: list<WorkLogDetail['recording'][number]>(d?.recording) };
  },
  /** A page of a session's timeline, oldest first; `next` continues it (null: that was the last page). */
  workLogEvents: async (uuid: string, f: WorkLogEventFilters = {}) => {
    const res = await get<WorkLogEvent[]>(`/work-log/tabs/${id(uuid)}/events${buildQueryString({ ...f })}`);
    return { items: list<WorkLogEvent>(res.data), next: res.meta?.next ?? null };
  },
  /** One gzipped asciicast part of a tab's screen recording. */
  workLogRecordingPart: async (uuid: string, part: number) =>
    (await apiClient.get<ArrayBuffer>(`${BASE}/work-log/tabs/${id(uuid)}/recording/${part}`,
      { responseType: 'arraybuffer' })).data,

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
  /** §28.3: the GitHub App alone (null clears all of it). */
  saveGithubApp: async (g: GithubAppInput | null) =>
    platform(await send<Record<string, unknown>>('put', '/platform/settings', { github: g })),

  // §28.3 GitHub for the built-in runner: the workspace's installations.
  github: async (): Promise<GithubStatus> => {
    const d = (await get<GithubStatus>('/github')).data;
    return { ...d, installations: list<GithubInstallation>(d.installations) };
  },
  /** The GitHub sign-in that proves the person can reach the installation GitHub just named. */
  githubAuthorize: (installationId: number) => send<{ url: string }>('post', '/github/authorize', { installation_id: installationId }),
  githubConnect: (code: string, state: string) => send<GithubInstallation>('post', '/github/installations', { code, state }),
  githubDisconnect: (uuid: string) => send<unknown>('delete', `/github/installations/${id(uuid)}`),
  /** The runners list, with the built-in runner's repositories read from GitHub again. */
  refreshRunners: async () => list<Runner>((await get<Runner[]>('/runners?refresh=1')).data),
};

export default aiRunner;
