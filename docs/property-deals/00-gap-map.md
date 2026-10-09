# Property Deals — Phase 1 gap map

Status: **approved 2026-10-09** (all recommendations). Built so far: D1–D5, D7 (screens are native pages), D9 (`emits`), D10 (AES-256-GCM `helper/secret-box.lua`) + D11 (core `namespace_ai_providers`) + D12 (plugin approvals, now executed) in Phase 5, D13 (APNs, Phase 3), D6 (`@opsapi/client/property-deals`, Phase 4), D8 (baked into the image via a named build context, Phase 4), D15 (`PROJECT_CODE=property`). · Branch `bsw/property_deals_backoffice` · 2026-10-09

This maps every concept in [SPEC.md](SPEC.md) §3.1 to what already exists in OpsAPI, and says
**reuse / extend / new** for each. Every new table has a reason. Nothing here is built yet.

Paths are relative to the repo root. `lapis/` is the backend, `opsapi-dashboard/` the web UI,
`~/projects/wslcrm-app` the iOS app, `~/projects/jobshout` JobShout.

---

## 0. Decisions I need from you (summary)

| # | Question | My recommendation |
|---|---|---|
| D1 | Plugin code `property_deals` → API prefix is `/api/v2/property-deals/...` (the loader turns `_` into `-`, `lapis/helper/project-loader.lua:256`). The prompt says `/api/v2/property_deals/...`. | Accept `/api/v2/property-deals`. Overriding `api_prefix` breaks the anonymous `/public/` routes (PLUGINS.md:291). |
| D2 | **Leads:** add columns to core `crm_leads`, or a 1:1 side table owned by the plugin? | **1:1 side table** `property_deals_lead_details` (FK `crm_leads.id`). Keeps the core table untouched; the plugin can be switched off cleanly. See §2.1. |
| D3 | **Deals:** spec's Deal overlaps `crm_deals` (hard rule 1: "stop and tell me"). | **Extend `crm_deals`** with a 1:1 `property_deals_deals`. The lead "convert" flow already creates a `crm_deals` row. See §2.4. |
| D4 | **Tasks:** extend `kanban_tasks` (needs the `kanban` feature on) or a plugin task table? | **Extend `kanban_tasks`** with a 1:1 `property_deals_task_details` + a dependency table. One deal = one kanban **epic**. See §2.6. |
| D5 | **Geo:** PostGIS is not in our Postgres images. | **`earthdistance` + `cube`** (contrib, available in `pgvector/pgvector` — checked) for radius; Postgres built-in `polygon @> point` for polygons. See §4. |
| D6 | **`@opsapi/client` excludes all plugin APIs** (`sdk/typescript/scripts/generate.mjs:28-54`, `--core`). Web + iOS prompts say "use `@opsapi/client`". | Add an opt-in `--plugin property_deals` mode to the generator and ship `@opsapi/client/property-deals` as a sub-export. Alternative: a separate generated file in the dashboard. |
| D7 | **Plugin pages are sandboxed static HTML iframes** (`components/plugins/PluginPageFrame.tsx`), so they can't reuse React layout/tables/kanban/charts. | Web pages are **native Next.js pages** under `opsapi-dashboard/app/dashboard/property-deals/...`; plugin auto-CRUD pages only for simple lists (suppliers, holidays). |
| D8 | **Deploy:** the OpsAPI image doesn't contain `projects/` (`lapis/Dockerfile:100-104`). The plugin only loads locally via the `../projects` mount. | Phase 4 adds a `COPY projects/property-deals` into the image (or a derived image like `diy-tax-return-uk`). Your call which. |
| D9 | **Custom events** (`stage_changed`, `health_changed`, `task.overdue`, …) emitted with `sdk.emit` are **not offered in the webhook catalogue** (`queries/NamespaceWebhookQueries.lua:78-95`). | Small core change: let a manifest declare `emits = {...}` so those names appear in the catalogue. Otherwise users must subscribe to `property_deals.deal.*`. |
| D10 | **Secrets:** `Global.encryptSecret` uses AES-CBC with a **fixed IV** (`lapis/helper/global.lua:74-115`). Fine for one webhook secret; weak for many LLM keys. | Store provider keys with AES-256-GCM + random IV per value (same scheme as the vault, `migrations/secret-vault.lua`), keyed from `OPENSSL_SECRET_KEY`. |
| D11 | **AI provider settings:** today they're env-only and global (`lapis/lib/agent/llm.lua`). Per-workspace providers could live in the plugin or in core. | **Core** table `namespace_ai_providers` — the chat agent and bookkeeping AI would benefit too. If you'd rather keep scope tight: plugin table. |
| D12 | **Approvals:** no generic approvals table (only timesheet/fs-job/time-entry specific). | Plugin table `property_deals_approvals` now; promote to core later if other modules want it. |
| D13 | **iOS push:** OpsAPI only sends FCM (`helper/push-notification.lua:21-66`); `apns-push.lua` exists but isn't wired; the iOS app has no push code. | Backend routes `device_type=ios` tokens to `apns-push.lua` (needs APNs key env vars). iOS agent adds registration. |
| D14 | **Tests:** web prompt asks for Playwright; the dashboard uses Cypress (`opsapi-dashboard/cypress/e2e/`). | Use **Cypress** — one e2e stack. |
| D15 | **`PROJECT_CODE=property`** doesn't exist. The plugin needs `crm` (contacts/accounts/deals/activities), `kanban` and `notifications`. | Add a `property` preset in `lapis/helper/project-config.lua` = core + crm + kanban + notifications + documents; manifest `depends = {"crm","kanban"}`. |

---

## 1. What already exists (inventory)

| Area | Table(s) | Where | Endpoints | Feature gate |
|---|---|---|---|---|
| **Leads** | `crm_leads` (+ `crm_lead_notification_settings`) | `lapis/migrations/crm-leads.lua:37-169` | `/api/v2/crm/leads[/:uuid]`, `/stats`, `/:uuid/convert`, public `POST /api/v2/public/leads/:ns_slug` | core (always on) |
| Contacts | `crm_contacts` | `migrations/crm-system.lua:106` | `/api/v2/crm/contacts[/:uuid]` | crm |
| Companies | `crm_accounts` | `migrations/crm-system.lua:59` | `/api/v2/crm/accounts[/:uuid]` | crm |
| Deals / pipelines | `crm_deals`, `crm_pipelines` (stages JSONB) | `migrations/crm-system.lua:31,152` | `/api/v2/crm/deals`, `/api/v2/crm/pipelines` | crm |
| Notes / activities | `crm_activities` (no `lead_id`), `kanban_task_comments` | `crm-system.lua:208`, `kanban-project-system.lua:828` | `/api/v2/crm/activities`, `/api/v2/kanban/tasks/:uuid/comments` | crm / kanban |
| Users / RBAC | `users`, `namespaces`, `namespace_members`, `namespace_roles` (JSON perms), `modules` | `migrations.lua:518+`, `migrations/namespace-system.lua` | `/api/v2/namespace/roles`, `/members` | core |
| Tasks | `kanban_projects/boards/columns/tasks`, assignees, labels, checklists, activities, sprints, **epics** | `migrations/kanban-project-system.lua` | `/api/v2/kanban/...`, `/api/v2/kanban/my-tasks` | kanban |
| Files | MinIO helper; **no generic attachment table** (each module has its own) | `helper/minio.lua`, `routes/documents.lua:727` | `/api/v2/documents/upload`, `/presigned/*` | core |
| Notifications | `notifications` (in-app), `kanban_notifications`, `device_tokens` (FCM), `namespace_mail_settings` | `migrations/notifications.lua`, `kanban-enhancements.lua:185`, `push-notifications.lua` | `/api/v2/notifications`, `/api/v2/device-tokens` | notifications |
| Audit | `audit_events` (DB trigger per catalogued entity), `namespace_audit_logs`, `user_activity` | `migrations/kafka-audit-system.lua:28`, `helper/plugin-events.lua` | `/api/v2/namespace/audit-logs`, `/activity` | core |
| Events / webhooks | `plugin_event_sources/subscriptions/events/deliveries`, `namespace_webhooks` | `helper/plugin-events.lua:297-342`, `migrations/outbound-webhooks.lua` | `/api/v2/namespace/webhooks...` | core |
| Jobs | `plugin_jobs` (lease + `SKIP LOCKED`, every ≥1m, `at` is UTC, no cron) | `helper/plugin-jobs.lua` | `POST /api/v2/plugins/:code/jobs/:job/run` | core |
| Settings / secrets | `namespace_plugins.settings` (flat scalars, `secret=true` encrypted; no `json` type), vault | `helper/plugin-workspaces.lua:46-113` | `GET/PUT /api/v2/namespace/plugins/:code` | core |
| AI | `lib/agent/llm.lua` (ollama/anthropic/openai-compatible, env config, fallback + circuit breaker), `ai_usage` (**no cost column**), Langfuse | `migrations.lua:2420` | `/api/v2/namespace/ai-usage` | core |
| Geo | lat/lng on `fs_sites`, delivery; PostGIS only optional in delivery (`pcall`) | `migrations/geolocation-delivery-system.lua:21` | — | — |
| Working days / TZ | **none**; no `namespaces.timezone` | — | — | — |
| Approvals / suppliers / bookings | module-specific only (`timesheet_approvals`, `fs_visits`, `patient_appointments`); no suppliers | — | — | — |

### 1.1 `crm_leads` — exact columns

`id BIGSERIAL`, `uuid TEXT UNIQUE`, `namespace_id BIGINT NOT NULL → namespaces CASCADE`, `first_name TEXT NOT NULL`,
`last_name`, `email`, `phone`, `company_name`, `job_title`, `source TEXT DEFAULT 'manual'`, `channel`, `campaign`,
`referrer_url`, `landing_page_url`, `status TEXT DEFAULT 'new'` (no CHECK; used: new/contacted/qualified/converted/lost),
`lost_reason`, `owner_user_uuid`, `score INT DEFAULT 0`, `priority TEXT DEFAULT 'medium'`, `notes TEXT`,
`converted_at`, `converted_contact_id → crm_contacts`, `converted_deal_id → crm_deals`, `metadata JSONB DEFAULT '{}'`,
`created_at`, `updated_at`, `deleted_at`, `enquiry_id → enquiries`.
Indexes: `(namespace_id,status)`, `uuid`, `owner_user_uuid`, `email`, `(namespace_id,source)`, BRIN `created_at`.
Events already published: `crm.lead.created/updated/deleted/qualified/converted/lost`.

**Who uses it**
- **Web:** `opsapi-dashboard/app/dashboard/leads/page.tsx` ("Leads Inbox") + `components/crm/leads-shared.tsx`; service `services/crm.service.ts:389-439`. List shows name, email, source, status, priority, score, created; create form has name/email/phone/company/job/source/priority/channel/campaign/notes; detail modal edits only status/priority/notes; convert modal creates contact + deal.
- **iOS / Android:** **not used.** Only the menu key `crm_leads` appears (`WSLCRM/Core/Permissions/PermissionSet.swift:111`).

**Existing gaps to know about (not ours to fix, but they affect us):**
- `/api/v2/crm/leads*` and the other CRM routes only check workspace membership — **no RBAC permission check**, and there is no `crm_leads` module. Our plugin endpoints will check permissions; the core leads endpoints won't.
- `POST /crm/leads/:uuid/convert` isn't gated on the CRM feature (comment at `lapis/app.lua:667-674` says it is).

---

## 2. Concept by concept (SPEC §3.1)

All new tables: prefix `property_deals_`, `id BIGSERIAL`, `uuid TEXT UNIQUE`, `namespace_id BIGINT NOT NULL → namespaces ON DELETE CASCADE`, `created_at/updated_at TIMESTAMPTZ`, created with `IF NOT EXISTS` (PLUGINS.md:585-602).

### 2.1 Lead — **extend** (1:1 side table)
`property_deals_lead_details (lead_id PK → crm_leads.id CASCADE, namespace_id, lead_kind, situation, situation_note, deadline_date, vulnerability_flag, vulnerability_note, consent_basis, consent_given_at, consent_channels JSONB, privacy_notice_sent_at, retention_until, property_id)`.
- `source` already exists on `crm_leads` — reuse it (add our values to the option list, no column).
- Why not `ALTER TABLE crm_leads`: it's a core table every deployment has; plugin-owned columns there would linger when the plugin is off and the core leads API wouldn't validate them. Why not `metadata` JSONB: we filter and sort on kind/situation/deadline, and Today needs indexes.
- The plugin exposes `GET /api/v2/property-deals/leads` (core lead + details joined, with the new filters) and `PUT .../leads/:uuid/details`. The web Leads page calls these when the plugin is on.

### 2.2 Property — **new** `property_deals_properties`
Nothing like it exists (`fs_sites` is a field-service site with lat/lng, no tenure/EPC/valuation). Columns per SPEC §3.1 plus `lat/lng DOUBLE PRECISION`, a GiST index on `ll_to_earth(lat,lng)`, `known_issues TEXT[]` + note, `tenancy JSONB`, valuation fields as `NUMERIC(14,2)`. Photos via §2.12.
Link tables: `property_deals_deals.property_id` (one property → many deals); `lead_details.property_id`.

### 2.3 Buyer profile — **new 1:1 on existing contact/company** `property_deals_buyer_profiles`
`contact_id → crm_contacts` **or** `account_id → crm_accounts` (CHECK exactly one). Holds entity type, capital band, proof of funds status/expiry, funding route, strategies `TEXT[]`, areas (centre+radius and/or polygon, §4), price range, min discount/yield, deal-breakers, preferred channel, time zone, holdings. The person/company itself stays in CRM — no copy.

### 2.4 Deal — **extend `crm_deals`** (1:1) `property_deals_deals`
**Overlap flagged (hard rule 1).** `crm_deals` already has name, value, currency, stage, owner, pipeline, contact, account, expected/actual close, won/lost. Proposal:
- Every property deal **is** a `crm_deals` row (it shows in CRM too). `property_deals_deals (crm_deal_id UNIQUE → crm_deals CASCADE, property_id, seller_lead_id, deal_type, template_version_id, offer_amount, agreed_price, fees JSONB, target_exchange_date, target_completion_date, actual_exchange_at, actual_completion_at, late_penalty_per_day, late_penalty_cap_days, finance_route, health, health_reason, predicted_completion_date, money_at_risk, kanban_epic_id)`.
- Buyers: `property_deals_deal_parties (deal_id, role [buyer|seller|buyer_solicitor|seller_solicitor|lender|broker|freeholder|…], contact_id | account_id)` — one table for all parties, so solicitors etc. aren't columns.
- Stage: the template version generates a `crm_pipelines` row (stages JSONB); `crm_deals.stage` holds the current stage key and our engine is the only writer. "Create deal" on a lead uses the existing convert flow, then adds the extension row.

### 2.5 Workflow template — **new** `property_deals_workflow_templates` + `property_deals_workflow_template_versions`
Nothing similar. Template = name, jurisdiction, active version. Version = immutable JSON (stages, task templates, SLAs, gates, compliance items, agent rules) + `version INT`, `published_at`. A deal pins `template_version_id`. Not stored in plugin settings (no `json` type, and versions must be immutable rows). Format documented in Phase 2 (`template-format.md`).

### 2.6 Task — **extend `kanban_tasks`** (1:1) `property_deals_task_details` + `property_deals_task_dependencies`
- Per workspace, the plugin auto-creates one kanban project "Property deals" with one board; **each deal = one kanban epic** (epics already roll up progress — `kanban_epics`, just merged). Tasks are normal kanban tasks, so they appear in `/kanban/my-tasks`, the board UI, comments, checklists, attachments and the iOS Tasks tab for free.
- `kanban_tasks` gaps we fill in the side table: `due_date` is a **DATE** (we need `due_at TIMESTAMPTZ` for a 60-min SLA), no SLA, no urgency, no dependencies, and `status` CHECK is fixed (open/in_progress/blocked/review/completed/cancelled).
- `property_deals_task_details (task_id PK → kanban_tasks, namespace_id, deal_id, property_id, lead_id, template_key, due_at, sla_minutes, sla_started_at, urgency_score, urgency_why JSONB, blocking BOOL, compliance BOOL, escalation_level, pd_status, owner_agent_key, agent_eligible, approval_rule, snoozed_until, snooze_reason)`.
- Status mapping (kanban status stays valid for kanban screens): `todo→open`, `in_progress→in_progress`, `waiting_third_party→blocked`, `agent_running→in_progress`, `awaiting_approval→review`, `done→completed`, `cancelled→cancelled`. `pd_status` keeps the precise value.
- Agent work: the iOS app already stores an "agent contract" (claim/lease/review) in `kanban_tasks.metadata.agent` (`wslcrm-app/WSLCRM/Features/Projects/AgentContract.swift:94`) — **client-side only, no server enforcement**. We'll write the same shape so the iOS review queue shows our agent tasks, but our server is the source of truth (agent runs + approvals tables).
- `kanban_tasks` has **no `namespace_id`** (resolved via board → project); our side table carries it so Today/SLA queries don't join four tables.
- Dependencies: kanban has none → `property_deals_task_dependencies (task_id, depends_on_task_id)`. Could move to core kanban later.

### 2.7 Chase log — **new** `property_deals_chases`
Closest is `crm_activities` (type/subject/description/contact/deal), but we need `channel`, `sent_at`, `reply_at`, `enquiry_id`, and fast "days since last third-party reply" per deal. We also write a `crm_activities` row (type `email`/`call`) on each chase so the CRM timeline stays complete.

### 2.8 Enquiry / blocker — **new** `property_deals_enquiries`
Nothing similar. Note: the core `enquiries` table is a website contact form — different thing, so the full prefixed name avoids confusion. Columns: deal_id, title, detail, owner_party_role, raised_at, due_at, resolved_at, resolution, source (email/manual/agent).

### 2.9 Supplier — **extend `crm_accounts`** (1:1) `property_deals_suppliers`
A supplier is a company → it's a `crm_accounts` row (name, phone, email, address already there). Side table: `account_id UNIQUE`, `kinds TEXT[]` (solicitor, surveyor, epc_assessor, broker, …), coverage (centre+radius / polygon), accreditations JSONB, price_list JSONB, booking_method, booking_config JSONB, measured `avg_turnaround_hours`, `on_time_pct`, rating, active. Councils go in the same table (kind `council`) so "council speed" uses the same stats.

### 2.10 Booking — **new** `property_deals_bookings`
`fs_visits` (field-service engineer visits) and `patient_appointments` (hospital) are module-specific and feature-gated. Ours: supplier_id, task_id, deal_id, slot_start/end, status (requested/tentative/confirmed/done/cancelled), cost, external_ref.

### 2.11 Compliance check — **new** `property_deals_compliance_checks`
Nothing similar. type, subject (contact/account/deal), status, evidence document, checked_by_uuid, checked_at, expires_at, risk_rating, jurisdiction_pack, data JSONB.

### 2.12 Documents — **new link table** `property_deals_documents`
There is no generic "file attached to any record" table. MinIO upload exists (`helper/minio.lua`, `routes/documents.lua`). Ours: entity_type/entity_id (deal, property, compliance check, task), object_key, filename, mime, size, category (title, lease, survey, EPC, search, ID…), uploaded_by. Upload goes through our endpoint (namespace-prefixed key) using the MinIO helper. Task-level files can also use `kanban_task_attachments`.

### 2.13 Agent run — **new** `property_deals_agent_runs` (+ `property_deals_agent_run_steps`)
`chat_agent_runs` is the chat assistant's turn log — different lifecycle. Ours: task_id, agent_key, provider (`anthropic|openai|…|local|jobshout`), model, jobshout_task_id/run_id/execution_id, prompt_version, input_snapshot JSONB (minimised), output_draft, sources JSONB, tokens in/out, `cost_usd`, latency, status. We **also** write `ai_usage` rows so workspace AI usage reporting stays in one place (and propose adding a `cost_usd` column there).

### 2.14 Approval — **new** `property_deals_approvals` (see D12)
subject (agent_run / outbound message / compliance close / stage gate), rule (any_operator / manager / two_person), payload_version + hash, decisions (who, when, decision, note, edited diff), jobshout_approval_id. One approval covers JobShout (§6).

### 2.15 Match — **new** `property_deals_matches`
property_id, buyer_profile_id, score, breakdown JSONB, status (suggested/sent/interested/declined), sent_at. UNIQUE(property_id, buyer_profile_id).

### 2.16 Supporting tables (new)
| Table | Why |
|---|---|
| `property_deals_holidays (jurisdiction, date, name)` | No working-day helper exists. Seeded from GOV.UK `bank-holidays.json` (England & Wales, Scotland, NI); swappable per country. |
| `property_deals_saved_searches` | Deal scout pins (centre, radius, filters, alert rules). |
| `property_deals_connectors` | Per-workspace data connector config (EPC, Price Paid, Companies House, paid stubs, CSV). Keys encrypted (D10). |
| `property_deals_market_records` | Cached connector results (sold prices, EPCs, listings, auction lots) with geo — map layers and comps. |
| `property_deals_ai_providers` / `property_deals_agent_configs` | Per-workspace providers, model per job type, fallback order, cost caps, local-only flag, JobShout mapping (or core `namespace_ai_providers` — D11). |
| `property_deals_digest_log` | One digest per user per local day (idempotent job). |

Added while building (Phases 5–6), each for a reason no existing table covers:

| Table | Why |
|---|---|
| `property_deals_ai_routes` | Model chain per job type (the providers themselves went to core `namespace_ai_providers`, D11). |
| `property_deals_notification_prefs` | Per-user push/email switches + quiet hours for this module (core `notification_preferences` only has shop-order email flags; kanban's are kanban-only). iOS request. |
| `property_deals_mail_connectors` / `property_deals_inbound_messages` | Mailboxes the legal chaser reads, and what they fetched (stored as data). Core mail is send-only. |
| `property_deals_scout_alerts` | One alert per home + kind + price for a saved search, so the deal scout's re-runs stay quiet. |
| core `idempotency_keys` | `Idempotency-Key` replay for offline clients (iOS request); any module can use it. |

Plain scalar settings (timezone, digest time, SLA thresholds 75/100/125, urgency weights, match weights, map tile key) go in **manifest `settings`** (`namespace_plugins.settings`). Timezone is a plugin setting (default `Europe/London`) because `namespaces` has no timezone column.

---

## 3. How the plugin plugs in (facts from the code)

| Need | Mechanism | Ref |
|---|---|---|
| Routes | `projects/property-deals/api/*.lua` → `function(app)`, auto-prefixed; `sdk.crud` gives list/show/create/update/delete with `<module>.<action>` RBAC and exact Swagger schemas | `lapis/helper/plugin-sdk.lua:540`, PLUGINS.md:244 |
| RBAC | manifest `modules` → `modules` table on migrate; admins/owners get `manage` on first install only | `helper/project-migrator.lua:154-169` |
| Roles (Operator, Manager, Compliance, Agent, Read-only) | seed `namespace_roles` per workspace in a plugin migration with our module grants; Agent = service user | `migrations/namespace-system.lua:176` |
| Migrations | `projects/property-deals/migrations/<ts>_*.lua`, tracked in `project_migrations`, advisory-locked, transactional; idempotency is on us (`IF NOT EXISTS`) | `helper/project-migrator.lua:46-237` |
| Events | manifest `publishes` → `<code>.<entity>.created/updated/deleted` + status verbs via DB trigger; extra via `sdk.emit` (see D9) | `helper/plugin-events.lua:567-716` |
| Audit | `publishes` tables get the `opsapi_audit` trigger → `audit_events` (deal timeline) | `helper/plugin-events.lua:~375` |
| Jobs | `jobs/*.lua` `{every, at, scope, run}`; `sla_tick` every 1m; `daily_digest` every 15m and checks each user's local time (since `at` is UTC-only) | `helper/plugin-jobs.lua:52-270` |
| Settings | manifest `settings` (scalars; `secret=true` encrypted, never returned) | `helper/plugin-workspaces.lua:46-74` |
| On/off per workspace | `PUT /api/v2/namespace/plugins/:code`; disabled → 404 `PLUGIN_DISABLED`, menu hidden | `middleware/namespace.lua:78-91` |
| Swagger | automatic; hand-written routes get a generic op → we'll add per-route schemas | `helper/openapi_generator.lua:1700-1930` |
| Menu | manifest `menu` → `menu_items` `plugin:property_deals:*`; for native pages we point `path` at `/dashboard/property-deals/...` | `project-migrator.lua:174-193` |
| Tests | home-made `check()` harness, `docker exec -w /app opsapi luajit spec/...` — **CI doesn't run specs** | `lapis/spec/plugin-platform_spec.lua` |
| Release | merge to `main` → `autotag` job cuts `1.0.N`; SDK released by pushing `sdk-vX.Y.Z` | `.github/workflows/deploy-k3s.yml:86-205`, `sdk-typescript-release.yml` |

---

## 4. Geo: PostGIS or not

- Local + CI images are `pgvector/pgvector:pg14/pg15` — **no PostGIS**. `earthdistance` and `cube` **are** available (checked on the running `pgvector:pg14` container).
- int/acc point at external DB IPs (`devops/helm-charts/.../values-int.yaml:57`) — **I can't see their image; needs checking before Phase 6.**

| | (a) Add PostGIS | (b) earthdistance + built-in polygon |
|---|---|---|
| Image change | yes — switch to a PostGIS+pgvector image on local, CI, int, acc, prod | none |
| Radius query | `ST_DWithin` on geography | `earth_box(ll_to_earth(lat,lng), r) @> ll_to_earth(...)` + exact `earth_distance` check, GiST index |
| Polygon | `ST_Contains` | Postgres native `polygon @> point` (planar; fine at county scale) with bbox prefilter |
| 100k rows < 500 ms | yes | yes (GiST bbox prefilter) |
| Risk | DB migration on prod; extension upgrades | slight accuracy loss on huge polygons |

**Recommend (b).** Wrap it in `lib/geo` inside the plugin so we can swap in PostGIS later without changing the API.

---

## 5. Dashboard and iOS (for the other agents)

**Web (`opsapi-dashboard/`, Next 16 / React 19)**
- The sidebar comes from the backend (`GET /api/v2/user/menu` → `components/layout/Sidebar.tsx`; icons from a fixed list in `hooks/useMenu.ts:29-142` — includes `Building2`, `Home`, `MapPin`).
- Plugin pages: `app/dashboard/plugins/[plugin]/[resource]/page.tsx` renders auto-CRUD or a sandboxed iframe (D7).
- Reusable: `@dnd-kit` kanban components (`components/kanban/*`, tied to kanban tasks), `recharts`, leads pages above. **No map library** — Leaflet + react-leaflet is the only new dependency.
- e2e: Cypress (D14).

**iOS (`~/projects/wslcrm-app`, SwiftUI, iOS 17)**
- Auth: JWT in Keychain, `X-Namespace-Id` header, refresh-on-401 (`WSLCRM/Core/Networking/APIClient.swift`).
- Screens: one folder per feature (`Features/<Name>/{XAPI,XModels,XViews}.swift`), tabs in `Features/Home/MainTabView.swift`, routes in `withAppDestinations()`.
- Offline: `Core/Offline/{ResponseCache,MutationQueue,SyncCenter}.swift` already exist — reuse for Today/deal cache and queued actions.
- Biometrics: `Core/Auth/BiometricGate.swift` (use for approval confirm).
- **No push code at all**, and OpsAPI only sends FCM (D13).
- Kanban agent review queue exists (`Features/Projects/AgentViews.swift:232`) — our agent tasks can show there.

---

## 6. JobShout integration (from `server/api/openapi.yaml`, `origin/master` `d607b0c`, 2026-10-08)

| Need | Endpoint | Notes |
|---|---|---|
| Auth | `POST /auth/login` `{email,password}` → `{access_token, refresh_token}`; `POST /auth/refresh` | **No API keys / service accounts.** JWT lasts 15 min; refresh **rotates** the refresh token. We store a JobShout *service user's* credentials (encrypted) and the latest refresh token. Org comes from the JWT. |
| Find agents | `GET /agents` (`listAgents`), `GET /agent-schemas` | Inputs come from the agent's schema — no special-casing (JobShout rule). |
| Project | `GET/POST /projects` | One JobShout project per workspace (stored in settings). |
| Start work | `POST /tasks/launch` (`launchTask`) `{agent_id, project_id, values:{prompt:…}}` | `values` is **strings only** → we send a minimised context as a JSON string in `prompt`. Spec says 200, server returns **202** — accept any 2xx. |
| Status / result | `GET /tasks/{taskID}`, `GET /task-runs/{runID}` (`getTaskRun`) | Output, tokens, `cost_usd`, `latency_ms` are on the **run**. Run status: queued/running/completed/failed. |
| Approvals | `GET /approvals?status=pending`, `POST /approvals/{id}/decide` `{decision: approve|reject, reason}` | Linked by `execution_id` (no task id). `decided_by` will be our service user — we record the real human in our approval row. |
| Live events | WebSocket `GET /api/v1/ws` (Bearer) — `execution.status_changed`, `approval.requested`, `approval.decided` | Hints only ("keep polling"). **No outbound webhooks exist.** |

**Plan:** a `jobshout_poll` job (every 1 min) polls open runs and pending approvals; the WebSocket is optional (needs a long-lived connection — maybe later). When JobShout raises an approval, we create **our** approval; when our human approves, we call `decide` on JobShout — one human click covers both. JobShout down → fall back to the built-in provider if allowed, otherwise put the task back to `todo` with a note.

---

## 7. Scope notes and things I'd leave out (for now)

- Material-information listing fields (SPEC §3.4) only matter if the workspace markets homes → in the optional "lettings/marketing" pack, Phase 7.
- WhatsApp/SMS/Slack outbound: via workspace webhooks only (no native sending) in v1.
- Paid data connectors: config-only stubs (SPEC says so).
- Investor portal role: role seeded read-only; portal UI later.

**Next (Phase 2, after your OK):** plugin skeleton, `PROJECT_CODE=property` preset, migrations for §2, CRUD under `/api/v2/property-deals/...`, roles, seeded templates (UK guaranteed-sale + sell via estate agent), tenant-isolation spec, run migrations twice.
