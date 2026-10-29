# Web terminal for task work (OpsAPI ↔ workstation-terminal)

**Start with AI → "Work on it with AI myself"**: the person picks a folder on the Mac and an agent, and
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
| W9 (2026-10-26) | **Managers issue each person a key** in OpsAPI (§10), not the people themselves. The key pair is made in the manager's browser; only its public half reaches OpsAPI. Keys last **90 days**; blocking one, or the person leaving the workspace, stops it within a minute. | One place controls who can open a shell, and every sign-in is one named person. |
| W10 (2026-10-26) | **Work log**: every terminal tab, every prompt (full text, 90 days), every AI request with tokens and cost, every AI action (commands and files, in full), and a **screen replay** of each tab (output only, never keystrokes; 30 days). Managers see everyone; each person sees their own. | Know what was done, by whom, at what cost. Employees must be told what is recorded (UK GDPR). |

## 1. Connecting a terminal (per workspace)

Dashboard: AI Runs → Machines → **Web terminals** → Add. Name + address (e.g. `https://dev.workstation.co.uk`; it must
be https, plain http only on this machine: `localhost`, `127.0.0.1`, `[::1]`. A terminal saved with http before can't
be launched until its address is changed).
OpsAPI generates a random 32-byte shared secret (sealed with `secret-box`, purpose `ai_runner_terminal`),
shows it **once** with a ready-to-paste `opsapi:` block for the terminal's `config.yaml` (built by the dashboard, which
knows the API address the browser uses), and can rotate it.
The workspace also lists the agents people may pick (id + label; default `claude` Claude Code,
`codex` Codex, `cursor` Cursor, `shell` Just a terminal) — the ids must match the terminal's config. An agent whose id
ends in `_auto` (or with `"unattended": true`) works without stopping to ask: only `ai_runs.manage` may start it
(others get 403 and aren't offered it), and it is never a default.

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
   `claude -- "$OPSAPI_TASK_PROMPT"`. The prompt only ever reaches the shell inside a variable, so its text is
   never parsed as shell syntax, and `--` ends the agent's options so it can't be read as one. OpsAPI never sends a
   prompt that starts with `-` (it puts "Task: " in front); the terminal refuses one that does.
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
| `GET /terminals` | `ai_runners.manage` | → `[terminal]` (never the secret), each with its `connection` (§12) |
| `POST /terminals` | `ai_runners.manage` | `{name, url, agents?}` → 201 `{terminal, secret}` |
| `PUT /terminals/:uuid` | `ai_runners.manage` | `{name?, url?, agents?, is_active?}` → `terminal` |
| `POST /terminals/:uuid/rotate-secret` | `ai_runners.manage` | → `{terminal, secret}` |
| `DELETE /terminals/:uuid` | `ai_runners.manage` | → `{deleted: true}` (sessions stay on their tasks) |
| `POST /tasks/:task_uuid/terminal-sessions` | `ai_runs.create` + may start AI work on the task | `{terminal_uuid, path, agent, prompt?}` → 201 `{session, launch_url}` |
| `GET /tasks/:task_uuid/terminal-sessions` | `ai_runs.read` | → `[session]` (also in `GET /tasks/:task_uuid/work`) |
| `POST /tasks/:task_uuid/runs/preview` | (as before) | adds `terminals: [{uuid, name, url, agents, default_path, recent_paths}]`, `terminal_prompt` |
| `POST /public/terminal/webhook` | the terminal's signature | §4 → `session` |
| `GET /terminal-autologin` | `ai_runs.read` | → `{allowed, stepup: {verified_at, expires_at} \| null}` (§8) |
| `POST /terminal-autologin/code` | `ai_terminal_autologin.create` or a live key (§10) | emails a code → `{sent: true}` (429 when too many) |
| `POST /terminal-autologin/verify` | `ai_terminal_autologin.create` or a live key (§10) | `{code}` → `{allowed, stepup}`; 401 wrong code |
| `DELETE /terminal-autologin` | `ai_runs.read` | forgets the step-up |
| `POST /public/terminal/report` | `Authorization: Bearer <report token>` | `{pr_url?, note?}` → `{task_uuid, pr?}` (§9) |
| `GET /terminals/:uuid/keys` | `ai_runners.manage` | → `{keys: [key], people: [{uuid, name, email}]}` (§10) |
| `POST /terminals/:uuid/keys` | `ai_runners.manage` | `{user_uuid, public_key}` (ssh-ed25519) → 201 `key`; blocks their old key there; 409 a key used before |
| `POST /terminals/:uuid/keys/:key_uuid/block` | `ai_runners.manage` | → `{blocked: true}`; 404 if not live |
| `GET /public/terminal/keys` | the terminal's signature | → the live keys, signed (§10) |

`POST /terminals`, `PUT /terminals/:uuid` also take `autologin` (boolean); `POST /tasks/:task_uuid/terminal-sessions`
takes `autologin: true` → 403 without the permission or a live key on that terminal, 409 if the terminal doesn't allow it, 403 `code: stepup_required`
without a live step-up. The report address is `OPSAPI_PUBLIC_URL` + `/api/v2/ai-runner/public/terminal/report` when
set, else the launch request's `Host` (scheme from `X-Forwarded-Proto`); it must be https
(or localhost), otherwise the launch has no `report` claim.

`terminal = {uuid, name, url, agents: [{id, label}], is_active, autologin, secret_hint, created_by, created_at, updated_at}`.
`session = {uuid, task_uuid, project_uuid, opened_by, opened_by_name, terminal_uuid, terminal_name, terminal_url, path,
agent, agent_label, terminal_user, session_id, autologin, reported_at, status, started_at, ended_at, exit_code, ended_reason, expires_at,
created_at, updated_at}`. Tables: `ar_terminals`, `ar_terminal_sessions` (migration
`20261023120000_ai_runner_web_terminals`), `ar_terminal_keys` (`20261026120000_ai_runner_terminal_keys`).
`key = {uuid, user_uuid, person_name, person_email, terminal_user, fingerprint, created_at, created_by_name, expires_at,
revoked_at, revoked_by_name, status: active|expired|blocked|replaced|left}`.

## 6. Status on the task

`ar_terminal_sessions.status`: `launched` → `active` → `ended`; `launched` rows older than the link
lifetime show as `expired`. The task's AI work panel lists sessions (who, terminal, folder, agent,
started, ended, duration). Start with AI is the one way in: it guides in steps — **How** ("Let AI do it" or
"Work on it with AI myself", the second only when a terminal is connected), **Set it up**, **Check & start**
("What happens next") — and the AI work panel explains both ways when a task has none yet, with **Show me
how**, a four-step tour of the task page.

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

Only a PR in the project's GitHub repository (`target_repo_url`) is followed like that (`"tracked": true` in the
answer); one in another repository is refused (422). When the project names no GitHub repository, or for a GitLab
merge request, OpsAPI can't check the PR belongs to the task: it is recorded (comment, listed for sign-off, no
number so the poll never follows it), the task doesn't move by itself, and the answer says so (`"tracked": false`,
`"message"`).

The webhook, activity, recordings and reports are refused once signed when the terminal is switched off or removed
(`403`, `code: TERMINAL_OFF`) or its workspace is inactive or has AI Runs off (`404`, `code: PLUGIN_DISABLED`).

**Unattended agents.** `claude_auto` ("Claude Code, unattended",
`claude --dangerously-skip-permissions -- "$OPSAPI_TASK_PROMPT"`) is no longer a default; terminals that list it keep
it. It never stops to ask; only AI runs managers can start it (any id ending in `_auto`, or marked unattended).

## 10. Keys managers issue (W9)

**Issuing.** Machines → Web terminals → **People** (`ai_runners.manage`). The manager picks a member of the workspace
and presses **Make a key**. The browser makes an ed25519 key pair (`opsapi-dashboard/lib/ssh-key.ts`) and locks the
private key with a generated passphrase (OpenSSH format, bcrypt KDF + aes256-ctr, as `ssh-keygen -N` writes). Only
the public key goes to OpsAPI. The manager downloads the key file and copies the passphrase **once**, and hands them
over separately. A new key for the same person on the same terminal replaces (blocks) their old one.

**Storage.** `ar_terminal_keys` (per terminal): person, terminal user name, public key, SHA256 fingerprint, issued
by/at, `expires_at` (90 days), blocked by/at/reason (`blocked`, `replaced`, `left`). The terminal user name comes
from the email's local part, numbered if taken; a name is never given to a different person, so a new starter can't
inherit a leaver's saved tabs.

**When a key stops.** It is sent to the terminal only while it isn't blocked, suspended or expired **and** its person
is an active user and an active member of the workspace. Someone who leaves or is deactivated has their keys blocked
for good (reason `left`); coming back later needs a new key. A terminal switched off in OpsAPI, or in a workspace that
is inactive or has AI Runs off, gets an empty (still signed) list.

**Suspend.** `POST /terminals/:uuid/keys/:key_uuid/suspend` and `/resume` (`ai_runners.manage`; People, or Suspend on
the Work log's "Now"): a suspended key (`suspended_at`, `suspended_by`) is left out of the list, so the terminal signs
the person out and closes their sessions within about 30 seconds; Resume gives the same key back. Status
`suspended`.

**Reminder.** Fourteen days before a key expires, whoever issued it gets a notification (once per key).

**The terminal fetches its keys.** `opsapi.keys` in the terminal's `config.yaml` (the config block shows it):

```yaml
opsapi:
  keys:
    url: https://<opsapi>/api/v2/ai-runner/public/terminal/keys
    terminal_id: <this terminal's id>
    interval_secs: 30        # default
    max_stale_secs: 900      # default: no good fetch for this long and OpsAPI's keys stop working
```

```
GET /api/v2/ai-runner/public/terminal/keys
X-Opsapi-Terminal: <terminal id>
X-Opsapi-Timestamp: <unix seconds>                 (within 5 minutes)
X-Opsapi-Signature: sha256=<hex HMAC-SHA256(secret, "keys\n<terminal id>\n<timestamp>")>

200  X-Opsapi-Signature: sha256=<hex HMAC-SHA256(secret, body)>
{ "terminal": "<id>", "generated_at": 1792828054,
  "keys": [ { "user": "priya", "public_key": "ssh-ed25519 AAAA…", "expires_unix": 1800604054,
              "email": "priya@example.com", "name": "Priya Shah" } ] }
```

`name` (the person's display name, optional) may be shown by the terminal; older terminals ignore it.

The terminal trusts a list only when its signature checks out, it names this terminal, `generated_at` is within 5
minutes and not older than the last list it took. OpsAPI keys get `local` access only and can't use a user name (or
key) that is in the terminal's own `authorized_keys`. A key that drops off the list stops at once, and the terminal
closes its sessions within seconds. If OpsAPI can't be reached for `max_stale_secs`, all OpsAPI keys stop; keys in
`authorized_keys` keep working (so the owner can still get in). The terminal audits `opsapi_key_added`,
`opsapi_key_removed` and `opsapi_keys_stale`; every sign-in is audited with the user and key fingerprint as before.

**Auto sign-in (§8).** A person with a live key on a terminal may also be signed in by Start with AI there, after the
emailed code, without the key file. The terminal matches them by the email in the key list, so its own
`autologin.users` is needed only for keys added on the terminal itself.

**What a key doesn't do.** Every shell runs as the macOS account the terminal runs under (W1): keys say *who* signs
in, not *what* they can reach. People sharing that account can see each other's files.

## 11. Work log (W10)

What is recorded, per terminal **tab** (one sshweb session: a task tab or a plain one):

| Kind | Recorded | Kept |
|---|---|---|
| Tab | who (terminal user + key fingerprint → the OpsAPI person who holds that key, or the launch's opener), the task (if opened from one), folder, agent, sign-in (`key` / `opsapi_launch`), IP, opened/closed, how it ended, exit code, active seconds (input or output in the last 60 s), bytes in/out | always |
| AI (Claude Code) | each prompt (text), each model request (model, input/output/cache-read/cache-write tokens, cost estimate, duration), each tool result (tool, success, duration, its parameters: commands, files), tool decisions (accepted/rejected), API errors, lines added/removed, commits, pull requests | text 90 days, numbers always |
| Screen | the tab's output as an [asciicast v2](https://docs.asciinema.org/manual/asciicast/v2/) recording (`o` and `r` events; **never input**) | 30 days |

Claude's numbers come from its own OpenTelemetry. Cost is Claude's estimate at list price (on a subscription
nothing is billed per token; it measures usage). Codex/Cursor/plain shells get tab and screen records only.

### 11.1 Terminal side (sshweb, `opsapi.work_log`)

```yaml
opsapi:
  work_log:
    enabled: true
    url: https://<opsapi>/api/v2/ai-runner/public/terminal   # base; paths below are appended
    otlp_port: 7683          # loopback-only plain HTTP receiver for Claude's telemetry
    record: true             # screen recordings
```

Needs `opsapi.keys.terminal_id` (the terminal's id) and `opsapi.webhook_secret`.

- **Per-tab token.** Every local tab gets a random token (32 bytes, hex) in its shell as `SSHWEB_TAB_TOKEN`, plus
  Claude's telemetry settings (overridable only by a stricter managed setting):
  `CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_LOGS_EXPORTER=otlp`, `OTEL_METRICS_EXPORTER=otlp`,
  `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`, `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://127.0.0.1:<otlp_port>/v1/logs`,
  `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://127.0.0.1:<otlp_port>/v1/metrics`,
  `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <tab token>`, `OTEL_LOG_USER_PROMPTS=1`, `OTEL_LOG_TOOL_DETAILS=1`,
  `OTEL_LOGS_EXPORT_INTERVAL=5000`, `OTEL_METRIC_EXPORT_INTERVAL=30000`. On the shared account the admin also installs
  Claude's managed settings (sshweb `packaging/claude-managed-settings.json`) so these can't be switched off; its
  `otelHeadersHelper` reads `SSHWEB_TAB_TOKEN`.
- **OTLP receiver** on `127.0.0.1:<otlp_port>` only: `POST /v1/logs`, `POST /v1/metrics` (JSON). The bearer token
  names the tab. Posts without a known token are answered 200 and **dropped** (only counted in the terminal's audit
  log): Claude's managed settings are machine-wide, so the owner's own Claude must not reach OpsAPI. Log records
  are forwarded when `event.name` is one of `user_prompt`, `api_request`, `api_error`, `tool_result`,
  `tool_decision`; metric data points for `claude_code.lines_of_code.count`, `claude_code.commit.count`,
  `claude_code.pull_request.count`, `claude_code.active_time.total` (delta temporality). Everything else is dropped.
  Text is cut to 16 KiB (`prompt`) and 8 KiB (`tool_parameters` / `tool_input`).
- **Recording.** Each local tab's PTY output → asciicast v2 lines (`[secs, "o", data]`, resize `[secs, "r", "COLSxROWS"]`),
  header `{"version":2,"width":..,"height":..,"timestamp":..}` in part 0 only. A part closes every 60 s or 1 MiB
  (uncompressed), whichever first, and at tab close; it is gzipped and uploaded, then deleted locally (kept in
  `<state_dir>/recordings`, mode 0600, until uploaded).

### 11.2 Terminal → OpsAPI

Both requests carry `X-Opsapi-Terminal: <terminal id>` and `X-Opsapi-Signature: sha256=<hex HMAC-SHA256(secret, …)>`.

**`POST {url}/activity`** — signature over the raw body. Sent every 10 s while there is something new; retried.

```json
{ "terminal": "<id>", "sent_at": 1792828054,
  "tabs": [ { "id": "<sshweb session id>", "user": "priya", "key": "SHA256:…", "via": "key",
              "ip": "203.0.113.4", "launch": "<launch uuid or null>", "kind": "local", "cwd": "/Users/…",
              "agent": "claude", "opened_at": 1792828000, "closed_at": null, "end_reason": null,
              "exit_code": null, "active_secs": 420, "input_bytes": 1200, "output_bytes": 88000,
              "last_input_at": 1792828040, "attached": true } ],
  "events": [ { "id": "<tab id>:<seq>", "tab": "<tab id>", "at": 1792828050.123,
                "type": "user_prompt", "session": "<claude session.id>", "prompt_id": "<prompt.id>",
                "attrs": { "prompt": "…", "prompt_length": 30 } },
              { "id": "…", "tab": "…", "at": 1792828051.9, "type": "api_request", "session": "…", "prompt_id": "…",
                "attrs": { "model": "claude-opus-5-5", "input_tokens": 2, "output_tokens": 4,
                           "cache_read_tokens": 23910, "cache_creation_tokens": 16690, "cost_usd": 0.13839,
                           "duration_ms": 2560 } },
              { "id": "…", "tab": "…", "at": …, "type": "metric", "session": "…",
                "attrs": { "name": "claude_code.lines_of_code.count", "type": "added", "value": 12 } } ] }
```

A tab entry is the tab's whole current state (upsert by terminal + id): sent at open, at close, and at least every
60 s for every open tab (a heartbeat; OpsAPI sets `seen_at`). Optional: `last_input_at` (unix seconds of the last
keystroke, or null) and `attached` (a browser shows the tab). Events are append-only; `id` is unique per terminal, so a retry is harmless. `attrs` carries the
OTel attributes as given (Claude sends many numbers as strings), minus `user.email`, `user.account_uuid`,
`organization.id`, `event.name`, `session.id`, `prompt.id`; `session`/`prompt_id` are left out when Claude sent none.
Answer `200 {"tabs": n, "events": n}`; `401` bad signature/terminal; `400` bad body; `403 TERMINAL_OFF` /
`404 PLUGIN_DISABLED` as for the webhook. Max body 5 MiB.

**`POST {url}/recordings`** — headers also `X-Opsapi-Tab: <tab id>`, `X-Opsapi-Part: <n>` (0, 1, …),
`X-Opsapi-Final: 0|1`; body = the gzipped part; signature over `"<tab id>\n<part>\n" .. body`. Max 4 MiB per part.
`200 {"stored": true}`; a part already stored → `200 {"stored": false}`.

### 11.3 OpsAPI

Tables (migration `20261026130000_ai_runner_work_log`): `ar_terminal_tabs` (one row per tab, totals rolled up from
events: tokens, cost, prompts, tool calls, lines, commits, PRs), `ar_terminal_events`, `ar_terminal_recordings`
(one row per stored part; object in MinIO). Each `api_request` with a known person also goes to `ai_usage`
(`feature = 'web_terminal'`), so the AI usage page includes it; the per-user daily in-app AI limit ignores it.

Who: a tab's person = the opener of its launch, else the holder of the OpsAPI key with that fingerprint on that
terminal. Unknown (a key added on the terminal itself) shows the terminal user.

Retention: prompt and tool text are blanked after 90 days, recordings deleted after 30 (hourly sweep). Open tabs a
terminal stopped reporting are closed (`end_reason` "the terminal stopped reporting", e.g. after a crash): after 10
minutes without news from a terminal that sends heartbeats (`attached`), else after 12 hours (checked every few
minutes, migration `20261029120000_ai_runner_terminal_live`); a tab reopens if the terminal reports it open again.

| Method & path | Who | → |
|---|---|---|
| `GET /work-log?user_uuid&task_uuid&from&to&terminal_uuid&state=open\|closed&agent&q&page&per_page` | `ai_terminal_worklogs.read`, else only your own | tabs, newest first, with totals; `q` searches person, folder, task title; `meta.total` counts up to 1000 (`total_capped`), `has_more` |
| `GET /work-log/options` | any member | the filters' terminals and agents |
| `GET /work-log/live` | same rule | who is working now: open tabs reported in the last 3 minutes, with `last_input_at` / `idle_secs`, `attached`, and `key_uuid` for `ai_runners.manage` |
| `GET /work-log/people?from&to` | `ai_terminal_worklogs.read` | per person: tabs, active time, prompts, tokens, cost |
| `GET /work-log/tabs/:uuid` | same rule | the tab + the first page of its timeline (`events`, `events_next`) + recording parts |
| `GET /work-log/tabs/:uuid/events?type&q&after&per_page` | same rule | the timeline, oldest first, 200 a page; `meta.next` continues it |
| `GET /work-log/tabs/:uuid/recording/:part` | same rule | the gzipped asciicast part |

## 12. Is the terminal connected?

Each terminal on **AI Runs → Machines → Web terminals** has a line that says whether it's in touch with OpsAPI,
in plain words, with **What to do** for anything but green. It updates every 15 seconds.

A terminal calls OpsAPI every 30 seconds for its keys (§10), and also with work-log activity (§11) and session
webhooks (§4). Every call is signed with the shared secret. OpsAPI notes, at most every 10 seconds per terminal:

- `ar_terminals.last_contact_at`: the last call it accepted;
- `last_refused_at` + `last_refused_reason`: the last call it refused from a known terminal: `secret` (the
  signature doesn't match the secret OpsAPI has) or `clock` (right secret, but the timestamp is more than
  5 minutes off). A refusal for another reason is written straight away.

`GET /terminals` answers each terminal with `connection: {state, seen_secs_ago?, refused_secs_ago?}`:

| `state` | On the card | It means | What to do |
|---|---|---|---|
| `connected` | Connected · checked in 12 seconds ago | an accepted call in the last 2 minutes | nothing (if it's switched off, nobody can sign in) |
| `waiting` | Not connected yet: this terminal hasn't checked in | it has never called | open its address (the sign-in page should load); make sure its settings have this card's terminal id and secret (the `keys` lines); not sure? **New secret** and put the new lines in |
| `lost` | Lost contact · last checked in 2 hours ago | it was in touch, but not in the last 2 minutes | the machine or the terminal is off or offline: start it. Meanwhile new or blocked keys don't reach it, and after 15 minutes it stops accepting OpsAPI's keys altogether |
| `secret` | Not connected: the secret on the machine doesn't match | it calls with a different secret (e.g. **New secret** was clicked and the machine wasn't updated); nobody can sign in with a key from People | **New secret**, put the new terminal id and secret into the terminal's settings, restart it. On the Workstation Mac Studio: `sudo /usr/local/libexec/sshweb-admin secret` |
| `clock` | Not connected: the machine's clock is wrong | right secret, clock more than 5 minutes off | switch on automatic date and time on the machine |

A refusal shows for 10 minutes, and only while it's newer than the last accepted call, so a stray request with
a wrong signature can't hide a terminal that is working. Terminals connected before §10 (no `keys` in their
config) only call when a session starts or ends, so they show `waiting` or `lost` between sessions.

