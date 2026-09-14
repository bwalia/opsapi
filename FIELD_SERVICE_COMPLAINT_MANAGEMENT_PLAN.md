# Field Service — Complaint & Job Management Extension (Design Plan)

Status: **DRAFT for build** · Feature flag: `field_service` · Builds on PR #604.

## 1. Purpose & scope

Turn the merged `field_service` module (job → phases → engineer visit → invoice) into
a full **complaint / service-request management system** for a field-service business —
e.g. a refrigeration & air-conditioning company servicing units installed at customer
sites such as hospitals.

Target flow:

```
Hospital's unit breaks
  → someone calls us / opens the customer app (later, calling this API)
  → we register a SERVICE REQUEST (complaint) against that unit + site
  → a MANAGER triages the queue and assigns it
  → it becomes one or more JOBS for an ENGINEER
  → the engineer makes one or MORE VISITS (each logs a timesheet + billable labour)
  → parts used are proposed, MANAGER-APPROVED, then billed
  → everything rolls up into an INVOICE and back to the complaint
```

This plan is **purely additive** — it does not rewrite any table shipped in PR #604.
It wraps a complaint/asset/parts layer around the existing job engine and adds a
staff directory.

### Design principles
- **Reuse before build.** Customers = CRM (`crm_accounts` + `crm_contacts`); billing =
  `invoices`; time = `timesheets`; alerts = the notifications module. Only genuinely new
  concepts get new tables.
- **Service request ≠ job** (separate tables). One complaint can spawn several jobs over
  time (diagnose, then return with parts), can be rejected/duplicate without ever becoming
  a job, and has a customer-facing SLA lifecycle distinct from a job's operational one.
- **Dynamic / expandable.** Category-style fields (asset category, fault category) are
  lookup-/text-driven, not DB enums, so a tenant can extend them without a migration.
  Every table carries `metadata JSONB` for custom fields.
- **Multi-tenant always.** Every table carries `namespace_id`; every query is
  namespace-scoped; handlers re-check ownership before write (house rule).

## 2. What already exists (reused, not rebuilt)

| Concept | Lives in | Notes |
|---|---|---|
| Customer (the hospital) + its callers | `crm_accounts` / `crm_contacts` | Already FK'd by `fs_sites`, `fs_jobs` |
| Site (address, access notes) | `fs_sites` | Gets asset link; gate/building granularity goes on the asset |
| Job | `fs_jobs` | Gets `service_request_id`, `asset_id` |
| Phases (+ templates) | `fs_job_phases`, `fs_phase_templates` | Unchanged |
| **Multiple engineer visits** | `fs_visits` | **Already 1 job → N visits.** No change needed |
| Timesheet per visit | `timesheets` / `timesheet_entries` (`user_uuid`) | Check-out already logs hours here |
| Labour + parts lines | `fs_job_items` | Gets `part_id` + approval fields |
| Invoicing | `invoices` + `invoice_line_item_id` stamping | Collector tightened to approved-only |
| Engineer login | `users` (JWT) | Enriched by new `employees` profile |

**Multiple visits per complaint is already supported** by the existing model: a job holds
unlimited `fs_visits`, each visit logs its own timesheet entry on check-out and bills its
own labour into the invoice (with the double-bill guard). The only new work is
**aggregating** visits/hours/invoices up to the service-request level (a rollup query, not
a new table), because the request is the new top-level parent.

## 3. Domain model (ERD)

```
crm_accounts (hospital) ─┬─ crm_contacts (callers)
                         ├─ fs_sites (premises: address, gate no.) ──┐
                         └─ fs_assets (the AC / fridge units) ───────┤ (asset lives at a site)
                                                                     │
fs_service_requests (COMPLAINT)  ← account, contact, site, asset ────┘
   │  (1 request → N jobs)
   └─ fs_jobs (JOB)  ← service_request_id, asset_id
        ├─ fs_job_phases  (← templates)
        ├─ fs_visits      (N visits; each → timesheet entry, billable labour)
        └─ fs_job_items   (labour + parts; part_id → fs_parts; manager-approved)
                └─ invoices (approved billable items + labour)

employees (staff directory) ── user_uuid → users (login)
   └─ an engineer = employees row where is_engineer AND is_active
      (assigned on fs_service_requests.assigned_manager_uuid, fs_visits.engineer_user_uuid)

fs_parts (catalog) ← referenced by fs_job_items.part_id
```

## 4. New & changed tables

Migration numbers continue after the existing `850–861`. **Lesson from PR #604's
reconcile blind spot: one migration = one table** (the old `853` created two tables and
`reconcile-migrations.lua` could only track one). Every new sequence table gets its own
migration and its own manifest entry.

### 4.1 `fs_assets` — equipment register (migration 862)
The units installed at the customer's site. A complaint is *about* an asset; enables
per-unit service history, warranty checks, and preventive-maintenance later.

```sql
CREATE TABLE fs_assets (
  id BIGSERIAL PRIMARY KEY,
  uuid TEXT UNIQUE NOT NULL,
  namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
  account_id BIGINT REFERENCES crm_accounts(id) ON DELETE SET NULL,   -- owner (hospital)
  site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL,          -- where it lives
  name TEXT NOT NULL,                    -- "Ward 3 walk-in chiller"
  asset_tag TEXT,                        -- our / customer label
  serial_number TEXT,
  category TEXT,                         -- air_conditioner | refrigerator | ...  (lookup-driven)
  manufacturer TEXT,
  model TEXT,
  location_detail TEXT,                  -- building / floor / room within the site
  installed_at DATE,
  warranty_expires_at DATE,
  status TEXT NOT NULL DEFAULT 'active'
      CHECK (status IN ('active','inactive','decommissioned')),
  notes TEXT,
  metadata JSONB DEFAULT '{}',
  created_by_uuid TEXT,
  created_at TIMESTAMP DEFAULT NOW(), updated_at TIMESTAMP DEFAULT NOW(), deleted_at TIMESTAMP
);
-- idx: (namespace_id, account_id), (namespace_id, site_id), (namespace_id, serial_number)
```

### 4.2 `employees` — staff directory (migration 863)
Enriches a `users` login with the engineer-specific attributes a service business needs,
and is the pool a manager assigns from. Keyed on `user_uuid` (consistent with how
`timesheets` and `fs_visits` reference people), so it augments the login rather than
replacing it. General-purpose (timesheets/HR can reuse), not field-service-only.

```sql
CREATE TABLE employees (
  id BIGSERIAL PRIMARY KEY,
  uuid TEXT UNIQUE NOT NULL,
  namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
  user_uuid TEXT NOT NULL,               -- → users.uuid (their OpsAPI login)
  employee_code TEXT,                    -- optional EMP-0001
  job_title TEXT,
  is_engineer BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  phone TEXT,
  email TEXT,
  region TEXT,                           -- team / area for assignment
  skills JSONB DEFAULT '[]',             -- certifications / competencies (skill-based routing later)
  hourly_cost_rate DECIMAL(10,2),        -- INTERNAL cost (≠ the customer bill rate on the visit/job)
  metadata JSONB DEFAULT '{}',
  created_by_uuid TEXT,
  created_at TIMESTAMP DEFAULT NOW(), updated_at TIMESTAMP DEFAULT NOW(), deleted_at TIMESTAMP,
  UNIQUE (namespace_id, user_uuid)       -- one employee record per user per tenant
);
-- idx: (namespace_id, is_engineer, is_active)
```
> `user_uuid` stays `TEXT` with no hard FK, matching the existing `timesheets.user_uuid`
> convention (`users` is global, not namespace-scoped). Queries resolve it against `users`.

### 4.3 `fs_request_sequences` + `fs_service_requests` — the complaint layer (migrations 864, 865)
`fs_request_sequences` mirrors the race-safe `fs_job_sequences` pattern (atomic
`INSERT … ON CONFLICT DO UPDATE … RETURNING`) to mint `SR-0001` per namespace. **Its own
migration** (don't repeat the 853 mistake).

```sql
-- 864
CREATE TABLE fs_request_sequences (
  namespace_id BIGINT PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
  prefix TEXT NOT NULL DEFAULT 'SR',
  current_number INTEGER NOT NULL DEFAULT 0,
  updated_at TIMESTAMP DEFAULT NOW()
);

-- 865
CREATE TABLE fs_service_requests (
  id BIGSERIAL PRIMARY KEY,
  uuid TEXT UNIQUE NOT NULL,
  namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
  request_number TEXT NOT NULL,          -- SR-0001
  account_id BIGINT REFERENCES crm_accounts(id) ON DELETE SET NULL,   -- the hospital
  contact_id BIGINT REFERENCES crm_contacts(id) ON DELETE SET NULL,   -- who called
  site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL,
  asset_id BIGINT REFERENCES fs_assets(id) ON DELETE SET NULL,        -- the unit that's broken
  title TEXT NOT NULL,
  description TEXT,
  fault_category TEXT,                   -- lookup-driven
  channel TEXT NOT NULL DEFAULT 'phone'
      CHECK (channel IN ('phone','app','email','portal','web','other')),
  reported_by TEXT,                      -- free-text name when the caller isn't a stored contact
  priority TEXT NOT NULL DEFAULT 'normal'
      CHECK (priority IN ('low','normal','high','urgent')),
  status TEXT NOT NULL DEFAULT 'new'
      CHECK (status IN ('new','triaged','assigned','in_progress','on_hold',
                        'resolved','closed','rejected','duplicate')),
  assigned_manager_uuid TEXT,
  sla_response_due_at TIMESTAMP,
  sla_resolve_due_at TIMESTAMP,
  first_response_at TIMESTAMP,
  resolved_at TIMESTAMP,
  closed_at TIMESTAMP,
  resolution_notes TEXT,
  metadata JSONB DEFAULT '{}',
  created_by_uuid TEXT,
  created_at TIMESTAMP DEFAULT NOW(), updated_at TIMESTAMP DEFAULT NOW(), deleted_at TIMESTAMP,
  UNIQUE (namespace_id, request_number)
);
-- idx: (namespace_id, status), (namespace_id, account_id), (namespace_id, asset_id),
--      (namespace_id, assigned_manager_uuid), BRIN(created_at)
```

### 4.4 `fs_parts` — parts / products catalog (migration 866)
The master list of parts we stock/fit. `fs_job_items` references it; free-text lines stay
allowed for ad-hoc items.

```sql
CREATE TABLE fs_parts (
  id BIGSERIAL PRIMARY KEY,
  uuid TEXT UNIQUE NOT NULL,
  namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
  sku TEXT,
  name TEXT NOT NULL,
  description TEXT,
  category TEXT,
  unit_cost DECIMAL(12,2),               -- buy price
  unit_price DECIMAL(12,2),              -- default sell price
  tax_rate DECIMAL(5,2) NOT NULL DEFAULT 0,
  stock_quantity DECIMAL(12,2),          -- NULL = not stock-tracked (inventory is optional/phase 2)
  reorder_level DECIMAL(12,2),
  is_active BOOLEAN NOT NULL DEFAULT true,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP DEFAULT NOW(), updated_at TIMESTAMP DEFAULT NOW(), deleted_at TIMESTAMP
);
-- idx: (namespace_id, is_active), (namespace_id, category);
-- partial unique (namespace_id, sku) WHERE sku IS NOT NULL
```
> Reuse note: ecommerce already has a `products` table. We deliberately keep `fs_parts`
> separate to avoid coupling field-service to the storefront; revisit only if a tenant
> genuinely needs one shared catalog.

### 4.5 `fs_jobs` — add complaint + asset links (migration 867, ALTER)
```sql
ALTER TABLE fs_jobs
  ADD COLUMN service_request_id BIGINT REFERENCES fs_service_requests(id) ON DELETE SET NULL,
  ADD COLUMN asset_id BIGINT REFERENCES fs_assets(id) ON DELETE SET NULL;
-- idx: (namespace_id, service_request_id)
```
Nullable → existing jobs and ad-hoc jobs (no complaint) keep working.

### 4.6 `fs_job_items` — parts catalog link + manager approval (migration 868, ALTER)
```sql
ALTER TABLE fs_job_items
  ADD COLUMN part_id BIGINT REFERENCES fs_parts(id) ON DELETE SET NULL,   -- nullable; free-text still allowed
  ADD COLUMN approval_status TEXT NOT NULL DEFAULT 'pending'
      CHECK (approval_status IN ('pending','approved','rejected')),
  ADD COLUMN approved_by_uuid TEXT,
  ADD COLUMN approved_at TIMESTAMP,
  ADD COLUMN rejection_reason TEXT;
-- idx: (namespace_id, approval_status)
```
**Billing rule change:** the invoice collector moves from `is_billable` to
`is_billable AND approval_status = 'approved' AND invoice_line_item_id IS NULL`.
- Parts/materials engineers add default to `pending` → back-office manager approves/rejects.
- Labour lines auto-created by check-out default to `approved` (the visit itself is the
  manager-sanctioned work) — confirm during build; a per-`item_type` default keeps it clean.

## 5. Lifecycles

**Service request** (new): `new → triaged → assigned → in_progress → on_hold →
resolved → closed`; side exits `rejected`, `duplicate`. `first_response_at` stamps on the
first manager action (SLA); `resolved_at`/`closed_at` on the closing transitions.
Converting to a job moves it toward `assigned`/`in_progress`; the request stays open until
all its jobs finish, then a manager resolves/closes it.

**Job** (existing, unchanged): `draft → scheduled → in_progress → completed`
(+ `on_hold`/`cancelled`).

**Visit** (existing, unchanged): `scheduled → en_route → on_site → completed`
(+ `cancelled`/`no_access`). Many per job.

**Job item approval** (new): `pending → approved | rejected`. Only `approved` bills.

## 6. Endpoints (REST, under `/api/v2/field-service`)

All wrapped in `AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(...))`,
gated by RBAC (§7), house response shape `{ success, data, meta }`.

**Service requests (complaint queue)**
| Method | Path | Purpose |
|---|---|---|
| GET | `/service-requests` | list + filters (status, account, asset, priority, assigned, SLA-breach) |
| POST | `/service-requests` | register a complaint |
| GET | `/service-requests/:uuid` | detail + linked jobs + asset + **rollup (visits, hours, invoiced)** |
| PUT | `/service-requests/:uuid` | edit |
| POST | `/service-requests/:uuid/status` | triage / resolve / close / reject transitions |
| POST | `/service-requests/:uuid/assign` | assign a manager |
| POST | `/service-requests/:uuid/convert-to-job` | **create a job linked to this request** |
| DELETE | `/service-requests/:uuid` | soft-delete |

**Assets**
| GET/POST | `/assets`, `/assets/:uuid` (detail incl. **service history**), PUT, DELETE; filter `?account_id`/`?site_id` |

**Parts catalog**
| GET/POST | `/parts` (search), `/parts/:uuid`, PUT, DELETE (deactivate) |

**Employees / engineers**
| GET/POST | `/employees` (`?is_engineer=true` = assignment pool), `/employees/:uuid`, PUT, DELETE |

**Job item approval** (on the existing jobs resource)
| POST | `/jobs/:uuid/items/:itemUuid/approve` · `/reject` (or one batch approve endpoint) |

Reused as-is: `POST /invoices/from-...` billing, timesheet endpoints, notifications.

## 7. RBAC modules (register in `project-config.lua` + a menu/grant migration)

New permission modules (`create/read/update/delete/manage`), granted to Owner + Admin by
migration, plus per-namespace propagation via `ModuleQueries.create` so **future
namespaces also get them** (fixes the "seeded once" gap flagged in the PR #604 review):
- `fs_service_requests` — the complaint queue (manager-facing)
- `fs_assets` — equipment register
- `fs_parts` — catalog
- `employees` — staff directory

Engineer overlay unchanged: an assigned engineer works their own visit/job without holding
`fs_jobs` grants; the complaint queue and approvals stay manager-facing.

## 8. Cross-cutting / reuse
- **Notifications** (existing module): fire on complaint assigned, parts awaiting approval,
  job completed, SLA nearing breach.
- **SLA**: due timestamps are stored on the request from day one; breach detection /
  escalation automation is phase 2 (a scheduled scan + notification).
- **Rollups**: request detail aggregates across all its jobs → visits → hours → invoices
  in one query (no N+1); this is what makes "multiple visits, all on the invoice" visible
  at the complaint level.

## 9. Build order (phased)

1. **Phase 1 — foundations:** `fs_assets` (862) + `employees` (863). Independent, unblock
   assignment and asset-linked complaints. Ship with CRUD routes + dashboard pages.
2. **Phase 2 — the complaint system:** `fs_request_sequences` (864) + `fs_service_requests`
   (865) + `fs_jobs` link (867) + triage/assign/**convert-to-job** endpoints + the queue UI.
   This is the headline feature.
3. **Phase 3 — parts & approval:** `fs_parts` (866) + `fs_job_items` alter (868) + approval
   endpoints + tighten the invoice collector to approved-only. **Fold the PR #604 Tier-1
   money-path fixes in here** (invoice race, part-pointer FKs, timesheet uniqueness) since
   we're already in the invoicing code.
4. **Phase 4 — polish:** request-level rollups, notifications wiring, SLA breach scan,
   the frontend robustness fixes from the PR #604 review (error boundary, defensive
   detail-page defaults, verify `engineer_user_uuid == user.uuid`).

Each phase: gate route loading in `app.lua` and migration registration in `migrations.lua`
on `field_service` (same flag), add the manifest entry in `reconcile-migrations.lua`
(one relation per migration), and validate `start.sh -j field_service`.

## 10. Open questions / phase 2+
- **Customer portal auth** — when the hospital's own app calls this API, who authenticates?
  Phase 1 is internal-only (call-centre staff log complaints on the customer's behalf).
  Phase 2 adds a token-scoped public intake endpoint (`POST /public/.../service-requests`)
  + a limited "customer" role so the hospital submits and tracks its own complaints.
- **Inventory** — decrement `fs_parts.stock_quantity` on part use? Deferred; the column is
  there, the logic is opt-in.
- **Preventive maintenance** — recurring service schedules per asset (auto-raise a request
  every N months). Natural once `fs_assets` exists; not in this plan.
