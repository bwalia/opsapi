# Supplier response — how we build it (DRAFT)

> **DRAFT, rebuilt by us** from the build prompt and the Phase 0 gap map, while the exported response
> document is not in the repo. Replace with the exported version when it arrives.

## Architecture
- **OpsAPI** is the system of record and the place work is organised.
  - It holds people, properties, opportunities, deals, interactions, tasks and knowledge records.
  - Projects, boards and teams there combine humans and AI agents.
  - It owns the PA screens (WSL CRM dashboard), the speech-to-text plumbing, the priority rules engine, the fact/inference store and the audit.
- **JobShout** runs every agent (Seller PA, Manager PA, capture/extraction, coach, Teach PA).
  - It owns role prompts, tool allowlists, approvals, the run log, knowledge retrieval and **all model routing** to the private UK GPU (OpenAI-compatible, swappable by config).
  - Its agents act on OpsAPI only through OpsAPI's API, as a service account, with the workspace's permissions.
- **Private AI:**
  - `PA_LLM_BASE_URL` / `PA_LLM_MODEL` are set in JobShout's per-org model routing.
  - `PA_STT_URL` is set in OpsAPI (`/api/v2/voice`).
  - Development uses fake data and a self-hosted stand-in (the LAN Mac's Ollama + Speaches).

## Component mapping
See `00-gap-map.md` §2 (data) and §3 (components). In short:
- **Reuse:** CRM, tasks/boards, approvals, agent run log, voice, playbook, urgency engine.
- **New tables (11):** opportunity, event, offer, relationship, risk, versioned knowledge, decision, outcome, proposed update, handoff, field facts.

## 4-week plan

| Week | Build | Tests |
|---|---|---|
| 0 | JobShout fixes (approvals, per-org routing, tenant isolation, API keys, webhooks, role context); private endpoint wired; fixtures; baseline logging | — |
| 1 — Brain | Data model; interaction timeline; PA chat (JobShout Seller PA); first seller playbook; audit | P05, P10 (part) |
| 2 — Capture | Voice/text capture; extraction; confirm and correct; next actions | P03, P04, P09, P11 |
| 3 — Think | Today; Prepare Me; next-best action; explainable scoring; playbook retrieval; Teach PA | P01, P02, P06, P07 |
| 4 — Work | Manager Today and handoffs; GHL + Outlook basics; measurement; hardening for one real agent | P08, P10, P12 |

## PoC checklist (done when)
- [ ] P01–P12 pass on fixture data; real cases in week 4.
- [ ] No public LLM has seen real data; the model is swapped by config.
- [ ] `docs/property-pa/` has: gap map, data model (Mermaid), priority signals and weights, prompt catalogue with versions, knowledge format, test results, demo script.
- [ ] One-command demo reset; the weekly demo (Mon 10:15) shows only what is built, with mocks marked.
- [ ] Open questions and exclusions listed.
