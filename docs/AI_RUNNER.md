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

---

## 23. Phase 3 build contract (real agents)

Phase 3 makes Claude Code a real, supervised worker:
- **Permission bridge:** anything risky the agent wants to do is asked of a person in the dashboard.
- **Conversation:** people can send follow-ups, and the agent can ask a question and wait (`needs_input`).
- **Usage:** every turn's tokens are metered into `ai_usage`.
- **Start approval:** runs that need a manager's approval to start, including every run of an `approval: unsupported` profile such as Cursor.
- **Task tools:** the agent can read its task and comment on it, through a run-scoped token.

Verified against Claude Code 2.1.280 on 2026-10-12 (protocol probe, §23.0).

### 23.0 Verified Claude Code facts
- **The runner is the permission host.** Claude is started with these flags:
  ```
  claude -p --input-format stream-json --output-format stream-json --verbose
    --permission-prompts host --permission-prompt-tool stdio
  ```
  - The runner sends the prompt on stdin as `{"type":"user","message":{"role":"user","content":"…"},"parent_tool_use_id":null,"session_id":""}`.
  - When the agent needs a permission, Claude writes:
    ```
    {"type":"control_request","request_id":"…","request":{"subtype":"can_use_tool","tool_name","display_name",
    "input",…,"description","permission_suggestions","blocked_path","tool_use_id"}}
    ```
  - The runner answers on stdin:
    ```
    {"type":"control_response","response":{"subtype":"success","request_id":"…","response":{"behavior":"allow",
    "updatedInput":<input>}}}
    ```
    or with `{"behavior":"deny","message":"…"}`.
  - A denied agent is told the message and carries on.
  - Each `result` message ends a turn. Another `user` message on stdin starts the next turn in the same session; closing stdin ends the process.
  - Without `--permission-prompt-tool stdio`, nothing is asked and anything that would prompt is denied.
  - Claude waits for the answer: a decision sent 150 s later was applied, so a person can take their time (the runner's own timeout decides).
- **Read-only commands don't ask.** `echo`, `ls` and similar never prompt. Changes outside the session's working folder are refused outright.
- **No `AskUserQuestion` tool in `-p` mode.** The agent asks by ending its reply with a line `NEEDS_INPUT: <question>`, which the default template now tells it to do.
- **`--restricted` does not remove MCP servers.** Without `--strict-mcp-config`, the machine owner's own claude.ai connectors were loaded into the agent's session. Every Claude profile must pass `--strict-mcp-config`; the run's own MCP server comes in through `--mcp-config`.
- **Rate limits:** stream-json carries `rate_limit_event` messages with `rate_limit_info: { status, resetsAt, rateLimitType, utilization }`.
- **Usage:**
  - `result` carries `usage { input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens }`, `total_cost_usd`, `num_turns` and `duration_ms`.
  - `system`/`init` carries `model`.

### 23.1 Statuses and schema (plugin migration 2, idempotent)
- **New status `pending_approval`:**
  - It comes before `queued` and is not claimable.
  - It is open: it counts for the one-run-per-task index and holds the folder lock.
  - The migration rebuilds the status CHECK and the `ar_runs_one_open_per_task` index to include it.
  - The runner may now report `waiting_permission` and `needs_input`. Allowed moves:
    - running → waiting_permission / needs_input
    - waiting_permission → running / needs_input / waiting_permission
    - needs_input → running / waiting_permission / needs_input
    - plus every final status
  - `cancelling` stays sticky.
- **`ar_runs` gains:**
  - `approved_by`, `approved_at`;
  - `question TEXT`: the open `needs_input` question, cleared when the run reports `running`;
  - `tokens_in`, `tokens_out`, `cache_read`, `cache_write` (BIGINT, default 0), `cost_estimate NUMERIC(12,4)` (default 0), `turns INT` (default 0);
  - `run_token_hash CHAR(64) UNIQUE` (nullable).
- **`ar_run_requests` gains:**
  - `request_id VARCHAR(255)`, with `UNIQUE (run_uuid, request_id)`;
  - `input JSONB` (redacted, at most 8 KB), `description TEXT`, `blocked_path TEXT`;
  - `rule_key VARCHAR(255)` and `remember BOOLEAN NOT NULL DEFAULT false`.
- **`ar_run_turns`:**
  - `seq` is assigned by the server: next per run, under the run row lock.
  - New columns: `status VARCHAR(20) NOT NULL DEFAULT 'delivered' CHECK (status IN ('queued','delivered'))`, `runner_turn INT`, `cost_estimate NUMERIC(12,4)`, `num_turns INT`, `duration_ms BIGINT`, `needs_input BOOLEAN NOT NULL DEFAULT false`.
  - Unique partial index on `(run_uuid, runner_turn)` where `role = 'assistant'`.
  - User rows are follow-ups and answers. Assistant rows are one per agent `result`.
- **Settings:** `approval_policy` gains `permission_timeout_minutes` (1–1440, default 30) and `input_timeout_minutes` (1–1440, default 60).
- **Sweep additions:**
  - pending requests past `expires_at` become `expired`;
  - `pending_approval` runs older than 72 h become `cancelled` (`approval_timeout`).

### 23.2 Runner API additions
All under `/api/v2/ai-runner/public/runner`, using the runner token. The run must be claimed by this runner and open, else 404 (or 409 for a finished run).

| Method & path | Body → response |
|---|---|
| `POST /runs/:uuid/permissions` | `{ request_id, tool, input: {}, tool_use_id?, description?, blocked_path?, rule_key? }` → 201 `{ request: { uuid, status, reason } }`. Idempotent on `request_id` (200 with the stored row). If this run already has an **allowed + remember** request with the same `rule_key`, it comes back `allowed` at once (`reason` "Allowed earlier in this run"). `expires_at = now + permission_timeout`. |
| `POST /runs/:uuid/permissions/:req_uuid/wait` | `{ wait_s ≤ 25 }` → `{ status: pending\|allowed\|denied\|expired, reason, decided_by_name, cancel }`. A long poll that returns early on a decision or when the run is `cancelling` (`cancel: true`). |
| `POST /runs/:uuid/turns` | `{ turn ≥ 1, text, model?, usage: { input_tokens, output_tokens, cache_read_tokens, cache_write_tokens }, cost_estimate?, num_turns?, duration_ms?, needs_input? }` → `{ stored }`. Idempotent on `turn`. It stores the assistant turn (text redacted, at most 8 KB), adds the usage to the run's totals (`turns + 1`), and writes **one `ai_usage` row**: `feature 'agent_run'`, `scope` = profile, `run_uuid`, `user_uuid` = requester, `provider` = the profile key cut to 20 characters, model, tokens, `ok = true`. |
| `POST /runs/:uuid/turns/next` | `{ wait_s ≤ 25 }` → `{ turns: [{ uuid, text, author_name }], cancel }`. A long poll for queued user turns; the ones returned are marked `delivered`. |

**Status reports** accept the new statuses, plus `question` (with `needs_input`).

**Heartbeat:** `capabilities.profiles[].rate_limit` is an optional `{ status, resets_at, type, utilization }`, stored and shown.

**Claim payload** gains:
- `run_token`: `oprt_` + 48 hex, stored hashed, valid while the run is open;
- `policy: { permission_timeout_s, input_timeout_s }`.

**Run-token API** (`/api/v2/ai-runner/public/run`, `Authorization: Bearer oprt_…`; the run must be open; plugin off → 404):
- `GET /task`: the task (title, description, checklist, status, priority, url) and its 20 latest comments (author name, text, at).
- `POST /comments` `{ text ≤ 4000 }`: adds a kanban comment on the task as the requester, prefixed `[AI run] `.

### 23.3 User API additions (`/api/v2/ai-runner`, session JWT)
**Deciders:**
- **Permission requests:** decided by whoever the workspace `approval_policy.deciders` names:
  - `requester`: the person who started the run;
  - `managers`: `ai_runs_approvals.manage` or `ai_runs.manage`, or an owner or admin of the run's project;
  - `requester_or_managers`: either.
- **Start approvals:** always decided by managers.

| Method & path | Notes |
|---|---|
| `GET /runs/:uuid` | Adds `requests` (newest first, at most 200), `turns` (in order, at most 200), usage totals, `question`, `can_decide` (for permission requests), `can_approve` (for `pending_approval`) and `can_message` (requester or `ai_runs.manage`, while the run is open). |
| `GET /runs` | Rows add `tokens_in`, `tokens_out`, `cost_estimate`, `turns`, `pending_requests`. |
| `GET /waiting` | What waits on the caller: `{ requests: [pending request + run/task info], approvals: [pending_approval runs] }`, both limited to what the caller may decide. |
| `POST /runs/:uuid/requests/:req_uuid/decide` | `{ decision: "allow"\|"deny", reason?, remember? }`. Returns 403 if not a decider, 409 if no longer pending. Sets `decided_by`, `decided_at`, `reason`. |
| `POST /runs/:uuid/turns` | `{ text ≤ 8000 }`. Allowed for the requester or `ai_runs.manage` while the run is open (not `pending_approval`/`queued`), else 409. Creates a queued user turn. |
| `POST /runs/:uuid/approve` · `POST /runs/:uuid/reject` `{ reason? }` | Managers only, `pending_approval` runs only. Approve → `queued`. Reject → `cancelled` (`error_category 'rejected'`) and releases the lock. |
| Start / retry | The run is created as `pending_approval` when the profile's `approval` is `unsupported`, or when `require_start_approval` is on and the requester is not a manager. Preview returns `needs_approval`. |
| `GET/PUT /settings` | `approval_policy.permission_timeout_minutes`, `approval_policy.input_timeout_minutes`. |

### 23.4 PromptPilot runner (Phase 3)
**Profile `io`:**
- `"args"` (default) is the Phase 2 behaviour: the prompt goes in argv.
- `"stream-json"`: the prompt goes on stdin, `{{prompt}}` is not allowed in the command, and the runner is the permission host.

**Each permission request:**
1. Check the fixed safety list first. These are denied without asking anyone, with the message "Blocked by the runner's safety rules: …":
   - `git push`, `git merge`, `git rebase`, `git reset --hard`;
   - `git checkout`/`git switch` to anything except the run's branch;
   - `sudo`;
   - `rm -r…` of `/` or `~`;
   - `curl|wget … | sh`;
   - `.ssh`, `id_rsa`, `.aws/`, `.env` files;
   - any `file_path`/`blocked_path` outside the repo folder.
2. `POST /permissions`, then report `waiting_permission`.
3. Long-poll `/wait` until it is decided, expired or the run is cancelled.
4. Answer Claude. On expiry, deny with "Nobody answered in time".
5. Report `running`.

Any other `control_request` subtype gets `{"subtype":"error","request_id":…,"error":"not supported"}`.

**`rule_key`:** for Bash, the first two words of the command; otherwise the tool name.

**After each `result`:**
1. `POST /turns` with the result text and its usage.
2. If the text has a line `NEEDS_INPUT: …`:
   - report `needs_input` with the question;
   - long-poll `/turns/next` until the input timeout;
   - send the answer as the next user message, and report `running`;
   - on timeout, end as `failed` (`needs_input_timeout`).
3. Otherwise check `/turns/next` once with `wait_s 0`:
   - queued follow-ups are sent as the next user message;
   - with none, close stdin and finish as in Phase 2.

**Placeholders:**
- `{{mcp_config}}`: the runner writes `<tmp>/mcp.json` (mode 0600, deleted at the end) with `{"mcpServers":{"opsapi_run":{"command":<promptpilot path>,"args":["run-mcp"],"env":{"OPSAPI_URL":…,"OPSAPI_RUN_TOKEN":…}}}}`.
- `{{model}}`: when the run has no model, the runner drops the `--model {{model}}` pair.

**`promptpilot run-mcp`:** a stdio MCP server using JSON-RPC 2.0, one message per line. It handles `initialize` (echoing the client's `protocolVersion`), `tools/list` and `tools/call`, with the tools `get_task` and `add_comment`, which call the run-token API.

**`promptpilot fake-agent`:** a Go test agent that speaks the full stdio protocol, controlled by `FAKE_AGENT_SCRIPT` (steps separated by `;`):
- `perm:<tool>:<command>`: ask; when allowed, it runs the step by writing a file;
- `edit`: writes `AI_RUN_NOTES.md`;
- `ask:<question>`: ends the turn with `NEEDS_INPUT:`;
- `sleep:<s>`.

Each turn emits assistant messages with `usage` and a `result` with usage and cost. It exits when stdin closes.

**Rate limit:** the runner keeps the latest `rate_limit_info` per profile and sends it in the heartbeat. A result that fails on a rate limit ends the run as `failed` (`rate_limited`).

**Profiles in `runner.example.json`:**
- **Claude (bridge):**
  ```
  claude -p --input-format stream-json --output-format stream-json --verbose --session-id {{run_uuid}}
    --model {{model}} --restricted --strict-mcp-config --mcp-config {{mcp_config}}
    --tools Read,Grep,Glob,Edit,MultiEdit,Write,Bash
    --allowedTools Read,Grep,Glob,mcp__opsapi_run__get_task,mcp__opsapi_run__add_comment
    --permission-mode acceptEdits --permission-prompts host --permission-prompt-tool stdio
  ```
  `approval: "bridge"`, `io: "stream-json"`. File edits inside the folder are allowed by `acceptEdits`, since the agent is on its own branch. Bash and anything else is asked.
- **Claude (no bridge):** the Phase 2 profile, plus `--strict-mcp-config`.
- **Cursor:** `cursor-agent -p {{prompt}} --output-format stream-json --model {{model}}`, `approval: "unsupported"`, without `--force`.
- **Fake:** `promptpilot fake-agent` with `io: "stream-json"`.

### 23.5 Dashboard
- **Run page:**
  - "Needs your decision" for pending requests: the tool, what it wants (the command or file), the path, Allow / Allow for this run / Deny with an optional reason. Others see "Waiting for a decision".
  - The history of requests.
  - The conversation: agent turns with their tokens, and people's messages.
  - A message box, for the requester or a manager while the run is open.
  - The `needs_input` question, highlighted.
  - Usage totals.
  - A `pending_approval` banner with Approve / Reject.
- **AI Runs:**
  - A "Waiting on you" panel (requests and approvals, with quick actions, refreshed every 10 s);
  - tokens and turns columns;
  - the new statuses.
- **Settings:** permission timeout and input timeout.
- **Runners:** each profile's rate-limit usage.
- **Start dialog:** the note "A manager must approve this run before it starts" when `needs_approval`.

### 23.6 Acceptance
- **Plugin sandbox:**
  - permission request → allow / deny / remember / expire;
  - decider rules for all three policies;
  - turns, follow-ups and `needs_input`;
  - usage totals and `ai_usage` rows;
  - `pending_approval` approve / reject and its RBAC;
  - the run-token API (scope, expiry at run end, other runs refused);
  - migration 2 run twice;
  - isolation between workspaces.
- **Real runner + `promptpilot fake-agent`:**
  - a permission that is allowed, then one that is denied;
  - a safety-list command denied without asking;
  - `NEEDS_INPUT` answered from OpsAPI;
  - a follow-up;
  - usage rows.
- **Go tests** for the stdio host, the safety list, `run-mcp` and `fake-agent`.
- **Cypress:**
  - the mocked spec decides a request, sends a message and approves a pending run;
  - the real-runner spec runs the same through the UI with `fake-agent`;
  - with `CYPRESS_AIR_CLAUDE=1`, a real Claude run whose permission is approved in the dashboard.

### 23.7 As built (differences from the contract above)
**Server**
- **Approvers can see runs:** holders of `ai_runs_approvals.manage` see every run, so they can open the runs they decide.
- **Decider checks:** these are made in code on decide, approve, reject and `/waiting`, because a decider may be just the requester.
- **`waiting_permission`** is only ever reported by the runner; the server never sets it.
- **Queue timeout:** an approved run's 24 h queue timeout counts from its approval.
- **Large inputs:** a permission input over 8 KB is stored as `{"truncated":true}`. The readable summary (command or file) is kept.
- **Task shape:** `GET /public/run/task` returns the task flat, with its `comments` inside.
- **Turn order:** turns are listed in the order they happened. A message sent while the agent is mid-turn comes before the agent's reply to it.
- **`usage` object:** the run detail and run rows carry `usage { tokens_in, tokens_out, cache_read, cache_write, cost_estimate, turns }`. On the detail, `turns` is the conversation list.

**Runner**
- **Cost:** each turn posts its own share of the cost. Claude's `total_cost_usd` is a running total over the session (probed: 0.0088 then 0.0152), while `usage`, `num_turns` and `duration_ms` are per turn.
- **Follow-ups:** several queued messages are sent as one user message, separated by blank lines.
- **Expiry backstop:** the runner treats a permission request as expired after the permission timeout plus 2 minutes, even if the server never expires it.
- **Deny wording:** a denial reads "Denied by <name>: <reason>". When the runner can't ask, or the run is stopping, it always denies and never allows.
- **Safety list** is a little broader than §23.4:
  - It also blocks the other private keys (`id_dsa`, `id_ecdsa`, `id_ed25519`) and `.env.*` files.
  - `git checkout -- <file>` is allowed.
  - Paths are checked with symlinks resolved.
  - Matching is on the command text, so it errs towards blocking.
- **Agent environment:** Claude Code session variables are stripped (`CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, the messaging socket and token, …), so a runner started from inside a Claude Code terminal doesn't leak them. `CLAUDE_CODE_OAUTH_TOKEN` is kept.
- **Args-mode turns:** agents in `args` mode (Claude without the bridge, Cursor) also post their turns, so their usage is metered too.

---

## 24. Phase 4 build contract (conflicts and hardening)

Phase 4 gives managers a picture of everything that is running and stops work from piling up or clashing:
- **Similar-work warnings:** layer 5 of §9.
- **Caps:** limits on open runs and on daily tokens.
- **Profile health:** a logged-out or locked agent takes no work (§19).
- **Machines page:** every session on every machine.
- **Overview:** numbers for managers.
- **Notifications:** deciders hear about new requests.
- **Retention:** old logs are pruned.
- **Setup runbook.**
- **Security review:** with its findings fixed.

### 24.1 Settings (`ar_settings.guards JSONB`, plugin migration 3)

| Setting | Default | Range | Meaning |
|---|---|---|---|
| `similar_threshold` | 0.45 | 0.1–1.0 | `pg_trgm` similarity of task titles above which open runs count as similar work |
| `max_open_runs_per_user` | 3 | 0–100, 0 = no cap | open runs (any open status) one requester may have |
| `max_open_runs_per_workspace` | 10 | 0–1000, 0 = no cap | open runs in the workspace |
| `daily_token_limit` | 0 | 0–10⁹, 0 = none | agent-run tokens (in + out) of the workspace today (UTC, from `ai_usage` feature `agent_run`); at the limit no new run starts, and running ones finish |
| `retention_days` | 365 | 30–3650 | after this, a finished run's log events are deleted and its turn texts and request inputs are cleared; the run row, summary and usage are kept |

These are exposed in `GET/PUT /settings` as `guards`, which need `ai_runs_settings.manage`.

### 24.2 Similar work and caps at start
- **Preview** adds `conflicts.similar`: up to 5 `{ run_uuid, task_uuid, task_number, task_title, status, requested_by_name, similarity }`. These are other open runs in the workspace whose task title is similar (`similarity(lower(a), lower(b)) >= similar_threshold`). If `pg_trgm` is missing, the check is skipped and logged once.
- **Preview** also adds `limits: { user_open, user_max, workspace_open, workspace_max, tokens_today, daily_token_limit }`.
- **Start and retry:**
  - If there is similar work and the body lacks `confirm_similar: true` → 409 `{ conflict: { type: "similar_work", runs: [...] } }`.
  - A cap that is reached → 409 `{ conflict: { type: "cap_reached", scope: "user"|"workspace", limit, open } }`.
  - The token limit reached → 409 `{ conflict: { type: "token_limit", limit, used } }`.
  - **Order of checks:** caps and the token limit first, then similar work.
  - **Approvals:** a manager approving a `pending_approval` run is not blocked by caps, because the run already counts as open.

### 24.3 Profile health (runner + server)
- **Runner profile** gains an optional `health: { command: [...], every_s: 300 }`.
  - The runner runs it with a 20 s timeout, at start and then every `every_s`.
  - The profile is available when the command exits 0 and its output, if it is JSON, has no `"loggedIn": false`.
  - **The output is never sent or logged.** `claude auth status` prints the account email. Only a short reason is reported: `not logged in`, `exit <n>` or `timed out`.
- **Heartbeat:** `capabilities.profiles[].available` (default true) and `unavailable_reason` (at most 120 characters).
- **Server:**
  - Start → 409 `profile_unavailable`.
  - Claim skips queued runs whose profile the runner reports as unavailable; they stay queued.
- **Example health commands:**
  - Claude: `["claude", "auth", "status", "--json"]`
  - Cursor: `["cursor-agent", "status"]`
  - Fake agent: none.

### 24.4 Machines page and sessions API
- **`GET /sessions?runner_uuid&busy=1&page&per_page`** (`ai_runs.manage` or `ai_runners.manage`): every reported session of the workspace's runners.
  - Fields: runner `{uuid, name, status}`, tool, status, cwd, branch, managed, run `{uuid, task_title, task_number}`, prompt_preview, updated_at, seen_at.
  - `busy=1` hides idle sessions.
- **Dashboard `/dashboard/ai-runner/machines`** (menu "Machines", module `ai_runners`):
  - a section per runner: status, last heartbeat, and each profile's health and rate limit;
  - the session table (managed runs link to their run; manual sessions are marked "Started by hand");
  - a filter for busy sessions only;
  - refreshes every 15 s.

### 24.5 Overview
- **`GET /overview`** (`ai_runs.manage`, `ai_runners.manage` or `ai_runs_approvals.manage`) returns:
  - `runs_by_status` `{status: n}` for open runs, plus `queue_depth` (queued);
  - `runners: { online, offline, paused }`;
  - `tokens_today` and `cost_today`;
  - `runs_7d: { succeeded, failed, cancelled, lost }`;
  - `avg_permission_wait_s_7d`: the average time from request to decision, over decided requests in the last 7 days.
- **Dashboard:** cards at the top of AI Runs for users who may see the overview.

### 24.6 Notifications to deciders
These use the existing notification center: `KanbanNotificationQueries.create` with `action_url` = the run page, plus the run's `task_id`/`project_id`.

| Event | Type | Sent to |
|---|---|---|
| A permission request is created as pending | `ai_run_permission` | the deciders of §23.3 |
| A run becomes `pending_approval` | `ai_run_approval` | managers |
| A run reports `needs_input` | `ai_run_input` | the requester |

- **Managers** are the workspace members whose roles grant `ai_runs.manage` or `ai_runs_approvals.manage`, the workspace owner(s), and the owners and admins of the run's project.
- **Limits:** at most 20 recipients per event, and never the actor.
- **Live push:** each recipient also gets a `ChatWS.push_user` of `ai_run:update`.
- **Best effort:** a failure never fails the request.

### 24.7 Retention
- A plugin job `ai_runner.retention` runs daily, per workspace.
- For runs finished more than `retention_days` ago, it deletes their `ar_run_events` and sets `ar_run_turns.text` and `ar_run_requests.input` to NULL.
- It also deletes `ar_sessions` rows of revoked runners.
- It returns the counts.

### 24.8 Docs and review
- **`docs/AI_RUNNER_SETUP.md`:** the runbook for a machine owner:
  - install the runner;
  - `claude setup-token`;
  - register in OpsAPI;
  - `runner.json` profiles;
  - the LaunchAgent;
  - test with the fake agent;
  - troubleshooting.
- **Security review:** a fresh review of the whole AI Runs change (plugin, runner, dashboard, MCP), with every confirmed finding fixed.

### 24.9 A readable run log (runner)
For a stream-json agent, the runner turns the agent's stdout into readable `log` events instead of forwarding raw JSON:

| Agent message | Log event |
|---|---|
| `system`/`init` | `Session started · model <m>` |
| assistant text | the text, one event per paragraph, at most 4 KB |
| assistant `tool_use` | `→ <Tool>: <command \| file_path \| pattern \| url>`, at most 300 characters |
| `user` `tool_result` | `← <first line of the result>`, at most 200 characters, or `← error: …` |
| `result` | `Turn <n> finished · <in>/<out> tokens · <duration>`, with the full text in `summary` |
| `rate_limit_event` | nothing (it goes to the heartbeat) |
| unparseable lines and stderr | as today |

Everything is redacted as before. For `args` agents (Claude without the bridge), the same rendering applies when their lines parse as Claude stream-json.

### 24.10 Acceptance
- **Plugin sandbox:**
  - similar-work warning and confirm;
  - the user and workspace caps;
  - the token limit;
  - profile unavailable (start refused, claim skipped);
  - the sessions API with RBAC;
  - the overview numbers;
  - notifications created for the right people;
  - the retention job;
  - migration 3 run twice;
  - isolation between workspaces.
- **Real runner:** a profile whose health command fails is reported unavailable, and its runs are not claimed.
- **Go tests:** health checks, that the output never leaves the runner, and the log rendering (§24.9).
- **Cypress:**
  - the Start dialog shows similar work and needs "Start anyway";
  - the Machines page lists sessions;
  - the overview cards render.

---

## 25. Security review fixes (2026-10-12)

A fresh review of the whole feature (plugin, runner, dashboard, MCP) confirmed the items below. Each one is fixed as specified. The review found tenant isolation, SQL, token handling, the dashboard and the long-polls clean.

### 25.1 Who may use a machine, decide and approve (review finding 1, high)
- **Runner access** is a new `ar_runners.access JSONB` column, default `{"mode":"owner"}`:
  - `owner`: only the runner's `created_by` and AI-run managers.
  - `everyone`: anyone who may start a run.
  - `listed`: the runner's owner, managers, plus `users[]` (user uuids) and `projects[]` (kanban project uuids).
  - Here, AI-run managers means `ai_runs.manage` or `ai_runners.manage`.
  - It is set with `PUT /runners/:uuid/access { mode, users?, projects? }`, which needs `ai_runners.manage`; uuids are validated against the workspace.
  - `GET /runners` (the Start dialog) lists only runners the caller may use, with `access` shown to `ai_runners.manage`.
  - Start, retry and preview → 403 "You can't use this runner" otherwise.
  - Runners registered before this change get `{"mode":"everyone"}`, so existing setups keep working.
- **Managers (deciders, approvers):** only `ai_runs.manage` or `ai_runs_approvals.manage`.
  - Project owners and admins count only when the new `approval_policy.project_admins_decide` is true (default false).
  - `projects.manage` no longer gives any AI-run power beyond seeing runs.
- **No self-approval:**
  - Under `deciders = "managers"`, the requester never decides their own run's requests, even if they are a manager.
  - Nobody approves a `pending_approval` run they requested (403); another manager must.
  - `requester` and `requester_or_managers` keep the requester as a decider, which is the workspace's explicit choice.
- **Custom prompts:** editing the prompt at start needs `ai_runs.manage`. Project admins no longer can.

### 25.2 "Allow for this run" is exact (finding 2, high)
- **The server computes the rule key** from the stored input and ignores the runner's `rule_key`:
  - Bash: the command, trimmed, with whitespace collapsed.
  - Edit / Write / MultiEdit / NotebookEdit: the tool name plus `file_path` (or `notebook_path`).
  - Any other tool: the tool name plus the canonical input summary.
- **Never remembered:** a Bash command containing any of `; & | \` $( ) < >`, a newline, or `\`. The server stores `remember = false`, and `rememberable: false` is returned on the request so the dashboard hides "Allow for this run".
- **Auto-allow** happens only on an exact rule-key match. It is recorded with `decided_by` = the original decider and reason "Allowed earlier in this run (exact match)".

### 25.3 The runner's git can't run repo code (finding 3, high)
- **Disabled hooks and fsmonitor:** every git call the runner makes runs as `git -c core.hooksPath=/dev/null -c core.fsmonitor=false …`. Commit and push also pass `--no-verify`.
- **Tamper check:**
  - At run start, the runner records a sha256 of `.git/config` and the list of `.git/hooks/*` and `.git/info/*` files.
  - Before committing, if any of them changed, the run fails as `git_tampered`: nothing is committed or pushed, and the folder is restored as for a failed run.

### 25.4 The decider sees everything that will run (finding 4, medium)
- **Oversized requests:** a request whose input JSON is over 8 KB, or whose readable summary is over 2,000 characters, is **denied automatically** with "Too large to review". That happens on the server (status `denied`, `decided_by` NULL, reason) and also in the runner, before asking.
- **Request id reuse:** a repeated `request_id` with a different tool or summary gets 409 instead of the earlier decision.

### 25.5 Safety list parsing (finding 5, medium)
- **Unquoting:** before matching, each word is unquoted the way a shell would (quotes and backslashes removed), so `g\it`, `g'i't` and `su""do` match.
- **Segments:** a command is split on `; && || | & $( \` ` and newlines, and every segment is checked.
- **`git -c`:** any `git -c …` is blocked, since it can redefine aliases, hooks or ssh. `git -C <dir>` is skipped, and scanning continues for the subcommand.

### 25.6 Secrets (finding 6, medium)
- **Server redaction** (`U.redact`) also masks:
  - `sk_live_`, `sk_test_`, `rk_live_`, `whsec_`, `glpat-`, `npm_` and `xox[abp]-` tokens;
  - AWS `AKIA…` keys;
  - JWTs (`eyJ…`);
  - URL credentials (`://user:pass@`);
  - `KEY=value` assignments whose key contains `SECRET`, `PASSWORD`, `TOKEN` or `API_KEY`.
- **Runner redaction:** the runner applies the same patterns to everything it sends (events, turns, summary, permission summaries, run-mcp comments).
- **Example profile:** the Claude profile adds `--disallowedTools "Read(**/.env),Read(**/.env.*),Read(**/*.pem),Read(**/id_*),Read(~/.ssh/**),Read(~/.aws/**),Read(~/.config/gh/**),Read(~/.netrc),Read(~/.npmrc),Read(~/.kube/**)"`.
- **Required flags:** the runner requires `--restricted` (as well as `--strict-mcp-config`) in every `claude` profile.
- **Agent environment** is an allow-list: `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_*`, `TERM`, `TZ`, `XDG_*`, `CLAUDE_CODE_OAUTH_TOKEN` (from the token file), the profile's `env`, and an optional `env_passthrough: [names]` in `runner.json`. Nothing else from the runner's own environment is passed (no `GH_TOKEN`, AWS keys, …).
- **Hand-started sessions:** their `prompt_preview` is sent only when `share_manual_prompts: true` in `runner.json` (default false).

### 25.7 Lower findings
- **Prompt fencing:** `task.title` and `project.name` have newlines replaced by spaces before rendering.
- **Branch names:** a branch name (`pr_base`, `base_branch`) may not start with `-`, on the server or in the runner.
- **Caps race:** caps are counted and the run inserted in one transaction, under `pg_advisory_xact_lock(hashtext('ai_runner:start:' || namespace_id))`.
- **Per-run limits:**
  - at most 20,000 log events (beyond that: dropped, plus one "log truncated" event);
  - at most 50 queued follow-ups (409 after that);
  - at most 500 permission requests (auto-denied after that).
- **MCP:**
  - `task_uuid` (and other ids) must be uuids;
  - `pr_url` must be `https://`;
  - the HTTP transport accepts only its own Host, and an Origin from `MCP_ALLOWED_ORIGINS` when one is sent.

### 25.8 As built
- **Listed projects:** for preview, start and retry, `listed` access means the task's project is in `projects[]`. For `GET /runners`, which has no task, it means the caller is a member of a listed project.
- **What `projects.manage` still gives:** it no longer counts as a project admin for AI runs. It only lets you see runs.
- **Redacted commands:** a command containing a redacted secret is never rememberable, since two different secrets would redact to the same key.
- **Never-remember characters:** the set also includes a bare `$` and `(`. So `python3 -c "print(6*7)"` can only be allowed once.
- **Rule keys for other tools** are the tool plus its whole input as sorted-key JSON, not its summary.
- **Rejecting your own pending run** is allowed, because it is the same as cancelling it. Only approving it is blocked.
- **Past 500 requests in a run:** the reply is `{ request: { uuid: null, status: "denied" } }`, and nothing is stored.
- **Past 20,000 events in a run:** further events are dropped, after one "Log truncated" event with seq 2147483647.
- **MCP HTTP:** allowed hosts come from `MCP_HOST` (default: localhost and the listen address). A request carrying an Origin needs that Origin in `MCP_ALLOWED_ORIGINS`.
- **Tampered folder:** after `git_tampered`, the runner runs no more git in that folder (a tampered config could define filters). The folder is left on the run's branch, with the agent's changes uncommitted, for a person to check `.git`. `gh` also gets the hook and fsmonitor overrides, through `GIT_CONFIG_COUNT`, because it runs git itself.

---

## 26. Tracking sessions started by hand as tasks

**Goal:** everything an AI agent does on a team machine is tracked in OpsAPI. When someone starts Claude Code or Cursor by hand on the Mac Studio (not through Start with AI), OpsAPI creates a kanban task for that session automatically. A manager can then assign it to an employee like any other task. Runs started from OpsAPI already have a task and are skipped.

### 26.1 What the runner reports (PromptPilot)
- **Session details:** the heartbeat inventory already lists every session the observer sees under the registration's roots: tool, status `busy|idle|ended`, cwd, branch, session_id, started_at, updated_at and labels.
- **`first_prompt`:** a new inventory field, with the session's first prompt (redacted, whitespace collapsed, at most 300 characters). It is sent only when `share_manual_prompts: true`. `prompt_preview` stays the latest prompt, cut to 80 characters.
- **`inventory_roots`:** an optional list in a registration. Sessions under these folders are reported in the inventory, but runs may still only use `allowed_roots`. The default is `allowed_roots`, and `["~"]` reports every session on the machine. Each entry must exist (config error otherwise).

### 26.2 Settings (`ar_settings.session_tracking JSONB`, plugin migration 5)
`{ enabled: false, project_uuid: null, column: null, status: "in_progress", notify: true }`, in `GET/PUT /settings`, which needs `ai_runs_settings.manage`.
- `project_uuid` must be a kanban project of the workspace, and is required when `enabled`.
- `column` is a column name on that project's first board. If it is not set, the task goes to the board's first column.
- `status` is the task status to set: `todo` or `in_progress`.

### 26.3 Creating the task (server, on heartbeat)
- **Table `ar_tracked_sessions`:**
  - columns: `namespace_id`, `runner_uuid`, `session_ref` (Claude's `session_id`, else the inventory `key`), `task_uuid`, `tool`, `cwd`, `branch`, `first_seen_at`, `last_seen_at`, `ended_at`;
  - `UNIQUE (runner_uuid, session_ref)`, with the same-namespace trigger.
- **When a task is created:** tracking is enabled, and the heartbeat reports a session that is **not managed** (no run linked), whose status is `busy`, and which has no row yet. All three must hold.
- **What happens:** the server creates one kanban task in the configured project, column and status, then inserts the row.
  - `ON CONFLICT DO NOTHING` plus the unique key mean two pods or two heartbeats never create two tasks.
  - At most 20 new tasks per heartbeat; any extra are created on later heartbeats.
- **The task:**
  - **Title:** the first line of `first_prompt` (at most 120 characters). Without it: `<Tool> session in <folder name> on <runner name>`.
  - **Description:**
    - "Started by hand on <runner> and tracked automatically by AI Runs.";
    - tool, folder, branch, started, session id;
    - the first prompt, if shared.
  - **Assignees:** none, so a manager assigns it.
  - **`created_by`:** the runner's `created_by`.
  - **`metadata.ai_session`:** `{ runner_uuid, runner_name, session_ref, tool, cwd, branch }`.
- **Notification:** when `notify` is on, managers (§24.6 rules, at most 20) get an `ai_session_task` notification, "New task from a Claude session on mac-studio: <title>", linking to the task. The migration widens the notification type check.
- **Ending:**
  - Each heartbeat updates `last_seen_at` for the sessions it reports.
  - A tracked session that is reported `ended`, or that stops being reported for 10 minutes, gets `ended_at` and one task comment: "Session ended (last active <time>)."
  - The lease sweep handles disappeared sessions of runners that stopped reporting.
  - The task status is not changed; people decide when it's done.
- **Best effort:** none of this can fail a heartbeat. It is wrapped and logged, like the notifications.

### 26.4 API and dashboard
- `GET /sessions` rows gain `task { uuid, task_number, title, project_uuid }` for tracked sessions.
- **AI run settings:** a "Track sessions started by hand" section with:
  - the toggle, project, column, status and notify fields;
  - a note that titles need `share_manual_prompts: true` on the runner, and that `inventory_roots` widens what is seen.
- **Machines page:** a manual session shows its task ("Task #12 →").

### 26.5 Acceptance
- **Plugin sandbox:**
  - a fake runner's busy manual session creates exactly one task, with no duplicate on the next heartbeat, nor from parallel heartbeats;
  - title from `first_prompt`, and the fallback title;
  - project, column and status;
  - managed sessions and idle-only sessions are skipped;
  - disabled tracking does nothing;
  - the 20-per-heartbeat cap;
  - ending: the comment is posted once, both for an `ended` status and for disappearance (with the clock backdated);
  - the notification;
  - settings validation and RBAC;
  - isolation between workspaces;
  - migration 5 run twice.
- **Go tests:** `first_prompt` is sent only with `share_manual_prompts`, and is redacted; `inventory_roots` (sessions outside `allowed_roots` are reported but can't be used for runs).
- **Real runner (`promptpilot_test.py`):** a fake "manual" session the runner reports (a session whose labels make it manual) becomes a task.
- **Cypress:** the settings section saves, and Machines shows the task link.

---

## 27. Everything configurable (multi-tenant SaaS)

AI Runs is a feature of a SaaS platform, so behaviour is set in the admin dashboard, not in code:
- **Workspace admins** configure their own workspace.
- **Platform admins** configure platform-wide timings and limits.
- **Machine owners** control what may leave their machine.

### 27.0 Boundaries (what is deliberately *not* configurable)
- **Tenant boundary:** a source's data is only ever written into the workspace that source is connected to. There is no token that writes across workspaces.
  - A machine or integration that should feed several workspaces connects to each one, with its own token. A `runner.json` has a list of `registrations`, and the Runners page registers a connection.
  - So "which workspace gets the tasks" is decided by which workspaces the source is connected to.
- **Consent boundary:** the machine owner's `runner.json` decides:
  - which folders may be reported at most (`inventory_roots`);
  - whether prompt text may leave the machine (`share_manual_prompts`);
  - which commands may run (profiles).

  Dashboards can narrow these, never widen them. The commands an agent profile runs are never set from a web page.
- **Safety:** the runner's built-in safety list and the server's redaction can be **added to** from the dashboard, never removed.

### 27.1 Sources, not just PromptPilot
- **Kinds:** a registered connection has `kind`, either `runner` (runs tasks and reports sessions; the default) or `source` (only reports sessions). A `source` gets 403 on `claim`.
  - **Register:** `POST /runners { name, kind }`.
  - **Runners page:** becomes **Runners & sources**, with a kind filter and register dialog.
- **Open session-report API, for any tool** (a CI job, another observer, an IDE plugin, Codex, Windsurf, …):
  - **Endpoint:** `POST /api/v2/ai-runner/public/runner/sessions { sessions: [ { key, tool, status, cwd, branch, session_id, started_at, updated_at, first_prompt, prompt_preview, labels } ] }`, with the connection's token.
  - **Behaviour:** the same storage and tracking as a heartbeat inventory.
  - **Fields:** `tool` and `status` are free text.
  - **Docs:** `docs/AI_RUNNER_SOURCES.md`, with a curl example.
- **PromptPilot report-only mode:** a registration with `report_only: true` never claims runs, so a machine can be tracked without running anything.

### 27.2 What a connection reports (server-driven, per connection)
- **Setting:** `ar_runners.report_filter JSONB`: `{ folders: [glob], exclude_folders: [glob], tools: [names] }`; empty means everything the owner allows. It is set on the Runners & sources page with `ai_runners.manage`.
- **Delivery:** the server returns it in the heartbeat's `config.report_filter`. The runner applies it on top of `inventory_roots` (only ever narrowing). The server also applies it on ingest, for sources that don't filter themselves.

### 27.3 Routing rules: where each session's task goes
- **Table `ar_track_rules`:** ordered per workspace; the first enabled match wins.
  - **`match`:** `{ runner_uuids[], tools[], folder_globs[], branch_globs[], prompt_keywords[] }`. Empty means any.
  - **`action`:**
    ```
    { type: "create_task"|"ignore", project_uuid, column, status: todo|in_progress, priority,
      assignee_uuids[] (empty = unassigned), title_template, description_template,
      notify: "managers"|"assignees"|"none"|"users", notify_user_uuids[] }
    ```
- **Fallback:** a session no rule matches uses the workspace default, the §26.2 `session_tracking` target.
- **Templates:** variables `{{first_prompt}}`, `{{prompt_preview}}`, `{{tool}}`, `{{tool_label}}`, `{{folder}}`, `{{repo}}`, `{{branch}}`, `{{runner}}`, `{{started}}` and `{{session_id}}`; unknown ones render empty. The defaults reproduce the §26.3 title and description.
- **API** (`ai_runs_settings.manage`):
  - `GET/POST /track-rules`, `PUT/DELETE /track-rules/:uuid`, `POST /track-rules/order { uuids }`;
  - `POST /track-rules/test { session }` returns `{ rule, action, title, description }` for a sample session. Nothing is created.
- **Checks:** projects and assignees must be in the workspace (assignees must be active members), and globs are capped in size.

### 27.4 Workspace tunables (AI run settings)
- **`session_tracking`** gains:
  - `gone_after_minutes` (1–1440, default 10);
  - `max_new_per_heartbeat` (1–100, default 20);
  - `idle_statuses` (default the current idle list): sessions with these statuses don't count as busy;
  - `tool_labels` `{ tool: label }` (default `{claude: "Claude", cursor: "Cursor"}`).
- **`task_automation`** replaces the fixed "in progress" / "review" with `on_start` and `on_success`, each `{ enabled, status, column }`. The status is a kanban status; the column name is optional (else unchanged). The old booleans are read as before.
- **`safety`** adds to the built-in lists:
  - `extra_denied_commands` ([prefix or glob]): sent to runners in the heartbeat config, and denied like the built-in safety list;
  - `extra_redactions` ([regex], validated and size-capped): masked on the server.

### 27.5 Platform settings (platform admins)
- **Table `ar_platform_settings`** (one row), set with `GET/PUT /api/v2/ai-runner/platform/settings` (platform admin only). It holds:
  - protocol timings: `heartbeat_s`, `claim_wait_s`, `lease_s`, `online_s`;
  - timeouts: `queue_timeout_hours`, `approval_timeout_hours`;
  - limits: `max_events_per_run`, `max_queued_followups`, `max_requests_per_run`, `max_tracked_per_heartbeat_cap`;
  - upper bounds for the workspace guards.
- **Defaults** are today's values, used when the table is empty.
- **Caching:** the values are read once a minute into a shared cache, so nothing extra happens per request. The runner already follows the heartbeat and claim timings the server sends.
- **Dashboard:** an admin-only page, **AI Runs platform settings**.

### 27.6 Acceptance
- **Plugin sandbox:**
  - source kind (no claim; the session API works);
  - report filters on ingest;
  - rules: first match wins, ignore, each match field, templates, assignees and notify modes, the tester, order, validation and RBAC;
  - the workspace tunables, task-automation columns and extra redactions;
  - platform settings (platform admin only, bounds, picked up by the heartbeat config and timeouts);
  - migrations run twice;
  - isolation between workspaces.
- **Go:** `report_filter` narrowing (never widening), `extra_denied_commands`, and report-only mode.
- **Cypress:** the rules editor and tester, connection kind and report filter, and the platform settings page.

### 27.7 As built
- **Routes:** a connection's kind and report filter are edited with `PUT /runners/:uuid { name?, kind?, labels?, report_filter? }`. `GET /runners?kind=` filters by kind.
- **Sources:** a `source` is left out of Start with AI, and a run on one is refused (422).
- **Report filter, the same on the runner and the server:**
  - **Globs:**
    - `*` and `?` stay within one folder name, and `**` crosses folders.
    - A glob covers its folder and everything below it.
    - `/…` is absolute; `~/…` means under any home folder; any other glob matches at any depth.
    - An empty glob matches nothing.
  - **Tools** are compared case-insensitively.
  - **Runs' own sessions:** a connection's own run sessions are always kept, because the busy-folder check needs them.
  - **When it applies:** the runner only gets the filter in its first heartbeat's reply. Until then, the server's ingest filter covers it.
- **Extra denied commands:**
  - An entry without `*` or `?` is a whole-word prefix of each command segment. One with them is a glob.
  - The runner denies a match before asking anyone. The server also denies it, as a backstop for older runners.
- **Rules:**
  - `session_tracking.enabled` still switches all tracking on and off, rules included. `project_uuid` is the fallback target.
  - To track only rule-matched sessions, end the list with a match-anything rule that ignores.
  - An ignored session is recorded, so it isn't routed again later.
  - At most 100 rules, each with an optional `name`.
- **Templates:** a line whose variables are all empty is dropped. `{{folder}}` is the full path and `{{repo}}` its last folder name.
- **Platform settings:**
  - They are cached for 60 s per worker; a save refreshes them at once on that worker.
  - `heartbeat_s` must be below both `lease_s` and `online_s`.
  - Lowering a bound caps the values workspaces already saved.
  - `GET /settings` returns the current bounds as `limits`, for the form.
- **Runner:**
  - It claims only after its first successful heartbeat, so the workspace's denied commands arrive before any run.
  - Version 0.5.0.
- **Dashboard address:** a platform setting `dashboard_url` (an http(s) address, no path) sets where task links point, in prompts, run details and the agent's `get_task`. When it's empty, links use `FRONTEND_URL`. The two differ where password-reset emails go to another site than the dashboard, as on workstation int (`FRONTEND_URL` is int.diytaxreturn.co.uk, the dashboard is int-opsapi-ui.workstation.co.uk).
- **Platform settings page:** reached from AI run settings, and shown only to platform admins. It has no sidebar entry, because plugin menus are per workspace.

---

## 28. The built-in runner: no machine needed

A workspace without a machine running PromptPilot can still run AI tasks. Each workspace gets a **built-in runner**: it runs inside OpsAPI on an AI model, so nobody has to keep a laptop or a Mac Studio on. Machines stay the way to run Claude Code or Cursor with a shell (builds, tests); the built-in runner is the always-there default.

### 28.0 Decisions
- **The model:** the workspace's own AI providers (Workspace → AI providers: a cloud API key, a local OpenAI-compatible server), then the platform's model (`AI_PROVIDER`, Ollama by default). A workspace provider's data never falls back to the platform's model.
- **What it can do:**
  - **Without a repository:** plan, answer and write on the task: comments and subtasks.
  - **With a GitHub repository:** read the code and commit to the run's own branch through the GitHub API, then open a pull request.
  - **No shell:** it can't run code, builds or tests, so it needs no permission bridge. Nothing reaches the base branch without a person merging the pull request.
- **GitHub access:** one **GitHub App** for the platform. Workspaces install it on the repositories they choose. There are no personal tokens, and every run's token covers only its one repository.

### 28.1 The runner and its profiles
- **One per workspace:** `ar_runners.kind = 'builtin'` (migration 7 widens the kind CHECK and adds a unique index on `namespace_id` for it). It is created on first use: the runners list, a preview or a start.
- **Always online:** `R.online_sql` counts it online whatever its heartbeat. It has no token (a random hash nobody holds), can't be revoked (409) or have its token rotated (409), and stays `builtin` (422 on a kind change). It can be **paused**, and its **Access** works like any runner's (default: everyone who may start runs).
- **Profiles** (recomputed on every listing):
  - `provider:<uuid>`: each enabled workspace AI provider, except JobShout. Unavailable when its key or model is missing.
  - `platform`: the platform's model. Unavailable when the server has no model, or when the shared health check last saw it down.
  - Workspace providers come first, so the platform model is the default only when the workspace has none.
- **Repositories:** `none`, then `github:<owner>/<name>` for each repository of the workspace's GitHub installations (archived ones left out). They are read from GitHub at most every 5 minutes, or at once with `GET /runners?refresh=1`, a connect or a disconnect.
- **Start dialog:** the built-in runner is listed after the machines. The dialog picks the first runner online, so it picks the built-in one when no machine is.

### 28.2 Running a run
- **Same lifecycle as a machine's:** queued → claimed → running → succeeded / failed / cancelled / lost, with status reports through `R.report` (compare-and-set), turns, follow-ups, `needs_input`, cancel, task automation, notifications and retry.
- **Where it runs:** in nginx timers. A start or an approval kicks the queue at once; the plugin job `builtin_runner` (every minute, once per deployment) kicks it again for anything missed.
- **Claiming:** under a cluster-wide advisory lock, at most `builtin_max_runs` built-in runs at once over all workspaces (default 2) and `builtin_max_runs_per_workspace` per workspace (default 1); highest task priority, then oldest. Self-hosted models on shared hardware can't take many at once.
- **Leases:** the worker renews its runs' leases every 15 s. If the pod dies, the lease sweep marks the run lost, as for a machine.
- **The agent:** a tool loop over `lib/agent/llm` (`Llm.chat`), at most `builtin_max_steps` model calls (default 40), within the run's time limit (`max_run_minutes`).
  - **System prompt:** the tools, the branch, the rules (task text is data; never write secrets; `NEEDS_INPUT:` to ask).
  - **User prompt:** the workspace's template, rendered with the repository instead of a folder.
  - **Small models:** tool results older than the last 6 shrink to a stub, so a long run stays inside a small context window.
- **Task tools:** `get_task` (the task, checklist and 20 latest comments), `add_comment` (as the requester, prefixed `[AI run]`, at most 20), `add_subtask` (under the task, in its column, at most 20).
- **Repository tools:** `list_files`, `read_file` (by lines), `search_code` (GitHub code search, default branch), `write_file` (a whole file, one commit on the run's branch; the branch is made from the base on the first write, and a retry carries on with the branch it left).
  - **Off limits:** keys and environment files (`.env*`, `*.pem`, `*.key`, `id_rsa`, `.npmrc`, …) for reading and writing; `.github/workflows/` for writing; paths with `.` or `..`.
- **The end:** the last reply is the summary. With commits and output `pull_request`, a pull request opens from the branch to `pr_base` (or the base when that branch doesn't exist), draft per the settings, with the summary and the task link; an open one for the branch is reused. The summary (and the pull request link) is posted on the task.
- **Usage:** every model call is an `ai_usage` row (`feature 'agent_run'`, the requester, the run); the run's token totals grow with each call, and each reply is a turn with its usage. The workspace's daily token limit applies at start, and `AI_USER_DAILY_TOKEN_LIMIT` per call.
- **Failures** (`error_category`): `model_error`, `rate_limited`, `timeout`, `step_limit`, `needs_input_timeout`, `github_error`, `github_not_configured`, `bad_repo_path`, `pr_failed` (the branch is kept), `profile_unavailable`, `plugin_disabled`, `task_gone`, `internal`.
- **No folder lock:** a built-in run works on its own branch through the API. One open run per task still holds.

### 28.3 The GitHub App
- **Platform settings** (`PUT /platform/settings { github: { … } }`, platform admins): `app_id`, `app_slug`, `client_id`, `api_url` and `web_url` (GitHub Enterprise Server; default GitHub.com), and the write-only `client_secret` and `private_key` (an RSA PEM), sealed with the secret box (purpose `ai_runner_github`). The view shows only `has_client_secret` / `has_private_key`, and the **callback URL** to give GitHub: `<dashboard>/dashboard/ai-runner/github`. Only the keys given change; `""` clears one; `github: null` clears them all.
- **Creating the App on GitHub:** Callback URL and Setup URL = that callback URL; *Redirect on update* on; *Request user authorization during installation* off; webhook inactive; repository permissions Contents read and write, Pull requests read and write.
- **Tokens:** a 9-minute app JWT (RS256, `iss` = App ID) mints installation tokens, cached for 50 minutes. A run's token is scoped to its one repository.
- **Connecting an installation** (workspace, `ai_runners.manage`):
  1. **Connect GitHub** opens `<web>/apps/<slug>/installations/new`; the person installs the App on the repositories they choose (or changes them).
  2. GitHub returns to `/dashboard/ai-runner/github?installation_id=…`. The page asks `POST /github/authorize { installation_id }` for a GitHub sign-in URL whose `state` is signed (HMAC with `JWT_SECRET_KEY`, 10 minutes) and names the workspace, the person and the installation.
  3. GitHub returns with `?code&state`. `POST /github/installations { code, state }` checks the state (same workspace, same person, unexpired), exchanges the code, and accepts the installation only if GitHub lists it among the person's own (`GET /user/installations`). Installation ids are sequential, so this check is what stops someone attaching another account's installation.
- **API:** `GET /github` (`ai_runs.create` or `ai_runners.manage`): configured, installations, and the install link for managers. `DELETE /github/installations/:uuid` disconnects one (the App stays installed on GitHub).
- **Table:** `ar_github_installations (namespace_id, installation_id, account_login, account_type, repository_selection, created_by, UNIQUE (namespace_id, installation_id))`. The same installation may serve several workspaces; each connected it itself.

### 28.4 Dashboard
- **Start with AI:** the built-in runner reads "(no machine needed)"; its profiles are "AI model"; the folder is a **Repository** list (no repository, or the connected repositories); the output line says what happens to the work.
- **Runners & sources:** a built-in runner card (what it does, GitHub status, Connect GitHub, the connected accounts with Disconnect, Refresh repositories) and its row (Built-in, Inside OpsAPI, Always on; Access and Pause only).
- **`/dashboard/ai-runner/github`:** finishes a connection, or says why it can't (organisation approval pending, sign-in denied, expired).
- **Platform settings:** the built-in limits, and the GitHub App form with the setup steps and the callback URL. Saving the other settings never sends the GitHub App back.
- **Runs:** a built-in run's "folder" shows as *GitHub owner/name* or *No repository*.

### 28.5 Security
- **Who:** the built-in runner follows the runner Access rules (§25.1) and every start rule (assignee, project admins, managers; caps; similar work; approval policy).
- **What it touches:** its own task (comments, subtasks) and, through a token scoped to one repository, its own branch. It can't merge, push to the base branch, change CI, or read keys and environment files. A prompt-injected task can at most write to its branch, which a person reviews.
- **Secrets:** the App's private key and client secret are sealed and never returned; installation tokens live only in the server's memory cache. Every text the agent writes is redacted (`U.redact`, with the workspace's extra redactions).
- **Isolation:** a workspace sees and uses only its own built-in runner and installations; another workspace's runner uuid is refused.

### 28.6 Acceptance
- **Sandbox (`builtin_test.py`, mock Ollama + GitHub, 122 checks):**
  - the runner in every workspace, online, preselected;
  - a plan run (tools, subtask, comments, turns, usage, `ai_usage` rows);
  - the GitHub App settings (platform admin only, validation, sealed, partial saves);
  - connecting (dev refused, tampered / foreign / other-workspace states refused, someone else's installation refused);
  - a code run (scoped token, RS256 signature checked with the public key, one commit on the run's branch, secret / workflow / `..` paths refused, the draft pull request, main untouched, the task comment) and its retry;
  - needs_input, a follow-up, cancel, the per-workspace limit, the step limit, a model failure;
  - pause, access, no token, no revoke, kind fixed; isolation; disconnect.
- **Real model (local stack, qwen3.8 on Ollama):** a plan run (comment and five subtasks) and a code run against a mock GitHub (read README and `src/app.js`, committed a correct section on its branch).
- **Cypress (`ai-runner-builtin.cy.ts`):** the runner card and row, a run started from the task page on the real model, the GitHub return page, the platform page (and that saving it never sends the App).

## 29. AI task completion (context, vault PRs, executors)

Per-project ways of working and a durable task work record so Start with AI is not prompt-only.

### 29.1 Project settings (`ar_project_settings`)
- `target_repo_url` — PRs open in this remote (never the OpsAPI repo); inherited by tasks.
- `skills_git_urls` JSON — `{ url, ref?, path?, label? }` packs the agent must load before coding.
- `md_refs` JSON — `{ path|url, label? }` reference markdown.
- `vault_url`, `vault_secret_path`, `vault_mount_path`, `vault_token_sealed` — HashiCorp/WSL Vault; the access token is sealed in OpsAPI (`secret-box` purpose `ai_runner_vault`). At PR time OpsAPI fetches `github_token`/`token`/`pat` from the secret and opens the PR in `target_repo_url`.
- `allowed_executors` — `machine` | `builtin` | `jobshout` | `provider` | `provider:<uuid>`; empty = all allowed.
- `executor_locked` + `default_executor` — when locked, only managers may change the executor at start.

API: `GET|PUT /projects/:project_uuid/settings` (no sealed token in responses; write `vault_token` to set/replace).

### 29.2 Task work (`ar_task_work`)
On every start (including `pending_approval` / queued with no machine), OpsAPI writes a work row: frozen prompt, context snapshot, executor, linked `run_uuid`. Turns update `conversation_summary`. Task page shows the AI work panel + manager links.

`GET /tasks/:task_uuid/work` → `{ work, history, pull_requests, project, manager_links }`.

### 29.3 Pull requests (`ar_task_prs`)
Multiple PRs per task (one unique per run). On success (or when `pr_url` is reported), `vault_pr.open_or_attach` stores the URL, comments on the task, and notifies managers (`ai_run_pr_ready`) with the task URL. Managers `POST /tasks/:task_uuid/prs/:pr_uuid/review` with `approved` | `changes_requested` — **never merges**.

### 29.4 Executors
`ar_runs.executor_kind` + optional `provider_uuid`. JobShout launches via `lib/jobshout-client` (`jobshout_exec`). Workspace AI providers may include `bedrock` and `xai` (Grok). Claim payload includes `context`, `skills_git_urls`, `md_refs` for preload before the IDE/agent starts.

### 29.5 Prompt variables
Added: `project.context`, `target_repo` (plus existing task/repo/branch/output variables).

### 29.6 Web terminal (workstation-terminal)

Replaced by **[AI_RUNNER_WEB_TERMINAL.md](AI_RUNNER_WEB_TERMINAL.md)** (2026-10-23): terminals are connected per
workspace (address + sealed shared secret + agents), Start with AI opens the task's folder there with a signed launch
link, and the webhook is verified with that terminal's secret against the launch it names. The first version's
environment variables (`WORKSTATION_TERMINAL_URL`, `WORKSTATION_TERMINAL_WEBHOOK_SECRET`) are no longer read.

### 29.7 PR status polling

`ar_task_prs.state` tracks GitHub lifecycle (`open` | `merged` | `closed`). Manager `review_status` is separate (approve / changes_requested — never merges). `pr_poll` refreshes open PRs via the project's Vault GitHub token (throttled on `GET .../work`, and a ~3 minute timer). On change it posts a task comment (“PR #N is now merged”).
