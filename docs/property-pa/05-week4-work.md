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
The PA puts each email from a person with an open opportunity onto that opportunity's timeline. Each message is
imported once, it runs every 5 minutes (`jobs/mail_import.lua`) and can be run now with
`POST /integrations/mail/import`. The text is stored as data: an instruction inside an email changes nothing.

**GoHighLevel** (LeadConnector v2, private integration token, read only):
- contacts are pulled hourly (`jobs/ghl_sync.lua`) or on demand (`POST /integrations/ghl/sync`);
- they are matched on the GHL id, then email;
- every change is recorded as an `integration` fact;
- the token is a secret setting and is never returned.
- `GHL_API_URL` can point at a proxy; it must be https unless `OPSAPI_INTEGRATIONS_ALLOW_PRIVATE=true`.

**Hardening for one real agent:**
- **Limits:** 3 PA questions in flight per person and 60 an hour (429 with the reason).
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
