# Reporting AI sessions from any tool (AI Runs sources)

Any tool can tell OpsAPI which AI coding sessions are running: a CI job, another observer, an IDE plugin, Codex,
Windsurf, … OpsAPI stores them like the sessions a PromptPilot runner reports (the **Machines** page), and, when the
workspace tracks sessions started by hand, turns each busy one into a kanban task routed by the workspace's rules
(docs/AI_RUNNER.md §26, §27.3).

## 1. Register a source

In the dashboard: **AI Runs → Runners & sources → Register**, kind **Source** (needs `ai_runners.manage`). Or:

```bash
curl -s -X POST "$OPSAPI/api/v2/ai-runner/runners" \
  -H "Authorization: Bearer $SESSION_JWT" -H "X-Namespace-Id: $WORKSPACE" -H "Content-Type: application/json" \
  -d '{"name": "ci-observer", "kind": "source"}'
```

The answer carries the connection's token (`oprn_…`) **once**. It belongs to that one workspace: a tool that feeds
several workspaces registers in each and uses each token for its own sessions. A source can't take runs (`claim` →
403); a `runner` connection may report sessions this way too.

## 2. Report sessions

```bash
curl -s -X POST "$OPSAPI/api/v2/ai-runner/public/runner/sessions" \
  -H "Authorization: Bearer $OPRN_TOKEN" -H "Content-Type: application/json" \
  -d '{"sessions": [{
        "key": "build-4711", "tool": "codex", "status": "busy",
        "cwd": "/home/ci/work/api", "branch": "feat/login",
        "session_id": "4f1c…", "started_at": "2026-10-13T09:30:00Z", "updated_at": "2026-10-13T09:41:00Z",
        "first_prompt": "Fix the flaky login test", "prompt_preview": "run the tests again",
        "labels": {"job": "4711"}
      }]}'
# -> {"success": true, "data": {"stored": 1, "tasks_created": 1}}
```

- **The list replaces** what this connection reported before: send every session it currently sees (an empty list
  clears them). Report again at least every few minutes while a session lives: a tracked session nobody reports for
  the workspace's `gone_after_minutes` (default 10) ends, and its task gets a "Session ended" comment.
- **Fields:** `key` (required, unique in the list, ≤ 255) identifies the session within this connection;
  `session_id` (if any) identifies it across reports. `tool` and `status` are free text (≤ 40); a status in the
  workspace's `idle_statuses` (idle, done, ended, …) isn't busy, and `ended` ends a tracked session at once. `cwd` is an
  absolute folder. `first_prompt` (≤ 300 kept) titles the task; send it only when the machine's owner agreed that
  prompt text may leave the machine. At most 500 sessions per call.
- **Redaction:** prompts, previews and labels are redacted on the server (keys, tokens, passwords, plus the
  workspace's own `safety.extra_redactions`) before anything is stored.
- **Liveness:** a report counts as a heartbeat (the connection shows online).
- Errors: 401 (bad or revoked token), 404 (AI Runs off in the workspace), 422 (`sessions` not a list, or > 500).

## 3. What a connection reports (report filter)

On **Runners & sources**, `report_filter` narrows what a connection's reports keep: `{ folders, exclude_folders,
tools }`, each a list (empty = everything). OpsAPI applies it to every report (and sends it to PromptPilot runners,
which apply it before sending). A session is kept when its tool is in `tools` (any case), its folder matches one of
`folders` and none of `exclude_folders`. A connection's own AI runs are always kept.

Folder globs, as the runner reads them:
- A glob covers the folder it names **and everything below it** (`/work/api` covers `/work/api/web`).
- `*` and `?` stay within one folder name; `**` spans any number of folders (`/work/**/secret`).
- A glob starting with `/` is absolute. `~/…` is a home folder: the server doesn't know whose machine it is, so it
  matches under any `/Users/<name>/` or `/home/<name>/`. Any other glob matches at any depth (`node_modules`,
  `client-*`).

## 4. Where the tasks go

**AI run settings → Track sessions started by hand** switches tracking on and sets the default project, column and
status. **Routing rules** (first enabled match wins) send sessions by runner, tool, folder glob, branch glob or prompt
keyword to another project, column, status, priority and assignees, notify managers, the assignees, named people or
nobody, or ignore them. The rule tester (`POST /api/v2/ai-runner/track-rules/test`) shows what a sample session would
become without creating anything.
