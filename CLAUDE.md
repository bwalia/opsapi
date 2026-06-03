# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OpsAPI is a multi-tenant SaaS platform that ships many business modules behind one API: authentication/RBAC, CRM, invoicing, accounting/bookkeeping, UK tax filing (HMRC MTD), hospital/care-home management, e-commerce, delivery, chat, kanban, timesheets, themes, secret vault, and more. A single codebase is sliced into "projects" (presets of features) selected at deploy time, and isolated at runtime by a Keycloak-style **namespace** (tenant) concept.

Stack ("OLP"): **OpenResty Nginx + Lua (Lapis framework) + PostgreSQL** for the backend, **Next.js** (App Router) for the admin dashboard, plus Redis, MinIO (S3 files), Kafka, Ollama (local LLM), Prometheus/Grafana. Lua runs inside the Nginx workers — there is no separate app server.

Repo layout: `lapis/` = backend API, `opsapi-dashboard/` = Next.js frontend, `node/` = optional Node file-upload service, `devops/` + `sre/` = infra (Helm, Ansible, nginx, monitoring), `projects/` = pluggable project modules, `start.sh` = the all-in-one dev/deploy orchestrator.

## Commands

### Full local stack (preferred)
`start.sh` orchestrates docker-compose, migrations, admin seeding, and `/etc/hosts`:
```bash
cp lapis/.sample.env lapis/.env           # first time only
./start.sh -e local -n -j all             # bring up everything, create ALL tables
./start.sh -e local -n -j tax_copilot     # only core + tax tables (see PROJECT_CODE below)
./start.sh -e local -n -j all -r          # -r resets the DB (drops volumes)
./start.sh -e local -n -j all -A admin@me.com -W MyPass123   # custom admin creds
```
Key flags: `-e <env>` (local|dev|test|acc|prod), `-j <PROJECT_CODE>`, `-n` (skip git), `-r` (reset DB), `-C` (CI mode, no dev volume mounts), `-c` (only update `.env`). Run `./start.sh -h` for the full list. Default admin: `admin@opsapi.com` / `Admin@123`.

Local URLs: API `http://127.0.0.1:4010` (Swagger at `/swagger`, health at `/health`), Dashboard `http://127.0.0.1:8039`, Adminer `:7779`, MinIO console `:9001`, Grafana `:3011`, Prometheus `:9090`, Gatus `:8888`.

### Backend (lapis/)
```bash
cd lapis && ./lapis-run-dev.sh            # compose up + run `lapis migrate` (standalone, no start.sh)
docker exec -it opsapi lapis migrate      # run migrations against the running container
docker exec -e PROJECT_CODE=ecommerce -it opsapi lapis migrate   # migrate a specific project
docker logs -f opsapi                     # tail API logs
```
Lint: `luacheck` (config in `lapis/.luacheckrc`; `ngx` is a known global, max line 120). CI validates syntax with `openresty -t` (see `.github/workflows/validate-opsapi-syntax.yml`).

### Frontend (opsapi-dashboard/)
```bash
npm run dev          # next dev on port 8039
npm run build        # next build (standalone output for Docker)
npm run lint         # eslint
npm run type-check   # tsc --noEmit
npm run cy:open      # Cypress interactive
npm run cy:run       # Cypress headless (e2e in cypress/e2e/)
npm run cy:run:login # run a single spec: cypress run --spec '...'
```
`NEXT_PUBLIC_API_URL` (default `http://127.0.0.1:4010`) points the dashboard at the backend.

## Backend architecture

### Two concepts decide what code runs
1. **PROJECT_CODE** (env var, build/deploy-time): selects which feature modules exist. `helper/project-config.lua` maps a code (`all`, `tax_copilot`, `ecommerce`, `hospital`, `business`, `collaboration`, `core_only`, …) to a set of features. Codes can be combined with commas (`ecommerce,chat`). `core` is always on.
2. **Namespace** (per-request, runtime): the tenant. Every business table carries `namespace_id`; middleware resolves the tenant and scopes all data.

`app.lua` wires both: it registers public routes (`/`, `/health`, `/ready`, `/live`, `/metrics`, `/swagger`, `/openapi.json`, auth endpoints), installs a global `before_filter` that runs JWT auth on everything else, then **feature-gated route loading** via `load_if(feature, "routes.x")` — a route file is only `require`d if its feature is enabled, so projects never query tables that don't exist for them. When adding a module, both the route loader in `app.lua` AND the migration loader in `migrations.lua` must be gated on the same feature.

### Layering (follow this pattern for any new module)
`routes/*.lua` → `queries/*.lua` → `models/*.lua` → PostgreSQL.
- **Models** (`models/XModel.lua`) are thin: `Model:extend("table_name", { timestamp = true })`. Auto-loaded via `models.lua` (`autoload("models")`).
- **Queries** (`queries/XQueries.lua`) hold all business logic, validation, pagination, and raw SQL (`require("lapis.db")`). Always filter by `namespace_id`.
- **Routes** (`routes/X.lua`) export `return function(app) ... end`, parse JSON bodies manually (`ngx.req.read_body()` + `cjson`), wrap handlers in auth + namespace middleware, and return `{ status = ..., json = ... }`. The house response shape is `{ success = true, data = ..., meta = ... }`.

See `routes/crm-accounts.lua` for the canonical CRUD example (note the explicit `namespace_id` ownership check on every read/update/delete).

### Middleware & auth
- `middleware/auth.lua`: `AuthMiddleware.requireAuth(handler)` verifies the `Bearer` JWT (`resty.jwt`, `JWT_SECRET_KEY`), sets `self.current_user`. Also `requireRole`. An `X-Public-Browse: true` header allows anonymous read access where wired in.
- `middleware/namespace.lua`: `requireNamespace`, `requirePermission(module, action, handler)`, `requireOwner`, `requireAdmin`. Resolves the tenant from `X-Namespace-Id`/`X-Namespace-Slug` header → JWT → subdomain, validates membership, and populates `self.namespace`, `self.namespace_permissions`, `self.is_namespace_owner`, `self.is_platform_admin`. Permissions are `module.action` (action `manage` = full access); platform admins and namespace owners bypass checks.
- Routes typically compose them: `AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(fn))`.
- The global `before_filter` in `app.lua` keeps an explicit allow-list of public URIs and URI patterns (e.g. `^/api/v2/[^/]+/public/`). Adding a new public endpoint means updating that list.

### Migrations
`migrations.lua` is a single large conditional migration registry: it uses `load_if_enabled(feature, "migrations.x")` so each project only creates its tables. Per-feature migration modules live in `migrations/*.lua`. There is also `schema-updates.lua`, `production-schema-upgrade.lua`, and `ecommerce-migrations.lua` for targeted upgrades. Migrations are tracked via `helper/migration-tracker.lua` (supports dry-run + skip logging).

### Helpers & libs (where cross-cutting logic lives)
- `helper/` — `auth.lua`, `jwt-helper.lua`, `otp.lua` (2FA), `namespace-resolver.lua` / `namespace_assignment.lua` (lazy tenant assignment on first request), `entitlement-service.lua` (billing entitlements), `openapi_generator.lua` (builds the Swagger spec served at `/openapi.json`), `invoice-generator.lua`, `pdf-generator.lua`, `hmrc.lua`, `mail.lua`, `minio.lua`, push helpers (`fcm-push`, `apns-push`), and the `project-loader.lua` that mounts external project modules from `/app/projects`.
- `lib/` — heavier services: `stripe.lua`/`stripe_payments.lua`/`payment-provider.lua` (billing), `accounting-engine.lua`, `tax-classifier.lua`/`tax-extraction.lua`, `llm-client.lua`/`ai-service.lua`/`langfuse.lua` (LLM/Ollama), `kafka-producer.lua`/`kafka-consumer.lua` (audit/outbox events), `prometheus_metrics.lua`, `theme-*.lua` (WordPress-style multi-tenant theming), `errors.lua`/`error_catalog.lua` (catalog-backed error envelopes; the handler installed in `app.lua` writes audit rows to the shared `error_occurrences` table).

### Pluggable projects
`projects/<name>/` (e.g. `hospital-patient-manager`) is a self-contained module with its own `project.lua` manifest, `api/`, `migrations/`, `services/`, `dashboards/`, and `themes/`. `helper/project-loader.lua` auto-discovers them at boot (from `OPSAPI_PROJECTS_DIR`, default `/app/projects`) and registers their routes + features dynamically via `ProjectConfig.registerFeature`.

### Code generators
`./generate-api.sh` (interactive) and `./quick-api.sh <ModelName>` scaffold a Model+Queries+Routes triple and auto-register the route in `app.lua`. See `API-GENERATOR.md`.

## Frontend architecture (opsapi-dashboard/)

Next.js 16 App Router + React 19 + TypeScript + Tailwind v4 + Zustand. Runs on port 8039, built with `output: "standalone"` for Docker.
- `app/` — routes: `login/`, `verify-otp/` (2FA), `dashboard/` (the authed app), `docs/`.
- `services/*.service.ts` — one typed API client per backend module (crm, invoices, tax, kanban, hospitals, themes, namespace, …), all going through `lib/api-client.ts` (axios; injects JWT + namespace headers).
- `store/*.store.ts` — Zustand stores (`auth`, `namespace`, `menu`, `kanban`, `notification`).
- `contexts/` — `NamespaceContext` and `PermissionsContext` mirror the backend tenant/RBAC model on the client; the dashboard menu is backend-driven (`useMenu` + `menu.service`).
- `hooks/` — `useWebSocket` (chat/notifications), `useDataFetch`, `useGridNavigation`.

## Conventions & gotchas

- **Always scope tenant data by `namespace_id`** in queries, and re-check ownership in route handlers before update/delete — middleware sets the namespace but does not auto-filter your SQL.
- **Adding a feature module** = create migration in `migrations/` + register it gated in `migrations.lua`; create model/queries/routes; gate the route in `app.lua` with the same feature; add RBAC modules under `PROJECT_MODULES` in `helper/project-config.lua`; add the matching `*.service.ts` on the frontend.
- Routes parse request bodies manually with `cjson` (no automatic body binding). JSON `metadata`/jsonb fields are `cjson.encode`d before storage.
- Billing/Stripe uses a single-merchant model and is deduped against webhook races (`StripeWebhookEventModel`, `BillingPaymentModel`) — be careful editing the `checkout.session.completed` / `invoice.paid` paths.
- `E2E_OTP_PEEK_ENABLED=true` exposes a test-only OTP peek endpoint (acc only, secret-gated). **Never set it on prod.**
- `lapis/core` (untracked, ~367 MB) is a runtime core dump, not source — do not commit it.
- The `.env` lives at `lapis/.env` (copy from `lapis/.sample.env`); `PROJECT_CODE`, `POSTGRES_*`, `JWT_SECRET_KEY`, Stripe/HMRC/SMTP/MinIO creds are read from there.

## Reference docs in repo

`README.md` (setup), `NAMESPACE_IMPLEMENTATION_PLAN.md` (tenancy design), `ECOMMERCE-API.md`, `API-GENERATOR.md`, `THEMING_GUIDE.md`, `DDOS_MITIGATION_GUIDE.md`, and the `*METRICS*`/`*PROMETHEUS*`/`*GRAFANA*` monitoring guides.
