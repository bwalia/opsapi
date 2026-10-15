# Build prompt: ATS and AI first-round interviews (OpsAPI module `ats`)

Build an **applicant tracking system (ATS)** in OpsAPI, with **hosted AI first-round
interviews** built in.

- **Recruiters** manage jobs, candidates and the hiring pipeline in the dashboard.
- **Interview kits:** recruiters turn a job description into a structured interview
  kit and invite candidates.
- **Candidates** do the interview in a browser at `/i/<token>`, with no account.
- **An AI interviewer** asks every candidate the same questions in the same order,
  and follows up on their answers.
- **An evaluator** turns each transcript into quoted evidence against the kit's
  rubric.
- **A person makes every decision.**

The module is paid: a namespace's payment **activates** it, and a lapsed payment
leaves the data readable and exportable, but stops new invitations.

This is the hosted side of **Snazzy Interview**. The Snazzy Pro Mac app runs the same
interviews locally without an OpsAPI account (snazzy repo,
`docs/plans/PROMPT_INTERVIEW.md`). Both sides share one contract:

| Contract | Source of truth (snazzy repo) | Copy in OpsAPI |
|---|---|---|
| Interview kit JSON (format 1, snake_case) | `docs/specs/fixtures/interview-kit.json` | `lapis/tests/ats/fixtures/interview-kit.json` |
| Interviewer, evaluator and kit-generator prompts | `Packages/SnazzyKit/Sources/Interview/Resources/prompts/*.v1.md` | `lapis/lib/ats/prompts/*.v1.md` (**byte-identical**; a change means a new `.v2.md` on both sides) |
| Engine behaviour (steps, follow-up limit, guards, time, pauses) | `Packages/SnazzyKit/Sources/Interview/InterviewEngine.swift` | `lapis/lib/ats/engine.lua` |
| Banned topics, quote check, redaction, evaluation combine | `KitValidator.swift`, `Evaluation.swift` | `lapis/lib/ats/topics.lua`, `evaluator.lua` |
| Notice hash (FNV-1a 64, hex) | `InterviewPrompts.hash` | `lapis/lib/ats/hash.lua` |

Read `docs/plans/PROMPT_INTERVIEW.md` §3 (law, fairness, safety) in the snazzy repo
before writing code. Those rules are product requirements here too.

---

## 0. Ground rules

- **Follow OpsAPI's module pattern** (`CLAUDE.md`):
  - migration → model/queries → routes;
  - feature-gated in `app.lua` and `migrations.lua`;
  - RBAC modules in `helper/project-config.lua`;
  - a dashboard service plus pages.

  It's a **core feature** named `ats`, not a `projects/` plugin, because plugins
  aren't deployed on k8s. It's in the `all` preset and is a feature-only code, so
  a deployment opts in with `PROJECT_CODE=tax_copilot,ats`.
- **No new third-party dependencies** (Lua rocks or npm) without approval.
- **Tenant isolation:** every table carries `namespace_id`, every query filters on
  it, and an id from another namespace is a 404.
- **A person decides.**
  - There is no automatic rejection, ranking-out or closing path.
  - Moving an application to `rejected` is its own endpoint, which needs a reason
    and records the user.
  - A decline email is sent only when a person presses send.
- **No emotion, face, voice-tone, typing-rhythm or personality analysis**, ever
  (EU AI Act Art. 5). Only the words of answers are assessed.
- **Secrets:** only in env/Vault. Candidate link tokens are 256-bit random values,
  and only their SHA-256 is stored; the link is shown once.
- **Commits:** DCO signed off. No real candidate data in fixtures.

---

## 1. Concepts

| Concept | Meaning |
|---|---|
| **Job** | A requisition: title, department, location, employment type, description, status (`draft`, `open`, `paused`, `closed`), hiring team |
| **Candidate** | A person, unique by email per namespace: name, email, phone, links, source, consent dates, tags |
| **Application** | A candidate on a job. Stage: `applied`, `screening`, `interview`, `review`, `offer`, `hired`, `rejected`, `withdrawn`. Stage history is in the audit log |
| **Kit** | A job's interview kit (shared contract): competencies with anchors for levels 1/3/5, eligibility questions, core questions, company facts, settings. Versioned; only an **approved** version runs interviews |
| **Interview** | One AI interview of one application: a snapshot of the kit, the link (hash plus expiry), state, transcript, flags, eligibility answers, evaluation, review |
| **Evaluation** | AI advice: quotes checked against the transcript, a suggested level or "not enough evidence", low-agreement marks. Never a decision |
| **Review** | The person's scorecard and decision (`advance`, `hold`, `decline`), with reason and note |
| **Self-ID** | Voluntary demographic answers, given after the interview. Stored apart, used only for aggregate fairness reports (groups of 10 or more) |
| **Activation** | Whether the namespace has paid for the module: `active` or `lapsed`, with source `stripe` or `manual` |

## 2. Data model (`migrations/ats-system.lua`, gated on `ats`)

Every table has `id BIGSERIAL`, `uuid TEXT UNIQUE`, `namespace_id` (FK, cascade),
`created_at` and `updated_at`.

| Table | Key columns |
|---|---|
| `ats_jobs` | `title`, `department`, `location`, `employment_type`, `description`, `status`, `kit_id`, `created_by_uuid`, `deleted_at` |
| `ats_candidates` | `name`, `email` (unique per namespace, lower), `phone`, `links` JSONB, `source`, `tags` JSONB, `notes_count`, `delete_after` |
| `ats_applications` | `job_id`, `candidate_id` (unique together), `stage`, `stage_changed_at`, `decision_reason`, `decided_by_uuid`, `decided_at` |
| `ats_notes` | `application_id` / `candidate_id`, `body`, `author_uuid` |
| `ats_attachments` | `candidate_id`, `name`, `content_type`, `size`, `object_key` (MinIO) |
| `ats_kits` | `job_id` (nullable), `title`, `kit` JSONB (the contract), `version`, `approved_at`, `approved_by` |
| `ats_interviews` | `application_id`, `kit_id`, `kit_version`, `source` (`hosted`, `snazzy_desktop`, `snazzy_file`), `external_id` (the app's session id, unique per namespace), `state`, `session` JSONB (the engine state: kit snapshot, turns, flags, eligibility answers, adjustments, forwarded questions, times, `rev`), `link_token_hash` (unique), `link_expires_at`, `started_at`, `ended_at`, `evaluation` JSONB, `evaluation_status`, `review` JSONB, `reviewed_at`, `self_id_key`, `delete_after` |
| `ats_self_id` | `key` (opaque, unique), `answers` JSONB. No FK to interviews |
| `ats_audit_log` | `actor_uuid` (or `candidate`/`engine`), `action`, `entity`, `entity_uuid`, `detail` JSONB |
| `ats_module_activations` | `namespace_id` (unique), `status`, `source`, `stripe_customer_id`, `stripe_subscription_id`, `activated_at`, `expires_at`, `lapsed_at` |
| `ats_settings` | `namespace_id` (unique): `retention_days`, `ratings_enabled`, `decline_reasons` JSONB, `legal_notice` (extra text for candidates), `interviews_per_month` |
| `ats_stripe_events` | `event_id` (unique), for webhook idempotency |
| `ats_integration_tokens` | `name`, `token_hash` (SHA-256, unique), `token_prefix`, `created_by_uuid`, `last_used_at`, `revoked_at`: tokens for the Snazzy Pro desktop app |

The tables don't depend on the tax/billing tables, so `ats` works with any preset.

## 3. Engine, prompts and evaluation (pure Lua in `lib/ats/`)

- **`engine.lua`** ports `InterviewEngine.swift`:
  - The plan is eligibility questions, then core questions in kit order, then the
    candidate's questions, then closing.
  - **The engine asks every question verbatim.** The model only returns JSON
    `{action, say, enough_evidence, flags}`.
  - Actions: `follow_up` (at most `max_follow_ups` per core question, and only when
    more than 60 s remain), `move_on`, `rephrase`, `answer`, `forward`, `done`.
  - Guards on what the model says:
    - sentences with praise or ratings are dropped;
    - a follow-up must contain `?` and no banned topic;
    - an acknowledgement contains no `?`;
    - anything unusable becomes "Thank you." and the engine moves on.
  - Time:
    - the limit is `minutes`, ×1.5 when the candidate asked for extra time;
    - pauses don't count;
    - when time runs out mid-question, the interview closes and is flagged `time_up`.
  - "Speak to a person" ends the interview kindly (`human_requested`). Withdrawing
    ends it (`withdrawn`).
  - Banned topics in an answer are flagged. A pasted answer is flagged (information
    only).
- **`evaluator.lua`:**
  - Builds the transcript: the candidate's name becomes `[candidate]`, protected
    sentences become `[redacted]`, and candidate turns are wrapped in
    `<external_data>`.
  - Runs the evaluator **twice**.
  - Keeps only **verbatim** quotes from candidate turns. Normalisation: case,
    curly quotes, whitespace, and trailing `"' .,…`.
  - No evidence means no level. Runs more than one level apart are marked
    `agreed = false`.
  - Ratings-off (NYC LL144 mode) keeps evidence only.
- **`validator.lua`** ports `KitValidator`. Approval is blocked by:
  - banned topics in questions;
  - salary history;
  - a competency without a question or without anchors;
  - duplicate ids.

  A criminal-record question needs `Legal basis for criminal record question:` in
  the company facts.
- **Answers to candidates' questions** come only from the kit's company facts.
  - An `answer` is given only when at least 60% of its meaningful words (four or
    more characters, not stop words) appear in the company facts.
  - Otherwise the question is forwarded to the team and flagged `other`.
  - At most 3 candidate questions, then the interview closes.
- **Concurrency:** each save bumps `session.rev` and only lands if `rev` is
  unchanged, so two tabs can't interleave answers.
- **`llm.lua`:** Anthropic Messages API.
  - Models: `ATS_INTERVIEWER_MODEL` (default `claude-sonnet-5-5`) and
    `ATS_EVALUATOR_MODEL` (default `claude-opus-5-5`); `anthropic-version: 2023-06-01`.
  - TLS verified, timeouts set, no retry on 4xx.
  - Without `ANTHROPIC_API_KEY` it falls back to Ollama through `lib/llm-client.lua`,
    and the interview records which model ran.

## 4. API

**Recruiter API**, under `/api/v2/ats/…`:
- Auth + namespace + `requirePermission(module, action)`.
- RBAC modules: `ats_jobs`, `ats_candidates`, `ats_interviews`, `ats_kits`,
  `ats_reports`, `ats_settings`.
- Responses use `{success, data, meta}`.

| Method and path | Does |
|---|---|
| `GET /api/v2/ats/overview` | Counts by stage, interviews awaiting review, activation status |
| `GET/POST /api/v2/ats/jobs`, `GET/PUT/DELETE /api/v2/ats/jobs/:uuid` | Jobs |
| `GET /api/v2/ats/jobs/:uuid/pipeline` | Applications grouped by stage (kanban) |
| `GET/POST /api/v2/ats/candidates`, `GET/PUT/DELETE /api/v2/ats/candidates/:uuid` | Candidates. DELETE is a real delete (interviews, notes, files, self-ID) plus an audit entry |
| `GET /api/v2/ats/candidates/:uuid/export` | Everything held about a candidate, as JSON (subject access) |
| `POST /api/v2/ats/applications` | Put a candidate on a job |
| `POST /api/v2/ats/applications/:uuid/stage` | Move to any stage except `rejected` |
| `POST /api/v2/ats/applications/:uuid/reject` | **A person's** rejection: `reason` required |
| `GET/POST /api/v2/ats/applications/:uuid/notes` | Notes |
| `GET/POST /api/v2/ats/kits`, `GET/PUT/DELETE /api/v2/ats/kits/:uuid` | Kits. An edit clears approval |
| `POST /api/v2/ats/kits/generate` | `{job_description, language}` → a draft kit from the generator prompt |
| `GET /api/v2/ats/kits/:uuid/validate`, `POST /api/v2/ats/kits/:uuid/approve` | Validator issues; approve (blocked by errors) |
| `POST /api/v2/ats/interviews` | Invite `{application_uuid, kit_uuid, expires_in_days}` → returns the link **once**. Needs activation |
| `GET /api/v2/ats/interviews`, `GET /api/v2/ats/interviews/:uuid` | List; detail with transcript, flags, evaluation, review |
| `POST /api/v2/ats/interviews/:uuid/evaluate` | Run (or re-run) the evaluator in the background |
| `POST /api/v2/ats/interviews/:uuid/review` | The person's levels, decision, reason and note. `decline` doesn't email anyone |
| `POST /api/v2/ats/interviews/:uuid/revoke` | Revoke the link |
| `GET /api/v2/ats/reports/fairness?job_uuid=&question=` | Advance rates and impact ratios by self-ID group (groups ≥ 10, warning below 0.8) |
| `GET /api/v2/ats/audit?entity_uuid=` | Audit log |
| `GET/PUT /api/v2/ats/settings` | Retention, ratings on/off, decline reasons, legal notice |
| `GET /api/v2/ats/activation`, `POST /api/v2/ats/activation/checkout` | Status; a Stripe Checkout session for `ATS_STRIPE_PRICE_ID` |
| `POST /api/v2/ats/admin/activation` | Platform admin: activate or lapse a namespace by hand |
| `POST /api/v2/ats/admin/purge` | Platform admin: run the retention purge now |

**Public API**, under `/api/v2/public/ats/…`:
- OpsAPI's global filter treats `/api/v2/<code>/public/…` as public only for
  registered plugins, so core public routes live under `/api/v2/public/`.
- There's no auth: core public routes must live under `/api/v2/public/`.
- Rate-limited per IP and per token.
- The namespace comes from the interview row, never from the client.

| Method and path | Does |
|---|---|
| `GET /api/v2/public/ats/interviews/:token` | The candidate's view: notice text and hash, role title, organisation, state, the visible turns, current choices, progress, seconds left. Expired → 410, unknown → 404 |
| `POST …/:token/start` | `{notice_hash, adjustments[]}`; checks the hash, then starts |
| `POST …/:token/answer` | `{text, input: typed\|spoken\|pasted}` (≤ 6000 chars). Runs the model when the engine asks |
| `POST …/:token/event` | `{type: repeat\|rephrase\|pause\|resume\|person\|withdraw\|adjustment, text?}` |
| `POST …/:token/self-id` | Voluntary answers, after the interview only |
| `POST /api/v2/public/ats/billing/webhook` | Stripe events (signature verified, idempotent) → activation |
| `GET /api/v2/public/ats/integration/ping` | Snazzy Pro: `{namespace, active, dashboard_url}` for its token |
| `GET /api/v2/public/ats/integration/kits` | Snazzy Pro: approved kits, as the app's RoleKit JSON |
| `POST /api/v2/public/ats/integration/interviews` | Snazzy Pro: an interview run in the app (see §6a) |

The recruiter API also has `POST /api/v2/ats/interviews/import` (a
`.snazzy_interview` file, see §6a) and `GET/POST /api/v2/ats/settings/tokens`,
`DELETE /api/v2/ats/settings/tokens/:uuid` (needs `ats_settings` manage).

## 5. Dashboard (UI/UX)

Section **Hiring** in the sidebar (backend-driven menu), with pages under
`app/dashboard/ats/`:

| Page | Layout and purpose |
|---|---|
| **Overview** `/dashboard/ats` | Cards: open jobs, candidates in each stage, interviews waiting for review. An activation banner when inactive, with "Activate" (checkout). |
| **Jobs** `/dashboard/ats/jobs` | Table (title, status, candidates, interviews to review) and "New job". |
| **Job** `/dashboard/ats/jobs/[uuid]` | Header with status. Tabs: **Pipeline** (kanban, one column per stage; moving a card calls `stage`; the Rejected column only accepts a move through the reject dialog, which asks for a reason), **Kit** (linked kit, open the editor), **Details**. "Add candidate" and "Invite to interview" per card. |
| **Candidates** `/dashboard/ats/candidates` | Search and table. **Profile** `/dashboard/ats/candidates/[uuid]`: contact details, applications with stages, interviews, notes, files, "Export data", "Delete candidate" (with confirmation). |
| **Kits** `/dashboard/ats/kits` | List. **"Generate from a job description"**: paste a description → draft. **Editor** `/dashboard/ats/kits/[uuid]`: title, summary, competencies (anchors for levels 1/3/5, weight), eligibility questions, core questions (each linked to a competency), company facts and settings. Validator issues show in a side panel (errors block **Approve**). The generator's warnings about the job description are shown at the top. |
| **Interviews** `/dashboard/ats/interviews` | Table: candidate, job, state, flags, evaluation status, decision. |
| **Review** `/dashboard/ats/interviews/[uuid]` | Left: the transcript; quotes are highlighted and link to their turn. Right: one card per competency with the evidence quotes, **"AI suggestion: level N"** (clearly labelled, with a low-agreement badge), the reason, "probe next", and the **reviewer's own level** control. Also: flags, eligibility answers as given (with "meets requirement" from the kit), questions forwarded to the team. Bottom: **Decision** (advance/hold/decline) with a reason picker and note. Decline never sends anything; "Send decline email" is a separate button. |
| **Reports** `/dashboard/ats/reports` | Fairness: per job and question, rows per group with rate, impact ratio and a warning below 0.8; suppressed groups counted. Export as CSV for a bias audit. |
| **Settings** `/dashboard/ats/settings` | Activation status and checkout, retention days, ratings on/off ("Evidence only (NYC Local Law 144)"), decline reasons, extra legal notice for candidates. |

**Candidate page** `/i/[token]`:
- No login, mobile first.
- **WCAG 2.2 AA:** keyboard only, visible focus, labels, `aria-live` for new
  questions, zoom to 200%, high-contrast and large-text toggles.
- Steps:
  1. **Notice**: AI, person decides, what's not analysed, data, retention, rights.
  2. **Adjustments**: checkboxes plus "something else", and "I'd prefer to speak to
     a person".
  3. **Practice question**: not assessed.
  4. **Interview**: one question at a time, a progress bar and time left; Repeat,
     Rephrase, Pause and "Speak to a person" buttons; a text box (pasting is allowed
     and noted).
  5. **Your questions.**
  6. **Thank you**, with next steps.
  7. **Optional self-ID**: clearly voluntary, with "prefer not to say".

## 6. Payment activation

- `POST /api/v2/ats/activation/checkout` creates a Stripe Checkout session:
  - `mode=subscription`, price `ATS_STRIPE_PRICE_ID`;
  - metadata `{namespace_uuid, module: "ats"}`;
  - success/cancel URLs from `ATS_DASHBOARD_URL`.
- The webhook `POST /api/v2/public/ats/billing/webhook`:
  - verifies the signature with `ATS_STRIPE_WEBHOOK_SECRET` (falling back to
    `STRIPE_WEBHOOK_SECRET`) and dedupes on `ats_stripe_events`;
  - `checkout.session.completed` / `invoice.paid` → `active`, with the subscription
    period end in `expires_at`;
  - `customer.subscription.deleted` → `lapsed`;
  - `invoice.payment_failed` → `lapsed` after `ATS_PAST_DUE_GRACE_DAYS` (default 7).
- `requireAtsActive` gates new invitations and starting an interview.
  - Reading, reviewing, exporting and deleting always work.
  - An interview already started is allowed to finish.
- Platform admins can activate by hand (`source = manual`), for trials and invoices.

## 6a. Desktop integration (Snazzy Pro)

Snazzy Pro on the Mac runs **Auto Interviews** itself, and keeps working
offline: a deck, spoken questions and on-device speech. It sends each result
here as soon as it can, or saves it as a file.

**Tokens:**
- **Hiring › Settings › Snazzy Pro app** creates a token. It is
  `snz_` + 256 random bits, shown once; only its SHA-256 is stored.
- Each token can be revoked, and its last use is shown.
- A token can only read approved kits and send interviews.
- The app sends `Authorization: Bearer snz_…`. The server looks the token up
  by hash and compares it in constant time.
- Rate limits: 120 requests a minute per IP and 600 per token. 20 bad tokens
  from one IP lock that IP out for 15 minutes.

**Interview payload:** the app's `InterviewSession` JSON (snake_case, as
`InterviewSession.swift`):
- `id`, `kit` (a RoleKit), `candidate {name, email, reference}`, `channel`, `state`;
- `turns`, `flags`, `eligibility_answers`, `adjustments`;
- `notice_hash`, `notice_accepted_at`, `started_at`, `ended_at`, `end_reason`;
- `models`, `evaluation`, `review`, `audit`, `created`, `delete_after`.

There is no `link_token_hash`. The maximum size is 1 MB, and no media is sent.

**`.snazzy_interview` files:** when OpsAPI isn't connected, the app saves

```json
{"format": "snazzy-interview", "version": 1, "exported_at": "<ISO 8601>",
 "app": "Snazzy Pro <version>", "interview": <InterviewSession>}
```

The integration endpoint accepts this wrapper as well as a bare session. The
**Interviews** page has "Import .snazzy_interview files" (several at once),
which posts each file to `POST /api/v2/ats/interviews/import`. The server
rejects a file with:
- the wrong `format`;
- a `version` other than 1;
- more than 1 MB.

**Upsert** (`AtsInterviewQueries.import`, shared by both paths):
1. **Kit:** the snapshot is stored as a kit version keyed by the app's kit id
   and version (`source = snazzy_desktop`).
2. **Job:** matched by the kit's id, else by the kit's title, else created.
3. **Candidate:** matched by email, else by name + reference, else created.
4. **Application:** created in stage `review` if new.
5. **Interview:** keyed by `(namespace, external_id = session id)`, so posting
   the same interview again updates it rather than duplicating it. The
   transcript is replaced only when it has at least as many turns. The
   evaluation and review are replaced only when theirs is newer.

**Rules for desktop data:**
- **Everything in the payload is untrusted.** Only known fields and values are
  kept, sizes are capped, and every evaluation quote is checked against the
  transcript again.
- **A decision is recorded only if `review.decision` is present.** It was made
  by a person in the app; it is recorded with the reviewer's name
  "(via Snazzy Pro)". A `decline` moves the application to `rejected` through
  the same person-only reject function.
- **Writes need the module active.** When it has lapsed, the API returns 402
  with a clear message.

The response is `{interview_uuid, application_uuid, candidate_uuid, job_uuid,
created, dashboard_url}`.

## 7. Retention and deletion

- Each interview gets `delete_after` = end + `retention_days` (default 180).
- A worker-0 job runs daily with an advisory lock (`lib/ats/retention.lua`). It
  deletes expired interviews and their self-ID rows, and candidates with nothing
  left whose own `delete_after` has passed. Each deletion is audited (who/what,
  no content).
- Deleting a candidate removes interviews, notes, files (MinIO objects) and
  self-ID immediately.

## 8. Phases

1. **Backend core:** migration, engine, validator, evaluator, prompts, tests.
2. **Recruiter API and candidate API**, activation, retention.
3. **Dashboard:** jobs, pipeline, candidates, kits, interviews/review, settings,
   reports; the candidate page.
4. **Emails:** invitation and reminder emails, decline template (sent by a person),
   through `helper/mail.lua`.
5. **Voice:** server-side speech-to-text and text-to-speech behind a provider
   interface, plus captions.
6. **Integrations:** importing candidates from other ATSs, and the Snazzy Pro app
   (sign in and pull hosted interviews into the Mac console).

## 9. Acceptance checks

- The Lua tests (`resty -I lapis lapis/tests/ats/run.lua`) pass. They mirror the
  snazzy `InterviewTests`: the same kit fixture, the same expectations, and the same
  notice hash for the same text.
- No route rejects or advances a candidate without a person's request (a code
  search for writes of `stage = 'rejected'` finds only the reject endpoint).
- A candidate from namespace A can't be read, changed or invited from namespace B
  (404).
- A link token works only until it expires; an unknown token is 404 and an expired
  one 410. Only its hash is in the database.
- An inactive namespace can't invite, but can read and export.
- Every quote shown on the review page exists verbatim in a candidate turn.
- Deleting a candidate leaves only the audit entry.
- The candidate page passes keyboard-only and screen-reader checks.

## 10. Out of scope for now

- Automatic ranking, shortlisting or CV screening.
- Video or voice analysis beyond transcription.
- Technical or coding tests.
- Job board posting and careers pages (a later phase; Forms can collect
  applications meanwhile).
