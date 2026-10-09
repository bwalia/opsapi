# Agent catalogue

Agents draft; people decide. Each agent is a prompt, a fixed tool allowlist and a rule for what its
draft becomes (`projects/property-deals/property_deals/ai/agents.lua`). None of them can send, book, pay
or sign anything: the draft becomes an **approval**, and the executor
(`property_deals/ai/executor.lua`) acts only after a named person approves it (SPEC hard rule 6).

| Agent | Job type | Tools (read-only) | Draft becomes | Default rule | Phase |
|---|---|---|---|---|---|
| `legal_chaser` — Legal chaser | draft | get_deal_summary, list_open_enquiries, list_recent_chases, list_recent_emails, list_parties | `send_email` chase to the party who owes the most open enquiries, plus proposed enquiry updates (resolve / new); or `update_enquiries` alone | any_operator | 5 |
| `booking_agent` — Booking agent | plan | get_property, find_suppliers, get_deal_summary | `request_booking`: emails to the 2–3 nearest suitable suppliers asking for slots; bookings recorded `requested`. Confirming one is a second approval (`confirm_booking`) | any_operator | 5 |
| `digest_writer` — Daily digest writer | summarise | — | No approval: rewrites a person's own rules-based digest as a few sentences (`digest.prose`). The lists stay the source of truth | none | 5 |
| lead_triage, property_enrichment, offer_reasoning, buyer_matcher, document_checker, compliance_assistant, investor_update | | | | | 7 |

## How a run works

1. **Start:** "Let AI do it" (`POST /tasks/{id}/agent-run`), the agent's auto pickup time
   (`auto_pickup_at`), a template task marked `agent.auto`, or (legal chaser) a solicitor's reply
   arriving.
2. **Context:** the run is given what the task needs: the deal's stage, dates, open enquiries and recent
   chases. It gets no email addresses or phone numbers. Everything is placed in an
   `<untrusted_data>` fence that the system prompt declares to be data.
3. **Model:** the job type's chain from `/ai/routes` is tried in order (the fallback order).
   - `local_only` (per route or per agent) skips every provider not flagged `is_local`.
   - The platform's own fallback model is never used for workspace data.
4. **Tools:** the model may call only the tools on the agent's allowlist; a call to anything else is
   refused and logged in `steps` (`refused: true`). Tool results from email are fenced too. Models
   without tool calling get the same records in the prompt and answer in JSON (the plain-JSON fallback).
5. **Caps:**
   - Each run stops once it costs more than `ai_max_cost_run_usd`.
   - No new run starts once today's spend reaches `ai_max_cost_day_usd` (429).
   - Cost = tokens × the provider's `input/output_cost_per_mtok`.
6. **Draft → approval:**
   - The agent's JSON is checked in code.
   - Recipients come from the deal's parties or the supplier directory, never from the model.
   - Only enquiries that exist on the deal can be proposed as resolved.
   - The task goes to `awaiting_approval`.
7. **Decision:**
   - Approve (optionally edited) → the action runs, the approval becomes `executed` (or `failed` with the
     reason), and the task moves on.
   - Reject with a note → the task goes back to `todo`; the next run reads the note.
8. **Log:** every run keeps `prompt_version`, model, provider, tokens, cost, latency, tool calls, the
   output, and the reviewer's note it worked from (`GET /agent-runs/{id}`, `GET /ai/usage`).

## Prompt injection

The things a solicitor's email (or any inbound text) cannot do:
- **Call a tool the agent doesn't have.** The allowlist is enforced in code, and the refusal is logged.
- **Change a recipient.** Addresses are filled in by the server from the deal's parties.
- **Close a blocker by itself.** Enquiry changes are proposals inside the approval.
- **Escape the data fence.** `<untrusted_data` inside the text is escaped.

`spec/ai_test.py` sends an email that tells the agent to email an attacker. The agent's tool call is
refused, the draft still goes only to the solicitor, and nothing reaches the attacker.

## JobShout agents

Any agent can be routed to a JobShout agent instead of a built-in model (`PUT /ai/agents/{key}
{ route: "jobshout", jobshout_provider_uuid, jobshout_agent_id }`). See [jobshout.md](jobshout.md).
