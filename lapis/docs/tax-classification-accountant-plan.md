# Plan: Profile-Aware, HMRC-Correct Tax Classification ("act as a UK accountant")

Status: PROPOSED (v2 — reworked to be diy-tax-return-uk-safe). For review before implementation.
Scope agreed: all six profiles · profile stored per-user · plan-first.

## Goal

Classify each bank transaction by the **user's actual business profile** (landlord,
sole trader, Amazon seller, IT contractor, construction, freelance developer),
guided by **HMRC rules**, so figures map cleanly onto the correct SA / MTD boxes
at filing time — **without breaking the diy-tax-return-uk app that shares this DB.**

No fine-tuning. Accountant behaviour = correct form/box routing + a rules-rich
prompt + RAG grounding + a human-review gate.

## CRITICAL: shared CODE + MIGRATION contract with diy-tax-return-uk

**Databases are separate** (diy has its own hosted Postgres; opsApi has its own). So
there are no shared rows, no namespace concern, no shared `vector(384)` column. The
**only** shared surface is **opsApi's code and migrations** — diy consumes opsApi as a
**pinned release-branch dependency** and deploys it in their own stack (their prod points
at `https://acc-api.diytaxreturn.co.uk/opsapi`). When diy bumps the opsApi release:
- **opsApi's migrations run against diy's database**, alongside diy's own SQL migrations
  and Python seeders (`seed_categories.py`, `sync_filesystem_profiles_to_db`).
- **opsApi's classifier/route code runs in diy's deployment** (diy's iOS app calls
  opsApi `/api/v2/tax/classify`; diy's web app uses its own Python classifier).

So a change is safe for diy iff its **migrations are additive/idempotent/feature-gated**
and its **API + output contracts are backward-compatible**.

### What diy's code expects from opsApi (verified)
- Canonical HMRC vocabulary = **snake_case `tax_hmrc_categories.key`**
  (`cost_of_goods`, `other_expenses`, `rent_rates`, `car_van_travel`, `wages_staff`…),
  consumed by diy's `core/categories.py` + `hmrc_aggregator.py`.
- diy's `seed_categories.py` **defers to opsApi as the source of truth** for
  `tax_hmrc_categories` (it stopped seeding after the UNIQUE(`box`) collision) — so our
  migrations own that catalogue, and any box we add appears in diy's DB.
- diy calls the existing `/api/v2/tax/*` endpoints and expects their current
  request/response shapes.

### Vocabulary note (corrected in Phase 5)
opsApi's classifier historically emitted **camelCase** `hmrc_category`. INITIAL assumption
was that this broke diy's filing. **Phase 5 verification disproved that**: diy's
`hmrc_aggregator.py` files on the transaction's **`category`** (`tax_categories.key`,
line 344) and resolves the box itself via the `hmrc_category_id` FK → `mtd_field_name`.
It does NOT sum the `hmrc_category` string column. So the camelCase issue was cosmetic for
filing, not a breaker. Phase 2 still aligns `hmrc_category` to snake_case (good hygiene /
correct if ever read). **The real filing key is `category`** — see Phase 5 gate.

### diy-safety rules (apply to every phase)
1. **Migrations: additive + idempotent + feature-gated.** New tables / nullable columns
   only; wrap in `IF NOT EXISTS`; gate behind the `TAX_COPILOT` feature in `migrations.lua`
   so the migration no-ops where the feature is off and can **never fail `lapis migrate`**
   on diy's DB. Never rename/drop/retype a column diy reads.
2. **`tax_hmrc_categories` additions (SA105):** add via opsApi migration (the source of
   truth) using **new, non-colliding `box` numbers**; never mutate existing rows. (The
   filing-side risk for diy's aggregator is the one true cross-code dependency — see Risks.)
3. **Never seed `classification_profiles` from an opsApi migration** — diy's
   `sync_filesystem_profiles_to_db` owns add-if-missing there and the `profile_key`s would
   collide. Keep opsApi's accountant guidance in **opsApi-owned storage** (new
   `tax_profile_guidance` table or nullable column) the migration creates fresh.
4. **API contract:** preserve existing `/api/v2/tax/*` request/response shapes; only add
   fields. Output **snake_case** HMRC keys validated against `tax_hmrc_categories`.
5. **Gate new classifier behaviour** behind a feature/config flag so diy's deployed
   opsApi can keep current behaviour if they don't want it yet.
6. **Frontend changes don't reach diy** — `opsapi-dashboard` is our UI only (diy has its
   own Next.js app), so the classify-timeout fix has zero diy impact.

## Phases (reworked)

### Phase 0 — Profile + form coverage (data/design)  ✅ DONE (2026-06-05)
- Created opsApi-owned `tax_profile_guidance` table via migration
  `710_tax_profile_guidance` (`migrations/tax-profile-guidance.lua`), TAX_COPILOT-gated,
  additive + idempotent. Does NOT touch `classification_profiles` or `tax_hmrc_categories`.
- Seeded 6 profiles with `{sa_form, mtd_section, filing_supported, persona,
  category_affinity, excluded_categories, rules_markdown}`. Five → SA103F (filing_supported
  = true); **landlord → SA105, filing_supported = false (classify-only; SA105 deferred).**
- `rules_markdown` drafted from HMRC guidance — **subject to review/refine before it
  drives any filing** (decision 3 resolved as: opsApi-drafted, pending sign-off).
- **DEFERRED (per decision):** no SA105 property categories added to the global
  `tax_hmrc_categories`; landlord filing is out of scope until diy's aggregator supports it.

### Phase 1 — Stored per-user profile resolution  ✅ DONE (2026-06-05)
- Added `resolveProfileType(user_id, requested)` in `routes/tax-classify.lua`:
  precedence **stored `tax_user_profiles.default_profile_key` → request param →
  sole_trader**, validated against `tax_profile_guidance` (unknown/inactive key →
  sole_trader). DB lookups pcall-guarded for graceful degradation.
- Wired into `POST /api/v2/tax/classify` (resolved after `user_id` is known). The
  `/classify/test` debug endpoint still honours its explicit param (intentional).
- Verified: stored `amazon_seller` resolved with no param (classified 20/20); bogus
  key → 0 guidance rows → falls back to sole_trader; param-only path unchanged.
- opsApi-side only; no diy impact (reads opsApi-owned tables; no schema/contract change).

### Phase 2 — Accountant prompt + vocabulary fix (diy-positive)  ✅ DONE (2026-06-05)
- `LLMClient.classify` (`lib/llm-client.lua`) rewritten to a guidance-aware prompt:
  persona + dynamic HMRC box map (snake_case keys from `tax_hmrc_categories`) + per-profile
  `rules_markdown` + capital/entertainment rules. Legacy camelCase prompt retained as the
  feature-flag-off fallback.
- `lib/tax-classifier.lua`: loads `tax_profile_guidance` + box map (preloaded once per
  batch), narrows categories by affinity/exclusions (DB-driven, replacing hardcoded
  `PROFILE_CATEGORIES`), forwards persona/rules/box-map to the LLM, and **validates the
  returned `hmrc_category` against the catalogue** — unknown keys are flagged and dropped
  below the 0.7 review threshold.
- Feature flag `TAX_CLASSIFIER_GUIDANCE` (default ON; set falsy to revert to legacy) so a
  consumer's deployed opsApi can opt out.
- Verified live: outputs are snake_case (`car_van_travel`, `capital_allowances`,
  `entertainment_costs`…); MacBook → `capital_allowances`, client lunch →
  `entertainment_costs` (non-deductible); a full `/classify` persisted only valid
  catalogue keys. **Resolves the camelCase mismatch for diy's aggregator.**

### Phase 3 — RAG grounding (embedding-safe)  ✅ DONE (2026-06-05)
- **Root cause fixed:** the Ollama embedding branch used the *chat* model
  (`OLLAMA_MODEL=qwen3:30b-a3b`), so query vectors could never match the stored
  `vector(384)`. Added `OLLAMA_EMBED_MODEL` (default **`all-minilm`** = all-MiniLM-L6-v2,
  384-dim — the same model/space as diy's drainer) in `lib/llm-client.lua` + `.env`.
  Verified 384-dim output.
- Backfilled all **406** `classification_reference_data` rows with all-minilm; pgvector
  retrieval now returns neighbours (similarity 1.000 for exact matches). Done via a
  one-off script on the dev DB (no auto-drainer added to opsApi code → can't run/conflict
  in diy's stack; diy's MiniLM drainer owns embedding there).
- **Corpus-quality guard:** the reference corpus stores **stale camelCase** `hmrc_category`
  (`costOfGoods`…) and noisy/conflicting labels. `adjust_confidence` now only accepts a
  RAG override when the neighbour's `hmrc_category` is a valid snake_case catalogue key;
  otherwise it keeps the LLM's answer and flags for review. So RAG cannot undo Phase 2.
- Verified: RAG-grounded classifications still emit valid snake_case; the guard blocks
  the camelCase neighbours.
- **Follow-ups (not blocking):** (a) normalise/curate the reference corpus to snake_case
  so RAG *improves* (not just grounds) accuracy; (b) add a flag-gated, 384-dim-guarded
  opsApi backfill job for opsApi's own DB; (c) feed accountant corrections into
  `classification_training_data` (1.25× weight).

### Phase 4 — Filing-safety gates  ✅ DONE (2026-06-05)
- `classify_transaction` now applies filing-safety gates that force `needs_review`
  (independent of confidence): unknown/non-catalogue `hmrc_category`, `capital_allowances`
  (AIA decision), amount > £10,000, and any profile with `filing_supported = false`
  (landlord/SA105 → triage only, never auto-files).
- **Catalogue is authoritative for deductibility**: `is_tax_deductible` is taken from the
  matched `tax_hmrc_categories` box, so the LLM cannot mark a non-deductible box (e.g.
  `entertainment_costs`) as deductible.
- `routes/tax-classify.lua` persists `NEEDS_REVIEW` when `needs_review` OR confidence < 0.7.
- Verified live: MacBook → capital review; £25k → capital + large-amount review; client
  dinner → entertainment_costs forced non-deductible; landlord → triage-only review;
  normal expense → no gate. opsApi-side only; no diy impact.

### Phase 5 — Verification (cross-app)  ✅ DONE (2026-06-05)
- Confirmed diy's `hmrc_aggregator.py` files on **`category`** (tax_categories.key), not
  `hmrc_category` (corrected the earlier assumption — see vocabulary note above).
- **New gate (closes the real gap):** opsApi previously validated `hmrc_category` but NOT
  `category` — yet `category` is what diy files on. Added a Phase-4 gate that validates the
  emitted `category` against `tax_categories.key`; an unknown value (e.g. `refunds_income`,
  which surfaced in testing) is now forced to `NEEDS_REVIEW` instead of being silently
  dropped from the return.
- Verified: per-profile golden pass (5 profiles) → sensible snake_case output; a full
  statement reconciled through diy's category→MTD mapping → all rows land in a real MTD
  bucket or are correctly excluded (`personal_expense`); the single unknown-category row
  was caught as `NEEDS_REVIEW`, never silently CLASSIFIED.

## Open decisions
1. **SA105 property categories in the global `tax_hmrc_categories`** — add now (and also
   teach diy's aggregator the property keys), or defer landlord filing until diy supports
   property? This is the only change that can affect diy's filing math.
2. **RAG embeddings** — Option A (rely on diy's drainer) or Option B (opsApi runs the
   same MiniLM model)?
3. **rules_markdown authorship** — I draft from HMRC HS222/PIM for review, or accountant-supplied?

## Risks
- **SA105/property is the only item that can't be fully decoupled** from diy: if a
  landlord's transactions carry property `hmrc_category` keys diy's aggregator doesn't
  know, diy-web filing for that user would mis-total. Mitigation: confirm landlords file
  via the opsApi/iOS path, or extend diy's aggregator in lockstep.
- Local 30B model is weak zero-shot on nuanced HMRC calls — safety = prompt + RAG + review.
- Keep `think = false` for Ollama (reasoning models return empty under JSON mode).

## Already shipped this session (no diy impact — verified opsApi-side only)
- Ollama via host-gateway IP (`OLLAMA_URL=http://192.168.5.2:11434`).
- `think = false` in `lib/llm-client.lua` (fixes empty JSON output from qwen3).
- Frontend classify timeout 30s → 300s in `services/tax.service.ts`.
