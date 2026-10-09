# Property Deals API (contract v1 — Phase 4)

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
{ "uuid": "…", "title": "Chase seller's solicitor", "subject_type": "chase", "action": "send_email",
  "rule": "any_operator", "payload": { "to": "…", "subject": "…", "body": "…" }, "payload_version": 1,
  "deal_name": "7 Mill Lane", "agent_key": "legal_chaser", "provider": "local", "model": "llama3.1:8b",
  "cost_usd": 0.0, "from_jobshout": false, "run_sources": [ … ], "can_decide": true, "decisions": [] }

// decide: approve as is | approve an edited version | reject
{ "decision": "approve" }
{ "decision": "approve", "payload": { "to": "…", "subject": "…", "body": "edited text" }, "note": "Tightened wording" }
{ "decision": "reject", "note": "Wrong solicitor" }          // note required
```
- **Diff:** compare `original_payload` (the agent's draft, kept after an edit) with `payload`.
- **Rules:** `any_operator` (one person with approvals.update), `manager` (approvals.manage),
  `two_person` (two different people; after the first approval the answer has
  `waiting_for: "a second person"`). Nobody decides their own request, and the AI account never
  decides.
- Every decision is logged with who, when, payload version and SHA-256.
- In v1 an approved item stays `approved`. From Phase 5 the system carries out the action (sends the
  email, confirms the booking) and moves it to `executed` or `failed`.
- People can ask for approval themselves (e.g. sending a deal pack): `POST /approvals { subject_type, action, title, payload, rule?, deal_uuid? }`.

### 2.6 Map / deal finder

```http
GET /api/v2/property-deals/map?lat=53.95&lng=-1.09&radius_miles=25&layers=properties,deals,leads,holdings
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
- The card gives the property, its active deal, `gross_yield_pct`, `discount_pct` and `top_matches` (3).
- Use Leaflet + OpenStreetMap tiles.
- **Phase 6** adds layers `sold_prices`, `epc`, `listings`, `auction_lots` (same feature shape), the
  match scores that fill `top_matches`, and saved searches. Until then an unknown layer is a 422.

### 2.7 Buyers

- **Profiles:** `GET/POST /buyer-profiles`, `PUT /buyer-profiles/{id}`. A profile sits on exactly
  one CRM contact (`contact_uuid`) or company (`account_uuid`).
- **Proof of funds:** `pof_status` none · requested · received · verified · expired, plus
  `pof_expires_on`. It expires automatically every day.
- **Matches:** `GET /matches?buyer_profile_uuid=&sort=score&order=desc`.
- **Send deal pack:** `POST /approvals { "subject_type": "deal_pack", "action": "send_deal_pack", … }`.
  It is sent only once approved (Phase 5/6).

### 2.8 Suppliers

- **Directory:** `GET /suppliers?kind=epc_assessor&active=true&sort=speed|on_time|rating&q=`.
- **Add a supplier:** `POST /suppliers { "name", "email", "kinds": ["epc_assessor"], "base_lat", "base_lng", "radius_miles" }`
  creates the CRM company, or pass `account_uuid` to use an existing one.
- **Bookings:** `GET/POST /bookings`, `PUT /bookings/{id} { "status": "confirmed" }`.
- **"Book nearest"** (nearest suppliers for a task, with the booking agent) is Phase 5/6. Until then
  create a booking task (`POST /tasks`) or a booking by hand.
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
| Run checks now | `POST /engine/run { "checks": ["sla","health","compliance_expiry","digest"] }` (managers) |
| AI providers, models, JobShout link, data connectors | **Phase 5/6** — see §4 |

An invalid template returns 422 with `details` as a list like
`["stages[3].tasks[1].due.from: stage_entry, deal_created, …"]`. Show it next to the editor.

### 2.11 Reports — Phase 7

Time per stage, late days, conversion, supplier/solicitor/council speed, AI usage and cost. Not in
v1. Until then use `GET /deals` and `GET /agent-runs` for mocks.

---

## 3. iOS screens (SPEC §3.9)

| Screen | Calls |
|---|---|
| Today | `GET /today`. Colour by `urgency_score`/`overdue`; cache the response for offline |
| Task detail | `GET /tasks/{task_uuid}`. Complete: `PUT /tasks/{task_uuid} {"pd_status":"done","evidence":{…}}`. "Let AI do it": Phase 5 |
| Approvals | `GET /approvals/inbox`, `POST /approvals/{id}/decide` (Face ID before sending is client-side) |
| Deal view | `GET /deals/{id}/overview` (stage, blockers = `enquiries` + `stage.next_gate.missing`, next tasks = `tasks.open`, contact phone in `parties`) |
| Quick capture | lead: core `POST /api/v2/crm/leads`, then `PUT /leads/{uuid}/details`. Property: `POST /properties { address_line1, lat, lng }` (GPS). Photos: `POST /documents` multipart, `category: "photo"`, `property_uuid`. Voice note: send the transcript as `notes` (on-device transcription in v1) |
| Permissions | `GET /me` |

**Offline:** cache `GET /today` and each `GET /deals/{id}/overview`. Queue `PUT /tasks/…` and
`POST /approvals/{id}/decide`; replays are safe, because a second decide answers 409 `Already approved`.

**Push** (native APNs):
- Register the token: `POST /api/v2/device-tokens { "token": "<hex>", "token_type": "apns", "apns_environment": "development|production", "bundle_id": "uk.co.workstation.wslcrm", "device_name" }`.
- Payload: `{ aps: { alert: { title, body }, sound, "thread-id": <deal uuid> }, namespace_id, route: "task"|"approval"|"deal"|"digest", uuid, event, deal_uuid, plugin: "property_deals" }`.
- Sent for: SLA warning (`Due soon`), overdue (`Overdue`), escalation (`Escalated to you`), daily digest (`Your day`), compliance expiring. Approval requests are added in Phase 5.
- Switch to `namespace_id` before opening `route` / `uuid`.

---

## 4. Coming next (not in v1 — mock against these shapes)

| Phase | Endpoint (planned) | For |
|---|---|---|
| 5 | `POST /tasks/{task_uuid}/agent-run` → `{ agent_run, approval? }`; `GET /agent-runs/{id}` (exists, read-only today) | "Let AI do it" |
| 5 | `GET/POST/PUT /ai/providers` (keys write-only: responses show `key_last4` only), `POST /ai/providers/{id}/test`, `GET/PUT /ai/agents` (model per job type, fallback order, cost caps, local-only), `GET/PUT /ai/jobshout` (URL, service user, agent mapping), `POST /ai/jobshout/test` | Settings → AI |
| 5 | Approval execution: `approved` → `executed`/`failed`, `execution_result` | Approvals |
| 6 | Map layers `sold_prices`, `epc`, `listings`, `auction_lots`; `GET/POST /saved-searches`; `GET/PUT /connectors`; `POST /matches/recompute` | Map, Buyers, Settings |
| 6 | `POST /suppliers/nearest { task_uuid | lat,lng, kind }` | "Book nearest" |
| 7 | `GET /reports/{stage-times|late-days|conversion|supplier-speed|ai-usage}` | Reports |

Exact shapes are fixed when each phase ships, and this table is updated.

---

## 5. Events and webhooks

Workspace webhooks (`/api/v2/namespace/webhooks`) can subscribe to:
- `property_deals.<entity>.created|updated|deleted` for deal, property, buyer_profile, task, enquiry,
  chase, supplier, booking, compliance_check, approval, match.
- `deal.completed|fell_through|stage_changed|health_changed`.
- `task.done|awaiting_approval|sla_warning|overdue|escalated`.
- `approval.requested|approved|rejected|decided`.
- `compliance_check.passed|failed|expiring|expired`.
- `booking.confirmed|cancelled`.

The payload is the event's `data` (a database row for change events, or `{ uuid, deal_uuid, … }` for
engine events). Use it for WhatsApp/Slack.

---

## 6. Answered API requests

| Request | Answer |
|---|---|
| [ios-apns-device-tokens](api-requests/ios-apns-device-tokens.md) | Done (Phase 3): APNs tokens, routing, payload contract (§3) |

## 7. Changes

- **v1 (Phase 4):**
  - Contract published.
  - New screen endpoints: `/me`, `/today`, `/deals/board`, `/deals/{id}/overview`, `/deals/{id}/timeline`, `/map`, `/properties/{id}/card`, `/approvals/inbox`, `POST /approvals`, `POST /approvals/{id}/decide`.
  - Every route is typed in OpenAPI. `@opsapi/client` 1.2.0 adds `/property-deals`.
