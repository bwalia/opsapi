# AI Task Runner — design

**Status:** draft for approval (Step 0). No code is written until this document is approved.
**Branch:** `feat/ai-task-runner` (opsapi) · PromptPilot changes go to `bwalia/promptpilot` on their own branch.
**Date:** 2026-10-12

A user asks the OpsAPI assistant for today's tasks, opens one and presses **Start with AI**. OpsAPI writes the prompt and hands
the task to an AI coding agent (Claude Code or Cursor) running on a machine of that workspace — the Mac Studio or any server
— through **PromptPilot**. The agent works in the chosen repo folder on a new branch (never `main`), asks OpsAPI before every risky step, and ends with a PR to `main`.
Managers watch every run live (prompt, turns, tokens, requests, machine) and the system refuses to start the same work twice.
Any MCP-capable agent can list, create and update OpsAPI tasks by URL with a personal key.

---

## 1. Requirements

| # | Requirement (client) | Where it is met |
|---|---|---|
| R1 | Connectivity between OpsAPI and PromptPilot | §3, §14 (PromptPilot runner mode) |
| R2 | "What are my tasks today?" lists my tasks by priority | §16.1, Phase 1 |
| R3 | Click a task → Start → OpsAPI generates the prompt and runs it on Claude / Cursor on the Mac Studio or any server | §4.2, §10, §14 |
| R4 | Managers see which task is running and its prompt | §16.3 |
| R5 | Check everything running on the machines to avoid conflicts and duplicate work | §9 |
| R6 | MCP can add tasks; the OpsAPI MCP works from any agent | §15 |

| # | Decision (client) | Consequence |
|---|---|---|
| D1 | Projects are managed in OpsAPI kanban; the repo is cloned on the Mac Studio and **the user gives the folder when starting a task** | The Start dialog asks for the repo folder (suggestions: repos the runner found under its allowed folders, and the last folder used for that project); the runner validates it (§4.2, §14) |
| D2 | Ask permission for risky steps; track every session (who sent which prompt, every request, tokens per turn) | Permission bridge (§7), `ar_run_turns` / `ar_run_requests`, usage metering (§8). Never bypass permissions |
| D3 | Output configurable in the dashboard | `output_mode` = `pull_request` (draft/ready) · `branch` · `local`, workspace default + project override (§11) |
| D4 | Assignee and managers start runs; full RBAC | RBAC matrix (§12) |
| D5 | Runners are per workspace | A runner token binds to exactly one workspace; one machine may host several registrations, isolated (§14.3) |
| D6 | Use what the Mac Studio has: Claude Code (Max plan), Cursor, Ollama — **no API key, no extra spend** | Claude runs authenticate with the Max subscription only (`claude setup-token`); the runner removes any API key from the agent's environment (§8) |
| D7 | Permission requests are decided by managers by default, configurable from the admin dashboard | `approval_policy` in workspace settings (dashboard), with a per-project override (§12) |
| D8 | PromptPilot stays an observer, reachable at `https://promptpilot.workstation.co.uk/` (basic auth) and on the Mac Studio in `/Users/balinderwalia/projects/promptpilot` | Runner mode is added to that code; the observer and its public URL stay as they are (§14) |

---

## 2. Verified facts (2026-10-12) and what differs from the brief

Confirmed as stated: kanban schema and checks, `GET /api/v2/kanban/my-tasks` (priority sort, no due/status/priority filter,
reads `perPage`), `list_my_tasks` assistant tool without `project_uuid`, assistant links open new tabs
(`AgentPane.tsx:43`), MCP server stdio-only with six tools, personal keys admin-minted (`routes/api-keys.lua:99`),
`Llm.chat` `record()` is local (`lib/agent/llm.lua:522`), `ChatWS.push_user` / `relay` (`lib/chat-ws.lua:163,189`),
plugin job leases renewed by heartbeat (`helper/plugin-jobs.lua:206`), kanban project roles
`owner|admin|member|viewer|guest`, `task_number` unique per board.

New or different:

| Fact | Impact |
|---|---|
| PromptPilot's source is on the Mac Studio (`/Users/balinderwalia/projects/promptpilot`, remote `bwalia/promptpilot`, private) | Runner mode is developed there; commits are pushed with the Mac Studio's own GitHub login |
| `https://promptpilot.workstation.co.uk/` answers 401 without credentials (basic auth); `/healthz` is open | The observer stays public behind basic auth |
| PromptPilot is started with `nohup` from `restart.sh`, not launchd; `ADDR=0.0.0.0:8095` with basic auth | Runner mode ships a launchd LaunchAgent; recommend binding the observer to 127.0.0.1 |
| Over SSH, `cursor-agent` fails: **"Your macOS login keychain is locked."** Claude Code is logged in with a claude.ai subscription (`authMethod: claude.ai`, Max plan) | Claude: `claude setup-token` ("Set up a long-lived authentication token (requires Claude subscription)") creates a login token **for the Max plan — not an API key, no API billing**; the runner passes it as `CLAUDE_CODE_OAUTH_TOKEN` from a 0600 file, so Claude runs need no keychain. Cursor: the runner runs as a **LaunchAgent in the logged-in user's GUI session** (`gui/501`, like the 12 GitHub Actions runners and `com.kubepilot.server` already there), so the keychain is open while the Mac is logged in. Verified in Phase 2/3 from that context |
| Claude Code **2.1.296** (headless flags below). `--bare` reads no keychain (API key only) → not usable with the subscription | Use normal print mode |
| Claude Code supports `--session-id <uuid>` | The Claude session id **is** the OpsAPI run uuid → PromptPilot's session ↔ run link needs no guessing |
| Claude Code supports `--restricted` (removes command-running tools unless `--tools` names them, confines file tools to the working dirs, refuses `bypassPermissions`, only a person or the permission handler may approve writes to settings / git / tool config) | Default for every run |
| `--permission-prompts host` sends prompts to the SDK host or `--permission-prompt-tool` (documented since 2.1.199); the tool answers `{"behavior":"allow","updatedInput":…}` or deny with a reason; `--allowedTools`/`--disallowedTools` are applied first and the tool cannot override a deny rule; PreToolUse hooks run in print mode | Permission bridge (§7). The wait for a human may exceed MCP tool-call time limits → §7 fallback |
| The final stream-json `result` carries `session_id`, `num_turns`, `duration_ms`, usage and a client-side `total_cost_usd` estimate, also with a subscription | Usage per turn and an estimated cost without a price table for Claude (§8) |
| No public documentation for the Cursor CLI (`cursor-agent`) headless flags or approvals | Treated as `approval: unsupported` until verified (§7) |
| `--input-format stream-json` + `--output-format stream-json` (+ `--replay-user-messages`) keep a live, two-way session | Follow-up prompts and answers go into the running session; `--resume <id>` after a restart |
| Ollama models present include `qwen3-coder:30b`, `qwen3.8`, `nomic-embed-text`, `all-minilm` | Platform model for prompt refinement and summaries; embeddings for similar-work detection (Phase 4) |
| The assistant already has a `create_task` tool; the MCP has none | Phase 1 adds MCP task-write tools |
| PR #727 (collapsible sidebar groups) is **not merged yet** | The "AI Runs" sidebar group appears once #727 is merged; until then the items show ungrouped |

Flags of Claude Code 2.1.296 used by this design: `-p`, `--output-format stream-json`, `--input-format stream-json`,
`--verbose`, `--session-id`, `--resume`, `--model`, `--permission-mode`, `--permission-prompts`, `--permission-prompt-tool`,
`--mcp-config`, `--strict-mcp-config`, `--allowedTools`, `--disallowedTools`, `--tools`, `--restricted`,
`--append-system-prompt`, `--add-dir`, `--settings`. Cursor's headless flags could not be read (keychain lock over SSH)
and are verified in Phase 3 from the LaunchAgent context.

---

## 3. Architecture

```
 Users / managers ── Dashboard (Ask AI · My tasks · task page · AI Runs · Runners)
                          │ JWT
 ┌────────────────────────▼─────────────────────────── OpsAPI (stateless pods) ───────────────────────────┐
 │ core: kanban · assistant (list_my_tasks) · personal keys · ai_usage · ChatWS (Redis) · idempotency     │
 │ plugin ai_runner: runners · runs · turns · requests · locks · sessions · templates · project settings  │
 │ MCP service (Node, stdio + Streamable HTTP at /mcp)                                                     │
 └───────▲──────────────────────────────────────────▲───────────────────────────────────▲─────────────────┘
         │ runner token (one workspace)              │ run token (one task, expires)      │ personal key
         │ heartbeat · claim (long-poll) · status    │ MCP: progress, PR, time,           │ any agent: tasks
         │ · events · usage                          │ permission requests                │ (Claude, Cursor…)
 ┌───────┴─────────── machine (Mac Studio / Linux) ──┴──────┐
 │ PromptPilot (LaunchAgent / systemd user unit)            │
 │  observer: every Claude / Cursor session (existing)      │
 │  runner:   per-workspace registrations → repo folder,     │
 │            new branch →                                  │
 │            claude -p … / cursor-agent -p … (agent profile)│
 └──────────────────────────────────────────────────────────┘
```

Principles:

1. **Machines pull; OpsAPI never connects to a machine.** Outbound HTTPS only: works behind the home NAT, in the cloud and
   on laptops; no inbound ports; no SSH keys in OpsAPI; capacity grows by adding runners (GitHub-Actions-runner model).
2. **OpsAPI is the single source of truth** for runs, prompts, decisions, locks and usage — implemented as the plugin
   `projects/ai-runner` (code `ai_runner`, "AI Runs"), switchable per workspace, depending on kanban.
3. **Core changes stay generic:** my-tasks filters, assistant tool fields and task cards, MCP tools and HTTP transport,
   self-service personal keys, an exported usage-metering helper, a workspace-managers realtime push.
4. **Every step can fail:** leases, heartbeats, compare-and-set status updates, idempotency keys, sweeps.

---

## 4. Flows

### 4.1 "What are my tasks today?"

```
User → assistant: "what are my tasks today?"
assistant → list_my_tasks(due: "today", include_overdue: true)   (runs as the user, projects.read)
assistant → reply: cards [priority · title · project · due] [Open] [Start with AI]   (in-app navigation)
```

### 4.2 Start → claim → run → permission → finish

```
User        Dashboard          OpsAPI (ai_runner)                 Runner (PromptPilot)        Agent CLI
 │ Start with AI ─▶ (pick agent, runner, repo folder on that machine)
 │                ─▶ POST /runs?preview=1 ─▶ build prompt, conflict report
 │◀── preview (prompt, profile list, locks, similar work) ──┘
 │ Confirm ───────▶ POST /runs (Idempotency-Key) ─▶ INSERT run queued; take locks; task → In Progress (setting)
 │                                                   push run:queued to requester + managers
 │                                      ◀── POST /runner/claim (long-poll, SKIP LOCKED) ─┤
 │                                      ── run{prompt, repo_path, profile, run token} ──▶ validate folder (clean),
 │                                                                                         git switch -c ai/<task#>-<slug>
 │                                                                                         write mcp.json (run token)
 │                                      ◀── status: starting → running (pid, session=run uuid) ─ claude -p … ──▶
 │                                                                                    agent works; risky step:
 │                                      ◀── MCP permission_request(tool, input) ───────────────────────────────┤
 │ ◀── push run:permission ── ar_run_requests row, run waiting_permission
 │ Approve ───────▶ POST /requests/:id/decide ─▶ decision stored ── MCP returns allow ──────────────────────▶ continues
 │                                      ◀── events / usage (batched, seq) ──┤ (stream-json parsed by runner)
 │                                      ◀── MCP complete_run(summary) + status: succeeded (exit 0) ──┤
 │                                                   output mode applied by runner (push / PR / local)
 │ ◀── push run:finished ── task → Review (setting); time logged; locks released; notify
```

### 4.3 Cancel

Dashboard `POST /runs/:id/cancel` → status `cancelling` → returned in the runner's next heartbeat (≤15 s) → runner kills the
process group → `status: cancelled` → locks released. If the runner never confirms, the lease sweep marks it `lost`.

### 4.4 Lost runner

No heartbeat until `lease_until` (default 60 s past the last heartbeat) → sweep job marks the run `lost`, releases locks after
a grace period, notifies requester and managers. Retry creates a new attempt.

---

## 5. Data model (plugin migrations, all rows carry `namespace_id`)

| Table | Columns (main) | Constraints / indexes |
|---|---|---|
| `ar_runners` | uuid, namespace_id, name, host, os, status `online\|offline\|paused\|revoked`, labels jsonb, capabilities jsonb (profiles, models, max_concurrency, cli_versions), allowed_roots jsonb, repos jsonb (git repos found under the allowed roots: path, remote, current branch — refreshed by heartbeat), token_hash, token_hint, last_heartbeat_at, version, created_by, timestamps | unique (namespace_id, name); index (namespace_id, status) |
| `ar_project_settings` | uuid, namespace_id, project_uuid (kanban), default_repo_paths jsonb `{runner_uuid: path}` (suggestion only; also remembered from the last run), base_branch (optional; default = the repo's current branch), output_mode, pr_options jsonb (draft, base, reviewers, labels), approval_policy jsonb, allowed_profiles jsonb, lock_scope `repo\|branch\|paths`, lock_paths jsonb, template_uuid, updated_by | unique (namespace_id, project_uuid) |
| `ar_settings` | namespace_id (PK), default output_mode, default approval_policy, caps jsonb (max concurrent runs per user / workspace, max run minutes, tokens per user per day, tokens per workspace per day), retention_days, price_table jsonb, task_automation jsonb (move to In Progress / Review, start timer, log time) | — |
| `ar_runs` | uuid, namespace_id, task_uuid, task_snapshot jsonb, project_uuid, requested_by, assignee_uuid, runner_uuid, profile, model, repo_path (given by the user), repo_remote (reported by the runner), base_branch, work_branch, previous_branch, output_mode, prompt text, template_uuid, template_version, prompt_sha256, status, status_seq int, lease_until, heartbeat_at, pid, agent_session_id, started_at, finished_at, exit_code, error_category, summary, pr_url, commit_sha, tokens_in, tokens_out, cache_read, cache_write, cost_estimate, attempt, idempotency_key, approved_by (when pre-approval is required) | **partial unique (task_uuid) where status in open states**; index (namespace_id, status, created_at desc); index (runner_uuid, status); index (lease_until) where open |
| `ar_run_turns` | uuid, run_uuid, namespace_id, seq, role `user\|assistant`, author_user_uuid (for user turns), text (redacted), model, tokens_in, tokens_out, cache_read, cache_write, at | unique (run_uuid, seq) |
| `ar_run_requests` | uuid, run_uuid, namespace_id, kind `permission\|tool_call`, tool, input_summary (redacted), tool_use_id, status `pending\|allowed\|denied\|expired`, decided_by, decided_at, reason, expires_at | index (run_uuid); partial index (namespace_id) where pending |
| `ar_run_events` | id bigserial, run_uuid, namespace_id, seq, type, data jsonb (small), log_object (MinIO key), at | unique (run_uuid, seq); retention job |
| `ar_locks` | lock_key, namespace_id, run_uuid, scope, expires_at | **unique (lock_key)** while held (row deleted on release) |
| `ar_sessions` | runner_uuid, namespace_id, session_key, tool, status, cwd, branch, started_at, updated_at, prompt_preview (redacted, short), run_uuid nullable, managed bool, seen_at | primary key (runner_uuid, session_key); pruned when not seen for 2 heartbeats |
| `ar_prompt_templates` | uuid, namespace_id, project_uuid nullable, name, version, body, variables jsonb, is_default, created_by | unique (namespace_id, project_uuid, name, version) |

Open run states: `queued, claimed, starting, running, waiting_permission, needs_input, cancelling`. Terminal: `succeeded,
failed, cancelled, lost`. Every status change is a compare-and-set (`UPDATE … WHERE status = ? AND status_seq < ?`).

Large logs (agent stream) go to MinIO in chunks (`ai-runs/<ns>/<run>/<seq>.ndjson.gz`); Postgres keeps pointers.

---

## 6. API

All responses use `{ success, data, meta }`; errors use the catalogue envelope. Prefix `/api/v2/ai-runner`.

### 6.1 Users (JWT + RBAC + kanban membership)

| Method & path | Permission | Notes |
|---|---|---|
| `POST /tasks/:task_uuid/runs?preview=1` | `ai_runs.create` (+ task rule §12) | → `{ prompt, template, profiles[], runners[], conflicts: {task, locks[], sessions[], similar[]} }`, no side effects |
| `POST /tasks/:task_uuid/runs` | same | body `{ profile, model?, runner_uuid, repo_path, prompt_override?, output_mode? }`, `Idempotency-Key` → 201 run, 409 conflict with reason, 422 when the folder is not an allowed git repo |
| `GET /runners/:id/repos` | `ai_runs.create` | git repos the runner found under its allowed folders (for the folder picker) |
| `GET /runs` | `ai_runs.read` (own) / `ai_runs.manage` (all) | filters status, project, runner, user, from/to; paged |
| `GET /runs/:id` | as above | run + turns + requests + recent events + usage |
| `POST /runs/:id/cancel` · `/retry` | own run or `ai_runs.manage` | |
| `POST /runs/:id/messages` | requester or manager | follow-up / `needs_input` answer → new user turn |
| `POST /requests/:id/decide` | per approval policy (§12) | `{ decision: allow\|deny, reason? }`; once only (CAS) |
| `GET /tasks/:task_uuid/runs` | task visible | run history |
| `GET/POST/PATCH /runners`, `POST /runners/:id/rotate-token`, `/pause`, `/revoke` | `ai_runners.manage` | token shown once |
| `GET /runners/:id/sessions`, `GET /sessions` | `ai_runs.manage` | live inventory, managed + manual |
| `GET/PUT /projects/:project_uuid/settings` | `ai_runs_settings.manage` or kanban project owner/admin | |
| `GET/PUT /settings` · `/templates` CRUD | `ai_runs_settings.manage` | |

### 6.2 Runners (runner token, bound to one workspace)

| Method & path | Notes |
|---|---|
| `POST /runner/heartbeat` | `{ version, capabilities, load, inventory[] }` → `{ cancel: [run ids], config }`; renews leases of its runs |
| `POST /runner/claim` | long-poll ≤ 25 s; `FOR UPDATE SKIP LOCKED` over queued runs matching labels/profiles, ordered by task priority then age, within caps → run payload incl. **run token** (or 204) |
| `POST /runner/runs/:id/status` | `{ status, seq, pid?, agent_session_id?, exit_code?, error_category?, commit_sha?, pr_url? }` — stale `seq` ignored |
| `POST /runner/runs/:id/events` | batched `{ seq, type, data }[]`, idempotent on (run, seq) |
| `POST /runner/runs/:id/usage` | per-turn usage `{ seq, model, tokens… }` → `ar_run_turns` + `ai_usage` |

### 6.3 The agent (MCP, run token: this task only, expires at run end)

`get_task`, `add_comment`, `report_progress`, `set_task_pr`, `log_time`, `complete_run`, `ask_user` (sets `needs_input`),
and `permission_request` (the `--permission-prompt-tool`, §7).

---

## 7. Permission bridge

**Claude Code** runs in print mode with `--permission-prompts host --permission-prompt-tool mcp__opsapi_run__permission_request`
and `--restricted`, `--permission-mode default`. Read-only tools (Read, Grep, Glob, LS) may be pre-allowed per agent profile
with `--allowedTools`; everything else that would prompt goes to the tool:

1. The tool receives `tool_name`, `tool_input` and `tool_use_id`, stores an `ar_run_requests` row (input redacted for
   display), sets the run to `waiting_permission`, pushes `run:permission` to the deciders.
2. It long-polls OpsAPI for the decision (policy timeout, default 30 min → `expired` → deny).
3. It answers Claude in the documented format: `{"behavior":"allow","updatedInput":<input unchanged>}` or a deny with the
   decider's reason. The exact deny field name is checked against the installed version in Phase 3.

A human may take longer than the MCP tool-call limit. Phase 3 measures it on 2.1.296: the runner raises the limit for the
run (MCP timeout environment settings) to the policy timeout; if that is not possible, the runner itself becomes the
permission host (`--permission-prompts host` with `--input-format stream-json`), receives each prompt on its stdio channel,
forwards it to OpsAPI and answers when the decision arrives — no tool-call limit applies. A PreToolUse hook adds a fixed
deny-list (e.g. `git push --force`, `rm -rf /`, reading `~/.ssh`) that no approval can override.

`bypassPermissions` / `--dangerously-skip-permissions` are never used; the runner refuses profiles that contain them.

**Cursor** (`cursor-agent -p`): if its headless CLI cannot hand approvals to an external tool, the profile is marked
`approval: unsupported`, runs with a restrictive allow/deny configuration, and OpsAPI requires a manager's approval before
such a run starts. Verified in Phase 3.

**Ollama** is the platform model inside OpsAPI (prompt refinement, summaries, similar-work embeddings). It can back an agent
profile only through a CLI on the machine that supports it, configured like any other profile.

---

## 8. Session tracking and usage

- Every user prompt (the initial prompt, follow-ups, `needs_input` answers) is an `ar_run_turns` row with its author.
- Every permission request and tool call (from the stream) is an `ar_run_requests` row with decision, decider and time.
- Per-turn usage comes from the stream-json assistant messages (`usage`: input, output, cache read, cache write) and the
  final `result` message (totals, turns, duration); the transcript PromptPilot already reads is the fallback.
- Each turn is also written to `ai_usage` (feature `agent_run`, scope = profile, `run_uuid`, user = requester) through a new
  exported `Llm.recordUsage(...)` — so the AI usage page, `AI_USER_DAILY_TOKEN_LIMIT` and workspace caps apply.
- **Billing:** Claude runs use the Max subscription only. The runner sets `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`)
  and **removes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `apiKeyHelper` settings** from the agent's environment, because
  an API key would take precedence over the subscription. `--bare` is never used (it ignores the subscription).
- **Max plan limits:** the plan has usage windows shared by everyone on that account. A run that hits the limit becomes
  `rate_limited` (not failed), shows when the window resets, and resumes the same session (`--resume`) then — or on retry.
  Concurrency caps per runner and workspace keep runs from exhausting the window together.
- Cost: Claude's `total_cost_usd` (client-side estimate, also on a subscription) is stored as `cost_estimate`; other
  profiles use the optional `price_table` (default 0 for local models).

---

## 9. Conflict and duplicate prevention

| Layer | Mechanism | Result |
|---|---|---|
| 1 | Partial unique index: one open run per task | double clicks, two users, two pods → 409 "already running" |
| 2 | Locks: `lock_key = ns + runner + repo folder (real path) + (branch \| path glob)` per `lock_scope`; taken atomically with the run insert | second run on the same area is queued (`waiting_lock`) or refused, naming holder and since |
| 3 | Machine inventory from heartbeats (managed **and manual** sessions) | before claim and at start: a busy session in the target checkout → refuse / requeue |
| 4 | The agent works **in the user's folder on a new branch** (`ai/<task_number>-<slug>`, never `main`); the folder is locked to one run, must be clean before the switch, and no manual session may be busy in it | two agents never edit the same folder; nobody's uncommitted work is touched |
| 5 | Similar work: `pg_trgm` similarity of title + prompt against open runs (threshold setting); embeddings (`nomic-embed-text`) later | warning in the preview, with links; starting anyway needs confirmation |

---

## 10. Prompt generation

Template (workspace default, project override, versioned) filled with: task title, description, checklist, latest comments,
attachment links, project repo / branch / conventions (the repo's CLAUDE.md is read by the agent itself), definition of done,
output mode, and fixed guardrails: stay in the repo folder and on the run's branch; never print or commit secrets; report progress, PR and time through
the MCP tools; call `ask_user` when unsure. Optional "Refine with AI" via `Llm.chat` (workspace provider; off by default).
The final prompt is frozen on the run with `template_uuid`, `template_version` and `prompt_sha256`; users with
`ai_runs_settings.manage` or the per-project "edit prompt" right may edit it in the preview.

---

## 11. Output modes (D3)

| Mode | Runner action at the end | Never |
|---|---|---|
| `pull_request` (draft / ready) — **default, PR to `main`** | commit, push `work_branch`, `gh pr create` against `base` (default `main`) with the task link and summary | merge |
| `branch` | commit, push `work_branch` | open PR, merge |
| `local` | commit on the branch in the folder; folder and branch reported | push |

Git and GitHub credentials stay on the machine. Workspace default + project override; the value is frozen on the run.

---

## 12. RBAC

Modules (plugin manifest): `ai_runs` (read, create, update, manage), `ai_runs_approvals` (manage), `ai_runners` (manage),
`ai_runs_settings` (manage). Kanban project membership always applies on top.

| Action | Assignee (has `ai_runs.create`) | Project owner/admin | Manager (`ai_runs.manage`) | Others |
|---|---|---|---|---|
| See runs | own tasks | project's runs | all | — |
| Start a run | tasks assigned to them | any task of the project | any task they can see | — |
| Edit the prompt before start | if policy allows | ✓ | ✓ | — |
| Decide permission requests | own run if policy `requester` | if policy includes project admins | ✓ (`ai_runs_approvals`) | — |
| Cancel / retry | own runs | project's runs | all | — |
| Pre-approval required before start | per project policy | — | — | — |
| Manage runners / settings / templates | — | project settings | `ai_runners.manage` / `ai_runs_settings.manage` | — |

Approval policy (workspace default set in the admin dashboard, per-project override): `deciders` = `requester` · `managers` ·
`requester_or_managers` (default `managers`);
`require_start_approval` for assignee-started runs (default off); profiles marked `approval: unsupported` always require it.

---

## 13. Configuration

- **Workspace** (`ar_settings`): output mode, approval policy, caps, retention, price table, task automation.
- **Project** (`ar_project_settings`): suggested repo folder per runner, base branch, output mode, PR options, approval
  policy, allowed profiles, lock scope, template.
- **Runner** (PromptPilot `runner.json` on the machine): registrations `[{opsapi_url, token_file, allowed_roots[],
  max_concurrency}]`, agent profiles `{name, command[], approval: bridge|unsupported, models[],
  allowed_tools[]}`, price table (optional), labels.
- **OpsAPI env:** none new required; optional `AI_RUNNER_CLAIM_WAIT_S` (25), `AI_RUNNER_LEASE_S` (60).

---

## 14. PromptPilot runner mode (Go, standard library only)

1. `promptpilot runner --config runner.json` (the observer keeps working in the same binary).
2. Per registration: heartbeat every 15 s with jitter (inventory from the existing scanner, filtered to the registration's
   allowed roots; the list of git repos found there, for the folder picker); claim loop with long-poll; up to `max_concurrency` runs.
3. Run: resolve the folder the user gave (real path, must be inside an allowed root of this registration, must be a git
   repo, must have no uncommitted changes, and no busy manual session in it; otherwise the run fails with `bad_repo_path`,
   `dirty_folder` or `folder_busy`); fetch, then `git switch -c ai/<task#>-<slug> origin/<base>` in that folder — never
   work on `main`; write `mcp.json` (OpsAPI MCP URL + run token);
   start the profile command in its **own process group** with `--session-id <run uuid>`; parse stream-json; send status,
   events (batched) and usage with sequence numbers; label the observer session `opsapi_run`, `opsapi_task`.
4. Cancel → kill the process group; timeout per run; on restart, report orphaned runs (`lost` or resumable).
5. End: apply the output mode (default: push the branch and open a PR to `main`); switch the folder back to the branch it
   was on before the run (configurable), so the next run or a person finds it as they left it.
6. Service files: a **LaunchAgent** (`~/Library/LaunchAgents/com.promptpilot.runner.plist`, `gui/<uid>` domain — needed
   for the keychain) and a systemd **user** unit for Linux.
7. Isolation (D5): one registration = one workspace token, its own work root, concurrency and inventory filter; no
   registration can claim another workspace's run (enforced by OpsAPI too).

---

## 15. MCP for any agent

- New tools: `list_projects`, `list_boards` (with columns), `create_task`, `update_task` (metadata merged), `move_task`,
  `search_tasks`, `list_my_tasks(due, priority)`, `start_ai_run`, `list_runs`, `get_run`.
- Streamable HTTP transport from the same code (`/mcp`, Bearer personal key), stdio kept. Deployed as a small Node service
  behind the existing ingress. Prepared for npm as `@opsapi/mcp`, not published.
- Self-service personal key ("My API keys", `/dashboard/settings/api-keys`): any member mints a key bound to themselves,
  expiry and revoke. Two choices: **AI agent** (`kanban` read/create/update + `projects` read) or **Read only**. On every
  request the key is narrowed to its owner's current role (removed or suspended owners lose it), and its actions are
  enforced by HTTP method (GET read, POST create, PUT/PATCH update, DELETE delete) — so a read-only key never writes,
  even on kanban routes that only check project membership. Kanban writes stay decided per project, as in the dashboard.
- README fix: `OPSAPI_NAMESPACE` takes the numeric id or uuid, never the slug.

---

## 16. Dashboard

1. **My tasks** view + home widget (today, overdue, this week; by priority); assistant answers render task cards with
   **Open** and **Start with AI**, navigating inside the app.
2. **Start with AI** dialog on the task page: profile (from live runner capabilities), runner (auto), **repo folder on that
   machine** (picker of repos the runner found, last folder used for the project, or typed in), prompt preview (editable if
   allowed), conflict report.
3. **AI Runs** board (live): task, assignee, machine, profile/model, status, elapsed, prompt, turns, tokens, pending
   permission requests with Approve / Deny, PR, cancel, retry. Run detail page. Run history on each task.
4. **Runners & machines**: register (token once), pause, revoke, every session on each machine (managed and manual).
5. **Settings**: workspace AI-run settings, templates, project code settings.

---

## 17. Scalability

- Stateless pods; claims with `FOR UPDATE SKIP LOCKED`; long-poll ≤ 25 s with jitter; heartbeats 15 s; leases 60 s.
- Queue order: task priority (critical → none), then age; label/profile routing; caps per user / workspace.
- Events batched; logs in MinIO; retention job (default 365 days); all lists paged.
- Realtime through the existing Redis relay (works across pods); a `push_users` helper for "requester + managers".
- Metrics: runs by status, queue depth, claim latency, active runners, permission wait time, tokens.

---

## 18. Threat model

| Threat | Mitigation |
|---|---|
| Stolen runner token | hashed at rest, one workspace, revocable, rotate; claims limited to that workspace |
| Agent acting outside its task | run token scoped to one task, expires at run end; MCP tools check it |
| Agent running destructive commands | permission bridge for every risky step, `--restricted`, never bypass; the run's branch only (never `main`); no merge |
| Secrets leaking into prompts / logs | guardrail in prompt; redaction of tool inputs and outputs before storage; secrets never sent by OpsAPI |
| A folder outside what the machine owner allowed | the runner resolves the real path and refuses anything outside its allowed roots or not a git repo; OpsAPI also checks against the runner's reported repos |
| Accidental API-key billing | the runner strips API-key variables and settings from the agent's environment; `--bare` never used |
| Observer password exposure | the observer is public behind basic auth; rotate its password (it was shared in a chat) and consider an IP allow-list at the edge |
| Cross-workspace leakage | every row and query carries `namespace_id`; runner bound to one workspace; separate work roots |
| Prompt injection from task text | task text fenced as data in the template; permission bridge still gates actions |
| Abuse / runaway cost | caps per user / workspace, run time limit, token limits via `ai_usage` |
| Unauthenticated observer on the LAN | recommend binding PromptPilot's dashboard to 127.0.0.1 |
| Replay / duplicate updates | sequence numbers, idempotency keys, CAS status changes |

---

## 19. Failure modes

| Failure | Handling |
|---|---|
| Runner dies mid-run | lease expiry → `lost`; locks released after grace; retry = new attempt |
| OpsAPI unreachable from the runner | runner keeps the agent running, buffers status/events locally, replays with seq |
| Agent hangs | per-run timeout → kill group → `failed` (`timeout`) |
| Permission never answered | request expires (default 30 min) → deny → agent continues or stops |
| Duplicate claim | SKIP LOCKED + CAS; second claimer gets 204 |
| Push / PR fails | run `failed` (`output`), branch kept locally, retry output step |
| Keychain locked (Mac logged out) | profile health check in heartbeat → runner reports profile unavailable; no claims for it |
| Similar-work false positive | warning only; user may start anyway with confirmation |

---

## 20. Phase plan and acceptance tests

| Phase | Scope | Acceptance |
|---|---|---|
| **1** My tasks + MCP | my-tasks filters; `list_my_tasks` fields; task cards + in-app links; My tasks view/widget; MCP task tools + HTTP transport; self-service key | Lua specs; sandbox e2e: "today" filter, cross-workspace denial; MCP tool tests against the sandbox; Cypress: assistant cards navigate |
| **2** Plugin core + runner | `ai_runner` plugin tables, RBAC, settings, runner registration + protocol, run lifecycle, locks, sweeps, templates + preview; PromptPilot runner mode with a **fake agent CLI** | sandbox e2e: start → claim → status → finish, one-run-per-task, lock refusal, lost-runner sweep, cancel, migrations twice, workspace isolation; Go tests for the runner |
| **3** Real agents | Claude profile with permission bridge, session tracking, usage metering, needs_input / follow-ups, output modes; Cursor profile; Start dialog, AI Runs board, run detail, task history | fake CLI emits real stream-json + permission requests; approve/deny/expire paths; usage rows; Cypress for the dialog and board |
| **4** Conflicts + hardening | inventory & machines page, manual sessions, similar-work warnings, routing, caps, retention, metrics, docs, security review | e2e for inventory conflict and caps; security review findings fixed |

No automated test calls the real Claude, Cursor or a paid model.

---

## 21. Decisions taken and open points

Resolved (2026-10-12): PromptPilot code is worked on in `/Users/balinderwalia/projects/promptpilot` on the Mac Studio;
Claude runs use the Max plan through `claude setup-token` (no API key); managers decide permission requests by default,
configurable in the admin dashboard; the user gives the repo folder on the Mac Studio when starting a task; the observer
stays at `https://promptpilot.workstation.co.uk/` behind basic auth.

Open:
1. Decided: the agent works in the folder the user gives, on a new branch (never `main`), and the output is a PR to
   `main` by default. One run per folder at a time; the folder must be clean.
2. Phase 2 changes PromptPilot on the Mac Studio (new runner code, a LaunchAgent, a one-time `claude setup-token` run by the
   account owner). Each of these is done only after you approve it at that time.

---

## 22. Phase 2 build contract (a slice testable from the dashboard)

Phase 2 makes the whole loop work from the UI: register a runner → **Start with AI** on a task → the runner claims the
run, works in the chosen folder on a new branch, applies the output mode → the run's status, log and result are visible
on **AI Runs**, with cancel and retry. Deferred to Phase 3: the permission bridge (until then a Claude run may only read
and edit files in the folder — anything that would prompt is **denied**, never auto-approved), per-turn session tracking
and usage metering, the run-scoped MCP token, `needs_input`, the Cursor profile. Phase 4: similar-work detection, routing.

### 22.1 Plugin

`projects/ai-runner` (code `ai_runner`, name "AI Runs", icon `Bot`, `default_enabled = false`, depends on kanban).
API prefix `/api/v2/ai-runner`. Native dashboard pages under `/dashboard/ai-runner/`.

Modules: `ai_runs` (read, create, update, delete, manage), `ai_runs_approvals` (manage — used in Phase 3),
`ai_runners` (manage), `ai_runs_settings` (manage). Menu: **AI Runs** (`/dashboard/ai-runner/runs`, `ai_runs`),
**Runners** (`/dashboard/ai-runner/runners`, `ai_runners`), **AI run settings** (`/dashboard/ai-runner/settings`,
`ai_runs_settings`).

Who may start a run on a task: `ai_runs.create` **and** (assignee of the task **or** `ai_runs.manage` **or** owner/admin of
the task's kanban project). Who sees runs: own runs with `ai_runs.read`; all with `ai_runs.manage`; project owners/admins
see their project's runs. Cancel/retry: the requester or `ai_runs.manage`.

### 22.2 Runner API (no user session: under the plugin's `public/` prefix, authenticated by the runner token)

Header `Authorization: Bearer oprn_<48 hex>`. The token is stored hashed (SHA-256) on `ar_runners`, belongs to exactly one
workspace, and is refused when the runner is revoked or the plugin is off in that workspace (404). A runner can only read
or change runs it claimed. All bodies JSON; all responses `{ success, data }`.

| Method & path | Body → response |
|---|---|
| `POST /api/v2/ai-runner/public/runner/heartbeat` | `{ version, host, os, capabilities: { max_concurrency, profiles: [{ key, label, approval: "none"\|"bridge"\|"unsupported", models: [] }] }, load: { running }, inventory: [{ key, tool, status, cwd, branch, session_id, started_at, updated_at, prompt_preview, labels }], repos: [{ path, remote, branch, dirty }] }` → `{ runner_uuid, cancel: [run_uuid], config: { heartbeat_s: 15, claim_wait_s: 25, lease_s: 60 } }` |
| `POST /api/v2/ai-runner/public/runner/claim` | `{ wait_s?: ≤25 }` → **200** `{ run }` or **204** (nothing to do). Atomic (`FOR UPDATE SKIP LOCKED`), ordered by task priority then age, at most `max_concurrency` running per runner |
| `POST /api/v2/ai-runner/public/runner/runs/:uuid/status` | `{ seq, status: "starting"\|"running"\|"succeeded"\|"failed"\|"cancelled", pid?, agent_session_id?, exit_code?, error_category?, error?, summary?, commit_sha?, pr_url?, work_branch?, previous_branch? }` → `{ status, cancel: bool }`. A `seq` not greater than the stored one is ignored (200). Terminal states release the folder lock |
| `POST /api/v2/ai-runner/public/runner/runs/:uuid/events` | `{ events: [{ seq, type: "log"\|"progress"\|"tool"\|"usage", text?, data? }] }` (≤ 200 per call, text ≤ 4 KB each, idempotent on (run, seq)) → `{ stored }` |

`run` (claim payload): `{ uuid, task: { uuid, task_number, title, url }, project: { uuid, name }, profile, model,
repo_path, base_branch, work_branch, output_mode: "pull_request"|"branch"|"local", pr: { draft, base }, prompt,
timeout_s }`. `work_branch` = `ai/<task_number>-<slug>`; `base_branch` empty = the folder's default branch.

### 22.3 User API (session JWT, RBAC above)

| Method & path | Notes |
|---|---|
| `GET /runners` | runners of the workspace: uuid, name, status (`online` if heartbeat < 45 s), host, os, version, capabilities, repos, last_heartbeat_at. Anyone with `ai_runs.create` (for the Start dialog) |
| `POST /runners` `{ name, labels? }` | `ai_runners.manage` → 201 `{ runner, token }` (token shown once) |
| `POST /runners/:uuid/rotate-token` · `/pause` · `/resume` · `DELETE /runners/:uuid` | `ai_runners.manage`; delete = revoke |
| `GET /runners/:uuid/sessions` | `ai_runs.manage`; last inventory (managed sessions linked to their run) |
| `POST /tasks/:task_uuid/runs/preview` `{ runner_uuid?, profile?, repo_path? }` | → `{ prompt, template_version, runners, default_repo_path, output_mode, conflicts: { open_run, folder_lock, busy_session } }` — no side effects |
| `POST /tasks/:task_uuid/runs` `{ runner_uuid, profile, model?, repo_path, prompt?, output_mode? }` | `Idempotency-Key`. `prompt` only for `ai_runs.manage` or project owner/admin. → 201 run, 409 `{ error, conflict }` (open run on the task, folder locked, busy session in the folder, runner offline/paused), 422 (folder not among the runner's reported repos, profile unknown) |
| `GET /runs` `?status&task_uuid&runner_uuid&mine&page&per_page` | paged, newest first |
| `GET /runs/:uuid` | run + last 500 events + task + runner |
| `POST /runs/:uuid/cancel` · `POST /runs/:uuid/retry` | cancel: queued → cancelled at once; running → `cancelling` (sent to the runner in the next heartbeat). Retry: a new run (attempt + 1) with the same inputs |
| `GET /tasks/:task_uuid/runs` | the task's run history |
| `GET/PUT /settings` | `ai_runs_settings.manage`: `{ output_mode, pr_draft, pr_base, max_run_minutes, task_automation: { in_progress_on_start, review_on_success }, approval_policy }` (approval_policy stored now, used in Phase 3) |
| `GET/PUT /projects/:project_uuid/settings` | owner/admin of the project or `ai_runs_settings.manage`: `{ default_repo_paths: { runner_uuid: path }, output_mode?, base_branch? }` |
| `GET/PUT /template` | `ai_runs_settings.manage`: the workspace prompt template `{ body, version }` (versioned on save) |

Run statuses: `queued → claimed → starting → running → succeeded | failed | cancelled | lost`, plus `cancelling`.
The lease sweep (plugin job every minute) marks `claimed/starting/running/cancelling` runs whose heartbeat is older than
`lease_s` as `lost` and releases their locks; queued runs older than 24 h are cancelled.

### 22.4 Prompt template (default; variables in `{{ }}`)

Task `#{{task.number}} {{task.title}}` from project {{project.name}} ({{task.url}}), its description and checklist; the
repo folder `{{repo_path}}` and branch `{{work_branch}}`; the output mode; fixed guardrails: work only in this folder on
this branch, never on `main`; never print, commit or log secrets; don't merge; when done, summarise what changed in one
short paragraph as the last message. Task text is fenced as data, not instructions.

### 22.5 PromptPilot runner mode (Phase 2)

`promptpilot runner -config runner.json` next to the existing observer (same binary, standard library only):
- config: `registrations: [{ name, opsapi_url, token_file, allowed_roots: [], max_concurrency }]`, `profiles: [{ key,
  label, approval, models, command: [...with {{prompt}} {{run_uuid}} {{model}}], env: {} }]`, `claude_oauth_token_file`
  (optional), `restore_branch` (default true).
- heartbeat every 15 s (inventory = the observer's sessions under the allowed roots; repos = git repos found up to 3
  levels under the allowed roots); claim loop; per run: validate the folder (real path inside an allowed root, a git
  repo, no uncommitted changes, no busy session in it), remember the current branch, `git fetch` (best effort),
  `git switch -c <work_branch> <base>`; start the profile command in its own process group with the run uuid as the
  Claude session id; stream stdout/stderr lines as `log` events (batched, every 1 s or 50 lines); parse Claude
  stream-json `result` for summary/usage; cancel (from heartbeat or status reply) kills the group; per-run timeout;
  on success apply the output mode (commit all changes "<task #> <title>"; `branch`/`pull_request`: push; `pull_request`:
  `gh pr create --base <base> [--draft]` with the task link and summary); restore the previous branch; report status.
- The agent's environment never contains `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`; `CLAUDE_CODE_OAUTH_TOKEN` comes
  from `claude_oauth_token_file` when set. Default Claude profile:
  `claude -p {{prompt}} --output-format stream-json --verbose --session-id {{run_uuid}} --restricted --permission-mode acceptEdits --permission-prompts none --allowedTools Read,Grep,Glob,Edit,MultiEdit,Write`.
- A `fake` profile (`scripts/fake-agent.sh`) edits a file and prints realistic stream-json, for tests.
- Service files: a LaunchAgent plist (macOS) and a systemd user unit (Linux), not installed by default.
