# Web terminal for task work (OpsAPI ↔ workstation-terminal)

**Start with AI → "Work in the web terminal"**: the person picks a folder on the Mac and an agent, and
OpsAPI opens the terminal ([bwalia/workstation-terminal](https://github.com/bwalia/workstation-terminal),
`sshweb`) in a new browser tab. The terminal opens a tab in that folder and starts the agent with the
task as its first message. OpsAPI shows the session on the task until it ends.

This replaces the first version (§29.6 of `AI_RUNNER.md`), which passed the task id, repo and return
link as plain query parameters and had no folder.

## Decisions (2026-10-23)

| # | Decision | Why |
|---|---|---|
| W1 | Terminals run under a **separate macOS account** (not the owner's) | Anyone with a terminal gets that account's files and credentials. |
| W2 | **SSH-key sign-in stays.** A launch link never signs anyone in. | A stolen OpsAPI login must not become a shell on the Mac. |
| W3 | The agent **starts by itself** with the task as its first message; when it exits the person is left in the shell. | One click from task to working agent. |
| W4 | Task terminals **stay alive while the agent works**: output counts as activity, and they keep running for hours after the browser closes. Ordinary terminals keep their limits. | Long agent work was being killed after 1 h without typing. |
| W5 | Terminals are **configured per workspace** in the dashboard (address + shared secret), not with environment variables. | SaaS: each workspace connects its own machine. |
| W6 | Commands come only from the terminal's own config (agent allowlist). The link carries an agent **id**, the folder and the prompt — never a command. | A crafted link must not run anything. |

## 1. Connecting a terminal (per workspace)

Dashboard: AI Runs → Machines → **Web terminals** → Add. Name + address (e.g. `https://dev.workstation.co.uk`).
OpsAPI generates a random 32-byte shared secret (sealed with `secret-box`, purpose `ai_runner_terminal`),
shows it **once** with a ready-to-paste `opsapi:` block for the terminal's `config.yaml` (built by the dashboard, which
knows the API address the browser uses), and can rotate it.
The workspace also lists the agents people may pick (id + label; default `claude` Claude Code,
`codex` Codex, `cursor` Cursor, `shell` Just a terminal) — the ids must match the terminal's config.

## 2. Launch link (OpsAPI → browser → terminal)

`POST /api/v2/ai-runner/tasks/:task_uuid/terminal-sessions` `{ terminal_uuid, path, agent, prompt }`
(needs `ai_runs.create`) records a launch (`ar_terminal_sessions`, status `launched`), remembers the folder
for this project and terminal (`ar_project_settings.default_repo_paths[terminal_uuid]`), and returns
`launch_url`:

```
https://dev.workstation.co.uk/#launch=<ticket>
```

The ticket is in the **fragment**, so it never reaches proxies or access logs and has no URL-length
limit. `ticket = <payload>.<sig>`:

- `payload` = base64url (no padding) of compact JSON,
- `sig` = lowercase hex HMAC-SHA256(shared secret, `payload` as ASCII).

Claims (all required unless marked optional):

| claim | type | rule |
|---|---|---|
| `v` | int | `1` |
| `id` | string | launch id = `ar_terminal_sessions.uuid` (UUID) |
| `iat`, `exp` | int | unix seconds; `exp > now`; `exp - iat ≤ 3600` (OpsAPI uses 900) |
| `task` | string | task UUID |
| `num` | int | task number (optional) |
| `title` | string | ≤ 200 chars |
| `path` | string | absolute folder on the terminal's machine, ≤ 1024 chars |
| `agent` | string | agent id `[a-z0-9_-]{1,32}`; `shell` = no agent |
| `prompt` | string | ≤ 8000 chars, may be empty (OpsAPI caps it at 8000 **bytes**, so the ticket stays well inside the terminal's 32 KiB body limit) |
| `by` | string | display name of the OpsAPI user, ≤ 120 chars |
| `return` | string | task page URL; `https://` (or `http://localhost…` / `http://127.0.0.1…`). Optional: left out when the deployment has no absolute dashboard address |
| `ws` | string | workspace name, ≤ 120 chars (optional, display only) |

## 3. What the terminal does

1. The page reads `#launch=…`. If the person isn't signed in, the sign-in screen says which task is
   waiting; the ticket is kept until they sign in.
2. `POST /api/launch {ticket}` (login cookie + Origin, like every state-changing call). The terminal
   verifies the signature (constant time), `v`, `exp`, the lifetime cap and every field; checks the
   person has `local` access; resolves `path` with `realpath` and requires an existing **directory inside
   one of `local.allowed_roots`** (no symlink escapes); and looks `agent` up in `opsapi.agents`
   (`shell` is always allowed). Errors: `invalid_link`, `expired`, `folder_not_allowed`,
   `folder_not_found`, `unknown_agent`, `forbidden`, `already_used` (409).
3. A launch id is **single use**. Re-posting the same ticket as the same user returns the session it
   already opened (so a reload re-attaches); another user gets `already_used`.
4. The page opens a tab named `#<num> <title>` in that folder. The shell gets
   `OPSAPI_LAUNCH`, `OPSAPI_TASK`, `OPSAPI_TASK_NUMBER`, `OPSAPI_TASK_TITLE`, `OPSAPI_TASK_URL` and
   `OPSAPI_TASK_PROMPT` in its environment, and then runs the agent's configured command line, e.g.
   `claude "$OPSAPI_TASK_PROMPT"`. The prompt only ever reaches the shell inside a variable, so its text is
   never parsed as shell syntax.
5. The tab shows a banner (plain text, no HTML from the link): task number and title, who launched it,
   and **Back to task**.
6. The fragment is removed from the address bar once used.

Task sessions (W4): idle time counts output as activity (`opsapi.idle_timeout_secs`, default 4 h with
neither input nor output), and they survive a closed browser for `opsapi.detach_grace_secs`
(default 4 h). Key revocation, logout and access narrowing still end them immediately.

## 4. Webhook (terminal → OpsAPI)

`POST /api/v2/ai-runner/public/terminal/webhook`, header `X-Opsapi-Signature: sha256=<hex>` =
HMAC-SHA256(shared secret, raw body). Body:

```json
{"event":"session_start","launch":"<launch id>","session_id":"<hex>","user":"<terminal user>",
 "ts":1792600000,"exit_code":null,"reason":null}
```

`event` is `session_start` or `session_end` (`exit_code`, `reason` on end). OpsAPI finds the launch by
`launch`, verifies the signature with **that launch's terminal secret**, rejects `|ts − now| > 300 s`,
and applies events idempotently (a repeated start or end changes nothing and posts nothing). The task
gets one comment when work starts and one when it ends (with the duration). Unknown launch → 404,
bad signature → 401. The task id is never taken from the webhook.

## 5. OpsAPI API

| Method & path | Who | Body → answer |
|---|---|---|
| `GET /terminals` | `ai_runners.manage` | → `[terminal]` (never the secret) |
| `POST /terminals` | `ai_runners.manage` | `{name, url, agents?}` → 201 `{terminal, secret}` |
| `PUT /terminals/:uuid` | `ai_runners.manage` | `{name?, url?, agents?, is_active?}` → `terminal` |
| `POST /terminals/:uuid/rotate-secret` | `ai_runners.manage` | → `{terminal, secret}` |
| `DELETE /terminals/:uuid` | `ai_runners.manage` | → `{deleted: true}` (sessions stay on their tasks) |
| `POST /tasks/:task_uuid/terminal-sessions` | `ai_runs.create` + may start AI work on the task | `{terminal_uuid, path, agent, prompt?}` → 201 `{session, launch_url}` |
| `GET /tasks/:task_uuid/terminal-sessions` | `ai_runs.read` | → `[session]` (also in `GET /tasks/:task_uuid/work`) |
| `POST /tasks/:task_uuid/runs/preview` | (as before) | adds `terminals: [{uuid, name, url, agents, default_path, recent_paths}]`, `terminal_prompt` |
| `POST /public/terminal/webhook` | the terminal's signature | §4 → `session` |

`terminal = {uuid, name, url, agents: [{id, label}], is_active, secret_hint, created_by, created_at, updated_at}`.
`session = {uuid, task_uuid, project_uuid, opened_by, opened_by_name, terminal_uuid, terminal_name, terminal_url, path,
agent, agent_label, terminal_user, session_id, status, started_at, ended_at, exit_code, ended_reason, expires_at,
created_at, updated_at}`. Tables: `ar_terminals`, `ar_terminal_sessions` (migration
`20261023120000_ai_runner_web_terminals`).

## 6. Status on the task

`ar_terminal_sessions.status`: `launched` → `active` → `ended`; `launched` rows older than the link
lifetime show as `expired`. The task's AI work panel lists sessions (who, terminal, folder, agent,
started, ended, duration) and its **Work in the web terminal** button opens Start with AI in terminal
mode.

## 7. Security notes

- The terminal's account is the security boundary (W1). `allowed_roots` decides where a launch may
  open; it is not a sandbox — the shell can `cd` anywhere that account can.
- Prompts come from task text written by workspace members. Agents treat them as instructions;
  review what an agent does before merging its work.
- The shared secret signs both directions. Rotate it in the dashboard and paste the new block into the
  terminal's config; old links then stop working.
