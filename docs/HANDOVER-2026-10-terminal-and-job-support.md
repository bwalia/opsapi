# Handover — AI task terminal bridge + JobShout Job Support

**Date:** 19–20 Oct 2026  
**Audience:** next developer picking up deploy / verification / follow-ons  
**Status:** All four PRs below are **merged**. Rings may still need image rollout via Ring Promoter.

---

## What shipped (four PRs)

| # | Repo | PR | What |
|---|------|-----|------|
| 1 | opsapi | https://github.com/bwalia/opsapi/pull/765 | AI-runner web terminal sessions + GitHub PR status polling into task comments |
| 2 | workstation-terminal | https://github.com/bwalia/workstation-terminal/pull/3 | OpsAPI task deep-link + HMAC webhook on session start/end |
| 3 | jobshout | https://github.com/bwalia/jobshout/pull/301 | Prod `www.jobshout.com` Insights → OpsAPI namespace `workstation` (int stays `jobshout`) |
| 4 | jobshout | https://github.com/bwalia/jobshout/pull/302 | Public **Job Support** chat dock: NebulaDB match + OpsAPI CRM identity |

---

## Part A — OpsAPI task ↔ workstation-terminal

### Intent
From an AI-runner task’s “AI work” UI, open a web terminal (sshweb), track sessions, post repo/PR links as task comments, accept manager review, and poll GitHub so open/merged/closed lands back on the task.

### Key code (opsapi)
- `projects/ai-runner/ai_runner/terminal.lua` — session create/list, HMAC webhook verify, comments
- `projects/ai-runner/ai_runner/pr_poll.lua` — throttled GitHub PR status → task comments
- `projects/ai-runner/api/terminal.lua`, updates in `api/runs.lua`
- Migration: `projects/ai-runner/migrations/20261017190000_ai_runner_terminal_sessions.lua`  
  Tables: `ar_terminal_sessions`, `ar_task_prs` (names as in migration)
- Dashboard: `opsapi-dashboard/components/ai-runner/TaskWork.tsx`, `services/ai-runner.service.ts`
- Docs: `docs/AI_RUNNER.md` (§ terminal / PR poll)
- Sample env: `lapis/.sample.env` (`TERMINAL_*` / webhook secret vars — follow sample)

### Key code (workstation-terminal)
- `src/opsapi.rs` — HMAC notify OpsAPI on start/end
- Session carries `opsapi_task`; browser query string can pass task/repo/return context
- Cookie note: SameSite=Strict → open terminal in a **new tab**, not iframe

### Deploy / config checklist
1. Run ai-runner project migration on the target OpsAPI ring.
2. Set terminal/webhook shared secret on **both** OpsAPI and sshweb (Vault preferred for deploy secrets; webhook HMAC is still env-driven on the app side).
3. Deploy workstation-terminal image that includes PR #3.
4. Smoke: TaskWork → Open web terminal → session row + comment; end session → webhook updates; manager review → PR poll reflects GitHub state.

### Tests
- `projects/ai-runner/spec/run.sh` / `ai_runner_test.py` cover launch, review comment, poll, webhook paths.

---

## Part B — JobShout.com Job Support bot

### Intent
Shop-style floating assistant on **int / test / acc / www.jobshout.com**:
- **Recruiters** → job brief → anonymised index in NebulaDB → match candidates  
- **Candidates** → CV / skills → anonymised index → match jobs  
- **Identity** (name, email, phone) → **OpsAPI CRM leads only**  
- **LLM / vectors** → cluster **NebulaDB → Ollama** — **not** Anthropic/OpenAI from the web pod  

Modelled on shop’s ChatDock UX (`workstation-website/shop`), but privacy and model path deliberately differ (shop uses Anthropic + OpsAPI shop chat-sessions).

### Key code (jobshout-com)
| Area | Path |
|------|------|
| Dock UI | `jobshout-com/web/nextjs/components/job-support/*` |
| Layout mount | `jobshout-com/web/nextjs/app/layout.tsx` |
| BFF SSE | `jobshout-com/web/nextjs/app/api/job-support/chat/route.ts` |
| Agent | `lib/job-support/agent.ts` |
| NebulaDB client | `lib/job-support/nebuladb.ts` — buckets `jobshout_jobs`, `jobshout_candidates` |
| PII redaction | `lib/job-support/pii.ts` — must run before any NebulaDB upsert |
| CRM | `lib/job-support/crm.ts` — `POST /api/v2/crm/leads`, `source=jobshout_job_support` |
| Helm | `jobshout-com/deploy/helm/jobshout-com/values-{int,test,acc,prod}.yaml` → `nebuladb.url` |
| Web env | `templates/web.yaml` → `NEBULA_URL` (+ optional `NEBULA_API_KEY`) |

### In-cluster NebulaDB URLs (already in values)
- int: `http://nebuladb.int.svc.cluster.local:8080`
- test: `http://nebuladb.test.svc.cluster.local:8080`
- acc: `http://nebuladb.acc.svc.cluster.local:8080`
- prod: `http://nebuladb.prod.svc.cluster.local:8080`

Public NebulaDB hosts (debug only): `int-nebuladb.nebuladb.net`, `showcase.nebuladb.net`, etc.

### OpsAPI CRM namespaces (JobShout Insights + Job Support)
| Ring | Site | `OPSAPI_NAMESPACE` |
|------|------|--------------------|
| int | int.jobshout.com | `jobshout` |
| prod | www.jobshout.com | `workstation` (no `jobshout` ns on prod OpsAPI) |

CRM writes use `OPSAPI_URL` + `OPSAPI_API_KEY` (Secret `jobshout-com-opsapi`) + `X-Namespace-Slug`.

**Permission check:** API key must be able to create CRM leads on that namespace. Prefer verifying with a test lead after deploy.

Optional cleaner public path (not used yet): `POST /api/v2/public/leads/:namespace_slug` — no key, IP rate-limited, 5‑min email dedupe. Current design is trusted BFF → authed CRM.

### Privacy rules (do not regress)
1. Never put email/phone/name into NebulaDB document text or metadata that is embedded.  
2. Never call public model APIs from `job-support/*`.  
3. Contact details → OpsAPI CRM only; matching corpus → NebulaDB only.  
4. Marketplace job copy is still redacted before index (`indexJob`).

### Deploy / smoke checklist
1. Ring Promoter (or helm) rolls `jobshout-com/web` image containing #302.  
2. Pod env shows `NEBULA_URL` and OpsAPI vars.  
3. Open site → bottom-right **Job Support**.  
4. `GET /api/job-support/chat` → `{ "enabled": true }`.  
5. Candidate path: paste skills/CV → status “Saving anonymised…” → matches; give email → CRM lead.  
6. Recruiter path: paste brief → match; contact → CRM.  
7. In NebulaDB admin/search: docs under `jobshout_*` have no raw emails.  
8. In OpsAPI CRM: lead with `source=jobshout_job_support`.

### Known ops caveat — embeddings
Deployed NebulaDB rings often still report **`mock-384`** embeddings (Ollama chat may work; embedder mock). Semantic match quality is then poor until:
- `NEBULA_OPENAI_*` (Ollama-compat) points at `nomic-embed-text` (or equivalent), and  
- indexes are wiped + reingested (dim change is a breaking reingest).

Job Support buckets are dedicated (`jobshout_jobs` / `jobshout_candidates`), but embedder is process-wide. Fix embeddings in NebulaDB helm/ops before promising match quality.

Talent Match demo in NebulaDB showcase (`TalentMatchTab`, buckets `talent_*`) is the UX/algorithm reference; production Job Support does **not** write into those demo buckets.

---

## Part C — JobShout Insights namespace (related)

PR #301 only changes prod helm: `opsapi.namespace: workstation` for www.  
Int remains `jobshout`. CMS Insights + `/hooks/opsapi` already wired; ensure webhook secret + API key in Vault/Secret stay in sync with OpsAPI.

---

## CI / runner note (jobshout)

Jobshout **PR image check** runs on a self-hosted Mac runner using Colima. Disk on `/dev/vdb1` filled during this work (`no space left on device`). If image check fails again: prune Colima Docker (`docker system prune`, `docker buildx prune`, builder recreate). Not an app bug.

---

## Suggested next work (not done)

1. Confirm Ring Promoter deployed #302 web to int → then test → acc → prod.  
2. Enable real NebulaDB embeddings + reingest strategy.  
3. Harden CRM: public lead upsert or shop-style session contact if API-key scopes are awkward.  
4. Richer match scoring (skills / rate facets) like NebulaDB Talent Match showcase — currently hybrid `/ai/search` + LLM grounded on hits.  
5. CV file upload → MinIO + CRM `metadata.cv` object key (today: pasted text only).  
6. Terminal: end-to-end verify on the ring that owns ai-runner + sshweb secrets.

---

## Quick file map

```
opsapi/
  projects/ai-runner/ai_runner/{terminal,pr_poll}.lua
  projects/ai-runner/api/terminal.lua
  projects/ai-runner/migrations/20261017190000_ai_runner_terminal_sessions.lua
  opsapi-dashboard/components/ai-runner/TaskWork.tsx
  docs/AI_RUNNER.md

workstation-terminal/
  src/opsapi.rs
  src/session/mod.rs, src/websocket/*, web/*

jobshout/
  jobshout-com/web/nextjs/lib/job-support/*
  jobshout-com/web/nextjs/components/job-support/*
  jobshout-com/web/nextjs/app/api/job-support/chat/route.ts
  jobshout-com/deploy/helm/jobshout-com/values-*.yaml
```

---

## Contacts / context

Built in Cursor session continuing from AI-runner terminal plan + JobShout↔OpsAPI CMS wiring. Vault holds OpsAPI API keys / webhook material for JobShout rings; do not commit secrets.
