# Extending OpsAPI with plugins

OpsAPI ships many modules: CRM, invoicing, accounting, HR, chat, kanban and more. When you need an API it doesn't have, you don't fork it. You write a **plugin**: a folder of Lua files that OpsAPI loads at startup. It sits next to the built-in modules and gets the same authentication, multi-tenancy, RBAC, migrations and Swagger docs, plus generated pages in the admin dashboard.

```
my-plugins/
└── helpdesk/
    ├── project.lua                          # manifest
    ├── api/
    │   ├── tickets.lua                      # → /api/v2/helpdesk/tickets
    │   └── stats.lua                        # → /api/v2/helpdesk/stats
    └── migrations/
        └── 20260930120000_create_helpdesk_tickets.lua
```

The same mechanism powers real products built on OpsAPI (for example diy-tax-return-uk ships its schema as a plugin). A complete example lives in [`projects/helpdesk`](projects/helpdesk).

---

## Contents

1. [Security model: read this first](#1-security-model-read-this-first)
2. [Quick start](#2-quick-start)
3. [The manifest](#3-the-manifest-projectlua)
4. [Generating a resource](#4-generating-a-resource)
5. [Writing routes](#5-writing-routes)
6. [Dashboard pages](#6-dashboard-pages)
7. [Migrations](#7-migrations)
8. [Multi-tenancy and RBAC](#8-multi-tenancy-and-rbac)
9. [Settings and secrets](#9-settings-and-secrets)
10. [Deploying](#10-deploying)
11. [Operating plugins](#11-operating-plugins)
12. [SDK reference](#12-sdk-reference)
13. [CLI reference](#13-cli-reference)
14. [Limits and roadmap](#14-limits-and-roadmap)

---

## 1. Security model: read this first

- **Plugins are trusted code.** They run inside the OpsAPI process with full database access, like a Drupal module or a WordPress plugin. Only the operator of a deployment installs them, by putting files in the plugins folder or baking them into an image.
- **Never let tenants upload plugins.** In a shared, multi-tenant deployment, code from one tenant could read every other tenant's data and the server's secrets. Tenant-level customisation (custom fields, workflows, webhooks) must be configuration stored in the database, not code.
- The SDK makes the safe path the easy path:
  - Every plugin route requires a valid login (JWT or API key), except routes under `/api/v2/<code>/public/`.
  - `sdk.crud` / `sdk.handler` require an active namespace membership and an RBAC permission.
  - `sdk.crud` / `sdk.resource` scope every query to the caller's namespace.
  - Input is whitelisted and type-checked.
- The loader keeps plugins in their lane:
  - A plugin can't replace a built-in route or use a built-in module's code or URL prefix.
  - A plugin's `before_filter` only runs for its own routes.
  - A plugin that fails to load takes the pod out of rotation (`/ready` → 503) instead of silently serving 404s.

---

## 2. Quick start

### With the repository (local development)

`./start.sh` mounts the repo's `projects/` folder into the container as `/app/projects`.

```bash
docker exec opsapi opsapi plugin:new helpdesk
docker exec opsapi opsapi make:resource helpdesk ticket \
    title:string:required description:text status:string:required due_on:date
docker exec opsapi opsapi migrate        # creates the table, registers RBAC module + sidebar entry
docker restart opsapi                    # loads the new routes
```

Then open the dashboard: **Tickets** is in the sidebar, at `/dashboard/plugins/helpdesk/tickets`.

### With only the Docker image

```bash
mkdir plugins
alias opsapi-cli='docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/plugins:/app/projects" bwalia/opsapi opsapi'
opsapi-cli plugin:new helpdesk
opsapi-cli make:resource helpdesk ticket title:string:required status:string:required

# run OpsAPI with the plugins mounted (plus your usual env / database settings)
docker run -d --name opsapi -v "$PWD/plugins:/app/projects" --env-file .env -p 4010:80 bwalia/opsapi
docker exec opsapi opsapi migrate && docker restart opsapi
```

### Try it

Log in as a user whose role has the new permission. Admin and owner roles get it automatically, see [§8](#8-multi-tenancy-and-rbac).

```bash
TOKEN=...   # from POST /auth/login
NS=...      # your namespace uuid
curl -X POST localhost:4010/api/v2/helpdesk/tickets \
  -H "Authorization: Bearer $TOKEN" -H "X-Namespace-Id: $NS" -H "Content-Type: application/json" \
  -d '{"title":"Printer on fire","status":"open"}'
curl "localhost:4010/api/v2/helpdesk/tickets?q=printer&sort=created_at&order=desc" \
  -H "Authorization: Bearer $TOKEN" -H "X-Namespace-Id: $NS"
```

The endpoints also appear in Swagger at `/swagger`, under a tag named after the plugin.

---

## 3. The manifest (`project.lua`)

```lua
return {
    code = "helpdesk",        -- required. Stable id: keys migrations + RBAC. Never rename.
    name = "Helpdesk",        -- required. Shown in Swagger and the admin API.
    version = "1.2.0",
    description = "Support tickets",
    sdk_version = 1,          -- SDK version the plugin targets (default 1)
    enabled = true,           -- false = skip entirely

    -- RBAC modules. Each becomes grantable in the dashboard's role editor as
    -- <machine_name>.read / create / update / delete / manage.
    modules = {
        { machine_name = "helpdesk_tickets", name = "Tickets", category = "Helpdesk" },
        -- opsapi:modules (make:resource adds entries above this line)
    },

    -- Dashboard sidebar entries: each opens the generated page of an sdk.crud
    -- resource (§6).
    menu = {
        { label = "Tickets", resource = "tickets", module = "helpdesk_tickets", icon = "LifeBuoy" },
        -- opsapi:menu (make:resource adds entries above this line)
    },

    -- api_prefix = "/api/v2/helpdesk",   -- default: /api/v2/<code with hyphens>
}
```

Rules enforced at load time:

- `code` is lowercase letters, digits and `_`, and must not be a built-in module's code (`crm`, `hospital`, …).
- `api_prefix` must be under `/api/` and must not already be used by OpsAPI or another plugin.
- A plugin needing a newer `sdk_version` than the running OpsAPI is refused. Upgrade OpsAPI first.
- Every `menu` entry needs a `label`, a `resource` and a `module` that is one of the plugin's `modules`.

---

## 4. Generating a resource

```bash
opsapi make:resource <plugin> <resource> <field:type[:required]>...
```

For `opsapi make:resource helpdesk ticket title:string:required due_on:date` you get:

| File | What it does |
|---|---|
| `migrations/<timestamp>_create_helpdesk_tickets.lua` | Creates the `helpdesk_tickets` table: `id`, `uuid` (public id), `namespace_id` (FK, cascade), your fields, `created_at` and `updated_at`, and a tenant index. |
| `api/tickets.lua` | List, show, create, update and delete via `sdk.crud`, plus the `ui` block for its dashboard page. |
| `project.lua` | The `helpdesk_tickets` RBAC module and a **Tickets** sidebar entry are added. |

Field types (validation → column type):

| Type | Validates | Column |
|---|---|---|
| `string` | text, max 255 chars | `VARCHAR(255)` |
| `text` | text, no max | `TEXT` |
| `integer` | whole number within `INTEGER` range | `INTEGER` |
| `number` | any number | `NUMERIC(14,2)` |
| `boolean` | `true`/`false` (or `"true"`/`"false"`) | `BOOLEAN` |
| `date` | `YYYY-MM-DD` | `DATE` |
| `datetime` | ISO-8601 (`YYYY-MM-DDTHH:MM…`) | `TIMESTAMPTZ` |
| `email` | `a@b.c` | `VARCHAR(255)` |
| `uuid` | 8-4-4-4-12 hex | `UUID` |
| `json` | an object or array | `JSONB` |

The generated files are a starting point. Edit them freely. For example, add `enum = { "open", "closed" }` or `min`/`max` to a field.

---

## 5. Writing routes

Every file in `api/` returns `function(app) … end`. Paths you register are relative to the plugin's prefix.

### 5.1 `sdk.crud`: a full REST resource in one call

```lua
local sdk = require("helper.plugin-sdk")

return function(app)
    sdk.crud(app, "/tickets", {
        table = "helpdesk_tickets",
        module = "helpdesk_tickets",               -- RBAC module (required)
        fields = {
            title    = { type = "string", required = true, max = 120 },
            status   = { type = "string", required = true, enum = { "open", "pending", "closed" } },
            priority = { type = "integer", min = 1, max = 5 },
        },
        searchable = { "title" },                  -- ?q=
        filterable = { "status", "priority" },     -- ?status=open
        sortable   = { "title", "created_at" },    -- ?sort=title&order=asc
        -- only = { "list", "show" },              -- register a subset
    })
end
```

| Route | Permission | Behaviour |
|---|---|---|
| `GET /tickets` | `helpdesk_tickets.read` | `?page=&per_page=` (max 100), `?q=`, `?sort=&order=`, filters. Returns `{ success, data: [...], meta: { page, per_page, total, total_pages } }`. |
| `GET /tickets/:uuid` | `.read` | 404 if missing or in another namespace. |
| `POST /tickets` | `.create` | 201. 422 with `details: { field: message }` on bad input. 409 on a unique-constraint clash. |
| `PUT /tickets/:uuid` | `.update` | Partial update of the fields sent. `null` clears an optional field. |
| `DELETE /tickets/:uuid` | `.delete` | 200. 404 if missing. 409 if other rows still reference it. |

`namespace_id`, `id` and `uuid` can never be set or changed through the API, and unknown fields are dropped.

### 5.2 Custom routes: `sdk.handler`

```lua
local sdk = require("helper.plugin-sdk")

return function(app)
    app:get("/stats", sdk.handler({ permission = "helpdesk_tickets.read" }, function(self)
        local rows = sdk.db.query([[
            SELECT status, COUNT(*)::int AS count
            FROM helpdesk_tickets WHERE namespace_id = ? GROUP BY status
        ]], sdk.namespace_id(self))
        return sdk.ok(sdk.array(rows))
    end))

    app:post("/tickets/:id/close", sdk.handler({ permission = "helpdesk_tickets.update" }, function(self)
        local tickets = sdk.resource("helpdesk_tickets")
        local row = tickets.update(sdk.namespace_id(self), self.params.id, { status = "closed" })
        if not row then return sdk.not_found("Ticket") end
        return sdk.ok(row)
    end))
end
```

`sdk.handler(opts, fn)` checks the tenant before your code runs:

| `opts` | Caller must be |
|---|---|
| `{ permission = "module.action" }` | An active member of an active namespace, holding that permission (platform admins pass). |
| `{}` or omitted | Any active member of the namespace. |
| `{ namespace = false }` | Any authenticated user. There is no tenant context, so don't touch tenant data. |

When you write SQL yourself, **always filter by `sdk.namespace_id(self)`**. That's the one rule the SDK can't enforce for you. Pass values as `?` placeholders, never by string concatenation.

### 5.3 Public (anonymous) routes

Routes under `/api/v2/<code>/public/` skip login. For example, `/api/v2/helpdesk/public/status` or `/api/v2/helpdesk/public/forms/:id`. This only works with the default `api_prefix`: a nested custom prefix doesn't match OpsAPI's public-route rule. With `sdk.handler({}, fn)` the namespace then comes from the `X-Namespace-Id` / `X-Namespace-Slug` header (inactive namespaces are refused). Validate everything, and rate-limit or add CAPTCHAs where abuse matters.

### 5.4 Request helpers

```lua
local body, err = sdk.body(self)          -- decoded JSON object; nil + message if invalid
local data, errors = sdk.validate(body, rules)          -- create
local data, errors = sdk.validate(body, rules, true)    -- partial update
local user = sdk.user(self)               -- current user (uuid, email, …)
if sdk.can(self, "helpdesk_tickets", "manage") then … end
return sdk.error(409, "Ticket already closed")
```

### 5.5 Plugin-wide filters

`app:before_filter(fn)` in a plugin runs only for that plugin's routes. Use it for things like audit headers. Call `self:write(response)` to stop a request.

---

## 6. Dashboard pages

Every `sdk.crud` resource can have a page in the admin dashboard: a searchable, sortable, filterable table with create, edit and delete forms. The dashboard builds the page at runtime from the resource's definition, so installing or changing a plugin needs **no dashboard rebuild**.

To show a page, list it in the manifest's `menu` (`make:resource` does this) and run `opsapi migrate`:

```lua
menu = {
    { label = "Tickets", resource = "tickets", module = "helpdesk_tickets", icon = "LifeBuoy" },
},
```

| Key | |
|---|---|
| `label` | Sidebar text. |
| `resource` | The `sdk.crud` path without the leading `/`. The page lives at `/dashboard/plugins/<code-with-hyphens>/<resource>`. |
| `module` | One of the plugin's `modules`. The item only shows to roles holding `<module>.read`, and each namespace can hide it in its menu settings. |
| `icon` | Optional Lucide icon name (default `Puzzle`). Besides the icons built-in modules use, the dashboard ships: Puzzle, LifeBuoy, Ticket, Inbox, Mail, Bell, Calendar, CalendarDays, CheckSquare, ListTodo, Folder, Archive, Box, Database, Layers, Tag, Bookmark, Star, Flag, Receipt, Wallet, CreditCard, Car, Plane, Camera, Image, Link, Megaphone, Target, TrendingUp, PieChart, Activity, Zap, Award, Gift, Lightbulb, Bug, Code, Server, Cloud, Headphones, Stethoscope, Utensils, Leaf, Hammer, Handshake, Newspaper. Unknown names show a generic icon. |
| `priority` | Optional sort position. By default plugin items come after the built-in ones. |

Shape the page in `sdk.crud`:

```lua
sdk.crud(app, "/tickets", {
    -- ...table, module, searchable, filterable, sortable as in §5.1
    fields = {
        requester_email = { type = "email", label = "Requester" },   -- caption in the table and form
        -- ...
    },
    ui = {
        label = "Tickets",                                        -- page title
        columns = { "title", "status", "priority", "due_on" },    -- default: the first 5 non-text fields
        form = { "title", "status", "priority", "due_on", "description" }, -- default: required first, then A–Z
    },
})
```

How the page behaves:

- **Inputs follow the field type**: text box, textarea, number, checkbox, date and date-time pickers, a dropdown for `enum`, and a JSON editor.
- **Search** appears when `searchable` is set. Each `filterable` field that is an `enum` or `boolean` gets a dropdown filter. `sortable` columns sort when their header is clicked.
- **Validation errors** from the API show under the field that caused them.
- **Buttons follow permissions.** New, Edit and Delete only appear when the user holds `<module>.create` / `.update` / `.delete` and the action isn't excluded with `only`. Without update rights, clicking a row opens a read-only view.
- Users without `<module>.read` see an access notice and no sidebar item. If the plugin is removed from the deployment, its sidebar items disappear.

The API stays the security boundary; the page only mirrors what the server allows. Custom screens (charts, workflows, hand-written routes like `/stats`) aren't generated: build those in your own frontend against the plugin's API.

`opsapi migrate` upserts the menu entries (key `plugin:<code>:<resource>`) and hides entries removed from the manifest. Per-namespace menu customisations are kept.

---

## 7. Migrations

- Files in `migrations/` run once each, in filename order, when `opsapi migrate` / `lapis migrate` runs. They're tracked per plugin in `project_migrations`.
- **Each migration runs in a transaction together with its tracking row.** A failure rolls everything back, nothing is marked done, and the migrate command exits non-zero so your deploy stops.
- **Never edit a migration that has been applied.** Add a new file. Edited files are reported as *drift* (a warning in the migrate output and in `GET /api/v2/plugins/:code`).
- Prefix your tables with the plugin code (`helpdesk_…`) so they can't collide with current or future OpsAPI tables. Avoid altering OpsAPI's own tables.
- Give every tenant table `namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE` and an index starting with `namespace_id`.
- Make migrations idempotent where you can (`IF NOT EXISTS`). Operators sometimes restore databases.
- Statements that can't run in a transaction (e.g. `CREATE INDEX CONCURRENTLY` on a big table) need the table form:

  ```lua
  return { transaction = false, up = function(schema, db)
      db.query("CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_helpdesk_tickets_status ON helpdesk_tickets (namespace_id, status)")
  end }
  ```

- Concurrent migrate runs (several pods, a Helm hook plus a manual run) are serialised with a Postgres advisory lock.
- `lapis migrate --dry-run` also dry-runs plugin migrations.

---

## 8. Multi-tenancy and RBAC

- Every request carries a **namespace** (tenant), from the `X-Namespace-Id` / `X-Namespace-Slug` header or the login token. Suspended namespaces are refused globally.
- Each `modules` entry in your manifest is added to OpsAPI's RBAC catalogue on migrate. **On first install, every namespace's `admin` and `owner` roles get `manage` on it.** Other roles get nothing until someone grants it in the dashboard's role editor. Later deploys never re-grant a permission an admin removed.
- A plugin is installed for the whole deployment, so its modules are grantable in every namespace. To offer a plugin to some tenants only, grant its module to their roles only.
- Platform admins pass every permission check but are still scoped to the namespace in their header.
- API keys work too: a key is bound to one namespace and its scopes act as permissions.

---

## 9. Settings and secrets

nginx hides environment variables from request handlers unless each is declared in `nginx.conf`, which plugins can't edit. So OpsAPI captures every variable named **`PLUGIN_*`** at startup:

```bash
docker run … -e PLUGIN_HELPDESK_SLACK_URL=https://hooks.slack.com/… bwalia/opsapi
```

```lua
local url = sdk.env("PLUGIN_HELPDESK_SLACK_URL")           -- nil if unset
local timeout = tonumber(sdk.env("PLUGIN_HELPDESK_TIMEOUT", "5"))
```

Name them `PLUGIN_<CODE>_<SETTING>`. These are deployment-wide. A setting that differs per tenant belongs in a database table keyed by `namespace_id`.

---

## 10. Deploying

### Production image (recommended)

Bake plugins into an image so every pod runs identical, versioned code:

```dockerfile
FROM bwalia/opsapi:1.0.160          # pin the OpsAPI version you tested against
COPY plugins/ /app/projects/
RUN opsapi plugin:check             # fail the build on a broken plugin
```

### Kubernetes

- Run `lapis migrate` before new pods take traffic, the same way you already do for OpsAPI (for example a Helm pre-upgrade Job using the new image). It runs core migrations then every plugin's.
- Keep the readiness probe on `/ready`. A pod whose plugins failed to load stays unready, so a rolling update stops with the old pods still serving.
- Don't mount plugins from a writable shared volume. Rebuild the image instead.

### Upgrading OpsAPI

- The SDK (`helper.plugin-sdk`) is the stable contract. Anything else inside OpsAPI can change between releases.
- If a release changes the SDK incompatibly it bumps `sdk_version`, and plugins written for the old version keep working until you move them.
- Run `opsapi plugin:check` in CI against the OpsAPI version you're upgrading to.

---

## 11. Operating plugins

| | |
|---|---|
| `GET /api/v2/plugins` | Platform admins. Every plugin, its routes, status, and load failures. |
| `GET /api/v2/plugins/:code` | The above plus migration status: executed, pending and drift. |
| `GET /ready` | 503 with `"Plugin failed to load: <codes>"` while any plugin is broken. |
| Logs | `[Plugin:<code>] …` lines at startup, and `[ProjectMigrator] …` lines on migrate. |

Common load failures:

- A syntax error in an `api/*.lua` file.
- A route that already exists.
- An `api_prefix` already in use.
- A reserved `code`.
- A manifest needing a newer SDK.

Each one is listed with its message in `GET /api/v2/plugins`.

---

## 12. SDK reference

`local sdk = require("helper.plugin-sdk")`

| Function | Returns / does |
|---|---|
| `sdk.crud(app, path, opts)` | Registers the 5 REST routes (§5.1) and the resource's dashboard page (§6, `opts.ui`), and returns the resource. |
| `sdk.resource(table, opts)` | Tenant-scoped repository (below). `opts`: `fields`, `searchable`, `filterable`, `sortable`, `key` (default `"uuid"`, needs a DB default), `timestamps` (default `true`: bump `updated_at`). |
| `sdk.handler(opts, fn)` | Wraps a handler with the namespace and permission checks (§5.2). |
| `sdk.validate(input, rules, partial)` | `clean` or `nil, { field = message }`. Rules: `type`, `required`, `min`, `max`, `enum` (`label` is used by dashboard pages only). |
| `sdk.body(self)` | Decoded JSON object, or `nil, message`. |
| `sdk.page(params)` | `page, per_page, offset` (`per_page` clamped to 1..100). |
| `sdk.namespace_id(self)` / `sdk.user(self)` | Caller's namespace id / user. |
| `sdk.can(self, module, action)` | Boolean permission check. |
| `sdk.env(name, default)` | A `PLUGIN_*` setting (§9). |
| `sdk.ok(data, meta)` / `sdk.created(data)` | 200 / 201 in the `{ success, data, meta }` envelope. |
| `sdk.error(status, message, details)` / `sdk.not_found(what)` | Error envelope `{ success = false, error, details }`. |
| `sdk.array(t)` | Marks a list so an empty one encodes as `[]`, not `{}`. |
| `sdk.db` | `lapis.db`: `query(sql, ...)`, `insert`, `update`, `NULL`, `raw`, … |
| `sdk.VERSION` | SDK version (matches `sdk_version`). |

Resource methods (the first argument is always the caller's namespace id):

| Method | Returns |
|---|---|
| `list(ns, params)` | `rows, meta`, or `nil, status, message` on a bad filter. |
| `find(ns, id)` | `row` or `nil`. |
| `create(ns, data)` | `row`, or `nil, status, message` (409 duplicate, 422 bad reference). |
| `update(ns, id, data)` | `row`, `nil` (not found), or `nil, status, message`. |
| `delete(ns, id)` | `true`, `false` (not found), or `nil, 409, message`. |

---

## 13. CLI reference

`opsapi` is on the `PATH` in the image. In the repo it's `lapis/bin/opsapi`.

| Command | |
|---|---|
| `opsapi plugin:new <name>` | Scaffold `<dir>/<name>/`. |
| `opsapi make:resource <plugin> <resource> <field:type[:required]>...` | Migration, CRUD API, RBAC module and dashboard page (§4, §6). |
| `opsapi plugin:check` | Validate every manifest and the Lua syntax of every file. Exit 1 on problems; use it in CI. |
| `opsapi migrate` | `lapis migrate`: core, then plugins. |

Plugins directory: `--dir <path>`, else `$OPSAPI_PROJECTS_DIR`, else `/app/projects`.

---

## 14. Limits and roadmap

- **Code changes need a restart.** OpsAPI caches compiled Lua per worker (`lua_code_cache on`), so restart the container or roll the deployment after changing a plugin.
- **Dashboard pages are generic.** Plugins get list/form pages for their `sdk.crud` resources (§6), not custom screens. Build anything else in your own frontend against the plugin's API.
- **No event hooks yet.** A plugin can't yet react to core events (e.g. "invoice paid"). For now, poll or call your plugin from your own frontend.
- Built-in modules (in `lapis/routes`) follow the same layering. See `CLAUDE.md` if you're contributing to OpsAPI itself rather than extending it.
