# Property PA — Week 1 "Brain": what was built

Scope (SUPPLIER-RESPONSE.md): data model, interaction timeline, PA chat (JobShout Seller PA), first seller
playbook, audit. Tests: **P05** (grounded or silent) and **P10** (AI changes show source, model, prompt
version and approver), the part a back end can prove without the screens.

## OpsAPI: the `property_pa` plugin (`projects/property-pa`)

| Area | What | Where |
|---|---|---|
| Data model | 12 `pa_*` tables + PA columns on `crm_activities` (the interaction timeline), `crm_contacts` (person roles) and `property_deals_task_details` (reason, source interaction). Same-workspace triggers on every reference. | `migrations/20261020100000_pa_core.lua` |
| Fact vs inference | Every write has an evidence row in `pa_field_facts`: value, source, confidence, `is_inferred`, model, prompt version, run, who confirmed it. Corrections supersede; nothing is lost (P11). | `property_pa/facts.lua` |
| Proposed updates | The PA never writes a record. `POST /captures` logs the interaction and stores one proposal per field. A person confirms, corrects or rejects each. Only then is the record written, in one transaction with its fact row. Material fields (price, offer, decision makers, next action) are flagged. | `property_pa/updates.lua`, `api/updates.lua` |
| Grounded or silent (P05) | (1) **At capture:** a proposal not marked `is_inferred` must quote the interaction word for word, and its figures must be in the quote, or it is refused. (2) **For answers:** `GET /context/:opportunity` gives every usable fact with a `ref`, and `POST /grounding/check` verifies cited refs exist in the workspace, every figure is in a cited source, and inferred values are labelled. Every PA chat answer goes through this check; a failing answer is withheld. | `property_pa/grounding.lua` |
| Timeline | Interactions, events, offers, next actions and changes, newest first, per opportunity or person. Inbound text is stored as data and never acted on. | `property_pa/interactions.lua` |
| Next actions | Property Deals tasks (kanban underneath) with owner, due time and a required reason. | `property_pa/actions.lua` |
| Knowledge | Versioned and approved. Scope is company / team / personal. Anyone (or the PA, flagged) proposes. A manager approves company and team rules; the owner approves personal ones. Approving supersedes the old version. The **first seller playbook** (10 rules) is seeded as approved v1. | `property_pa/knowledge.lua`, `property_pa/seed/seller_playbook.lua` |
| Audit (P10) | `GET /audit` and `GET /history/:table/:id` show each AI change: source, model, prompt version, run, interaction, approver. PA chat runs are `property_deals_agent_runs` rows (one audit table for every agent) with JobShout's model and prompt version. | `api/pa.lua`, `property_pa/bridge.lua` |
| Handoffs | Question, context and PA recommendation go to a manager. The reply becomes a `pa_decisions` row and a note on the deal's timeline (scene 5, part of P08). | `api/pa.lua` |
| PA chat | `POST /ask` starts a JobShout run with role context (`seller_agent` / `manager`) and the mode skill. There is one JobShout task per person and role, with a new run per turn. The result arrives by signed webhook (`POST /public/jobshout/events`) or by polling `GET /ask/:id`. The `pa_output` block is parsed and grounding-checked before it is shown. | `property_pa/bridge.lua`, `api/ask.lua` |
| Fixtures | The How It Works cast: Sophie, Ashley, Sarah / 22 Station Road, Michael, Rick, 7 more sellers, and James the buyer. All fake. Reset with one call or `scripts/reset-demo.sh`; only rows tagged as fixtures are touched. | `property_pa/fixtures.lua` |
| Docs | Every route is in `/openapi.json` / Swagger with typed schemas. | `api/openapi.lua` |

Roles: `POST /setup` adds PA permissions to the Property Deals roles. `pd_agent` (the JobShout service
account) can read, capture, hand off and propose knowledge, but **can never confirm** a proposed update.

## JobShout (`feat/property-pa-agents`, not yet a PR)

- Seller PA and Manager PA (prompts `seller-pa@1.1.0` / `manager-pa@1.1.0`), mode skills, installed with
  `POST /property-pa/install`.
- `opsapi_get` / `opsapi_post` tools call OpsAPI with a per-org `opsk_` key. Writes are limited to `captures`,
  `handoffs`, `knowledge` and `grounding/check`.
- Output contract `property-pa.output.v1`.
- Run webhooks carry model and prompt version.

## Connecting a workspace

1. **JobShout:** `POST /property-pa/install` (org admin). Note the two agent ids. Create a `jsk_` API key
   (scopes: runs, approvals, agents:read, knowledge). Add an `opsapi` integration holding the workspace's
   `opsk_` key, created for a user with the `pd_agent` role.
2. **OpsAPI:** add a JobShout link under Workspace → AI providers (`provider_type` jobshout, `base_url`
   `…/api/v1`, username = any label, secret = the `jsk_` key).
3. **OpsAPI:** Workspace → Plugins → Property PA settings: the link id, project id, both agent ids, and the
   webhook secret.
4. **JobShout:** `POST /webhook-endpoints` pointing at
   `https://<opsapi>/api/v2/property-pa/public/jobshout/events` for `run.completed` and `run.failed`, with
   the same secret.
5. `POST /api/v2/property-pa/setup`, then optionally `POST /api/v2/property-pa/demo/reset`.

## Tests

`projects/property-pa/spec/pa_brain_test.py` runs in the Property Deals sandbox
(`ONLY=pa_brain_test projects/property-deals/spec/run.sh`):
- knowledge versioning and approval;
- fixtures reset;
- the scene 3 voice-note capture (5 proposals; confirm, correct, P09 inferred £225k);
- P05 refusals at capture and in answers;
- P10 audit;
- P11 history;
- timeline;
- inbound text treated as data;
- handoff;
- PA chat via the JobShout mock (grounded answer shown; invented figure, made-up source or missing contract withheld; signed and replayed webhooks; Manager PA gating);
- tenancy;
- OpenAPI coverage.

The full Property Deals regression still passes.

## Open (carried to Week 2 or later)

- **Real model run.** Everything above runs against the mock. Pointing it at the private model
  (qwen3.8 on the shared Mac, 2–6 min per answer) is a demo-day step. A dedicated GPU is still needed for
  usable speed.
- **Screens.** Week 1 is back end only. The capture confirm sheet, timeline and Today come in Weeks 2–3.
- **Proposals idempotency.** `opsapi_post` sends no `Idempotency-Key` yet, though OpsAPI honours one on
  `POST /captures`. Add it in JobShout.
- **JobShout key exposure.** Integration credentials, including the `opsk_` key, are stored unencrypted and
  returned by `GET /integrations`. They must be sealed and masked before production (with
  `SECRETS_ENCRYPTION_KEY`).
- **Knowledge sync.** Approved company rules aren't yet pushed to JobShout's
  `PUT /agents/{id}/knowledge/external/{key}`. The agents read them live from `GET /knowledge` instead.
- **Model used.** A run records the requested model, not the one an org's fallback chain actually used
  (JobShout follow-up).
