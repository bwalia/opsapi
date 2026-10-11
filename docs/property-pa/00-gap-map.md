# Property PA — Phase 0 gap map

Branch `feat/property-pa-poc` (opsapi, from main `d4a09bb`). No code yet.

> **Inputs missing.** `PRD.md`, `HOW-IT-WORKS.md` and `SUPPLIER-RESPONSE.md` are not in any repo or on this
> machine. This map is built from the build prompt's own entity list (§3) and component list (§4). PRD §6/§7
> wording, the How It Works fixtures (Sophie, Sarah / 22 Station Road …) and the supplier mapping still need
> checking against the real documents. Please add them to `docs/property-pa/`.

## 1. Summary and the one decision needed

The PA can be built mostly on what OpsAPI already has (the `property_deals` plugin and core AI layer):
- Workspace-scoped CRM: leads, contacts, companies, deals, tasks (kanban), documents, audit.
- An agent framework: prompt plus a fixed tool allowlist; drafts become approvals that a person decides; an executor carries out approved actions; every run is logged with its model and prompt version.
- Per-workspace AI providers with fallback order, local-only routing and usage metering.
- Self-hosted speech-to-text and text-to-speech (`/api/v2/voice`).
- A page assistant with a tool loop and a briefing call.
- Rules-based urgency with a reason.
- An editable playbook.
- pgvector (already used by the shop module).

**Decision (Balinder, 11 Oct): JobShout is the agent platform; OpsAPI is the system of record.**
- **JobShout** runs every PA agent: role prompts, tool allowlists, approvals, the run log, knowledge
  retrieval (pgvector) and **all model routing** to the private UK GPU (OpenAI-compatible; swapped by config).
  No "army of agents" is built inside OpsAPI.
- **OpsAPI** owns the data (people, properties, opportunities, deals, interactions, tasks, knowledge records),
  the **tasks, boards and teams** where humans and AI agents work together, the PA screens, speech-to-text
  plumbing, and the deterministic parts (priority engine, fact/inference store, audit). JobShout agents
  read and write OpsAPI only through OpsAPI's API, as a service account, with the workspace's permissions.
- OpsAPI's own small AI layer (`lib/ai-providers`, page assistant) stays as the fallback/UX layer; new PA
  intelligence goes to JobShout.

**Week 0 therefore starts with making JobShout fit for this** (it doesn't fully work today; §5). We own it, so fix it:
1. **Approvals:** a run paused for approval must report `awaiting_approval`, not `completed`; after the decision the task run gets the real output and status; decide resumes asynchronously (no 30 s cut-off); the native tool-calling path pauses instead of failing.
2. **Model routing per org:** use the stored per-org provider configs (`llm_provider_configs`), so an org can point at its private OpenAI-compatible endpoint with an ordered fallback; env stays the default.
3. **Tenant isolation:** org checks on approval get/decide and on knowledge CRUD.
4. **Service access:** org API keys (or service accounts) so OpsAPI can call JobShout without a user login; an outbound webhook (or SSE) for `run.completed` / `approval.requested` / `approval.decided`.
5. **Role-aware runs:** per-run role context (skills per role, plus the user's role passed through) so one Seller PA / Manager PA agent pair serves each workspace.
6. **Knowledge:** org-scoped knowledge with versions and an approval status (or keep versioned knowledge in OpsAPI and push approved rules to JobShout's index; to decide in Week 1).

## 2. Entities (build prompt §3) → OpsAPI tables

R = reuse, E = extend, N = new.

| Entity | Table(s) | | Columns / change |
|---|---|---|---|
| Person | `crm_contacts` (id, uuid, namespace_id, account_id, first_name, last_name, email, phone, mobile, job_title, owner_user_uuid, status, metadata) + `crm_leads` for unqualified people | E | Add `person_roles jsonb` (seller/buyer/agent/solicitor/broker/supplier), `preferred_channel`, `consent_basis`, `opted_out_at`. Leads already carry consent and opt-out in `property_deals_lead_details`; move them to the person at conversion. |
| Organisation | `crm_accounts` (name, industry, phone, email, address…, metadata) | R/E | Add `company_number` (Companies House). Suppliers already extend accounts (`property_deals_suppliers`). |
| Property | `property_deals_properties` (address, uprn, lat/lng, title_number, tenure, property_type, beds, condition, known_issues, est_market_value…) | E | Ownership: link owners through Person + a `property_owner` role. **Listing history:** `property_deals_market_records` already stores listings / sold prices (price, previous_price, status, event_date); add `property_uuid` to link records to our property, and derive days listed, price changes and SSTC/fall-through from it. |
| Lead | `crm_leads` + `property_deals_lead_details` | R/E | `source` already exists; add values `ghl`, `agent`, `direct`; `external_id` for GHL de-dupe. |
| Opportunity | — | **N** `pa_opportunities` | Qualified seller/buyer potential: lead/person, property, kind (sell/buy), motivation, expectation_price, our_position, temperature, decision_makers jsonb, primary_concern, status. Justification: a qualified seller is neither a raw lead nor an agreed `crm_deals` transaction. PRD separates them, and the priority engine needs fields neither table has. |
| Deal | `crm_deals` + `property_deals_deals` (stage_key, offer_amount, agreed_price, fees, target dates, health, money_at_risk) + `property_deals_deal_parties` + `property_deals_stage_history` (milestones) | R | — |
| Interaction | `crm_activities` (activity_type, subject, description, contact/deal ids, activity_date) + `property_deals_chases` (outbound) + `property_deals_inbound_messages` (inbound email) | E | Make `crm_activities` the single timeline. Add `channel` (call/email/whatsapp/meeting/note/voice), `direction`, `raw_text`, `transcript`, `summary`, `audio_document_uuid`, `opportunity_uuid`, `property_uuid`, `meaningful bool`. Backfill views over chases and inbound messages rather than copying them. |
| Task / Next action | `kanban_tasks` + `property_deals_task_details` (owner, due_at, urgency_score, **urgency_why**, status, dependencies table, metadata) | E | Add `reason text`, `created_from_interaction_uuid`, `opportunity_uuid`. Priority and status already exist; dependencies already exist (`property_deals_task_dependencies`). |
| Event | `property_deals_stage_history` covers deal milestones only | **N** `pa_events` | kind (valuation, price_reduction, promise, appointment, deadline), at, person/property/opportunity/deal, details, source. Justification: promises ("I'll decide after the second valuation") and valuations are the strongest priority signals and have no home today. |
| Offer | `property_deals_deals.offer_amount` holds the current figure only | **N** `pa_offers` | amount, made_at, conditions, response, responded_at, authority_user_uuid, opportunity/deal. Justification: negotiation needs the full history and who approved each offer. |
| Relationship | — | **N** `pa_relationships` | user ↔ person: strength, last_meaningful_contact_at, preferences jsonb. One row per pair. Could live in `crm_contacts.metadata`, but it is per agent, not per person. |
| Risk | `property_deals_deals.health/health_reasons` (deal risk, rules), compliance checks | **N** `pa_risks` | kind (deal/relationship/compliance/operational), subject, severity, evidence jsonb (source ids), status. Generalises today's deal-only health reasons. |
| Knowledge | `property_deals_playbooks` (key, title, body, no versions) | **E → N** `pa_knowledge` + `pa_knowledge_versions` | rule, rationale, domain, scope (personal/team/company), owner_user_uuid, triggers jsonb, version, status (draft/approved/retired), approved_by, approved_at, `embedding vector(384)`. Migrate playbook sections in as approved company rules. |
| Decision | `property_deals_approvals` covers action approvals only | **N** `pa_decisions` | situation, pa_recommendation, human_decision, rationale, decided_by, links (opportunity/deal/handoff). |
| Outcome | — | **N** `pa_outcomes` | what happened, at, links to decisions/actions. Small table, for learning and metrics. |
| ProposedUpdate | `property_deals_approvals` (payload, original_payload, status) is close but per action, not per field | **N** `pa_proposed_updates` | capture_uuid, target_table, target_uuid, field, old_value, new_value, confidence, is_inferred, source_interaction_uuid, status (proposed/confirmed/corrected/rejected), decided_by. |
| HandoffCard | — | **N** `pa_handoffs` | from_user, to_user, opportunity/deal, context jsonb, question, pa_recommendation, reply, replied_at, status. |

**Fact vs inference (rule 5): use a field-history table, `pa_field_facts`.** Columns: table, record uuid, field, value, source, confidence, is_inferred, confirmed_by, confirmed_at, superseded_by.
- Why: adding four columns per AI-writable field would double every table, and corrections must keep history (P11).
- The live column keeps the current value; `pa_field_facts` is the evidence trail and drives the "UNCONFIRMED" labels.
- Confirmed ProposedUpdates write the column and a `pa_field_facts` row in one transaction.

New tables: **11** `pa_*` (each justified above). All have `namespace_id` and the existing same-workspace trigger, and live in the new `property_pa` plugin.

## 3. Components (build prompt §4) → code

| Capability | Existing code | | Work |
|---|---|---|---|
| Today | `GET /api/v2/property-deals/today` (urgency, red deals, money at risk), `/due`, `/hot-leads`, `/pa/briefing`; Today page; home widgets | Modify | `GET /pa/today` returns ranked **cards** from the new priority engine, with a time-aware mode ("minutes:30" packs cards by estimated minutes). |
| Why #1? | `property_deals.sla` urgency score + `urgency_why` factors (time, completion, blocking, blockers, silence, money; weights in plugin settings) | Modify | Generalise into `pa_priority` with the PRD signals (§4 of the prompt) and configurable weights. `GET /pa/why/:card` returns the signal list. The model may phrase it but never sets the score (already true today). |
| Prepare Me | `GET /deals/:id/overview`, lead signals/replies, PA guide "prepare for call" | Modify | A dedicated `GET /pa/prepare/:opportunityId`: deterministic assembly of facts with source ids, then one model call to phrase; a validator checks that every fact maps to a record (P02/P05). |
| Capture | `/api/v2/voice/transcribe` (self-hosted Whisper via Speaches); replies scoring; chases logging | Modify + new | `POST /pa/capture`: STT, resolve person/property (ask if ambiguous), extraction to a JSON schema with confidence and `is_inferred`, ProposedUpdates, a timeline summary, and a proposed next action. |
| Confirm | Approvals inbox (edit, then approve) | New | `POST /pa/capture/:id/confirm`: per-field confirm/correct; material fields (price, offer, decision makers, next action time) are always confirmed; recompute priority and temperature. |
| Ask PA | Chat agent (`routes/chat-agent.lua`, page scopes, tool loop, allow-list) + `property-pa.md` scope | Modify | Retrieval: records via tools plus knowledge via pgvector; answers cite source ids; gaps are stated. "Ask Ashley" becomes a tool that creates a HandoffCard. |
| Coach | Playbook + PA guide | New prompt | A coaching prompt over history and negotiation knowledge; fact vs assumption; questions before money. |
| Handoff | Approvals routing to managers; notifications (push, in-app, email, ntfy, Telegram, SMS) | New | `POST /pa/handoff` creates a card on the recipient's Today; the reply goes back to the opportunity/deal timeline and into the next brief. |
| Teach PA | Playbook editor (managers, unversioned) | New | `POST /pa/teach` turns natural text into a proposed rule; scope choice; `POST /pa/knowledge/:id/approve`; versions stay readable. |
| Manager Today | Approvals inbox, deals at risk, the manager view in `/due` | New view | `GET /pa/today?role=manager`: exceptions only. |
| Audit (rule 7) | `property_deals_agent_runs` (model, prompt_version, sources, steps), `ai_usage`, `audit_events` (old/new values, actor) | Extend | Every AI write records run, model, prompt version and approver; an AI change-history panel on the record view (P10). |
| Fallback UI (rule 10) | WSL CRM leads/deals/today pages work without AI | Keep | Add a timeline, sources and AI change history to the record views. |
| Mic everywhere | Assistant panel: mic, face, TTS, speaker | Modify | A persistent Ask PA bar and mic on every screen; phone-friendly Today (cards + buttons). |

**Integrations**
- **GoHighLevel:** none today. New webhook `POST /pa/integrations/ghl` with a shared secret; upserts Lead + Person, de-duplicated on GHL contact id, then email or phone.
- **Outlook:** `property_deals.mail` already reads Microsoft 365 through Graph (read-only, client credentials). Linking threads to a person/deal is partly there (sender match). **Draft replies** need `Mail.ReadWrite` and creating Graph drafts. Mocked in development (the existing mocks have Graph).

## 4. Speech-to-text path (built and live on int)

1. Browser `MediaRecorder` (webm/opus or mp4)
2. `POST /api/v2/voice/transcribe` (auth, max 10 MB, audio types only)
3. OpsAPI forwards a multipart request to `VOICE_URL/v1/audio/transcriptions` (Speaches: faster-whisper, self-hosted)
4. Returns `{text}`

On int: `VOICE_URL=http://192.168.1.177:8014`, the LAN Mac. For the PRD: point `VOICE_URL` (`PA_STT_URL`) at the private UK GPU's OpenAI-compatible STT; config only. Text-to-speech is the same path (`/v1/audio/speech`, Kokoro British voices).

## 5. JobShout facts (origin/master `2788297`; local checkout is 543 files behind)

- **Running a role-aware agent:**
  - `POST /api/v1/tasks/launch {agent_id, values}`, or `POST /tasks/{id}/run {prompt, model_provider, model_name, skill_slugs[]}`; poll `GET /task-runs/{id}`.
  - The prompt and tool allowlist (`agent_tool_permissions`) are fixed per agent; the user's role is not used. Options: one agent per role, or per-run `skill_slugs`.
- **Run log:**
  - `task_runs`: status, tokens, cost, latency.
  - `execution_tool_calls`: tool, input, output, duration.
  - Plus Langfuse traces; no per-step reasoning log.
- **Approvals:**
  - `agent_approval_rules (agent, tool)` pauses a run.
  - `GET /approvals?status=pending`, `POST /approvals/{id}/decide`.
  - **Bugs:** a paused run is saved as `completed` with empty output and is never updated after the decision; decide resumes inside a 30 s HTTP request; native tool-calling fails instead of pausing; the langchain/langgraph engines may skip the gate.
- **pgvector:**
  - `knowledge_chunks … embedding vector(1536)`, ivfflat cosine; 800-char chunks with 100 overlap; top 5 injected at run start, plus a `knowledge_search` tool.
  - Per agent only; no versions, approval or org column on files; no search endpoint.
- **Model routing:**
  - The agent's provider/model, else `LLM_PROVIDER`.
  - One `OPENAI_BASE_URL` / `OPENAI_DEFAULT_MODEL`, or `OLLAMA_BASE_URL` with a JWT.
  - Fallback is one hop to Ollama (`LLM_OLLAMA_FALLBACK`); per-org provider configs are not used.
- **Events:**
  - No outbound webhooks; Slack/Teams/Telegram/email adapters only.
  - The `/ws` WebSocket has `execution.status_changed` and `approval.requested`/`decided`.
- **Auth and tenancy:**
  - User JWT login only (no API keys); one org per user.
  - Approval decide/get and knowledge CRUD skip the org check.
  - OpsAPI already calls it with a service user (see `docs/property-deals/jobshout.md`).
- **Speech-to-text:** none.

JobShout is the routing and agent layer (decided). Fix list and order: §1 "Week 0". Estimate about 1 week.

## 6. Risks and unknowns

1. **The private UK GPU endpoint:** URL, model (does it do tool calling reliably?), STT model and capacity. Today's self-hosted Qwen on a shared Mac takes 2–6 min per PA answer under load; the PoC needs a dedicated GPU (target under 10 s per turn).
2. **Missing client documents** (PRD, How It Works, Supplier Response): fixture details, the exact P01–P12 wording and the PoC checklist are unconfirmed.
3. **Extraction accuracy** on voice notes (P03/P09): needs the private model's JSON-schema quality; the P01–P12 regression suite guards model changes.
4. **Groundedness (P02/P05):** enforce with deterministic fact assembly and a validator, not prompt wording alone.
5. **JobShout fixes** (§1) come first in week 0; the local checkout has someone's unsaved work on `feat/launch-design`, so fixes are done on a separate branch from `origin/master`.
6. **GHL and Outlook:** no live accounts yet; build against mocks, then need test tenants and Graph `Mail.ReadWrite` consent.
7. **Data protection:** real client data only on the private GPU; fake data in development (already the rule in OpsAPI's AI layer: workspace providers only, local-only flag).
8. **Scope creep:** 11 new tables; keep the PoC to Seller Agent + Manager as the prompt says.
