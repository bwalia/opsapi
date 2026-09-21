# OpsAPI Kanban — MCP server

An [MCP](https://modelcontextprotocol.io) server that lets Claude Code (or any
MCP-compatible agent) work an employee's OpsAPI kanban tasks:

- **read the employee's tasks** — "what are my tasks today?"
- **log time per task** — builds a per-task timesheet so you can see how long a
  task took
- **attach the PR link** and mark a task done when the work ships

The agent acts **as a specific employee**, so `list_my_tasks` returns *their*
tasks and logged time is attributed to *them*.

## How it authenticates: a personal API key

OpsAPI API keys can be **bound to a user** (a "personal access token"). Such a
key both authenticates the request *and* identifies the employee. A namespace
admin creates one:

```http
POST /api/v2/api-keys
Authorization: Bearer <an admin's session JWT>
Content-Type: application/json

{
  "name": "alice — claude code",
  "user_uuid": "<the employee's user uuid>",
  "scopes": { "kanban": ["read", "update"], "projects": ["read"] }
}
```

- `user_uuid` must be a member of the admin's namespace — this is what makes the
  key act as that employee. Omit it and you get an ordinary machine key.
- `scopes` **must** include `"kanban"` (to reach the kanban routes) and
  `"projects": ["read"]` (for `list_my_tasks`). `"update"` on `kanban` is for
  logging time / attaching PRs.
- The response returns the raw `opsk_...` key **once** — store it now.

Writes (log time, attach PR, complete) also require the employee to be an
**editor** (owner/admin/member) on the task's project.

## Configure the MCP server

Environment variables:

| var | required | example |
|---|---|---|
| `OPSAPI_URL` | yes | `https://int-opsapi.workstation.co.uk` |
| `OPSAPI_API_KEY` | yes | the employee's `opsk_...` personal key |
| `OPSAPI_NAMESPACE` | no | `1` or a slug/uuid — only if your deployment requires an explicit `X-Namespace-*` header (the key is already namespace-bound) |

### Build

```bash
cd mcp
npm install
npm run build
```

### Register in Claude Code

Add to your MCP settings (`claude mcp add`, or the JSON config):

```json
{
  "mcpServers": {
    "opsapi-kanban": {
      "command": "node",
      "args": ["/absolute/path/to/opsapi/mcp/dist/index.js"],
      "env": {
        "OPSAPI_URL": "https://int-opsapi.workstation.co.uk",
        "OPSAPI_API_KEY": "opsk_....",
        "OPSAPI_NAMESPACE": "1"
      }
    }
  }
}
```

The same `command`/`args`/`env` shape works in any MCP client (Claude Desktop,
other agents).

## Tools

| tool | what it does |
|---|---|
| `list_my_tasks` | list the employee's open assigned tasks (with uuids) |
| `get_task` | one task's details incl. any attached PR |
| `log_time` | record minutes spent on a task (a timesheet entry) |
| `set_task_pr` | attach/update the PR URL in the task's `metadata.pr_url` |
| `complete_task` | in one step: optionally log time, attach the PR, set status = completed |
| `add_comment` | add a comment to a task |

Example conversation:

> **You:** what are my tasks today?
> **Claude** *(list_my_tasks)*: You have 2 open tasks: #14 "Refresh-token rotation" …
> **You:** I finished #14, spent about 3 hours, PR is github.com/acme/api/pull/812
> **Claude** *(complete_task minutes=180, pr_url=…)*: Task #14: logged 180m, attached PR, marked completed.

## Notes

- Bodies are sent as `application/x-www-form-urlencoded` (what the OpsAPI routes
  parse), with the jsonb `metadata` field carried as a JSON string — same as the
  dashboard.
- `set_task_pr` / `complete_task` read the task first and merge, so attaching a
  PR never clobbers other `metadata` keys.
- This server talks to OpsAPI's existing kanban REST API only; it stores nothing
  locally and holds no state.
