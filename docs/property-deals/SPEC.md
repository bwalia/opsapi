# Build Prompt — "Property Deals" Back Office Module (OpsAPI + WSL CRM + iOS + AI agents)

> Paste this whole file into your coding agent (Claude Code / Cursor) at the root of a workspace that has the `opsapi`, WSL CRM dashboard, iOS app and `jobshout` repos checked out. Work in phases. Stop at the end of each phase and show me the result before going on.

---

## 0. Your role and the goal

You are a senior engineer adding a new module to an existing platform. The module is a **back office for buying and selling houses**. It must:

1. Track every deal from first lead to completion (and after: refurb, letting, refinance).
2. **Create tasks by itself** at each step, with deadlines, and flag what is urgent (for example: EPC not booked, solicitor not replying, exchange date at risk).
3. Make sure every **compliance and legal step** is done on time, and **remind operators every day** about what is due.
4. Let tasks be done by a **person or an AI agent**. An agent can pick up a task and work on it, but **a human must approve** before anything is sent, signed, paid or marked done.
5. Work with **external LLM APIs** (bring your own key), **local LLMs**, and **JobShout** (call agents already set up there).
6. Be **generic**: any company that buys or sells homes (cash-buyer firm, sourcing agent, investor club, estate agent, developer) can use it. No client names, brands, prices or rules hard-coded. The first client (a UK "guaranteed sale" buyer + investor sourcing business) is just the **seed template**.

### Platform you are building on (read the code, do not guess)

| Part | What it is | Where |
|---|---|---|
| **OpsAPI** | Multi-tenant API on OpenResty / Lapis / Lua / PostgreSQL. JWT auth, RBAC, namespaces (workspaces), migrations by project code, Swagger, MinIO for files, Prometheus/Grafana. Has a **plugin system** (`opsapi plugin:new`, `make:resource`, `make:page`, `make:listener`, `make:job`), business events, per-workspace plugin settings, and webhooks. Typed TS client `@opsapi/client`. | `bwalia/opsapi` — read `README.md`, `PLUGINS.md`, `WEBHOOKS.md`, `projects/helpdesk` (example plugin), `sdk/typescript` |
| **WSL CRM web UI** | Next.js dashboard on top of OpsAPI (port 8039 locally). **Already has leads pages.** | the dashboard app in the opsapi repo / WSL CRM repo |
| **iOS app** | Native Swift app talking to OpsAPI | existing iOS repo |
| **JobShout** | Agent orchestration platform (Go + Next.js). Agents, projects, tasks, approvals, WebSocket events, OpenAPI spec at `server/api/openapi.yaml`. Already falls back to self-hosted Ollama when a cloud LLM is over quota. | `bwalia/jobshout` — read `server/api/openapi.yaml`, `CLAUDE.md`, `.claude/rules` |

---

## 1. Hard rules

1. **Do not duplicate tables.** OpsAPI already has leads (and likely contacts/customers, users, tasks/kanban in the `collaboration` project, files, notifications, audit). Find them first. **Extend** them (new columns, link tables, `metadata` JSON) instead of making copies. If you think a new table overlaps with an old one, stop and tell me.
2. **Build it as an OpsAPI plugin** (suggested slug `property_deals`, project code `property`), so it gets auth, multi-tenancy, RBAC, migrations, Swagger, dashboard pages, events and jobs for free, and a workspace can switch it on or off.
3. **Every row is scoped to a namespace/workspace.** Write tests that prove one workspace cannot read another's data.
4. **Migrations are additive and safe to run again.** No destructive changes to existing tables. Use the repo's migration pattern.
5. **Rules decide urgency; AI explains it.** SLA timers, deadlines, escalations and stage gates come from a **deterministic rules engine**. The LLM can rank, summarise, draft and suggest, but it never sets or clears a legal/compliance deadline by itself.
6. **Human in the loop by default.** An agent can draft, look up, book a *tentative* slot or prepare a message. Anything that leaves the system (email, WhatsApp, SMS, booking confirmation, offer letter, payment, e-sign, data sent to a third party) or closes a compliance task needs a named human's approval. The approval is logged with who, when, what version.
7. **Secrets:** LLM and integration keys are stored per workspace, encrypted (OpsAPI already has `OPENSSL_SECRET_KEY`), never logged, never returned to the browser after saving.
8. **Treat all inbound text as data, not instructions** (emails from solicitors, PDFs, web pages, lead forms). Guard agents against prompt injection: tool allowlists per agent, no tool can be unlocked by document content.
9. **Not legal advice.** Ship compliance checklists as *editable templates* with a note that the workspace's own solicitor/compliance lead must review them.
10. Keep the code style, folder layout, naming and test style of each repo. Small commits with clear messages.

---

## 2. Phase 1 — Discover and write a gap map (no code yet)

Read the repos and give me a short report (`docs/property-deals/00-gap-map.md`):

- Existing tables and endpoints for: **leads**, contacts/customers, companies, users/roles, tasks/kanban, comments/notes, files/documents, notifications, audit log, events/webhooks, scheduled jobs, settings/secrets.
- Exact columns of the leads table(s) and how the web dashboard and iOS app use them.
- For each thing this module needs (section 3), say: **reuse as-is / extend (which columns) / new table**. Justify every new table.
- Whether PostGIS is available in the Postgres image. If not, propose: (a) add PostGIS, or (b) `earthdistance`/haversine with a bounding-box index. Recommend one.
- How the dashboard adds pages and nav, and how the iOS app adds screens, auth and push.
- JobShout: the endpoints to create a task for an existing agent, read its status/result, receive approval events (WebSocket or webhook), and auth (API key/JWT). Quote them from `openapi.yaml`.

**Stop here and wait for my OK.**

---

## 3. What the module must do (functional spec)

### 3.1 Core objects (generic names)

Use these concepts. Map each to an existing table where one fits.

| Concept | Notes |
|---|---|
| **Lead** (existing) | Extend with `lead_kind` (`seller`, `buyer_investor`, `landlord`, `agent_referral`, …), `source`, `situation` (probate, broken chain, divorce, relocation, care fees, repossession risk, tenanted, unmortgageable, other), `deadline_date`, `vulnerability_flag` + note, `consent` fields. |
| **Property** | Address, UPRN, lat/lng (geo index), postcode, title number, tenure, lease years left, ground rent, service charge, type, beds, baths, floor area, EPC rating + cert number + expiry, council tax band, condition, known issues (enum list + free text: spray foam, non-standard construction, short lease, knotweed, subsidence, shale floors, cladding, sitting tenant…), tenancy (rent, arrears, end date), flood / mining risk, photos (MinIO), est. market value, est. rent, refurb estimate, end value. One property can link to many leads/deals. |
| **Buyer profile** (on an existing contact/company) | Entity type (person, Ltd/SPV, overseas co, pension SSAS/SIPP, trust/family office), capital band, where funds are held, proof of funds status + expiry, funding route (cash, mortgage, bridging, cash-then-refinance), speed to commit, strategies (BTL, BRR, flip, HMO, blocks, semi-commercial, commercial, tenanted), areas (polygons or centre+radius), price range, min discount / min yield, refurb appetite, top priority, deal-breakers, preferred channel, time zone, current holdings. |
| **Deal** | Links property + seller lead + buyer(s). Type (`buy`, `sell`, `buy_and_assign`, `sourcing`), stage, offer amount, agreed price, fees, target exchange date, **target completion date**, actual dates, **late-penalty per day** (configurable, may be 0), late-penalty cap, finance route, solicitor(s), status colour, `money_at_risk` (computed). |
| **Workflow template** | Per workspace. Ordered stages, task templates per stage, SLAs, gates, compliance items. Versioned. A deal is pinned to the template version it started with. |
| **Task** (extend existing tasks if possible) | Link to deal/property/lead, `template_key`, owner (user **or** agent), due_at, SLA minutes, priority, **urgency score** (computed), `blocking` (is it on the path to exchange/completion?), status (`todo`, `in_progress`, `waiting_third_party`, `agent_running`, `awaiting_approval`, `done`, `cancelled`), escalation level, `compliance` flag. |
| **Chase log** | Each chase: to whom, channel, what was asked, sent_at, reply_at, linked enquiry. |
| **Enquiry / blocker** | Open legal questions and missing items, each with owner (seller / buyer solicitor / seller solicitor / lender / freeholder / council), raised_at, due, resolved_at. |
| **Supplier** | Generic directory: solicitor, surveyor, EPC assessor, broker, bridging lender, builder, letting agent, auction house, freeholder/managing agent. Areas covered (geo), accreditation numbers, price list, booking method (email/API/link), **measured** average turnaround and on-time %, rating, active flag. |
| **Booking** | Supplier + task + slot + status (`requested`, `tentative`, `confirmed`, `done`, `cancelled`) + cost. |
| **Compliance check** | Type, subject (person/company/deal), status, evidence file, checked_by, checked_at, expires_at. |
| **Agent run** | Task, agent (provider + model or JobShout agent id), input snapshot, steps/tool calls, output draft, cost/tokens, status, approval record. |
| **Match** | Property ↔ buyer profile, score 0–100 with breakdown, status (`suggested`, `sent`, `interested`, `declined`), sent_at. |

### 3.2 Workflow engine and tasks made automatically

- On stage change (and on deal creation) create the stage's tasks from the template, with owner, due date and SLA.
- Due dates can be relative to: stage entry, another task finishing, the **target exchange date** or **target completion date** (count backwards, in working days, using a UK bank holiday calendar that can be swapped per country).
- **Gates:** a deal cannot move to *Exchange* or *Completion* while any required compliance task or required document is missing. Show exactly what is blocking.
- Dependencies between tasks (e.g. "book survey" only after "offer accepted").
- **Seed template: "UK residential — guaranteed-sale buyer + investor sourcing" (England & Wales).** Stages and example tasks:

| Stage | Example tasks (SLA) |
|---|---|
| New seller lead | Call back (**60 min**); log situation, deadline, vulnerability check |
| Qualified | Pull title, EPC lookup, sold comps, flood/mining, lease check; draft written offer (24 h) |
| Offer sent | Send written offer with reasoning (48 h from lead) — **needs approval** |
| Accepted | Memo of sale; instruct both solicitors; request seller ID + forms (same day) |
| Seller papers | Chase seller forms (TA6, TA10, TA7 if leasehold) (2 working days) |
| Searches | Order searches (day 1); record council and expected time |
| EPC | **Check public register for a valid EPC first**; if none, book assessor (**60 min** to book) |
| Survey / valuation | Book from panel; or lender valuer for bridging (**60 min** to book) |
| Lease pack | Request management pack from managing agent/freeholder (day 1) |
| Enquiries | Daily chase of each open enquiry; phone after 24 h with no reply |
| Funds & buyer | Buyer proof of funds / mortgage offer / bridging offer; AML on buyer |
| Exchange | All gates green → exchange |
| Completion | Funds moved; keys; final statement |
| After completion | Refurb plan, letting, refinance (optional sub-workflow) |

- Ship a second, smaller template ("Sell via estate agent") to prove the engine is generic.
- Templates are editable in the UI (stages, tasks, SLAs, gates, who owns what) and exportable/importable as JSON.

### 3.3 Urgency, SLAs, escalation and daily reminders

- **SLA engine** (OpsAPI scheduled job, every minute): for each open task compute time left. At 75% of SLA → notify owner. At 100% → notify manager and mark overdue. At 125% → reassign to manager or escalation queue (configurable).
- **Urgency score** (deterministic, documented formula, weights configurable per workspace). Inputs: time left vs SLA, working days to target completion, whether the task is blocking, number of open blockers, days since last third-party reply, and **money at risk** = late-penalty-per-day × predicted days late (capped). Show the score and *why* on each task.
- **Deal health:** green / amber / red. Red when predicted completion > target, or a blocking task is overdue, or fewer than N working days remain with open blockers.
- **Completion slip prediction:** start with rules (sum of remaining expected durations from supplier/council/solicitor history vs days left). Later the AI can add a note, but the number comes from rules.
- **Daily digest** per operator at a set local time (default 07:30, workspace time zone): my overdue tasks, due today, deals at risk with £ at risk, compliance items expiring (ID checks, proof of funds, EPC), approvals waiting for me. Send in-app + email + iOS push; WhatsApp/Slack optional via webhooks.
- **Manager view:** all red deals, all overdue tasks by person, slowest suppliers/solicitors/councils.

### 3.4 Compliance and legal steps (configurable checklist, UK seed)

Seed these as compliance task templates. Each has evidence upload, who checked, expiry, and blocks the right stage gate:

- **AML (Money Laundering Regulations 2017, HMRC-supervised businesses):** customer due diligence on seller and buyer; ID + address verification; beneficial owners for companies (Companies House lookup); **source of funds / source of wealth** for buyers; sanctions and PEP screening; risk rating; enhanced checks for high-risk; record keeping period; re-check on expiry.
- **Redress scheme membership** recorded for the workspace (e.g. Property Redress Scheme / The Property Ombudsman).
- **Consumer protection:** vulnerability flag and handling note; no pressure selling; written offer with reasoning kept on file; price-change reasons recorded; no fake or incentivised reviews (illegal in the UK since April 2025).
- **UK GDPR / ICO:** lawful basis and consent per contact, privacy notice sent, data retention dates, right-to-erasure handling, a log of data sent to third parties.
- **Material information** for listings (Parts A/B/C style fields) where the workspace also markets homes.
- **Conveyancing items:** title checked, searches back, enquiries resolved, lease pack received, mortgage/bridging offer, buyer funds cleared, completion statement agreed.
- **Property compliance (if letting after purchase):** EPC minimum rating, gas safety, EICR, smoke/CO alarms, deposit protection, Right to Rent, licensing (HMO/selective). Make these a separate optional pack.
- Allow other countries/regions by adding **jurisdiction packs** (Scotland differs: missives, Home Report). Do not hard-code England & Wales.

### 3.5 AI layer

**Provider abstraction** (one interface, many back ends):

- External APIs with the workspace's own key: Anthropic, OpenAI, Google Gemini, Azure OpenAI, Mistral, plus any **OpenAI-compatible** endpoint.
- **Local LLMs:** Ollama, LM Studio, vLLM, llama.cpp server, LocalAI — via OpenAI-compatible base URL + optional key.
- **JobShout:** "provider" type that sends the task to an existing JobShout agent instead of calling a model directly.
- Per-workspace settings: providers, default model per *job type* (classify, extract, draft, plan, chat), fallback order (e.g. cloud → local on quota/outage, like JobShout already does), max tokens and **max cost per run / per day**, data-residency flag ("local only" for sensitive tasks such as ID documents).
- Tool calling where the model supports it; a plain JSON-output fallback where it doesn't.
- Log every run: prompt version, model, tokens, cost, latency, result. Optional Langfuse/OpenTelemetry tracing.

**Agent task lifecycle**

```
todo ──(human or agent claims)──► agent_running ──► awaiting_approval ──(approve)──► done / action executed
                                       │                    └──(reject + note)──► todo (agent can retry with the note)
                                       └──(error / needs info)──► todo + comment for human
```

- Each task template says whether it is **agent-eligible**, which agent/tool set, and the **approval rule** (any operator, manager only, two people).
- An operator can click **"Let AI do it"** on any agent-eligible task, or a workspace can set auto-pickup for some task types (e.g. "draft daily chase emails at 08:00").
- The agent writes a **draft** (email text, booking request, offer reasoning, summary, risk list). The UI shows the draft, its sources, and a diff if edited. Approve → the system performs the action through a controlled tool (send email, confirm booking, etc.) and logs it.
- Nothing irreversible runs without approval. Booking APIs may hold a *tentative* slot only.

**Agents to ship (each is a prompt + tool allowlist + approval rule; generic, no client names):**

1. **Lead intake & triage** — read form/call notes, fill structured fields, set situation, flag vulnerability, suggest priority.
2. **Property enrichment** — EPC lookup, sold prices nearby, flood/mining, title summary; write to Property.
3. **Offer reasoning drafter** — comparables + condition + chosen completion window → offer range and plain-English reasoning. *Manager approval required.*
4. **Buyer matcher** — score new property vs all buyer profiles; draft personal deal packs. *Approval to send.*
5. **Legal chaser** — read solicitor emails (IMAP / Gmail / Microsoft 365 connector), update enquiries, draft chase emails, flag blockers, update slip prediction. *Approval to send* (workspace may allow auto-send for plain reminders later).
6. **Booking agent** — find nearest suitable suppliers (EPC assessor, surveyor) from the directory, request slots from 2–3 at once, hold tentative, ask human to confirm.
7. **Document checker** — read title, lease, survey, EPC, searches; list red flags with page refs. Never "clears" an issue — only flags.
8. **Compliance assistant** — prepare AML checklist, compare ID data across documents, flag gaps and expiries. A human signs off every check.
9. **Daily digest writer** — turns the rules-based digest into a short readable summary.
10. **Investor update writer** — weekly plain-English progress notes per buyer with photos.

**JobShout integration**

- Workspace setting: JobShout base URL + API key + list of mapped agents (`task_template_key → jobshout_agent_id`).
- On "Let AI do it" with a JobShout agent: create a JobShout task with the deal context (minimal data needed, no unneeded personal data), store the JobShout task id, and listen for status/approval events (WebSocket or webhook). Mirror JobShout's approval into our approval record so **one** human approval covers both systems — do not ask twice.
- If JobShout is down, fall back to the built-in provider (if allowed) or leave the task with a clear note.

### 3.6 Map and deal finder

- Map page (Leaflet + OpenStreetMap tiles by default; Mapbox/Google as optional keys). Operator drops a pin and picks a radius (default 25 miles, 5–50 slider).
- Layers: own seller leads, pipeline deals (colour by stage/health), buyers' current holdings, sold prices, EPC ratings, listings from **data connectors**, auction lots.
- Click a home: summary card, yield, discount vs comps, EPC, lease, issues, and **top 3 matching buyers** with score breakdown; buttons: create deal, send to buyer (via approval), add note.
- Saved searches per pin that the **deal scout** job re-runs daily and alerts on new / reduced / stale / cash-only homes.

**Data connectors** (adapter interface so a workspace can plug in its own; do not scrape portals that forbid it):
- EPC (GOV.UK "Get energy performance of buildings data" service), HM Land Registry Price Paid, Companies House API, planning data, flood data — free/open.
- Paid listing/market data (e.g. PropertyData, Searchland, Street Data, Homedata) — adapter stubs with config only.
- CSV import for anything else (auction catalogues, agent feeds).

### 3.7 Matching score (configurable weights)

Default: budget fit 30, area fit 20, strategy fit 20, yield/discount vs target 20, condition appetite 10. Any deal-breaker → 0. Show the breakdown. Store results; re-run when a property or profile changes.

### 3.8 Web UI (WSL CRM, Next.js) — reuse existing layout, components and leads pages

1. **Today** — my tasks sorted by urgency, red deals, approvals waiting, £ at risk.
2. **Leads** — existing page, extended with the new fields and a "Create deal" action.
3. **Deals** — Kanban by stage + list view; deal page with timeline, tasks, enquiries, chase log, documents, compliance panel, money-at-risk, slip prediction.
4. **Map / Deal finder.**
5. **Buyers** — buyer profiles, proof-of-funds status, matches.
6. **Suppliers** — directory with turnaround stats; "book nearest".
7. **Approvals inbox** — every AI draft waiting, with sources and approve / edit / reject.
8. **Compliance** — all checks, expiries, evidence.
9. **Settings** — workflow templates editor, SLA/urgency weights, AI providers & models, JobShout link, data connectors, notification channels, jurisdiction pack.
10. **Reports** — time per stage, late days, conversion, supplier/solicitor/council speed, AI usage and cost.

### 3.9 iOS app (Swift) — extend the existing app

- **Today** list with urgency colours; tap → task detail; complete or "Let AI do it".
- **Approvals**: review an AI draft and approve/edit/reject from the phone (biometric confirm for approvals).
- **Push notifications** for SLA warnings, escalations, approvals, daily digest.
- **Quick capture**: new seller lead or property with photos, voice note (transcribe), location from GPS.
- **Deal view** (read-mostly): stage, blockers, next tasks, call/WhatsApp the contact.
- Works with poor signal: cache Today + deal views, queue actions offline, sync when back.

### 3.10 Events, webhooks and jobs (use OpsAPI's built-ins)

- Emit events: `property_deals.deal.created`, `.stage_changed`, `.health_changed`, `.task.created`, `.task.overdue`, `.task.escalated`, `.approval.requested`, `.approval.decided`, `.compliance.expiring`, `.match.created`. Available to workspace webhooks.
- Jobs: `sla_tick` (1 min), `daily_digest` (per workspace time), `deal_scout` (daily), `compliance_expiry` (daily), `connector_sync` (configurable), `supplier_stats` (nightly).

### 3.11 API

- REST under `/api/v2/property_deals/...` following existing conventions; documented in Swagger; types regenerated in `@opsapi/client`.
- RBAC roles (map to existing roles if possible): Operator, Manager, Compliance officer, Agent (service account for AI), Read-only/Investor portal (later).

---

## 4. Non-functional

- Tenant isolation tests; RBAC tests per endpoint.
- Audit log for every state change, approval and outbound message (who/what/when/before/after).
- Times stored in UTC, shown in workspace time zone; working-day maths with bank holidays.
- Performance: Today view < 300 ms for 5k open tasks; map radius query < 500 ms for 100k properties.
- Observability: Prometheus metrics (tasks overdue, SLA breaches, agent runs, cost), a Grafana dashboard JSON.
- Data retention settings and export (CSV/JSON) per workspace.

---

## 5. Delivery phases (stop after each one and show me)

| Phase | Scope | Done when |
|---|---|---|
| 1 | Gap map (section 2) | I approve it |
| 2 | Plugin skeleton, migrations (extend leads, add new tables), CRUD APIs, Swagger, seed templates | Migrations run twice cleanly; isolation tests pass |
| 3 | Workflow engine, auto tasks, gates, SLA engine, urgency score, escalation, daily digest | Scenario test below passes for the rules part |
| 4 | Web UI: Today, Deals, Deal page, Approvals, Compliance, Settings (templates) | Operator can run a deal end to end by hand |
| 5 | AI layer: provider abstraction (cloud + local + JobShout), agent lifecycle, approvals, 3 first agents: legal chaser, booking agent, daily digest writer | Scenario test passes incl. AI draft + approval |
| 6 | Map + data connectors (EPC, Price Paid, Companies House) + matching + buyer pages | Pin + radius shows layers; matches with breakdown |
| 7 | iOS: Today, approvals, push, quick capture, offline cache | Approve an AI draft from the phone |
| 8 | Remaining agents, reports, supplier stats, hardening | All tests green; docs written |

### Scenario test (must pass from phase 3/5)

Seed workspace "Demo Buyers Ltd" with the UK template. A deal is at stage *Searches*. Target completion is in **9 working days**. Late penalty £500/day, cap 20 days. EPC task not started. Seller's solicitor last replied **50 hours** ago with 2 open enquiries.

Expected:
1. EPC task created with 60-min SLA; at 45 min owner notified; at 60 min manager notified and task overdue.
2. Register lookup runs first; if a valid EPC is found the booking task closes itself with evidence.
3. Deal health = **red**; money at risk shown with the reason.
4. Daily digest for the owner lists the deal at the top.
5. Legal chaser agent (using a **local model** in the test) drafts a chase email listing the 2 enquiries; it sits in Approvals; nothing is sent until approved; on approval the email is sent and a chase log row is written.
6. The same flow works when the task is routed to a JobShout agent (mock JobShout in tests).
7. Exchange stage is blocked while buyer AML is incomplete, with a clear reason.
8. A user from another workspace cannot see any of it.

---

## 6. Output I want from you at the end

- Code in each repo on a feature branch, with migrations, tests and docs.
- `docs/property-deals/`: gap map, data model diagram (Mermaid), workflow template JSON format, urgency formula, agent catalogue (prompt, tools, approval rule), JobShout integration notes, setup guide for local LLMs, compliance-template disclaimer.
- A short list of open questions and anything you chose to leave out.
