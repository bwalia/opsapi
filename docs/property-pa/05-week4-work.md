# Property PA — Week 4 "Work": what was built

Scope (SUPPLIER-RESPONSE.md): Manager Today and handoffs, GHL + Outlook basics, measurement, and hardening for one
real agent. Tests:

| Test | What it checks |
|---|---|
| P08 | The handoff reaches Ashley; his reply returns to the deal |
| P10 | The AI change history and metrics a manager needs |
| P12 | The plain CRM screens work with the AI off |

## OpsAPI (`projects/property-pa`)

**Manager Today** (`GET /manager/today`, managers only) shows exceptions only:
- handoff decision cards (question, context, the PA's recommendation);
- unusual negotiations (an offer waiting; our position 10%+ below the seller's minimum);
- relationship risks (hot or warm, with 14+ quiet days);
- overdue next actions, red deals, and the top opportunities.

It ends with: "N need you. Everything else (M) is being handled."

**Handoffs (P08):** the reply closes the card, becomes a decision record and a note on the deal's timeline, and
appears in the agent's next **Prepare me** under "manager replies", with its source.

**Metrics** (`GET /metrics?days=30`, managers only):
- **Capture accuracy as people judged it:** accepted as proposed, corrected, rejected, and time to confirm.
- **Answers:** grounded vs withheld, failed, and p50/p90 answer time.
- **Follow-through:** open, overdue and done next actions, and opportunities gone quiet.
- **Handoffs:** waiting, and median time to reply.

**Outlook (and Gmail / IMAP).** Property Deals' mail connectors already sync inboxes (Microsoft Graph for Outlook).
The PA puts each email from a person with an open opportunity onto that opportunity's timeline. It runs every 5
minutes (`jobs/mail_import.lua`) and can be run now with `POST /integrations/mail/import`. The text is stored as data:
an instruction inside an email changes nothing.
- **Each message is imported once,** even when the job and a manual import run at the same moment: the message id is
  claimed in `pa_external_refs` (unique per workspace) in the same transaction as the import.
- A message whose opportunity has no owner (or that can't be imported) is marked as seen, so it never holds up newer
  mail.

**GoHighLevel** (LeadConnector v2, private integration token, read only):
- contacts are pulled by `jobs/ghl_sync.lua`, every 15 minutes: it carries on a pull under way or starts the hourly one.
  `POST /integrations/ghl/sync` asks for one now and answers **202** (the pull runs in the background; the reply has the
  previous pull's summary). A location with more than 2,000 contacts is pulled over several runs: the cursor is saved
  in `pa_sync_state`.
- **Webhook:** `POST /api/v2/property-pa/public/ghl/<workspace slug>/contacts`, for a GHL workflow's webhook action or
  an app's ContactCreate / ContactUpdate events. The caller sends the workspace's `ghl_webhook_secret` (a secret PA
  setting) as `X-Webhook-Secret`; it is refused while the secret is unset, answers 404 while the PA is off in that
  workspace, and is limited to 120 calls a minute per IP.
- People are matched on the GHL id, then email, then phone (stored as E.164; UK numbers without +44 are read as UK).
  The same contact arriving twice at once becomes one person.
- GHL's do-not-disturb flag records an **opt-out**, and a `consent_basis` the webhook sends is kept (see Consent).
- every change is recorded as an `integration` fact;
- the token and the webhook secret are secret settings and are never returned.
- `GHL_API_URL` can point at a proxy; it must be https unless `OPSAPI_INTEGRATIONS_ALLOW_PRIVATE=true`.

**Consent.** Each person can have a consent basis (consent, contract, legitimate interests, legal obligation) and an
opt-out (`pa_consent`; `PUT /people/:id/consent`, shown on `GET /people/:id`). The PA never proposes contacting someone
who opted out: such a next action is refused at capture and at confirm, and their Today card says "Don't contact".
An integration can record an opt-out but never lift one; only a person can.

**Hardening for one real agent:**
- **Limits:** 3 PA questions in flight per person and 60 an hour (429 with the reason). Every finished run is one
  `ai_usage` row (feature `property_pa`), so the AI usage page shows PA runs and `AI_USER_DAILY_TOKEN_LIMIT` applies.
- **Who may make the PA write:** the agent writes as the `pd_agent` service account, so modes that write (capture,
  handoff, teach) need the asker's own `.create` on that module; read-only members can only ask. The checked mode and
  ids always win over `inputs`.
- **Deciding once:** a proposed update or a handoff card is locked while it is decided; a second confirm or reply at
  the same moment gets 409 (no duplicate offers, events, tasks or decisions).
- **Errors:** JobShout's and GoHighLevel's own error text is logged, never shown.
- **Retention:** `retention_text_days` (default 365): a nightly job removes the words of older notes, transcripts and
  imported emails; the interaction stays.
- **Demo data:** `/demo/reset` and `DELETE /demo` are for platform admins only (404 for everyone else), and only delete
  fixture rows: a fixture that real work points at is kept as an ordinary record.
- **Property Deals:** the PA needs it installed (else the PA switches itself off) and on in the workspace (setup, next
  actions and mail import answer 409 / do nothing while it is off, and the checklist says so).
- **Stuck runs:** the `jobs/pa_runs.lua` sweep polls runs whose webhook hasn't arrived and fails runs stuck for
  30 minutes, with the reason shown. `POST /runs/sweep` runs it now.
- **Idempotency:** JobShout's `opsapi_post` sends an `Idempotency-Key`, so a repeated write is stored once.
- **Go-live checklist:** `GET /status` covers the playbook, JobShout link, both agent ids, webhook secret and speech
  server, plus optional mail and GHL.

## Screens

- **Manager today:** decision cards ([Agree] [Reply] [Open deal]) and the exception lists.
- **Opportunity page → Ask my manager:** pick the manager, ask the question, add a recommendation; the deal's facts
  go with it.
- **PA insights:** metrics tiles, the go-live checklist, "import email now" and "sync GoHighLevel now", and the AI
  change history table (P10: value, model and prompt version, who confirmed it, current or replaced).

## Tests

`pa_week4_test.py` covers:
- **P08:** card to Ashley, his reply to the timeline and the next brief.
- **Manager Today:** exceptions, managers only.
- **Metrics:** 50% accepted / 50% corrected, 1 grounded and 1 withheld.
- **Outlook:** imported once, and the injection in it is ignored.
- **GHL:** create, update with history, no changes on a second pull, token never returned.
- **Limits:** a 429 on the 4th question in flight.
- **Sweep:** the timed-out run fails with its reason.
- **Checklist:** ready / not ready.
- **P12:** with the AI off, Today, Prepare, Coach, records, history, notes, hand edits and next actions all work;
  with the PA plugin off, CRM contacts and Property Deals work; turning it back on loses nothing.

The full regression passes: 15 suites, 1,356 checks.

## Review fixes (October 2026) and what is still open

Built: everything above marked as review fixes (demo for platform admins, upstream errors hidden, AI metering and the
daily limit, write modes, decide-once, batched Today ranking and the missing indexes, import-once for mail and GHL,
background GHL pulls with a cursor, text retention, the Property Deals dependency, RBAC-audited setup grants,
checked interaction ids, the webhook off switch, `/audit` for managers, the GHL webhook, consent). `pa_risks` and
`pa_outcomes` were dropped while empty: Manager Today computes risks live, and stored risks and outcomes come back
with risk detection and learning (month 3).

Still open, needing work outside OpsAPI:
- **JobShout agents** (`feat/property-pa-agents`, not yet a PR): the Seller / Manager PA prompts and skills. JobShout
  still stores the workspace's `opsk_` key unencrypted and returns it from `GET /integrations`; it must be sealed and
  masked first. JobShout's `opsapi_post` should also refuse writes the asking person couldn't make (OpsAPI only gates
  the mode).
- **Outlook draft replies:** need Microsoft Graph `Mail.ReadWrite` consent on the tenant.
- **Knowledge embeddings** (pgvector sync of approved rules): needs a decision on the embedding model.
- **Speech-to-text gating** is being fixed in core (`/api/v2/voice`), not in the plugin.
