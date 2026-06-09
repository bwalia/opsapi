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

### HMRC MTD Income Tax filing (UK Self Assessment)
End-to-end "File your tax" flow against HMRC's Making Tax Digital APIs. Feature-gated under `tax_copilot`. **Read this before touching tax filing — it captures non-obvious HMRC behaviour that is expensive to rediscover.**

**Layers**
- `lib/hmrc-mtd-client.lua` — the MTD API client (one function per HMRC endpoint). Env-switched by `HMRC_ENVIRONMENT` (`sandbox`→`test-api.service.hmrc.gov.uk`, `production`→`api.service.hmrc.gov.uk`); `Client.is_sandbox()` gates sandbox-only behaviour. Endpoints + Accept versions: `list_businesses` (Business Details v2), `list_obligations` (Obligations v3), `submit_cumulative` (Self-Employment cumulative v5, `STATEFUL`), `trigger_calculation`/`get_calculation`/`poll_calculation` (Individual Calculations v8), `submit_final_declaration` (Calculations v8 — the BINDING crystallisation), `create_test_business`/`set_itsa_status` (Self Assessment Test Support v1, sandbox only).
- `helper/hmrc.lua` — OAuth token storage/refresh (`get_valid_token`), and `build_fraud_headers()` (HMRC mandatory anti-fraud `Gov-Client-*`/`Gov-Vendor-*` headers).
- `lib/hmrc-aggregator.lua` — rolls classified transactions into the MTD cumulative body (`build_cumulative_body`); flags negative fields (a credit mis-filed as an expense) which HMRC rejects.
- Routes: `routes/tax-hmrc-auth.lua` (OAuth initiate/callback/disconnect), `routes/tax-hmrc-data.lua` (status, businesses/obligations fetch+cache, NINO get/save/delete), `routes/tax-hmrc-filing.lua` (`aggregate-preview`, `calculate-preview`, **`submit-final-declaration`**, `business/default|select`, `sandbox/provision`).
- Frontend: `app/dashboard/tax/file/page.tsx` (the 6-step wizard), `services/tax.service.ts`, `lib/hmrc-fraud.ts` (browser anti-fraud signal collection).

**Wizard flow (6 steps, auto-advancing):** connect (OAuth) → business (auto-fetched) → obligations (auto-fetched) → check figures (auto-aggregated; inline-fix negative credits) → preview calculation (submits cumulative + in-year calc, non-binding) → **finalise & declare** (binding final declaration, gated on a declaration checkbox). Steps 2–4 run themselves via `useEffect` guards (refs `autoBizFor`/`autoOblFor`/`autoPreviewFor`) — no "Load"/"Fetch" buttons; only genuinely-human steps need a click.

**Sandbox gotchas (each cost real debugging):**
- **Obligations return 2018-era data unless you send `Gov-Test-Scenario: DYNAMIC`** — the default sandbox response is a fixed historical sample ignoring your `from`/`to`. DYNAMIC echoes periods matching the requested dates. It returns synthetic businessIds (`XBIS…` self-employment, `XPIS…` UK property, `XFIS…` foreign property) for ALL three business types → filter to self-employment and don't filter by the real `business_id` in sandbox, or you get triplicate/empty results. The header is auto-dropped outside sandbox.
- **`calculate-preview`/final-declaration are STATEFUL** — they only work against a business created via the Test Support API. The businesses from Business Details / obligations (e.g. `XBIS12345678901`) are NOT fileable → HMRC returns `MATCHING_RESOURCE_NOT_FOUND`. Both routes **self-heal** in sandbox: on that error they auto-call `provisionSandboxBusiness()` (create test business + set MTD ITSA status, store as `default_business_id`) and retry once.
- **Calculation figures nest under `calculation.taxCalculation.*`** (with sub-totals in `.incomeTax` and `allowancesAndDeductions`), NOT top-level — `parse_figures` reads the right paths. Sandbox always returns `-99999999999.99` for the grand total (a placeholder, flagged via `is_sandbox_placeholder`); other figures are real.
- The final declaration must reference an **`intent-to-finalise`** calc (not `in-year`), and real HMRC rejects finalising a tax year before it ends (`RULE_FINAL_DECLARATION_TAX_YEAR`); sandbox simulates success.

**Production readiness (env-only is NOT enough — needs the code already in place + these):**
- `ssl_verify` is env-aware (`not Client.is_sandbox()` / `tls_verify()`): verified TLS in production, off in sandbox. Production requires `lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt` in the nginx http block (already in `nginx.conf` + `nginx-values-template.conf`).
- **Anti-fraud headers** pass HMRC's "Test Fraud Prevention Headers" validator. Browser-only signals are collected in `lib/hmrc-fraud.ts`, forwarded as `X-Gov-Client-*` headers (allow-listed in `middleware/cors.lua`), and remapped server-side in `build_fraud_headers`. `Gov-Vendor-Public-IP`/`Gov-Vendor-Forwarded` need `HMRC_SERVER_PUBLIC_IP` (the backend's egress IP) set in prod — omitted if unset (HMRC rejects private IPs). The only remaining validator output is a non-blocking `Gov-Client-Multi-Factor` warning (fine for username+password+OTP).
- **Env vars** (in `.sample.env`): `HMRC_ENVIRONMENT`, `HMRC_CLIENT_ID`, `HMRC_CLIENT_SECRET`, `HMRC_REDIRECT_URI`, `HMRC_SERVER_PUBLIC_IP`. OAuth scopes must include `read:self-assessment` + `write:self-assessment`. The HMRC app must subscribe (Developer Hub) to: Business Details / Obligations / Self Employment Business / Individual Calculations (MTD) — plus Self Assessment Test Support, Create Test User, Test Fraud Prevention Headers for sandbox only.

**Testing without a browser OAuth flow:** mint a JWT for a user with a stored `hmrc_tokens` row by HMAC-signing `{userinfo:{uuid,sub}, iat, exp, iss:"opsapi"}` with `$JWT_SECRET_KEY` (the container lacks `perl`, so `resty` CLI won't run — build the JWT with `openssl dgst -sha256 -hmac`). Syntax-check Lua via `docker exec opsapi /usr/local/openresty/luajit/bin/luajit -b <file> /dev/null`.

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
