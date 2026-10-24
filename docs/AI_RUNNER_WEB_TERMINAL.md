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
| W7 (2026-10-24, narrows W2) | **Power users may be signed in by the link** (§8), when all of these hold: the terminal has auto sign-in on, the OpsAPI user holds `ai_terminal_autologin`, they confirmed an emailed code in the last 12 h (step-up), **and the terminal's own config maps their email to a terminal user**. Everyone else still signs in with an SSH key. | One click from task to working agent for trusted people; a stolen OpsAPI password alone still isn't a shell (step-up code + terminal-side allowlist). |
| W8 (2026-10-24) | The agent **reports its pull request** to OpsAPI with a per-launch token (§9); the task moves to Review when it opens and to Done when it merges. | Task to finished work with no hand-offs. |

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
| `login` | object | optional, §8: `{ "email": ≤ 254 chars, "user": OpsAPI user UUID, "stepup": unix seconds of the step-up }`. When present OpsAPI keeps `exp - iat` at **120** |
| `report` | object | optional, §9: `{ "url": https URL ≤ 512 chars, "token": [A-Za-z0-9_-]{32,128} }` |

Terminals ignore claims they don't know, so a newer OpsAPI works with an older terminal (it just never signs anyone in).

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
| `GET /terminal-autologin` | `ai_runs.read` | → `{allowed, stepup: {verified_at, expires_at} \| null}` (§8) |
| `POST /terminal-autologin/code` | `ai_terminal_autologin.create` | emails a code → `{sent: true}` (429 when too many) |
| `POST /terminal-autologin/verify` | `ai_terminal_autologin.create` | `{code}` → `{allowed, stepup}`; 401 wrong code |
| `DELETE /terminal-autologin` | `ai_runs.read` | forgets the step-up |
| `POST /public/terminal/report` | `Authorization: Bearer <report token>` | `{pr_url?, note?}` → `{task_uuid, pr?}` (§9) |

`POST /terminals`, `PUT /terminals/:uuid` also take `autologin` (boolean); `POST /tasks/:task_uuid/terminal-sessions`
takes `autologin: true` → 403 without the permission, 409 if the terminal doesn't allow it, 403 `code: stepup_required`
without a live step-up. The report address is `OPSAPI_PUBLIC_URL` + `/api/v2/ai-runner/public/terminal/report` when
set, else the launch request's `Host` (scheme from `X-Forwarded-Proto`); it must be https
(or localhost), otherwise the launch has no `report` claim.

`terminal = {uuid, name, url, agents: [{id, label}], is_active, autologin, secret_hint, created_by, created_at, updated_at}`.
`session = {uuid, task_uuid, project_uuid, opened_by, opened_by_name, terminal_uuid, terminal_name, terminal_url, path,
agent, agent_label, terminal_user, session_id, autologin, reported_at, status, started_at, ended_at, exit_code, ended_reason, expires_at,
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

## 8. Auto sign-in for power users (W7)

**OpsAPI.** A terminal row has `autologin` (off by default; `ai_runners.manage` turns it on). In Start with AI a
person who holds `ai_terminal_autologin` (owners and admins have it through RBAC) sees **Sign me in automatically**.
The first time, OpsAPI emails a 6-digit code (`POST /terminal-autologin/code`), they type it
(`POST /terminal-autologin/verify {code}`) and OpsAPI remembers the step-up for **12 hours**
(`ar_terminal_stepups`), bound to the email the code went to (if the account's email changes, it lapses). While it holds, a launch with `autologin: true` adds the `login` claim and the link
lives 120 s. The session row records `autologin = true`; the task comment says the person was signed in by OpsAPI.

**Terminal** (`config.yaml`):

```yaml
opsapi:
  autologin:
    enabled: true
    max_stepup_age_secs: 43200      # the step-up may be at most this old
    users:                          # OpsAPI email -> terminal user (must have an authorized key with local access)
      "alice@example.com": alice
```

`POST /api/launch/login {ticket}` (no login cookie needed; Origin checked; rate-limited and lock-out tracked like
SSH sign-in) verifies the ticket exactly like `/api/launch`, then also: `login` is present; `exp - iat ≤ 120`;
auto sign-in is on; the email (any case) is mapped; that terminal user has an authorized key allowing `local`;
`stepup ≤ iat` and `now - stepup ≤ max_stepup_age_secs`. It signs the person in as that user **through that
key** (its fingerprint), so revoking the key still ends the login. Each launch id can sign someone in **once**
(a second try → 409 `already_used`). Audit `auth_success` with `via=opsapi_launch`, the OpsAPI email and user.
Then the page calls `/api/launch` with the same ticket as usual. Errors: `autologin_off`, `autologin_not_allowed`,
`stepup_stale`, plus the §3 ones; the page then shows the normal SSH sign-in screen with the task waiting.

## 9. Reporting back and finishing (W8)

Every launch gets a random report token (only its SHA-256 is stored, on `ar_terminal_sessions.report_token_hash`;
good for 7 days). The terminal puts `report.url` / `report.token` into the shell as `OPSAPI_REPORT_URL` /
`OPSAPI_REPORT_TOKEN`; the prompt tells the agent to call it once the pull request is open:

```
POST /api/v2/ai-runner/public/terminal/report
Authorization: Bearer $OPSAPI_REPORT_TOKEN
{ "pr_url": "https://github.com/o/r/pull/12", "note": "optional summary" }
```

OpsAPI attaches the PR to the task (`ar_task_prs`, once per URL), comments, and applies
`task_automation.on_pr_open` (default: status `review`, column "Review"). The PR poll (§29.7 of `AI_RUNNER.md`)
then applies `task_automation.on_pr_merged` (default: status `completed`, column "Done") when GitHub says it
merged. Both are workspace AI run settings and can be switched off. The token can only attach PRs and notes to
its own task.

**Unattended agents.** The default agents include `claude_auto` ("Claude Code, unattended"):
`claude --dangerously-skip-permissions "$OPSAPI_TASK_PROMPT"`. It never stops to ask; this is only acceptable
because the terminal runs under its own macOS account (W1). Leave it out of a terminal's config to forbid it.
