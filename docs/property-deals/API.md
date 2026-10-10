# Property Deals API (contract v1.6)

Read this before building the web dashboard (SPEC §3.8) or the iOS app (SPEC §3.9).
It goes screen by screen: which call fills each screen, and what it returns. Types:
`@opsapi/client/property-deals` (TypeScript) and `/openapi.json` (Swagger at `/swagger`, tag
**Property Deals**). Every route below has an exact schema there.

- Base path: **`/api/v2/property-deals`** (hyphen, gap map D1).
- Rules behind the numbers: [urgency.md](urgency.md). Template JSON: [template-format.md](template-format.md).
  Tables: [data-model.md](data-model.md).
- Missing something? Write `docs/property-deals/api-requests/<web|ios>-<short-name>.md` (what, why, an
  example response) and use a clearly marked mock until it ships. Don't work around the API.

---

## 1. Conventions

| | |
|---|---|
| Auth | `Authorization: Bearer <JWT>` (from `/auth/login` + 2FA) or an API key |
| Workspace | `X-Namespace-Id: <uuid>` or `X-Namespace-Slug: <slug>` on every call |
| Envelope | `{ "success": true, "data": …, "meta": { page, per_page, total, total_pages }? }` · errors `{ "success": false, "error": "text", "details": {…}? }` |
| **Nulls** | **Fields that are null are left out of the JSON.** Treat every non-required property as optional |
| Lists | `?page=1&per_page=20` (max 100); `meta.total` |
| Ids | uuids. Tasks use the **kanban task uuid** (`task_uuid`) |
| Times | ISO 8601 UTC (`due_at`); plain dates (`target_completion_date`) are workspace-local. Show in the workspace `timezone` from `GET /me` |
| Money | numbers in the deal `currency` (default GBP) |
| **Retries** | Send `Idempotency-Key: <uuid>` on creates (every `POST` that makes a row, core `POST /api/v2/crm/leads` and kanban comments too). A retry with the same key — same workspace, user and body — gets the first answer back (header `Idempotent-Replayed: true`) and creates nothing. Same key + different body → 422; still running → 409. Keys live 24 h |

Status codes: `401` not signed in · `403` role can't do it (show "you don't have access", hide the
button next time) · `404` not in this workspace, **or the plugin is off** (`"code": "PLUGIN_DISABLED"`:
hide the module) · `409` conflict, e.g. a stage gate isn't met · `422` validation (`details`: field →
message).

**Module on/off:** the plugin is opt-in per workspace. Turn it on with
`PUT /api/v2/namespace/plugins/property_deals { "enabled": true }` (needs `namespace.update`), then
call `POST /setup` once (managers). Before setup, `GET /setup` answers `data: null`.

**Roles:** `GET /me` returns `permissions[module] = [actions]` for
`deals, properties, buyers, tasks, suppliers, compliance, approvals, ai, settings, reports`. Show a
button only when the action is allowed, and still handle a 403. Seeded roles: `pd_operator`,
`pd_manager`, `pd_compliance`, `pd_agent` (AI service account: can't approve or sign off),
`pd_read_only`. Owners and admins can do everything.

```ts
import { createPropertyDealsClient } from '@opsapi/client/property-deals';
const api = createPropertyDealsClient({ baseUrl: 'https://int-opsapi.workstation.co.uk', token, namespace: 'demo-buyers' });
```

---

## 2. Web screens (SPEC §3.8)

### 2.1 Today — `GET /today`

One call for the whole screen.

```http
GET /api/v2/property-deals/today?limit=50
```
```jsonc
{ "success": true, "data": {
  "today": "2026-10-09", "generated_at": "2026-10-09T07:31:02Z",
  "counts": { "open": 7, "overdue": 1, "due_today": 2, "awaiting_approval": 0 },
  "tasks": [ {                              // my open tasks, most urgent first
    "task_uuid": "d6b6fa89-…", "title": "Book an EPC assessor", "pd_status": "todo",
    "deal_uuid": "885bfb31-…", "deal_name": "7 Mill Lane", "deal_health": "red", "stage_key": "epc",
    "due_at": "2026-10-09T08:15:00Z", "overdue": true, "sla_minutes": 60, "escalation_level": 2,
    "urgency_score": 81.4, "blocking": true, "agent_eligible": true, "agent_key": "booking_agent",
    "urgency_why": [                        // show on hover
      { "factor": "time", "points": 35, "why": "Overdue (133% of its time used)" },
      { "factor": "money", "points": 10, "why": "£7000 at risk on the deal" },
      { "factor": "completion", "points": 11, "why": "9 working day(s) to target completion" } ] } ],
  "red_deals": [ { "uuid": "885bfb31-…", "name": "7 Mill Lane", "stage_key": "searches", "health": "red",
                   "money_at_risk": 7000, "target_completion_date": "2026-10-22",
                   "predicted_completion_date": "2026-11-05",
                   "health_reasons": ["1 blocking task(s) overdue", "£7000.00 at risk: 14 day(s) late × £500/day (cap 20 days)"] } ],
  "money_at_risk": 7000,
  "approvals_waiting": [ { "uuid": "…", "title": "Chase seller's solicitor", "rule": "any_operator",
                           "deal_name": "7 Mill Lane", "agent_key": "legal_chaser", "from_jobshout": false } ],
  "approvals_waiting_count": 1 } }
```
**Live updates:** poll `GET /today` every 30–60 s. Health and urgency are recomputed every minute,
and after every change made through the API. A WebSocket feed is not part of v1.

### 2.1a Due this week — `GET /due?days=7&mine=`
Deal tasks and renovation jobs with a due date within `days` (default 7, max 60), overdue first. Managers
(`property_deals_approvals.manage`) get the whole team (`everyone: true`) unless `mine=true`; everyone
else gets the tasks they own and the renovation jobs they're assigned. A job is done once its card is in
a Done column (or completed/cancelled).
```json
{ "data": { "days": 7, "everyone": true, "items": [
  { "kind": "renovation_job", "uuid": "…", "title": "Survey and schedule of works", "due_at": "2026-10-08T17:00:00Z",
    "overdue": true, "status": "open", "deal_uuid": "…", "deal_name": "3 Brick Row", "project_uuid": "…",
    "project_name": "Renovation — 3 Brick Row", "column_name": "Survey & quotes", "assignee": "Sam Builder" } ] } }
```

### 2.1b Renovations — `GET /renovations`, `POST /renovations`
A renovation is a core kanban project (open it at `/dashboard/projects/{project_uuid}`): its board's
columns are the build stages and its cards are dated jobs (`seed/renovation_standard.lua`, ~50 days,
stretched to `target_end_date`). `POST` takes `{ deal_uuid?, property_uuid?, name?, budget?,
start_date?, target_end_date?, builder_user_uuids? }`; the builders are added as project members.
The list returns progress (`jobs_total`, `jobs_done`, `jobs_overdue`), budget/spent and the board uuid;
filter with `?status=active|completed|all&deal_uuid=`.

### 2.1c Hot leads — `GET /hot-leads`, lead news and replies
Customer request: personal follow-ups and "call them now" alerts.
- **News** `GET /leads/{id}/signals`: Companies House events from the daily watch (a company they formed,
  a new directorship, filings, a new charge, often a mortgaged purchase) and posts a person captured with
  `POST /leads/{id}/signals { kind: social_post|website|news|note, text?, url? }`. Social networks are
  never fetched by the server. Link a lead with `PUT /leads/{id}/details { company_number, ch_officer_id }`
  (find the officer with `GET /companies-house/officers?q=`). New property companies (SIC 68xxx/41100)
  in the `ch_new_company_areas` setting become leads (`source = companies_house`).
- **Replies** `GET /leads/{id}/replies`: emails matched to the lead by sender (`matched_by = lead`) and
  replies logged with `POST /leads/{id}/replies { channel: whatsapp|sms|phone|social|email|other, text }`.
  Each is scored 0-100 (`reply_temperature` hot/warm/cold, `reply_reason`) by the workspace's AI provider
  (rules without one); an opt-out is always cold.
- **Hot** (score >= `hot_score_threshold`, default 70): one "Call <name> now" task due in
  `hot_call_within_minutes` (default 15, escalated by the SLA engine), for the lead's owner (else managers),
  and alerts: app push (Workstation CRM) + in-app, email, and the free channels the workspace set up as
  connectors: `ntfy` (open-source push), `telegram` (bot), `sms_gateway` (Android SMS Gateway, texts from
  your own phone). Per-person switches and addresses (`ntfy_topic`, `telegram_chat_id`) are in
  `/notification-preferences` (category `hot_lead`). `GET /hot-leads` lists leads whose call task is
  still open.

### 2.1d Personal follow-ups — `POST /leads/{id}/follow-up`
`{ channel?: email|whatsapp|sms, signal_uuid?, note? }` → 202 `{ task_uuid, run_uuid }`. The
`lead_followup` agent drafts ONE short message opening with the lead's newest news (or the one given), with
an angle per lead kind (seller, buyer, landlord, agent, solicitor, broker). The draft is an approval
(`action = send_lead_followup`, `subject_type = chase`): edit and approve it in the inbox. On approval:
- **email** → workspace SMTP, with an opt-out line; **sms** → the workspace's Android SMS Gateway (else an
  `sms:` link); **whatsapp** → a `https://wa.me/...` click-to-chat link in `execution_result.manual_link`
  (no paid API; the task stays `in_progress` until it's sent);
- refused (409/422) if the lead opted out, or is a private person with no `consent_basis` (B2B leads with a
  company name may be contacted); the address is re-read from the lead at send time;
- logs a chase on the lead (`outcome = followup`), marks the news `used_at`, sets `last_followup_at`.
New news from the Companies House watch starts a draft by itself (`followup_auto_on_news`, default on,
needs an AI provider, leads with an owner, one open follow-up per lead). An opt-out reply cancels waiting
drafts and blocks new ones; vulnerable leads need a manager's approval.

### 2.2 Leads (extend the existing page)

Keep creating, editing and converting leads through core `/api/v2/crm/leads`. Add the Property
Deals fields:

| Need | Call |
|---|---|
| List with new filters | `GET /leads?lead_kind=seller&situation=probate&vulnerable=true&deadline_before=2026-12-01&sort=deadline&q=` |
| One lead (+ `details`, + `deal_uuid` if a deal exists) | `GET /leads/{uuid}` |
| Save kind / situation / deadline / vulnerability / consent | `PUT /leads/{uuid}/details` |
| "Create deal" | `POST /deals { "lead_uuid", "property_uuid"?, "deal_type", "target_completion_date"?, … }` |

```jsonc
// PUT /leads/{uuid}/details      (only fields sent change; null clears)
{ "lead_kind": "seller", "situation": "probate", "deadline_date": "2026-12-01",
  "vulnerability_flag": true, "vulnerability_note": "Recently bereaved",
  "consent_basis": "legitimate_interests", "privacy_notice_sent_at": "2026-10-09T09:00:00Z" }
```
Enums: `lead_kind` seller · buyer_investor · landlord · agent_referral · other. `situation` probate ·
broken_chain · divorce · relocation · care_fees · repossession_risk · tenanted · unmortgageable · other.
Converting creates the CRM contact, marks the lead converted, adds the seller as a deal party, and
creates the first stage's tasks.

### 2.3 Deals — Kanban and list

```http
GET /api/v2/property-deals/deals/board?template=uk_guaranteed_sale     # default: template most deals use
```
```jsonc
{ "template": { "key": "uk_guaranteed_sale", "name": "UK residential — …", "version": 2 },
  "columns": [ { "key": "searches", "name": "Searches", "parallel": false, "has_gate": false,
                 "deals": [ { "uuid": "…", "name": "7 Mill Lane", "health": "red", "money_at_risk": 7000,
                              "open_tasks": 6, "overdue_tasks": 1, "target_completion_date": "2026-10-22" } ] },
               { "key": "exchange", "name": "Exchange", "has_gate": true,
                 "gate_summary": { "tasks": 3, "compliance": 5, "documents": 2, "fields": 2, "no_open_blocking_enquiries": true },
                 "deals": [] } ] }
```
- **Drag and drop:** before dropping, call `GET /deals/{id}/gate?to=<stage>`. If `ok` is false,
  show `missing[].message` and don't move. To move, call `POST /deals/{id}/stage { "to": "<stage>" }`.
  It answers 409 with `details.missing` if the gate isn't met.
- `parallel` columns (EPC, survey, lease pack…) start with the stage before them. Deals don't sit
  in them, so don't allow drops there.
- **List view:** `GET /deals?status=active&health=red&stage_key=&q=&sort=health|target_completion|money_at_risk|created`.

### 2.4 Deal page — `GET /deals/{id}/overview`

```jsonc
{ "deal": { /* Deal: prices, dates, penalty, health, stage, template… */ },
  "property": { /* Property */ },
  "stage": { "current": "searches", "next": "enquiries",
             "next_gate": { "stage": "enquiries", "ok": true, "missing": [] },
             "stages": [ { "key": "new_lead", "state": "done" }, { "key": "searches", "state": "current" },
                         { "key": "lease_pack", "state": "skipped" }, { "key": "exchange", "state": "upcoming", "has_gate": true } ] },
  "health": { "health": "red", "reasons": ["…"], "money_at_risk": 7000, "working_days_left": 9,
              "target_completion_date": "2026-10-22", "predicted_completion_date": "2026-11-05",
              "late_penalty_per_day": 500, "late_penalty_cap_days": 20 },
  "parties": [ { "role": "seller", "name": "Pat Probate", "phone": "07…", "email": "…", "contact_uuid": "…" } ],
  "tasks": { "counts": { "total": 9, "done": 2, "overdue": 1 }, "open": [ /* TaskSummary, by urgency */ ] },
  "enquiries": [ { "title": "Missing FENSA certificate", "owner_party": "seller_solicitor", "raised_at": "…" } ],
  "recent_chases": [ { "channel": "email", "subject": "Enquiries", "sent_at": "…", "reply_at": "…" } ],
  "compliance": [ { "key": "aml_cdd_buyer", "name": "AML customer due diligence — buyer", "status": "in_progress", "applies": true } ],
  "documents": [ { "category": "title", "count": 1 } ],
  "approvals_waiting": [ /* ApprovalCard */ ], "top_matches": [] }
```

Tabs:

| Tab | Read | Write |
|---|---|---|
| Tasks | `GET /tasks?deal_uuid=&open=true` | **Do it** `PUT /tasks/{task_uuid} { "pd_status": "done", "evidence": {"note": "…"} }`. Compliance tasks need evidence. **Assign** `{ "owner_user_uuid" }`. **Snooze** `{ "snoozed_until", "snooze_reason" }` (reason required). **Let AI do it**: Phase 5 (§4) |
| Enquiries & blockers | `GET /enquiries?deal_uuid=&status=open` | `POST /enquiries`, `PUT /enquiries/{id} { "status": "resolved", "resolution" }` |
| Chase log | `GET /chases?deal_uuid=` | `POST /chases` (hand-sent chases; AI chases come through approvals) |
| Documents | `GET /documents?deal_uuid=` | `POST /documents` multipart `file` + `deal_uuid` + `category`; `GET /documents/{id}` gives `download_url` (valid 5 min) |
| Compliance | `overview.compliance` + `GET /compliance-checks?deal_uuid=` | `POST /compliance-checks`, `PUT /compliance-checks/{id} { "status": "passed" }`. The server records who and when. Waiving needs `notes` |
| Buyers / matches | `overview.top_matches`, `GET /matches?property_uuid=` | `PUT /matches/{id} { "status": "interested" }` |
| Timeline | `GET /deals/{id}/timeline?page=` (audit trail, newest first) | — |
| Parties | `GET /deal-parties?deal_uuid=` | `POST/PUT/DELETE /deal-parties` |

Header actions: **edit** `PUT /deals/{id}` (target dates re-time the tasks that count from them) ·
**move** `POST /deals/{id}/stage` · **next** `POST /deals/{id}/advance` ·
**refresh health** `GET /deals/{id}/health` (facts + slip breakdown).

### 2.5 Approvals inbox

```http
GET /api/v2/property-deals/approvals/inbox            # pending items I may decide (?all=true: all pending)
POST /api/v2/property-deals/approvals/{id}/decide
```
```jsonc
// inbox item
{ "uuid": "…", "title": "Chase seller solicitor — 7 Mill Lane", "subject_type": "chase", "action": "send_email",
  "rule": "any_operator", "payload_version": 1, "payload_sha256": "…",
  "payload": { "to": "sol@firm.example", "to_party": "seller_solicitor", "subject": "Open enquiries [PD-1a2b3c4d]",
               "body": "…", "enquiry_uuids": ["…"], "enquiry_updates": [], "new_enquiries": [] },
  "deal_name": "7 Mill Lane", "agent_key": "legal_chaser", "provider": "builtin", "model": "qwen3:8b",
  "cost_usd": 0.0002, "from_jobshout": false, "run_steps": [ { "round": 1, "tool": "list_open_enquiries" } ],
  "run_output": { "summary": "…", "blockers": ["…"] }, "can_decide": true, "decisions": [] }

// decide: approve as is | approve an edited version | reject. Always send the version you showed.
{ "decision": "approve", "payload_version": 1 }
{ "decision": "approve", "payload_version": 1, "payload": { "to": "…", "subject": "…", "body": "edited text" }, "note": "Tightened wording" }
{ "decision": "reject", "note": "Mention the completion date" }   // note required; the agent's rerun follows it
```
- **Diff:** compare `original_payload` (the agent's draft, kept after an edit) with `payload`.
- **Rules:** `any_operator` (one person with approvals.update), `manager` (approvals.manage),
  `two_person` (two different people; after the first approval the answer has
  `waiting_for: "a second person"`). Nobody decides their own request, and the AI account never
  decides.
- Every decision is logged with who, when, payload version and SHA-256.
- **Version guard:** with `payload_version` (or `payload_sha256`), a decision on a draft that changed
  since it was shown answers **409** `"The draft has changed since you opened it"` with
  `details: { payload_version, payload_sha256 }` — re-fetch and show the new one.
- **After approval the system acts** (property_deals/ai/executor.lua) and the approval moves to
  `executed` (`execution_result`, e.g. `{ chase_uuid, sent_to }`) or `failed` (`execution_result.error`,
  e.g. no email server). Managers retry a failed one with `POST /approvals/{id}/retry`.

  | action | what runs | task afterwards |
  |---|---|---|
  | `send_email` | email `payload.to` (workspace SMTP), write a chase row, apply `enquiry_updates` / `new_enquiries` | done |
  | `update_enquiries` | apply the proposed enquiry changes only | unchanged |
  | `request_booking` | email each supplier in `payload.requests`, record bookings `requested` | waiting_third_party |
  | `confirm_booking` | email the supplier, booking `confirmed`, other requests for the task `cancelled` | done |
  | `jobshout:<tool>` | passed to JobShout, which runs its own tool (`execution_result.by = "jobshout"`) | done when JobShout finishes |
  | anything else | recorded; nothing automatic | unchanged |
- **Rejected** → the task goes back to `todo` with a comment; "Let AI do it" again redrafts using the note.
- **JobShout:** when a JobShout agent asks for approval it shows up here once (`from_jobshout: true`,
  `jobshout_approval_id`). Deciding here decides it in JobShout too; a decision made in JobShout's own
  UI is mirrored here. Nobody is asked twice.
- Confirm one supplier's slot: `POST /bookings/{id}/confirm { slot_start?, slot_end?, cost?, body? }` creates
  a `confirm_booking` approval (the booking turns `tentative` until it is approved).
- People can ask for approval themselves (e.g. sending a deal pack): `POST /approvals { subject_type, action, title, payload, rule?, deal_uuid? }`.

### 2.6 Map / deal finder

```http
GET /api/v2/property-deals/map?lat=53.95&lng=-1.09&radius_miles=25&layers=properties,deals,leads,holdings,sold_prices,epc,listings,auction_lots
GET /api/v2/property-deals/map?polygon=53.9,-1.2;54.0,-1.2;54.0,-1.0;53.9,-1.0&layers=deals
GET /api/v2/property-deals/properties/{id}/card
```
```jsonc
{ "center": { "lat": 53.95, "lng": -1.09 }, "radius_miles": 25, "truncated": false,
  "counts": { "deals": 1, "properties": 4 },
  "features": [ { "layer": "deals", "uuid": "<property uuid>", "lat": 53.96, "lng": -1.08, "title": "7 Mill Lane",
                  "subtitle": "YO1 7AA", "distance_miles": 0.8, "deal_uuid": "…", "deal_stage": "searches", "deal_health": "red" } ] }
```
- Radius: 1–100 miles (UI slider 5–50, default 25). At most 2000 features (`truncated`).
- Colour deal pins by `deal_health` or `deal_stage`.
- **Market layers** `sold_prices`, `epc`, `listings`, `auction_lots` come from data connectors and CSV
  imports (same feature shape plus `price`, `previous_price` (before a cut), `event_date`, `epc_rating`,
  `cash_only`, `url`, `source`). An unknown layer is a 422.
- **Card:** the property, its active deal, `gross_yield_pct`, `discount_pct` (vs the estimate),
  `comps` (sold prices within a mile, 24 months: `count`, `median`), `discount_vs_comps_pct` and
  `top_matches` (3, each with `breakdown`).
  - Card buttons: "create deal" (`POST /deals { property_uuid }`), "send to buyer"
    (`POST /matches/{id}/send`, an approval), "add note" (`PUT /properties/{id} { notes }`).
- Use Leaflet + OpenStreetMap tiles.
- **Saved searches (deal scout):**
  - `GET/POST/PUT/DELETE /saved-searches { name, lat, lng, radius_miles | polygon: [[lat,lng],…], filters: { min_price, max_price, min_bedrooms, property_types[], record_types[] }, alerts, stale_after_days }`.
  - Run one now: `POST /saved-searches/{id}/run`.
  - The daily job alerts the owner about **new**, **reduced**, **stale** (over `stale_after_days`) and **cash_only** homes. The first run only sets the baseline.
  - Alerts: `GET /scout-alerts?unseen=true`, `POST /scout-alerts/seen { uuids? }`. Push/in-app category: `deal_scout`.
- **Data:** `GET /market-records?record_type=&postcode=`.
  - Import a CSV (auction catalogue, agent feed): `POST /market-records/import { record_type, csv, source? }` (header row; missing lat/lng are geocoded from the postcode).
  - Look up a property: `POST /properties/{id}/enrich` (EPC register → `epc_rating`, certificate, expiry; nearby sold prices; geocodes a postcode-only property). New properties are looked up automatically when the workspace has these connectors.

### 2.7 Buyers

- **Profiles:** `GET/POST /buyer-profiles`, `PUT /buyer-profiles/{id}`; the list with names: `GET /buyer-profiles/directory?q=`. A profile sits on exactly
  one CRM contact (`contact_uuid`) or company (`account_uuid`).
- **Proof of funds:** `pof_status` none · requested · received · verified · expired, plus
  `pof_expires_on`. It expires automatically every day.
- **Matches:** `GET /buyer-profiles/{id}/matches` (properties, best first) and
  `GET /properties/{id}/matches` (buyers, best first).
  - Each row has `score` 0–100 and a `breakdown`: per factor `{ weight, fit, points, why }` for
    `budget, area, strategy, yield, condition`, plus `deal_breakers` (any → score 0).
  - Weights are the plugin settings `match_w_*` (default 30/20/20/20/10).
  - Scores update by themselves when a property or profile changes. Re-score by hand:
    `POST /matches/recompute { property_uuid? | buyer_profile_uuid? }`.
  - Mark a buyer's reply: `PUT /matches/{id} { status: interested | declined }`.
- **Send deal pack:** `POST /matches/{id}/send { subject?, body? }` creates a `send_deal_pack` approval
  addressed to the buyer's email. Once approved, the email goes and the match becomes `sent`. A
  match that hits a deal-breaker answers 409.
- **Company buyers (Ltd/SPV):** `GET /companies/search?q=`,
  `POST /buyer-profiles/{id}/company-check { company_number }`. Companies House returns the profile,
  active officers and `flags` (e.g. accounts overdue), saved on the profile as `company_check`.

### 2.8 Suppliers

- **Directory:** `GET /suppliers?kind=epc_assessor&active=true&sort=speed|on_time|rating&q=`.
- **Add a supplier:** `POST /suppliers { "name", "email", "kinds": ["epc_assessor"], "base_lat", "base_lng", "radius_miles" }`
  creates the CRM company, or pass `account_uuid` to use an existing one.
- **Bookings:** `GET/POST /bookings`, `PUT /bookings/{id} { "status": "confirmed" }`.
- **"Book nearest":** `POST /suppliers/nearest { kind, task_uuid | property_uuid | lat+lng, limit? }`
  lists suppliers nearest first, with measured speed. To have the requests drafted and sent, use the
  booking agent ("Let AI do it" on the booking task).
- `avg_turnaround_hours` and `on_time_pct` are measured nightly from Phase 7.

### 2.9 Compliance

| View | Call |
|---|---|
| All checks | `GET /compliance-checks?status=&check_type=&deal_uuid=` |
| Expiring soon | `GET /compliance-checks?expiring_within_days=30` (passed checks) |
| Expired | `?status=expired` |
| Evidence | `evidence_document_uuid` → `GET /documents/{id}` |
| Template items per deal | `GET /deals/{id}/overview` → `compliance` |

### 2.10 Settings

| Area | Call |
|---|---|
| Module on/off and scalar settings (time zone, digest time, SLA %, escalation, urgency weights, `red_min_working_days`, `due_time`, `expiring_within_days`, `digest_email`) | core `GET /api/v2/namespace/plugins` and `PUT /api/v2/namespace/plugins/property_deals { "settings": {…} }` |
| Workflow templates | `GET /workflow-templates`, `GET /workflow-templates/{id}` (with the active `definition`), `GET …/{id}/versions`, `GET …/{id}/versions/{n}`, `POST …/{id}/versions { definition, notes }` (publish), `PUT …/{id} { is_active, active_version_uuid }` (roll back), `GET …/{id}/export`, `POST /workflow-templates/import { definition }` |
| Bank holidays | `GET/POST/PUT/DELETE /holidays` (also a generated page at `/dashboard/plugins/property-deals/holidays`) |
| Run checks now | `POST /engine/run { "checks": ["sla","health","compliance_expiry","digest","agents","mail","scout","nightly"] }` (managers) |
| Deals board default | plugin setting `default_template` (default `uk_guaranteed_sale`): the board opens on it when no template has more active deals |
| **AI providers** (core, any workspace module can use them) | `GET/POST /api/v2/namespace/ai-providers`, `GET/PUT/DELETE …/{id}`, `POST …/{id}/test`, `GET …/{id}/agents` (JobShout). Body: `{ name, provider_type: anthropic\|openai\|gemini\|azure_openai\|mistral\|openai_compatible\|ollama\|jobshout, base_url?, default_model?, secret?, username? (JobShout), options? (Azure: deployment, api_version), is_local?, enabled?, input_cost_per_mtok?, output_cost_per_mtok? }`. **Keys go in, never out**: answers carry `has_secret` + `secret_hint` ("…a1b2"); `secret: ""` clears it. Needs `namespace.update` |
| Model per job type + fallback order | `GET /ai/routes`, `PUT /ai/routes/{classify\|extract\|draft\|plan\|chat\|summarise} { chain: [{ provider_uuid, model? }], local_only?, max_tokens? }` — tried in order |
| Agents | `GET /ai/agents` (catalogue + settings), `PUT /ai/agents/{key} { enabled, route: builtin\|jobshout, jobshout_provider_uuid, jobshout_agent_id, fallback_to_builtin, local_only, approval_rule, auto_pickup, auto_pickup_at: "08:00" }` |
| Cost caps | plugin settings `ai_max_cost_run_usd` (stop a run), `ai_max_cost_day_usd` (no new runs today), `ai_max_tokens`; spend: `GET /ai/usage?days=30` |
| Mailboxes (legal chaser reads replies) | `GET/POST /mail-connectors`, `GET/PUT/DELETE …/{id}`, `POST …/{id}/sync`; kinds `imap { host, port, ssl, username, mailbox }` + password, `gmail { client_id }` + `{ client_secret, refresh_token }`, `m365 { tenant_id, client_id, mailbox }` + client secret. Received mail: `GET /inbound-messages?deal_uuid=`; log one by hand: `POST /inbound-messages` |
| Email server for approved sends | core `PUT /api/v2/namespace/mail-settings` (else the deployment's SMTP) |
| Data connectors | `GET/POST /connectors`, `GET/PUT/DELETE /connectors/{id}`, `POST /connectors/{id}/run { postcode }`. Kinds: `epc` (config `email`, secret API key), `price_paid`, `companies_house` (secret API key), `postcodes`, `csv`; paid feeds `propertydata`, `searchland`, `streetdata`, `homedata` are stubs (run → 501: import their CSV). `sync_enabled` → the daily deal scout fetches for active deals' and saved searches' postcodes. Keys are sealed and never returned |
| Match weights | plugin settings `match_w_budget`, `match_w_area`, `match_w_strategy`, `match_w_yield`, `match_w_condition` |

An invalid template returns 422 with `details` as a list like
`["stages[3].tasks[1].due.from: stage_entry, deal_created, …"]`. Show it next to the editor.

### 2.10a "Let AI do it" (task page, deal page)

```http
POST /api/v2/property-deals/tasks/{task_uuid}/agent-run      { "note"?: "extra instruction" }   → 202 { data: AgentRun }
GET  /api/v2/property-deals/agent-runs/{id}                   poll until status is succeeded | failed | cancelled
POST /api/v2/property-deals/agent-runs/{id}/cancel
```
Show the button when the task has `agent_eligible: true` and `GET /me` allows `ai.create`. The task goes
`agent_running` → `awaiting_approval` (the draft is in the Approvals inbox) or back to `todo` with a comment
("AI couldn't finish: …" / "AI found nothing to send"). Errors: 409 an agent is already on it · 422 not
eligible / agent off / no AI provider · 429 today's AI budget is used up. The run (`AgentRun`) shows the
model, tokens, cost, the tools it called (`steps`, refused ones marked `refused: true`) and the draft.
Agents and what each may do: [agents.md](agents.md).

### 2.11 Reports

All `GET`, `?from=YYYY-MM-DD&to=YYYY-MM-DD` (default: the last 90 days; `meta` echoes the window), permission `reports.read`:

| Report | What |
|---|---|
| `/reports/stage-times` | `completed_stages[]` { stage_key, deals, avg_days, median_days, max_days } and `current[]` { stage_key, deals, avg_days_so_far } |
| `/reports/late-days` | completed deals vs their target: on time / late, `avg_days_late`, `on_time_pct`, `penalty_cost` (late penalty, capped), the ten latest `worst[]` |
| `/reports/conversion` | `totals` (leads, deals, completed, conversion %), `by_month[]` (leads, deals, exchanged, completed, fell_through), `by_source[]` |
| `/reports/supplier-speed` | per supplier: bookings, hours to confirm, hours to done, on-time %, cancelled |
| `/reports/party-speed` | chases by party (replied, avg / median hours to reply) and enquiries by owner (raised, resolved, still open, days to resolve) |
| `/reports/ai-usage` | `daily[]` runs / failures / cost / tokens per agent, `approval_outcomes[]` drafts / approved / rejected / edited / failed / pending per agent |

Supplier directory figures (`avg_turnaround_hours`, `on_time_pct`, `jobs_measured`) are measured
nightly from the last 12 months of bookings. Turnaround runs from the request to done (or to
confirmed). A booking is on time when it's done by `slot_end` plus one hour.

**Export** (managers, `reports.manage`): `GET /export/{deals|tasks|properties|buyer_profiles|suppliers|bookings|enquiries|chases|compliance_checks|documents|approvals|agent_runs|matches|market_records|stage_history}?format=csv|json&from=&to=`.
- It downloads as an attachment, up to 50,000 rows; `X-Truncated` is set when the export is cut.
- CSV cells starting with `= + - @` get a `'` prefix so spreadsheets don't run them.

**Retention** (plugin settings, applied nightly):
- `retention_inbound_days` (365): after this, email bodies are removed; sender, subject and the matched deal stay.
- `retention_agent_run_days` (365): after this, AI run inputs and drafts are removed; the outcome, tokens and cost stay.
- `retention_market_days` (730): older market data is deleted.

---

## 3. iOS screens (SPEC §3.9)

| Screen | Calls |
|---|---|
| Today | `GET /today`. Colour by `urgency_score`/`overdue`; cache the response for offline |
| Task detail | `GET /tasks/{task_uuid}`. Complete: `PUT /tasks/{task_uuid} {"pd_status":"done","evidence":{…}}`. "Let AI do it": `POST /tasks/{task_uuid}/agent-run` (§2.10a). After a call / WhatsApp / email from the phone: `POST /tasks/{task_uuid}/contact-log { channel, outcome?, note?, to_name?, to_address? }` — works on lead-stage tasks too (no deal yet); the log moves to the deal when the lead becomes one |
| Settings → Notifications | `GET/PUT /notification-preferences` — per category `{ push, email }` for `sla_warning, overdue, escalated, approval_requested, digest, compliance_expiring, agent_update`, plus `quiet_hours { from, to }` (workspace time; holds back push, not the digest). In-app always on |
| Approvals | `GET /approvals/inbox`, `POST /approvals/{id}/decide` (Face ID before sending is client-side) |
| Deal view | `GET /deals/{id}/overview` (stage, blockers = `enquiries` + `stage.next_gate.missing`, next tasks = `tasks.open`, contact phone in `parties`) |
| Quick capture | lead: core `POST /api/v2/crm/leads`, then `PUT /leads/{uuid}/details`. Property: `POST /properties { address_line1, lat, lng }` (GPS). Photos: `POST /documents` multipart, `category: "photo"`, `property_uuid`. Voice note: send the transcript as `notes` (on-device transcription in v1) |
| Permissions | `GET /me` |

**Offline:** cache `GET /today` and each `GET /deals/{id}/overview`. Queue `PUT /tasks/…` and
`POST /approvals/{id}/decide`; replays are safe, because a second decide answers 409 `Already approved`.
Send `Idempotency-Key` on queued creates (leads, properties, photos, contact logs, comments) and
`payload_version` on decides.

**Push** (native APNs):
- Register the token: `POST /api/v2/device-tokens { "token": "<hex>", "token_type": "apns", "apns_environment": "development|production", "bundle_id": "uk.co.workstation.wslcrm", "device_name" }`.
- Payload: `{ aps: { alert: { title, body }, sound, "thread-id": <deal uuid> }, namespace_id, route: "task"|"approval"|"deal"|"digest", uuid, event, deal_uuid, plugin: "property_deals" }`.
- Sent for: SLA warning (`Due soon`), overdue (`Overdue`), escalation (`Escalated to you`), daily digest (`Your day`), compliance expiring, approval needed (`Approval needed`, route `approval`), and "AI couldn't finish" (route `task`) — each subject to the person's notification preferences.
- Switch to `namespace_id` before opening `route` / `uuid`.

---

## 4. Coming next

The backend for SPEC phases 1–8 (backend prompt phases 1–7) is complete. New fields or endpoints
arrive through `api-requests/` like any other change.

---

## 5. Events and webhooks

Workspace webhooks (`/api/v2/namespace/webhooks`) can subscribe to:
- `property_deals.<entity>.created|updated|deleted` for deal, property, buyer_profile, task, enquiry,
  chase, supplier, booking, compliance_check, approval, match, agent_run, inbound_message.
- `deal.completed|fell_through|stage_changed|health_changed`.
- `task.done|awaiting_approval|sla_warning|overdue|escalated`.
- `approval.requested|approved|rejected|decided|executed`; `agent_run.succeeded|failed`; `inbound_message.created`.
- `match.sent|interested`; `saved_search.*`, `scout_alert.created`.
- `compliance_check.passed|failed|expiring|expired`.
- `booking.confirmed|cancelled`.

The payload is the event's `data` (a database row for change events, or `{ uuid, deal_uuid, … }` for
engine events). Use it for WhatsApp/Slack.

---

## 6. Answered API requests

| Request | Answer |
|---|---|
| [ios-apns-device-tokens](api-requests/ios-apns-device-tokens.md) | Done (Phase 3): APNs tokens, routing, payload contract (§3) |
| [ios-approval-version-guard](api-requests/ios-approval-version-guard.md) | Done (Phase 5): `payload_version` / `payload_sha256` on decide → 409 when the draft changed (§2.5) |
| [ios-contact-log-without-deal](api-requests/ios-contact-log-without-deal.md) | Done (Phase 5): option 1 + 2 — chases take `lead_uuid` (deal optional), `GET /chases?lead_uuid=`, `POST /tasks/{id}/contact-log`; moved onto the deal when the lead converts (§3) |
| [ios-idempotent-creates](api-requests/ios-idempotent-creates.md) | Done (Phase 5): `Idempotency-Key` on every create, core leads and kanban comments included (§1) |
| [ios-notification-preferences](api-requests/ios-notification-preferences.md) | Done (Phase 5): `GET/PUT /notification-preferences` + quiet hours; the workspace setting `escalations_always_notify` can make escalations unmutable (§3) |
| [web-buyer-directory](api-requests/web-buyer-directory.md) | Done: `GET /buyer-profiles/directory?q=&pof_status=` — profiles with the buyer's `name` and `email` |

## 7. Changes

- **v1.6:** personal follow-ups (`POST /leads/{id}/follow-up`, agent `lead_followup`, action
  `send_lead_followup`, setting `followup_auto_on_news`, lead `opted_out_at` / `last_followup_at`).

- **v1.5:**
  - Lead news (`/leads/{id}/signals`, Companies House watch + captured posts, `jobs/lead_signals.lua`
    daily, `POST /signals/run`), replies (`/leads/{id}/replies`, email matched by sender), reply scoring and
    hot-lead call alerts (`/hot-leads`), officer search.
  - Free / open-source alert connectors: `ntfy`, `telegram`, `sms_gateway`; preference channels `ntfy`,
    `telegram`, `sms` and category `hot_lead`.
  - Lead kinds `agent`, `solicitor`, `broker`; leads filter `temperature`, sort `last_reply`.

- **v1.4:**
  - `GET /due` (deal tasks + renovation jobs due soon) and the "Due this week" card on Today.
  - Renovations on kanban boards: `GET/POST /renovations`, a Renovations page and a deal tab.
  - Seeded roles include the back-office modules (CRM, orders, invoices, purchase orders, payments,
    projects); new `pd_builder` role for builders and site managers.
  - The `property` deployment preset now includes invoicing.

- **v1.3 (Phase 7):**
  - The other seven agents: lead triage, property enrichment, offer reasoning (manager-only), buyer
    matcher, document checker (reads PDFs, cites pages), compliance assistant, investor update.
    `read_document` and other read-only tools.
  - Reports (`/reports/*`), export (`/export/{entity}`), retention settings, nightly supplier speed.
  - Stage history (time per stage).
  - Prometheus metrics + Grafana dashboard ([observability.md](observability.md)).
  - Performance targets measured (`spec/perf_test.py`).
  - The board opens on `default_template`.

- **v1.2 (Phase 6):**
  - Data connectors (EPC register, Land Registry Price Paid, Companies House, postcode lookup; paid-feed
    stubs) and CSV import.
  - Map layers `sold_prices`, `epc`, `listings`, `auction_lots`; comparables on the property card.
  - Automatic EPC lookup for new properties (SPEC §5 #2).
  - Matching with breakdown, configurable weights and deal-breakers; recompute; deal packs via approval.
  - Companies House checks; saved searches + deal scout alerts (`jobs/deal_scout.lua`, daily);
    `POST /suppliers/nearest`.

- **v1.1 (Phase 5):**
  - AI layer: core workspace AI providers (`/api/v2/namespace/ai-providers`, AES-256-GCM sealed keys),
    `/ai/routes`, `/ai/agents`, `/ai/usage`, `POST /tasks/{id}/agent-run`, `POST /agent-runs/{id}/cancel`.
  - Approvals are carried out after approval (`executed` / `failed`), `POST /approvals/{id}/retry`,
    version guard on decide, JobShout approvals mirrored both ways, `POST /bookings/{id}/confirm`.
  - Mail connectors (IMAP, Gmail, Microsoft 365) and `/inbound-messages`; replies mark chases replied.
  - iOS requests: `Idempotency-Key`, contact log on leads (`lead_uuid`, `outcome`, `/tasks/{id}/contact-log`),
    `/notification-preferences`.
  - Daily digest: `prose` (digest writer agent) when the workspace has a model.
  - Plugin CRUD: a check-constraint violation is now 422 (was 500).

- **v1 (Phase 4):**
  - Contract published.
  - New screen endpoints: `/me`, `/today`, `/deals/board`, `/deals/{id}/overview`, `/deals/{id}/timeline`, `/map`, `/properties/{id}/card`, `/approvals/inbox`, `POST /approvals`, `POST /approvals/{id}/decide`.
  - Every route is typed in OpenAPI. `@opsapi/client` 1.2.0 adds `/property-deals`.
