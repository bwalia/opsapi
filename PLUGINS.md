# Extending OpsAPI with plugins

OpsAPI ships many modules: CRM, invoicing, accounting, HR, chat, kanban and more. When you need an API it doesn't have, you don't fork it. You write a **plugin**: a folder of Lua files that OpsAPI loads at startup. It sits next to the built-in modules and gets the same authentication, multi-tenancy, RBAC, migrations and Swagger docs, plus generated pages in the admin dashboard. It can react to events such as "invoice paid" or "lead created", run scheduled jobs, and ask each workspace for its own settings. Each workspace can turn it on or off.

```
my-plugins/
└── helpdesk/
    ├── project.lua                          # manifest
    ├── api/
    │   ├── tickets.lua                      # → /api/v2/helpdesk/tickets
    │   └── stats.lua                        # → /api/v2/helpdesk/stats
    ├── events/
    │   └── billing.lua                      # runs when an invoice is paid / a customer is added
    ├── jobs/
    │   └── close_stale.lua                  # runs every hour, once per workspace
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
7. [Reacting to events](#7-reacting-to-events)
8. [Scheduled jobs](#8-scheduled-jobs)
9. [Migrations](#9-migrations)
10. [Multi-tenancy and RBAC](#10-multi-tenancy-and-rbac)
11. [Settings and secrets](#11-settings-and-secrets)
12. [Deploying](#12-deploying)
13. [Operating plugins](#13-operating-plugins)
14. [SDK reference](#14-sdk-reference)
15. [CLI reference](#15-cli-reference)
16. [Limits and roadmap](#16-limits-and-roadmap)

---

## 1. Security model: read this first

- **Plugins are trusted code.** They run inside the OpsAPI process with full database access, like a Drupal module or a WordPress plugin. Only the operator of a deployment installs them, by putting files in the plugins folder or baking them into an image.
- **Never let tenants upload plugins.** In a shared, multi-tenant deployment, code from one tenant could read every other tenant's data and the server's secrets. Tenant-level customisation (custom fields, workflows, webhooks) must be configuration stored in the database, not code.
- The SDK makes the safe path the easy path:
  - Every plugin route requires a valid login (JWT or API key), except routes under `/api/v2/<code>/public/`.
  - `sdk.crud` / `sdk.handler` require an active namespace membership and an RBAC permission.
  - `sdk.crud` / `sdk.resource` scope every query to the caller's namespace.
  - Input is whitelisted and type-checked.
  - `sdk.http` refuses private and internal addresses, for URLs that came from a user or a workspace setting.
  - Event handlers receive the tenant (`event.namespace_id`) of every event and must scope their writes to it.
- Turning a plugin off in a workspace is a hard switch, whatever the caller's role. Its routes answer 404 there, its sidebar entries and pages disappear, and no events or jobs run for that workspace (§10).
- The loader keeps plugins in their lane:
  - A plugin can't replace a built-in route or use a built-in module's code or URL prefix.
  - A plugin's `before_filter` only runs for its own routes.
  - A plugin that fails to load takes the pod out of rotation (`/ready` → 503) instead of silently serving 404s.
- Custom dashboard pages (§6.2) run in a sandboxed frame with no access to the dashboard's session, storage or DOM. They reach the API only through the dashboard, as the signed-in user, and only the plugin's own API plus the prefixes its manifest lists.

---

## 2. Quick start

### With the repository (local development)

`./start.sh` mounts the repo's `projects/` folder into the container as `/app/projects`.

```bash
docker exec opsapi opsapi plugin:new helpdesk
docker exec opsapi opsapi make:resource helpdesk ticket \
    title:string:required description:text status:string:required due_on:date
docker exec opsapi opsapi migrate        # creates the table, registers RBAC module + sidebar entry
```

Then open the dashboard: **Tickets** is in the sidebar, at `/dashboard/plugins/helpdesk/tickets`.

**Hot reload.** `./start.sh -e local` runs the API with `OPSAPI_DEV_RELOAD=true`, so there's no restart step:

- **Save any `.lua` file** (a route, a handler, the manifest, or core code) and the server reloads itself within about 3 seconds. In-flight requests finish on the old code.
- **A file that doesn't compile** is reported in the log (`[dev-reload] not reloading — fix this first`), and the old code keeps running.
- **Saving `project.lua` or an `events/` file** also re-syncs the plugin's RBAC modules, sidebar menu and event subscriptions.
- **New migration files** don't run by themselves, because a half-written one would be marked as applied. Run `opsapi migrate`.

### With only the Docker image

```bash
mkdir plugins
alias opsapi-cli='docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/plugins:/app/projects" bwalia/opsapi opsapi'
opsapi-cli plugin:new helpdesk
opsapi-cli make:resource helpdesk ticket title:string:required status:string:required

# run OpsAPI with the plugins mounted (plus your usual env / database settings)
docker run -d --name opsapi -v "$PWD/plugins:/app/projects" --env-file .env -p 4010:80 bwalia/opsapi
docker exec opsapi opsapi migrate && docker exec opsapi opsapi reload
```

Outside `./start.sh`, `opsapi reload` picks up code changes without downtime. Or set `OPSAPI_DEV_RELOAD=true` on a development container to reload on save; never set it in production.

### Try it

Log in as a user whose role has the new permission. Admin and owner roles get it automatically, see [§10](#10-multi-tenancy-and-rbac).

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

    -- Custom dashboard pages: your own HTML under ui/ (§6.2).
    pages = {
        { key = "overview", label = "Support overview", entry = "ui/overview.html", module = "helpdesk_tickets" },
        -- opsapi:pages (make:page adds entries above this line)
    },

    -- Dashboard sidebar entries: each opens the generated page of an sdk.crud
    -- resource, or a custom page (§6).
    menu = {
        { label = "Support overview", page = "overview", module = "helpdesk_tickets", icon = "LayoutDashboard" },
        { label = "Tickets", resource = "tickets", module = "helpdesk_tickets", icon = "LifeBuoy" },
        -- opsapi:menu (make:resource adds entries above this line)
    },

    -- Tables whose changes are published as events other plugins can
    -- subscribe to: helpdesk.ticket.created / updated / deleted (§7).
    -- `verbs` add business events: helpdesk.ticket.closed fires when a
    -- ticket becomes closed. The short form `ticket = "helpdesk_tickets"`
    -- publishes only created / updated / deleted.
    publishes = {
        ticket = { table = "helpdesk_tickets", verbs = { closed = { status = "closed" } } },
        -- opsapi:publishes (make:resource adds entries above this line)
    },

    -- Settings each workspace fills in under Workspace -> Plugins (§11).
    settings = {
        auto_close_days = { type = "integer", label = "Close pending tickets after (days)", default = 14, min = 1 },
        slack_webhook_url = { type = "url", label = "Slack webhook URL", secret = true },
    },

    -- default_enabled = false,           -- off in every workspace until it's turned on there (§10)
    -- api_prefix = "/api/v2/helpdesk",   -- default: /api/v2/<code with hyphens>
}
```

Rules enforced at load time:

- `code` is lowercase letters, digits and `_`, and must not be a built-in module's code (`crm`, `hospital`, …).
- `api_prefix` must be under `/api/` and must not already be used by OpsAPI or another plugin.
- A plugin needing a newer `sdk_version` than the running OpsAPI is refused. Upgrade OpsAPI first.
- Every `menu` entry needs a `label`, either a `resource` or a `page`, and a `module` that is one of the plugin's `modules`.
- Every `pages` entry needs a unique `key`, a `label`, an `entry` under `ui/` ending in `.html`, and a `module`. Its optional `api` lists must start with `/api/`.
- `publishes` names are lowercase. Each verb has a condition `{ column = value }` or `{ column = { value, value } }`, and can't be called `created`, `updated` or `deleted`.
- `settings` names are lowercase. Types are `sdk.validate`'s except `json`. A `default` must pass its own rules. Only `string`, `text` and `url` settings can be `secret`, and a secret has no default.

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
| `project.lua` | The `helpdesk_tickets` RBAC module, a **Tickets** sidebar entry, and `publishes` (events `helpdesk.ticket.*`) are added. |

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

Database errors you don't catch become client errors, not 500s: a duplicate value answers `409`, a missing required column or a reference to a row that doesn't exist answers `422`, and a malformed value (text where a UUID or number belongs) answers `400`. The body is `{ error = { code, message, context } }`, never the SQL. Anything else is a logged `500` with a generic message. Catch errors yourself only when you want a different status or message.

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

Plugins add pages to the admin dashboard in two ways, and neither needs a dashboard rebuild:

- **Generated pages (§6.1).** A full list/form page for any `sdk.crud` resource, from its definition. No frontend code.
- **Custom pages (§6.2).** Your own HTML (plain JS, React, Vue, Svelte…) for anything else: dashboards, charts, workflows, wizards.

### 6.1 Generated pages

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

The API stays the security boundary; the page only mirrors what the server allows. For charts, workflows or hand-written routes like `/stats`, write a custom page (§6.2).

`opsapi migrate` upserts the menu entries (key `plugin:<code>:<resource or page>`) and hides entries removed from the manifest. Per-namespace menu customisations are kept.

### 6.2 Custom pages

A custom page is an HTML file in your plugin's `ui/` folder. The dashboard shows it inside its own layout, under the plugin's sidebar entry, and it looks native: the dashboard's colours, tenant branding included, are applied to it. [`projects/helpdesk/ui/overview.html`](projects/helpdesk/ui/overview.html) is a complete example: stats, a prioritised list, escalation with a confirm dialog, a create form and a deep-linked detail view.

```bash
opsapi make:page helpdesk overview "Support overview"   # ui/overview.html + pages + menu entries
opsapi migrate                                          # adds the sidebar item
```

```lua
-- project.lua
pages = {
    { key = "overview", label = "Support overview", entry = "ui/overview.html",
      module = "helpdesk_tickets",            -- users need helpdesk_tickets.read to open it
      description = "Open tickets by priority", -- optional: subtitle under the page title
      api = { "/api/v2/customers" } },        -- optional: other APIs the page may call
},
menu = {
    { label = "Support overview", page = "overview", module = "helpdesk_tickets", icon = "LayoutDashboard" },
},
```

The page itself:

```html
<link rel="stylesheet" href="/plugin-ui/_sdk/opsapi-ui.css">   <!-- dashboard look: cards, tables, buttons, forms -->
<script src="/plugin-ui/_sdk/opsapi-ui.js"></script>             <!-- the page bridge -->
<script>
  OpsAPI.connect().then(async (ops) => {
    const { data, meta } = await ops.api.get('/tickets', { status: 'open', per_page: 10 });  // this plugin's API
    if (ops.can('create')) { /* show the form */ }
    ...
  });
</script>
```

**The bridge (`ops`).** Your page gets no token and never talks to the API directly. Every call goes through the dashboard, which adds the user's session and the current workspace.

| | |
|---|---|
| `ops.api.get(path, query)`, `.post(path, body)`, `.put`, `.patch`, `.delete(path)` | Resolves with the JSON body (`{ success, data, meta }`). Rejects with an `OpsAPIError` that has `status`, `message` and `body`. Relative paths (`/tickets`) are this plugin's API; absolute ones (`/api/v2/customers/…`) must be listed in the page's `api`. |
| `ops.context` | `{ plugin, page, user: { uuid, email, name }, namespace: { uuid, name, slug }, params, theme, can, permissions, isAdmin }` |
| `ops.can(action)`, `ops.can(module, action)` | Whether the user may do it: for the page's module as the API decided, otherwise from the user's role. Use it to hide buttons; the API still enforces everything. |
| `ops.navigate('/dashboard/…')` | Open another dashboard page. |
| `ops.toast(message, 'success' \| 'error' \| 'info')` | A dashboard notification. |
| `ops.confirm({ title, message, confirmLabel, danger })` | The dashboard's confirm dialog. Resolves `true` or `false`. |
| `ops.setParams({ ticket: id })`, `ops.on('params', fn)` | Keep page state in the dashboard URL, so links can be shared and the back button works. `ops.context.params` has the values the page opened with. |
| `ops.on('theme', fn)` | The user switched light/dark or the branding changed. `opsapi-ui.css` follows by itself. |

**Height.** The frame grows and shrinks with your content, so the dashboard scrolls, not the frame. Don't set `height: 100%` on `html` or `body`.

**Styling.** `opsapi-ui.css` provides `ops-page`, `ops-grid`, `ops-card`, `ops-stat`, `ops-btn` (`-primary`, `-danger`, `-ghost`, `-sm`), `ops-input`/`ops-select`/`ops-textarea` with `ops-label`, `ops-table` inside `ops-table-wrap`, `ops-badge` (`-success`, `-warning`, `-error`, `-info`), `ops-alert`, `ops-empty`, `ops-skeleton` and `ops-muted`. Use the `--ops-*` colour variables in your own CSS (`var(--ops-primary)`, `var(--ops-border)`, …) and it follows the tenant's branding and dark mode too.

**Frameworks and build tools.** Any static output works. Put the build in `ui/` and point `entry` at its HTML. Build with relative asset URLs; for Vite that's `base: './'`. Files are served from `/plugin-ui/<code>/…` with an ETag, so a redeployed page shows at once without stale caches. Only web asset types are served (html, js, css, json, images, fonts, source maps), never anything outside `ui/` or starting with a dot.

**Security.**

- **The frame is sandboxed without same-origin access.** Your page can't read the dashboard's session, storage or DOM.
- **The bridge only answers its own frame.** Each page load gets a random token. A document the frame navigates to never learns it, so it can't use the bridge.
- **API calls are limited** to your plugin's API prefix plus the page's `api` list. Encoded or `..` paths are refused.
- **Requests run as the signed-in user.** The API's RBAC and tenant scoping apply exactly as they do for the dashboard.
- **`ui/` files are public static assets**, like any web app's bundles. Never put secrets in them; keep secrets server-side and read them with `sdk.env`.

---

## 7. Reacting to events

Plugins can react when something changes in OpsAPI (an invoice is paid, a lead comes in, a task moves) without touching core code.

```bash
opsapi events                                      # everything you can subscribe to
opsapi make:listener helpdesk invoice.paid billing
```

```lua
-- projects/helpdesk/events/billing.lua
local sdk = require("helper.plugin-sdk")
local tickets = sdk.resource("helpdesk_tickets")

return {
    ["invoice.paid"] = function(event)
        local row, code = tickets.create(event.namespace_id, {
            title = "Thank " .. (event.data.customer_name or "the customer") .. " for paying",
            status = "open",
            source_event = event.id,    -- unique index: a redelivery can't open a second ticket
        })
        if not row and code ~= 409 then error("could not open ticket") end  -- retried later
    end,
}
```

Run `opsapi migrate`, which registers the subscription and the database trigger. With hot reload the handler is live as soon as you save it; otherwise run `opsapi reload`. The full example is [`projects/helpdesk/events`](projects/helpdesk/events).

### Events you can subscribe to

- **Core table events**, `<entity>.created` / `.updated` / `.deleted` (or `<entity>.*` for all of an entity's events):

  | Area | Entities |
  |---|---|
  | Sales | `customer`, `order`, `invoice`, `invoice.payment` |
  | CRM | `crm.account`, `crm.contact`, `crm.deal`, `crm.lead`, `crm.activity` |
  | People | `employee`, `timesheet`, `member` (namespace membership) |
  | Work | `kanban.project`, `kanban.task`, `fs.job`, `fs.visit` |

  Entities whose module isn't enabled in your deployment never fire. `opsapi events` prints the list with each entity's table.
- **Business events**: what happened, not just "a row changed". `invoice.paid` fires once when an invoice *becomes* paid: it's created as paid, or updated from any other status to paid. Saving a paid invoice again doesn't repeat it. These come from the same trigger and transaction as `invoice.updated`, so they're just as reliable. `<entity>.*` includes them, so a change that pays an invoice delivers both `invoice.updated` and `invoice.paid` to such a subscriber.

| Entity | Business events |
|---|---|
| `invoice` | `sent`, `paid`, `partially_paid`, `overdue`, `cancelled` (status cancelled or void) |
| `order` | `confirmed`, `shipped`, `delivered`, `cancelled`, `paid` and `refunded` (financial status) |
| `crm.deal` | `won`, `lost` |
| `crm.lead` | `qualified`, `converted`, `lost` |
| `crm.activity` | `completed` |
| `customer` | `disabled` |
| `employee` | `deactivated` |
| `timesheet` | `submitted`, `approved`, `rejected` |
| `kanban.project` | `completed`, `archived` |
| `kanban.task` | `completed`, `blocked` |
| `fs.job` | `scheduled`, `started` (in progress), `completed`, `cancelled` |
| `fs.visit` | `arrived` (on site), `completed`, `cancelled`, `no_access` |
| `member` | `joined` (became active), `suspended`, `left` |

- **Plugin table events**: every table in a manifest's `publishes` gives `<plugin>.<name>.created` / `.updated` / `.deleted`, plus the `verbs` you declare (§3). `make:resource` adds its table.
- **Custom events**: `sdk.emit(namespace_id, "helpdesk.ticket.escalated", { ... })` from any plugin code. Name them `<plugin>.<entity>.<action>`; core entity names are reserved.

### The event

| Field | |
|---|---|
| `id` | UUID, the same on every retry. Use it to make handlers idempotent. |
| `name`, `entity` | `"invoice.updated"`, `"invoice"`. |
| `entity_id` | The row's `uuid` (or `id`). |
| `namespace_id` | The tenant. **Scope everything you read or write to it.** |
| `data` | The row after the change (before it, for `*.deleted`); for custom events, what was emitted. NULL columns are absent. |
| `changes` | `*.updated` and business events caused by an update: `{ column = { from = …, to = … } }` for the columns that changed. An update that only touches `updated_at` isn't an event. |
| `occurred_at`, `attempt` | When it happened; which delivery attempt this is (1, 2, …). |
| `settings` | The workspace's settings for your plugin (§11), read on first use. |

`data` mirrors the database row, so column names follow the table (see `opsapi events`). Read it defensively; columns can change between OpsAPI releases.

### Delivery guarantees

- **Transactional.** Events are recorded in the same database transaction as the change. A rolled-back change never fires; a committed one always does, whoever made it: the API, the AI assistant, an import, or another service writing to the database.
- **Background, at least once.** Handlers run in background workers about 2 seconds after the commit, never inside the user's request. If a handler raises an error (or returns `false, "reason"`), the event is retried with backoff (15s, 30s, 1m … up to 1h). After 8 attempts it is marked dead. Events can arrive more than once and in any order, so make handlers idempotent: key on `event.id`, as `projects/helpdesk` does with a unique index.
- **Isolated.** Each events file is its own subscriber, so a failing handler doesn't hold up the others. Eventing never fails the original write.
- **Scales out.** Every worker in every pod pulls deliveries, and each delivery is claimed by exactly one of them (`FOR UPDATE SKIP LOCKED`).
- **No cost when unused.** A table only gets its trigger while some plugin subscribes to its events.
- **Only where the plugin is on.** A workspace that has turned your plugin off gets no deliveries, so its events aren't queued up for later (§10).
- **Retention.** Delivered events are purged after 7 days, dead ones after 30.

### Writing good handlers

- Scope every query to `event.namespace_id`.
- Be idempotent (above), and keep handlers short. Call external services with timeouts. A delivery that runs longer than 5 minutes is handed to another worker.
- Read the workspace's settings from `event.settings` and deployment-wide secrets with `sdk.env` (§11). Call a URL a workspace typed in with `sdk.http`, which refuses internal addresses.
- Finish any transaction you open. A handler that leaves one open has it rolled back, and the delivery counts as failed.
- Don't do work when the file loads: `lapis migrate` and `plugin:check` load it too.
- For your own domain events, prefer table events (`publishes`), which are transactional. When "what happened" is a state change, declare a verb rather than decoding `changes` in every handler. Use `sdk.emit` for things that aren't a row change ("escalated", "reminder due").

### Workspace webhooks use the same outbox

Tenants can have these events sent to their own URLs without writing code. See [WEBHOOKS.md](WEBHOOKS.md). Each webhook is a subscriber scoped to its workspace, so it shares these guarantees and the retries. Everything a plugin lists in `publishes` is offered to webhooks too.

### Audit trail

Every table in `publishes` and every `sdk.emit` is also recorded in the workspace's audit trail: who changed which record, with the fields before and after. Workspace admins see it under **Activity → Audit trail**. You don't need to write anything for this. Name secret columns so they contain `password`, `secret`, `token`, `api_key` or `private_key`, and they're left out of the trail. See [USER_ACTIVITY.md](USER_ACTIVITY.md#audit-trail-record-changes).

### Watching and fixing

- `GET /api/v2/plugins/:code` (platform admin) → `events`: subscriptions, published tables, delivery counts (pending / running / done / dead), and recent failures with their last error.
- `POST /api/v2/plugins/:code/events/retry` re-queues dead deliveries once you've fixed the handler.
- A broken events file fails `opsapi migrate`, and `/ready` reports it.

---

## 8. Scheduled jobs

A job is work that runs on a schedule: closing stale tickets, sending reminders, syncing with another system. By default it runs once per workspace that has the plugin on.

```bash
opsapi make:job helpdesk close_stale 1h
```

```lua
-- projects/helpdesk/jobs/close_stale.lua
local sdk = require("helper.plugin-sdk")

return {
    every = "1h",
    run = function(job)
        sdk.db.query([[
            UPDATE helpdesk_tickets SET status = 'closed', updated_at = NOW()
            WHERE namespace_id = ? AND status = 'pending'
              AND updated_at < NOW() - make_interval(days => ?)
        ]], job.namespace_id, job.settings.auto_close_days)
    end,
}
```

| Key | |
|---|---|
| `every` | A number and `s`, `m`, `h` or `d`: `"15m"`, `"1h"`, `"1d"`. At least one minute. It's the gap after a run finishes. |
| `at` | With `every` in whole days: the time of day, UTC (`every = "1d", at = "03:00"`). |
| `scope` | `"workspace"` (default): once per workspace that has the plugin on. `"global"`: once per deployment, with no `job.namespace_id`. |
| `run(job)` | `job` = `{ name, namespace_id, settings, last_run_at }`. Raise an error (or `return false, "why"`) to mark the run failed. |

How jobs run:

- **One run at a time, anywhere.** Every worker in every pod polls for due jobs, and each run is claimed by one of them (`FOR UPDATE SKIP LOCKED`) for 15 minutes. If the worker dies, the job runs again when that time is up. **Make runs safe to repeat**, as the example is: it only touches tickets that are still pending.
- **No retries, like cron.** A failed run is recorded and the job waits for its next slot. Runs missed while OpsAPI was down happen once at startup; the schedule then continues.
- **Spread out.** A new job's first run in each workspace falls somewhere in the next 5 minutes, so a deploy doesn't start them all at once. `at` jobs keep their time.
- **Follows on/off.** A workspace that turns the plugin off stops getting runs; turning it back on starts them again.
- Scope every query to `job.namespace_id`, and finish any transaction you open (one left open is rolled back and the run counts as failed).

Watching them: `GET /api/v2/plugins/:code` (platform admin) → `jobs` gives each job's schedule, how many workspaces run it, how many last failed, and their errors. `POST /api/v2/plugins/:code/jobs/:job/run` runs a job now, for every workspace or `?namespace_id=` one: handy while developing. Workspace admins see each job's last and next run under **Workspace → Plugins**, without the error text.

---

## 9. Migrations

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

## 10. Multi-tenancy and RBAC

- Every request carries a **namespace** (tenant), from the `X-Namespace-Id` / `X-Namespace-Slug` header or the login token. Suspended namespaces are refused globally.
- Each `modules` entry in your manifest is added to OpsAPI's RBAC catalogue on migrate. **On first install, every namespace's `admin` and `owner` roles get `manage` on it.** Other roles get nothing until someone grants it in the dashboard's role editor. Later deploys never re-grant a permission an admin removed.
- A plugin is installed for the whole deployment, so its modules are grantable in every namespace.
- Platform admins pass every permission check but are still scoped to the namespace in their header.
- API keys work too: a key is bound to one namespace and its scopes act as permissions. Scope a key to one of your plugin's modules (e.g. `helpdesk_tickets: ["read"]`) and it can call your plugin's API, within those actions.

### Turning a plugin on or off per workspace

Workspace owners turn plugins on and off under **Workspace → Plugins** (`PUT /api/v2/namespace/plugins/:code` with `{ "enabled": false }`, needs `namespace.update`). Off is a hard switch for that workspace, whatever the caller's role, platform admins included:

- the plugin's routes answer `404` with `"code": "PLUGIN_DISABLED"`;
- its sidebar entries and pages disappear;
- no event deliveries are queued for that workspace, and its jobs don't run.

Your code doesn't need to check anything. Plugins are on everywhere by default. Set `default_enabled = false` in the manifest for an opt-in plugin, which stays off until a workspace turns it on. Turning a plugin on fails with `422` while a `required` setting without a default is empty.

**Calling your plugin from other apps.** Your plugin's routes are in the server's `/openapi.json`, with exact types for every `sdk.crud` resource: fields, required fields, enums, filters and sort options. Pair it with the TypeScript client, [`@opsapi/client`](sdk/typescript), for a typed SDK of your deployment:

```bash
npx openapi-typescript https://api.example.com/openapi.json -o src/opsapi.d.ts
```

```ts
const opsapi = createClient<paths>({ baseUrl, token: process.env.OPSAPI_KEY, namespace: 'acme' });
await opsapi.POST('/api/v2/helpdesk/tickets', { body: { title: 'Printer on fire', status: 'open' } });
```

---

## 11. Settings and secrets

### Per workspace

Declare the settings a workspace fills in under `settings` in the manifest (§3). Each workspace sees a form for them under **Workspace → Plugins**, generated from the rules: no dashboard code. Read them with:

```lua
sdk.settings(self)              -- in a route: { auto_close_days = 14, slack_webhook_url = "https://…" }
event.settings                  -- in an event handler
job.settings                    -- in a job
sdk.settings("helpdesk", ns)    -- anywhere else
```

A setting nobody filled in has its `default` (or `nil`). Rules are `sdk.validate`'s (`type`, `required`, `min`, `max`, `enum`, `label`) plus:

| | |
|---|---|
| `default` | Used until the workspace sets a value. Clearing a value goes back to it. |
| `description` | Help text under the field. |
| `secret = true` | Stored encrypted (with `OPENSSL_SECRET_KEY`). The API never returns it, only whether it's set, and the audit trail records only that it changed. Your code gets the plain value. |

The API is `GET /api/v2/namespace/plugins` (`namespace.read`) and `PUT /api/v2/namespace/plugins/:code` with `{ "settings": { "auto_close_days": 7 } }` (`namespace.update`). Updates are partial, `null` clears a setting, and every change is in the workspace's audit log. Check URLs a workspace gives you with `type = "url"`, and call them with `sdk.http`: it refuses private and internal addresses.

### Per deployment

nginx hides environment variables from request handlers unless each is declared in `nginx.conf`, which plugins can't edit. So OpsAPI captures every variable named **`PLUGIN_*`** at startup:

```bash
docker run … -e PLUGIN_HELPDESK_SLACK_URL=https://hooks.slack.com/… bwalia/opsapi
```

```lua
local url = sdk.env("PLUGIN_HELPDESK_SLACK_URL")           -- nil if unset
local timeout = tonumber(sdk.env("PLUGIN_HELPDESK_TIMEOUT", "5"))
```

Name them `PLUGIN_<CODE>_<SETTING>`. These are deployment-wide: use them for the operator's own credentials, and workspace settings for anything a tenant chooses.

---

## 12. Deploying

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

## 13. Operating plugins

| | |
|---|---|
| `GET /api/v2/plugins` | Platform admins. Every plugin, its routes, status, and load failures. |
| `GET /api/v2/plugins/:code` | The above plus migration status (executed, pending, drift) and events (subscriptions, delivery counts, recent failures). |
| `POST /api/v2/plugins/:code/events/retry` | Re-queue the plugin's dead event deliveries. |
| `POST /api/v2/plugins/:code/jobs/:job/run` | Run a job now: every workspace, or `?namespace_id=` one (§8). |
| `GET /api/v2/namespace/plugins` | Workspace members with `namespace.read`: each plugin, on or off here, its settings (secrets: only whether set) and its jobs' last and next runs. |
| `PUT /api/v2/namespace/plugins/:code` | `namespace.update`: `{ "enabled": true/false, "settings": { … } }` for this workspace (§10, §11). Audited. |
| `GET /ready` | 503 with `"Plugin failed to load: <codes>"` while any plugin is broken. |
| Logs | `[Plugin:<code>] …` lines at startup, `[ProjectMigrator] …` lines on migrate, and `[dev-reload] …` lines when hot reload is on. |

Common load failures:

- A syntax error in an `api/*.lua` file.
- A route that already exists.
- An `api_prefix` already in use.
- A reserved `code`.
- A manifest needing a newer SDK.

Each one is listed with its message in `GET /api/v2/plugins`.

---

## 14. SDK reference

`local sdk = require("helper.plugin-sdk")`

| Function | Returns / does |
|---|---|
| `sdk.crud(app, path, opts)` | Registers the 5 REST routes (§5.1) and the resource's dashboard page (§6, `opts.ui`), and returns the resource. |
| `sdk.resource(table, opts)` | Tenant-scoped repository (below). `opts`: `fields`, `searchable`, `filterable`, `sortable`, `key` (default `"uuid"`, needs a DB default), `timestamps` (default `true`: bump `updated_at`). |
| `sdk.handler(opts, fn)` | Wraps a handler with the namespace and permission checks (§5.2). |
| `sdk.validate(input, rules, partial)` | `clean` or `nil, { field = message }`. Rules: `type` (`string` `text` `integer` `number` `boolean` `date` `datetime` `email` `url` `uuid` `json`), `required`, `min`, `max`, `enum` (`label` is used by dashboard pages only). |
| `sdk.body(self)` | Decoded JSON object, or `nil, message`. |
| `sdk.page(params)` | `page, per_page, offset` (`per_page` clamped to 1..100). |
| `sdk.namespace_id(self)` / `sdk.user(self)` | Caller's namespace id / user. |
| `sdk.can(self, module, action)` | Boolean permission check. |
| `sdk.env(name, default)` | A `PLUGIN_*` setting (§11). |
| `sdk.settings(self)` / `sdk.settings(code, ns)` | The workspace's settings for the plugin, with defaults; secrets decrypted (§11). |
| `sdk.http(url, params)` | An HTTP request to a URL a user gave you: public addresses only, https only. `params`: `method`, `headers`, `body`, `query`, `timeout_ms`. Returns `{ status, headers, body }` or `nil, err`. |
| `sdk.emit(namespace_id, name, data)` | Publish a custom event (§7). Returns the number of deliveries queued (0 when nobody listens). |
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

## 15. CLI reference

`opsapi` is on the `PATH` in the image. In the repo it's `lapis/bin/opsapi`.

| Command | |
|---|---|
| `opsapi plugin:new <name>` | Scaffold `<dir>/<name>/`. |
| `opsapi make:resource <plugin> <resource> <field:type[:required]>...` | Migration, CRUD API, RBAC module, dashboard page and published events (§4, §6, §7). |
| `opsapi make:listener <plugin> <event> [file]` | `events/<file>.lua` with a handler for `<event>` (§7). |
| `opsapi make:job <plugin> <name> [every]` | `jobs/<name>.lua`, a scheduled job (§8). `every` defaults to `1h`. |
| `opsapi make:page <plugin> <page> [label]` | `ui/<page>.html`, a working custom page, plus its `pages` and sidebar entries (§6.2). |
| `opsapi events` | List the events you can subscribe to: core tables and every plugin's `publishes`. |
| `opsapi plugin:check` | Validate every manifest, events file, jobs file and the Lua syntax of every file. Exit 1 on problems; warns about events nothing publishes. Use it in CI. |
| `opsapi migrate` | `lapis migrate`: core, then plugins. |
| `opsapi reload` | `plugin:check`, then a graceful reload of the running server. New workers load the new code while the old ones finish their requests. Refuses to reload into a broken plugin. |

Plugins directory: `--dir <path>`, else `$OPSAPI_PROJECTS_DIR`, else `/app/projects`.

---

## 16. Limits and roadmap

- **Code is cached per worker** (`lua_code_cache on`). Development reloads on save (`OPSAPI_DEV_RELOAD=true`). Elsewhere, run `opsapi reload` or roll the deployment. Deleting a file isn't noticed by hot reload; run `opsapi reload`.
- **Custom pages are static.** A page is HTML/JS served from `ui/` and talks to your API through the bridge; there's no server-side rendering of plugin pages.
- **Jobs are interval schedules**, not cron expressions: `every`, plus `at` for daily ones (UTC). A run longer than 15 minutes may start a second time on another worker.
- **Turning a plugin off is per workspace, not per user.** Use RBAC (§10) to limit who in a workspace can use it.
- **Event payloads are database rows**, not the API's JSON shape. Business events cover status changes (`invoice.paid`); anything subtler can still be derived from `invoice.updated` and its `changes`.
- Built-in modules (in `lapis/routes`) follow the same layering. See `CLAUDE.md` if you're contributing to OpsAPI itself rather than extending it.
