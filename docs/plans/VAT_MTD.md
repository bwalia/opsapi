# Prompt: VAT management, AI-assisted VAT returns and HMRC MTD VAT filing in OpsAPI

## Your task

Build full VAT management into OpsAPI (`bwalia/opsapi`). A VAT-registered UK business, or its
accountant, must be able to do all of the following:

1. Keep VAT-correct records.
2. Have AI work out the VAT on every transaction.
3. Review only what the AI is unsure of.
4. See the 9-box VAT return built from those records.
5. File it with HMRC through Making Tax Digital (MTD) for VAT.
6. See what HMRC says they owe and have paid.

The AI must get **more accurate and faster with use**: every correction a person makes teaches
it, for that business and, safely, for everyone.

Work in phases (below). Ship each phase as its own PR with tests, merge only when CI is green,
and check each phase on int against HMRC's sandbox before starting the next.

## Read first

- `CLAUDE.md`. In particular:
  - the module layering (routes → queries → models);
  - namespace scoping on every query;
  - feature gating in **both** `app.lua` and `migrations.lua`;
  - RBAC modules in `helper/project-config.lua`;
  - the "HMRC MTD Income Tax filing" section: fraud headers, OAuth, sandbox gotchas, and
    production readiness all apply to VAT too.
- **What exists for VAT today** (extend it; don't duplicate it):
  - `lapis/lib/accounting-engine.lua`: 9-box calculation from the ledger. Box 2 is a
    placeholder. Box 4 comes from `is_vat_reclaimable` expenses.
  - `lapis/queries/AccountingQueries.lua` and `lapis/routes/accounting.lua`:
    `/api/v2/accounting/vat-returns` (create, list, get) and `/submit`, which only marks the
    return as submitted and never reaches HMRC. Also `/api/v2/accounting/ai/vat-suggest`.
  - `lapis/migrations/accounting-system.lua`: the `accounting_vat_returns` table and the
    `2100 VAT Payable` account.
  - Dashboard: `opsapi-dashboard/app/dashboard/accounting/*` and
    `services/accounting.service.ts`.
- **What to reuse from Income Tax MTD:**
  - `helper/hmrc.lua`: OAuth tokens and `build_fraud_headers()`.
  - `lib/hmrc-mtd-client.lua`: the client pattern, including sandbox switching, TLS and
    `Gov-Test-Scenario`.
  - `routes/tax-hmrc-auth.lua`: connect and disconnect.
  - `lib/tax-classifier.lua`: the five-layer pipeline, including RAG over
    `classification_training_data` (pgvector) and the filing-safety review gates.
  - `lib/agent/*`: the tool-calling assistant, with `tax-tools.lua` as the model.
  - `lib/tax-delta.lua` and `components/tax/EstimateVsHmrc.tsx`: the "ours vs HMRC" comparison.
- **HMRC test users:** `sidecars/hmrc-test-users` currently makes **individual** test users
  only. VAT needs an **organisation** test user enrolled for `mtd-vat`.
- **HMRC's spec:** read HMRC's published VAT (MTD) API spec rather than relying on memory. It is
  public on GitHub as `hmrc/vat-api`, under `resources/public/api/conf/1.0`; read its schemas
  and examples with `gh api`.

## Ground rules

- **The LLM never does VAT arithmetic.** A deterministic Lua engine computes every figure and
  all 9 boxes. The AI only:
  - suggests the VAT treatment of a transaction (rate code, reclaimable share, net/VAT split
    when a receipt shows it);
  - explains;
  - flags what looks wrong.
- **Nothing reaches HMRC that a person hasn't confirmed.** Submitting a VAT return is legally
  binding. It needs:
  - an explicit declaration checkbox;
  - the `finalised: true` flag only after that declaration;
  - an audit row written **before** the binding call;
  - idempotency (never file the same period twice; refuse while a submission is in flight).

  Copy the guards in `submit-final-declaration` (`routes/tax-hmrc-filing.lua`).
- **Every row is namespace-scoped, and every route is feature-gated.** Use a new feature such as
  `vat`, inside the `tax_copilot` and `all` presets (not `business`: VAT needs tax_copilot's HMRC
  sign-in, Tax menu and bank lines; deploy `business,tax_copilot`).
- **No secrets in code or commits**, including test fixtures: generate them at runtime, because
  GitGuardian blocks PRs that contain them.
- **Write for a business owner, not a tax expert.** Use plain English in the UI. Show box
  numbers, with plain labels, for accountants.

## Phase 1: VAT records (the data model)

Store the VAT facts once, so the return, the AI and reports all read the same data.

**VAT registration per namespace or business (`vat_registrations`):**
- VRN (9 digits, check-digit validated);
- effective date;
- scheme: standard (accrual), cash accounting, flat rate (with sector % and the
  first-year 1% discount), or annual accounting;
- stagger (period pattern);
- whether the business is a limited-cost trader;
- whether it is partially exempt (start with a flag plus a manual recovery % for v1).

**VAT fields on each transaction.** This covers `tax_transactions` (bank-statement lines) and
accounting expenses and invoices. Add:
- `vat_code`, one of:

  | Code | Meaning |
  |---|---|
  | `STD20` | standard rate, 20% |
  | `RED5` | reduced rate, 5% |
  | `ZERO` | zero-rated |
  | `EXEMPT` | exempt |
  | `OUTSIDE` | outside the scope of VAT (wages, rates, transfers) |
  | `RC_SERVICES` | reverse charge on services received from abroad |
  | `RC_CIS` | domestic reverse charge for construction |
  | `PVA` | postponed import VAT |
  | `NI_EU_GOODS` | Northern Ireland protocol goods |

- `net_amount`, `vat_amount`;
- `vat_reclaimable_pct`: 100, 50 for cars with private use, 0 for business entertainment,
  partial exemption otherwise;
- `vat_period_key`;
- `vat_evidence`: whether there is a VAT invoice or receipt, the supplier's VRN, and a link to
  the receipt image;
- `vat_source`: `ai` | `rule` | `user`, with confidence and the AI's reason. The reason must
  survive confirmation, as PR #898 did for income tax.

**Rules engine (`vat_rules`):** per namespace, map a supplier, merchant or category to a VAT
code. Learned rules are created from corrections (see Phase 3). Global seed rules cover the
obvious cases:
- HMRC, wages, council tax and bank transfers are `OUTSIDE`;
- insurance and most bank charges are `EXEMPT`;
- rail fares are `ZERO`, and domestic energy is `RED5`.

**Acceptance:**
- migrations are gated and idempotent;
- money is stored as numeric and rounded half-up to the penny;
- `net + vat = gross` is enforced, with a 1p tolerance on imports.

## Phase 2: the deterministic 9-box engine

Replace and extend `accounting-engine.lua`'s VAT calculation with `lib/vat-return.lua`. It
builds a return for a period from the confirmed VAT data, for each scheme:

| Box | Content |
|---|---|
| Box 1 | output VAT on sales + reverse-charge output VAT + postponed import VAT + fuel scale charges |
| Box 2 | VAT due on acquisitions of goods from the EU (NI only) |
| Box 3 | Box 1 + Box 2 |
| Box 4 | reclaimable input VAT, including the reverse-charge and PVA input side, after `vat_reclaimable_pct` and partial exemption |
| Box 5 | the absolute value of Box 3 − Box 4 |
| Box 6 | net sales; whole pounds; includes reverse-charge supplies received |
| Box 7 | net purchases; whole pounds |
| Box 8 | supplies of goods to the EU (NI only); whole pounds |
| Box 9 | acquisitions of goods from the EU (NI only); whole pounds |

Scheme behaviour:
- **Cash accounting:** uses payment date, not invoice date.
- **Flat rate:** Box 1 is the flat % × the VAT-inclusive turnover. Box 4 holds only capital
  assets over £2,000. Apply the limited-cost-trader 16.5% test.
- **Annual accounting:** one return a year, with interim payments.

Adjustments:
- **Bad debt relief:** over 6 months overdue and written off.
- **Error correction:** apply in-return corrections within the threshold
  (£10,000, or 1% of Box 6 up to £50,000). Above that, flag for a separate disclosure; never
  auto-correct.

Every box carries its **audit trail**: the list of transactions behind it, and the rule that put
each one there. Each figure must be clickable down to the lines.

**Acceptance:** a spec with worked examples for each scheme and each special case, using the
figures from HMRC's own guidance (VAT Notice 700, 700/12, 733 and 731) as expected values.

## Phase 3: AI VAT classification that learns

Extend the classifier pipeline with a VAT step (or a sibling `lib/vat-classifier.lua` that
shares its layers), in this order:

1. **Rules first:** a namespace rule, then a global rule. These are free and instant; skip the
   LLM when a rule matches with high confidence.
2. **RAG over past decisions:** pgvector similarity over this namespace's confirmed VAT
   decisions, then the anonymised global set (`classification_training_data`, extended with
   `vat_code` and `reclaimable_pct`). Pass the nearest examples to the LLM as few-shot
   evidence.
3. **LLM, structured output:** return `{vat_code, reclaimable_pct, confidence, reason,
   needs_evidence}`, restricted to valid codes. Validate the output, never trust it. Give it the
   business's sector, scheme and partial-exemption status as context.
4. **Receipts:** when a receipt or invoice image or PDF is attached, read the VAT amount, the
   supplier's VRN and the rate, using the existing vision/OCR path. A receipt's actual VAT beats
   20/120 of the gross. A supplier VRN that fails its check digit is a red flag.
5. **Safety gates (send to review, never auto-confirm):**
   - confidence below 0.75;
   - VAT reclaimed with no evidence over £250;
   - entertainment or cars;
   - reverse charge;
   - an imported item;
   - anything that changes Box 1 or Box 4 by more than 10% period on period;
   - VAT charged by a supplier whose VRN is unregistered.

**The learning loop:**
- Every confirmation or correction writes a training row: description, merchant, amount band,
  the codes chosen, and who decided.
- Two corrections that agree on the same supplier become a **namespace rule** automatically.
  Show it to the user ("We'll now treat PROPDESK as standard-rated") and let them undo it.
- Corrections agreed across many namespaces go to an admin queue to be promoted to global rules.
  Never promote automatically; one tenant must never change another's VAT.
- **Speed:** rule and RAG hits skip the LLM. Batch the LLM for the rest. Process statements in
  the background worker (`routes/tax-process.lua`, which already survives restarts).

**Measure it:**
- Build a labelled evaluation set (a few hundred real-looking UK lines across sectors) under
  `lapis/spec/fixtures/vat-eval.json`, plus `lapis/spec/vat-classifier-eval_spec.lua` reporting
  accuracy, review rate and LLM-call rate.
- Record the baseline in the PR. Each later phase must not reduce accuracy.
- Track live accuracy per namespace, measured as the share of AI codes confirmed unchanged.

## Phase 4: HMRC VAT (MTD) API client

`lib/hmrc-vat-client.lua`, the VAT (MTD) API v1.0 (`Accept: application/vnd.hmrc.1.0+json`):

| Call | Endpoint | Purpose |
|---|---|---|
| obligations | `GET /organisations/vat/{vrn}/obligations?from&to&status` | which periods are open, with their `periodKey` and due date |
| submit return | `POST /organisations/vat/{vrn}/returns` | the 9 boxes plus `periodKey` and `finalised: true` |
| view return | `GET /organisations/vat/{vrn}/returns/{periodKey}` | the return HMRC holds |
| liabilities | `GET /organisations/vat/{vrn}/liabilities?from&to` | what HMRC says is owed |
| payments | `GET /organisations/vat/{vrn}/payments?from&to` | what HMRC has received |
| penalties | penalties and financial details, where the spec version offers them | late-submission points and late-payment interest |

Requirements:
- OAuth scopes `read:vat` and `write:vat`. Check whether the existing HMRC connection needs
  re-consent; if so, handle it in the UI.
- The fraud-prevention headers are mandatory. Reuse `build_fraud_headers()`.
- In sandbox, support `Gov-Test-Scenario`. Document the scenarios that matter
  (e.g. `QUARTERLY_NONE_MET`, `DUPLICATE_SUBMISSION`, `TAX_PERIOD_NOT_ENDED`) with specs
  against stubbed responses.
- Validate boxes against HMRC's rules before sending:
  - Box 3 = 1 + 2;
  - Box 5 = |3 − 4|;
  - boxes 6–9 are whole numbers;
  - value ranges.

  HMRC rejects violations, so catch them first and say which box is wrong.

**Test users:**
- Extend `sidecars/hmrc-test-users` to also create **organisation** test users
  (`/create-test-user/organisations`) with `mtd-vat`, returning the VRN.
- Keep the same rate limit, Basic auth and no-logging of passwords.

**Developer Hub:** the sandbox app must be subscribed to the **VAT (MTD)** API. Before
testing, check whether it is subscribed. If HMRC answers `403 RESOURCE_FORBIDDEN`, stop and ask
the user to subscribe it. It is self-serve and takes effect instantly; landlord filing needed the
same step.

## Phase 5: the VAT screens and the assistant

**Dashboard: "VAT" under Tax and Accounting.** All screens work on a phone.
- **VAT overview:** registration and scheme, next deadline (period end + 1 month + 7 days), what
  is owed or refundable this period so far, and the late-submission points from HMRC.
- **Check your VAT:** the transactions for the period with their VAT code, net/VAT, the AI's
  reason and confidence, and "Please check" for flagged ones (copy the `TransactionReview`
  pattern). Include bulk "Confirm the rest" with consent, and receipt upload per line.
- **Your VAT return:** the 9 boxes with plain labels, each clickable to its transactions.
  Show the period-on-period change, and flag anomalies.
- **File with HMRC:** connect → obligations (pick the open period) → check boxes → declaration →
  submit → HMRC's receipt (processing date, form bundle number, charge reference). The receipt
  is stored and downloadable.
- **Ours vs HMRC:** after filing, compare our return with HMRC's view of it and with HMRC's
  liabilities and payments. Reuse the `EstimateVsHmrc` side-by-side pattern and explain any
  gap.
- **Accountant view:** an accountant (with RBAC) can review and file across their clients'
  namespaces, using the existing filing-requests flow as the model.

**Assistant ("Do your VAT with AI"):** add tools in `lib/agent/vat-tools.lua`:
- `get_vat_status`
- `get_vat_review_queue`
- `apply_vat_fix` (the user confirms first)
- `compute_vat_return` (the engine, never the LLM)
- `explain_box`
- `get_vat_obligations`
- `preview_vat_submission`

Filing stays a human click on the File screen, never a chat command. Answers in £ and in plain
English.

## Phase 6: VAT management

- **Registration threshold watch** for businesses that aren't registered: the rolling 12-month
  taxable turnover against the current threshold (£90,000 from April 2024; read it from config,
  not code). Warn at 80% and 100%, with the 30-day registration deadline.
- **Deadlines and reminders:** email and in-app, using existing notifications. 14 and 3 days
  before each due date.
- **Records:** keep 6 years. Include a "digital links" export (CSV/JSON) of every transaction
  behind every box, for an inspection.
- **Reports:** VAT by code, by supplier and by period, plus reclaimable versus blocked VAT.

## Phase 7: production go-live

Real VAT returns can only be filed once HMRC approves the software.

- Run HMRC's production checks:
  - fraud-prevention headers pass the Test Fraud Prevention Headers API for every connection method used;
  - the evidence pack HMRC asks for: screenshots and test logs of each endpoint, and the error handling.
- Production credentials stay in the Vault ExternalSecret, never in values files or code.
- `HMRC_ENVIRONMENT=production` must switch the VAT client, as Income Tax does. Add a per-release kill switch (`VAT_FILING_ENABLED`) so filing can be turned off without a deploy.
- Monitoring and alerts on submission failures. A runbook for HMRC outages and rejected returns.
- Get the product listed as recognised MTD VAT software.

Steps that need the user (HMRC application and forms) are reported, not done.

## Phase 8: accountants (agents)

- Accountants sign in with their HMRC Agent Services account.
- Each client authorises them through HMRC's Agent Authorisation API, MTD VAT service: create an invitation, see its status, cancel it.
- An accountant view lists their clients' VAT registrations, deadlines and draft returns, and files on their behalf. Each client's data stays in their own namespace; access is granted per client, with RBAC.
- Audit: every return records whether the business or its agent filed it.

## Phase 9: VAT on sales from our own modules

- Invoices from Invoicing and the Shop carry valid VAT invoice details:
  - supplier VRN, tax point and invoice number;
  - VAT rate and amount per line, with VAT-exclusive and VAT-inclusive totals;
  - the reverse-charge wording when it applies.
- Issued invoices (sales) and supplier bills (purchases) feed the return directly as coded lines. Match them to bank lines so nothing is counted twice.
- Cash accounting uses payment dates; standard accounting uses the tax point.

## Phase 10: less common schemes

- Full partial exemption: the standard method, the de minimis tests and the annual adjustment.
- Capital Goods Scheme adjustments.
- Margin schemes for second-hand goods.
- VAT groups (one VRN, several members).
- Northern Ireland EU sales lists where required.

Shipped (phase 10): `lib/vat-return.lua` (purchase attribution taxable/exempt/residual, recovery %
rounded up, de minimis tests 1, 2 and the original test, margin global accounting with negative
margins carried forward, intra-group supplies left out, `cgs` / `pe_annual` adjustments),
`lib/vat-schemes.lua` (annual adjustment, capital goods intervals and disposal with the output-tax
cap, EC Sales List), `queries/VatSchemeQueries.lua`, `migrations/vat-schemes.lua`, the routes listed
in `routes/vat.lua`, and `components/vat/VatSchemesPanel.tsx`. A VAT group's representative
collects every member's lines; members join with a one-time code and can't file on their own. The
EC Sales List is a CSV to key into HMRC's online service (not HMRC's bulk file format). The AI is
never offered the MARGIN code.

## Phase 11: e-invoicing readiness

The UK is moving to mandatory e-invoicing for VAT-registered businesses from April 2029.

- Export and import invoices as structured data (UBL / Peppol BIS Billing 3.0).
- Validate them against the schema.
- Keep the data model ready to exchange through an access point when the UK model is final.
- Track the HMRC guidance, and record what changes when it is published.

Shipped (phase 11): UBL 2.1 / Peppol BIS Billing 3.0 export of issued invoices, import of
supplier e-invoices (recorded as pending purchases with the VAT coded), a business-rule check,
and `vat_einvoice_documents` as the outbox/inbox for a future access point. What is and isn't
covered, and the guidance log: `docs/plans/VAT_EINVOICING.md`.

## Testing and definition of done

For each phase:
- Lua specs (standalone LuaJIT, the same style as `lapis/spec/*_spec.lua`) for every engine
  rule, classifier gate and client response, including HMRC error bodies;
- Cypress or Playwright for the screens;
- eslint and tsc clean.

On int, end to end against HMRC's sandbox:
1. Create an organisation test user with the sidecar.
2. Register VAT.
3. Upload a quarter of statements.
4. The AI classifies them, and you review the flagged lines.
5. Build the return.
6. Submit, and get HMRC's receipt.
7. View the return back from HMRC, then liabilities and payments.
8. Check that resubmitting the same period is refused.

Record a short demo video with the recorders in `devops/demo/` (same style as the landlord
video).

Also:
- Keep the classifier evaluation numbers in each PR. Accuracy may only go up.
- Update `CLAUDE.md` with a "HMRC MTD VAT" section (layers, sandbox gotchas, production
  readiness), as for Income Tax.

## Follow-ups beyond Phase 11

- The Tour Operators' Margin Scheme.
- Making Tax Digital for corporation tax.

## Report back

At the end of each phase, give:
- what shipped (PR links);
- what was checked on int and against HMRC's sandbox;
- the classifier evaluation numbers;
- anything that needs the user (Developer Hub subscriptions, production credentials, policy
  choices such as auto-creating rules).
