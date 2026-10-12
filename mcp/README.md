# @opsapi/mcp — OpsAPI kanban for AI agents

An [MCP](https://modelcontextprotocol.io) server that lets Claude Code, Cursor or
any MCP-capable agent work with OpsAPI kanban **as you**: list your tasks for
today, create and update tasks, move them across columns, search, log time and
attach the PR when the work ships.

It authenticates with a **personal API key** (`opsk_…`) that is bound to one
user, so `list_my_tasks` returns *your* tasks and every write is done and
logged as *you*, with your project permissions.

Two ways to run it, same tools:

- **stdio** (default): the agent starts it locally with your key in its env.
- **Streamable HTTP**: one shared service at `https://…/mcp`; each agent sends
  its own key as `Authorization: Bearer opsk_…`. The service holds no key.

> New here? The plain-English setup guide is [GETTING-STARTED.md](GETTING-STARTED.md).

## Tools

| tool | arguments | what it does |
|---|---|---|
| `list_my_tasks` | `due?` (today · overdue · today_and_overdue · week · upcoming · none), `date?` (YYYY-MM-DD, default: today on the machine running the server), `priority?[]`, `status?[]` (open · in_progress · blocked · review), `project?`, `search?`, `limit?` | your open assigned tasks, most urgent first, with overdue flag and dashboard link |
| `get_task` | `task_uuid` | one task: status, priority, project/board/column, description, PR, link |
| `list_projects` | `search?`, `limit?` | projects you are a member of |
| `list_boards` | `project` | a project's boards with their columns (name + numeric id) |
| `create_task` | `project`, `title`, `description?`, `board?`, `column?`, `priority?`, `due_date?`, `assignees?[]` | creates a task; returns uuid, number and link |
| `update_task` | `task_uuid`, `status?`, `priority?`, `title?`, `description?`, `due_date?`, `metadata?` | changes fields; `metadata` is **merged** into the existing metadata (`null` removes a key) |
| `move_task` | `task_uuid`, `column`, `position?` | moves a task to a column of its board |
| `search_tasks` | `query`, `project?`, `limit?` | full-text search across your projects, or one |
| `log_time` | `task_uuid`, `minutes`, `description?`, `billable?` | adds a timesheet entry |
| `set_task_pr` | `task_uuid`, `pr_url` | sets `metadata.pr_url` (other metadata kept) |
| `complete_task` | `task_uuid`, `pr_url?`, `minutes?`, `note?` | marks completed, optionally attaching the PR and logging time |
| `add_comment` | `task_uuid`, `content` | comments on a task |

`project`, `board`, `column` and `assignees` accept an id/uuid or a name:

- projects, boards, columns: exact name, or a unique part of it (`"redesign"`);
- assignees: user uuid, email, full name or username of a **project member**,
  matched exactly;
- several matches or none → the tool fails, names the candidates, and **creates
  nothing**, so the agent can ask you or retry with the id.

Tools return a short text answer plus `structuredContent` (JSON) for clients
that use it. Task links are dashboard paths (`/dashboard/projects/…/tasks/…`),
or full URLs when `OPSAPI_DASHBOARD_URL` is set.

`list_my_tasks` filters need an OpsAPI with the my-tasks filters; older servers
ignore them and the tool says the list is unfiltered.

## The personal API key

A key bound to a user both authenticates and identifies that user. Scopes the
tools need:

```json
{ "kanban": ["read", "create", "update"], "projects": ["read"] }
```

- `kanban` lets the key reach the kanban routes; `projects: read` is needed for
  `list_my_tasks`, `list_projects`, project-name lookups and assignees.
- Writes also need an **editor** role (owner/admin/member) on the project.
- The raw key is shown **once** at creation.

Make one in the dashboard (see [GETTING-STARTED.md](GETTING-STARTED.md)) or via
the API with an owner session:

```http
POST /api/v2/api-keys
Authorization: Bearer <owner session JWT>
Content-Type: application/json

{ "name": "alice — claude code", "user_uuid": "<alice's user uuid>",
  "scopes": { "kanban": ["read", "create", "update"], "projects": ["read"] } }
```

## Run it: stdio

```bash
cd mcp && npm ci && npm run build
```

| env | required | notes |
|---|---|---|
| `OPSAPI_URL` | yes | e.g. `https://int-opsapi.workstation.co.uk` |
| `OPSAPI_API_KEY` | yes | your `opsk_…` key |
| `OPSAPI_NAMESPACE` | no | your workspace's **numeric id or uuid** (sent as `X-Namespace-Id`). **Not the slug** — a slug gets 403. The key is already bound to its workspace, so usually leave it out. |
| `OPSAPI_DASHBOARD_URL` | no | e.g. `https://int-opsapi-ui.workstation.co.uk`, to return full task links |

**Claude Code:**

```bash
claude mcp add opsapi -s user \
  -e OPSAPI_URL=https://int-opsapi.workstation.co.uk \
  -e OPSAPI_API_KEY=opsk_your_key \
  -- node /absolute/path/to/opsapi/mcp/dist/index.js
```

**Cursor** (`~/.cursor/mcp.json`) and other clients:

```json
{
  "mcpServers": {
    "opsapi": {
      "command": "node",
      "args": ["/absolute/path/to/opsapi/mcp/dist/index.js"],
      "env": {
        "OPSAPI_URL": "https://int-opsapi.workstation.co.uk",
        "OPSAPI_API_KEY": "opsk_your_key"
      }
    }
  }
}
```

The package is prepared for npm as `@opsapi/mcp` but **not published yet**.
Once it is, `npx -y @opsapi/mcp` replaces `node …/dist/index.js`. Binaries:
`opsapi-mcp` (stdio), `opsapi-kanban-mcp` (same, old name kept for existing
setups) and `opsapi-mcp-http`.

## Run it: Streamable HTTP

```bash
OPSAPI_URL=https://int-opsapi.workstation.co.uk npm run start:http
# or
docker build -t opsapi-mcp ./mcp
docker run -p 8787:8787 -e OPSAPI_URL=https://int-opsapi.workstation.co.uk opsapi-mcp
```

| env | default | notes |
|---|---|---|
| `OPSAPI_URL` | — (required) | OpsAPI the service forwards to |
| `PORT` | `8787` | |
| `HOST` | `127.0.0.1` (`0.0.0.0` in the image) | |
| `OPSAPI_DASHBOARD_URL` | — | full task links |

Endpoints:

- `POST /mcp` — MCP Streamable HTTP, **stateless** (JSON responses, no
  sessions). Requires `Authorization: Bearer opsk_…`; optional `X-Namespace-Id`
  (numeric id or uuid) is passed through. `GET`/`DELETE /mcp` answer 405.
- `GET /healthz` — liveness, no auth.

Behaviour: no or malformed key → `401` JSON-RPC error and nothing is sent to
OpsAPI; bodies over 1 MB → `413`; the request must arrive within 30 s and each
OpsAPI call times out after 20 s. Logs are JSON lines (method, path, status,
duration) and never include headers. SIGTERM/SIGINT stop accepting, finish
in-flight requests (up to 10 s), then exit. No CORS headers: desktop/CLI agents
don't need them; put a proxy in front if a browser-based client must call it.

**Claude Code:**

```bash
claude mcp add --transport http opsapi https://mcp.example.com/mcp \
  --header "Authorization: Bearer opsk_your_key" -s user
```

**Cursor** (`~/.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "opsapi": {
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer opsk_your_key" }
    }
  }
}
```

Serve it only over HTTPS: the key travels in every request.

## Security

- A personal key **acts as you**: anything the agent does is done and logged in
  your name, with your project roles. Give it only the scopes above.
- Keep it out of repos and shared configs (`-s user` keeps it in your user
  config, not the project's `.mcp.json`).
- Rotate it by creating a new key, updating the agent config, and deleting the
  old key; delete it at once if it leaks. Revoked keys stop working immediately.
- The HTTP service stores no keys and no state; it only forwards each request's
  key to OpsAPI.

## Development

```bash
npm ci
npm run build
npm test        # node:test: tools against a mocked OpsAPI + HTTP end-to-end
```

Writes are sent as `application/x-www-form-urlencoded` with nested values as
JSON strings (what OpsAPI routes parse first). Task updates replace `metadata`
wholesale on the server, so every tool that touches metadata reads, merges and
writes back the whole object.
