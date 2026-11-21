# Build prompt: Corporation Tax (CT600) and statutory accounts, filed with HMRC (OpsAPI module `corporation_tax`)

Let a limited company, or the accountancy practice acting for it, go from the company's
books to a **filed CT600** with **iXBRL accounts and computations**, then file the
**accounts at Companies House**. It's a **Daybook key feature**: "Self Assessment, VAT,
payroll and Corporation Tax in one place for your practice".

Read first:

- `CLAUDE.md`, sections "HMRC MTD Income Tax" and "HMRC MTD VAT": the same principles
  apply;
- `lib/accounting-engine.lua` (double-entry journals, trial balance, P&L, balance
  sheet);
- `routes/accounting.lua`;
- `PROMPT_PAYROLL.md` §5: payroll posts its journals into the same ledger.

---

## 0. Ground rules

- **Follow OpsAPI's module pattern:**
  - feature `corporation_tax`, gated identically in `app.lua` and `migrations.lua`;
  - RBAC modules `corporation_tax`, `corporation_tax_agent` and `statutory_accounts`;
  - presets `all`, `business` and `tax_copilot`, plus a feature-only code.
- **The channel is not MTD.**
  - CT600 returns go to HMRC through the **Transaction Engine (GovTalk XML)** with the
    accounts and computations attached as **iXBRL**.
  - Read HMRC's current "Corporation Tax online: support for software developers"
    pages, the CT600 schema and the business rules.
  - Implement against **their** XSDs (`lib/ct/schemas/<version>/`), and test on HMRC's
    Local Test Service, then Test-in-Live.
  - Before live filing, HMRC software recognition and the "Corporation Tax online"
    listing are needed. Until then `CT_FILING_LIVE=false` and live submissions are
    refused.
  - MTD for Corporation Tax has no confirmed date. Keep a `CtChannel` interface so an
    MTD API can be added later without touching the engine.
- **Figures come from rules, never from AI.** A deterministic engine
  (`lib/ct/engine.lua`) and versioned rate tables per financial year compute:
  - taxable profit;
  - capital allowances;
  - losses;
  - marginal relief;
  - the s455 charge;
  - tax payable.

  AI may only:
  - suggest tax adjustments for ledger lines (e.g. "client entertaining → disallow"),
    with reasons, for a person to accept;
  - suggest the asset pool for an addition;
  - draft the notes to the accounts for a person to edit.
- **A person signs off:**
  - a director approves the accounts;
  - the agent/director approves the return with a declaration checkbox;
  - both are recorded with user and time;
  - any change after approval needs re-approval.
- **No hard-coded rates.** Small profits rate, main rate, the marginal relief
  thresholds and fraction, the s455 rate, AIA limit, writing-down rates, SBA rate and
  full-expensing rules all live in `ct_rates` rows by financial year. Seed them from
  GOV.UK with source URLs, and **re-verify at build time**. Periods that straddle 1
  April are apportioned by day across financial years.
- **Tenant isolation:** `namespace_id` everywhere, and `company_id` for practice
  (agent) mode. Each company is a CRM account in the practice's namespace, as payroll
  employers are.
- **Tests:** `lib/ct/*_test.lua` covers HMRC's published examples (marginal relief,
  associated companies, short periods, straddling periods) and §3.

## 1. Scope by phase

1. **Company and periods:**
   - Company record: CRN, UTR, SIC codes, registered office, directors,
     shareholders/participators, associated companies count, accounting reference
     date, accounting periods (with the 12-month CT period split for long periods of
     account).
   - Import from Companies House's public data API (company profile, officers, filing
     history) where configured.
   - Deadline calendar: CT payment at 9 months + 1 day, CT600 at 12 months, accounts at
     Companies House at 9 months (private), quarterly instalment payments for large
     companies.
2. **Year-end books:**
   - Trial balance from the ledger (`accounting-engine.lua`), plus year-end journals:
     accruals, prepayments, depreciation, director's loan account, dividends declared.
   - Payroll and VAT control accounts reconciled to their modules.
   - The TB locks on approval.
3. **Statutory accounts:**
   - FRS 105 (micro-entity) and FRS 102 Section 1A (small): profit and loss, balance
     sheet, notes, director's report (where needed), approval statement.
   - Generated as **iXBRL** tagged with the current FRC taxonomy, validated with an
     iXBRL validator (the HMRC/Companies House-accepted rules) before filing.
   - PDF for clients via `helper/pdf-generator.lua`.
4. **Tax computation (`lib/ct/engine.lua`):**
   - accounting profit → add-backs: depreciation, client entertaining, fines, private
     use, non-deductible legal costs, general provisions; each with source lines;
   - deductions;
   - capital allowances (`lib/ct/allowances.lua`):
     - pools: main, special rate, single asset;
     - AIA, full expensing / 50% FYA where eligible, writing-down allowances, small
       pools, balancing charges/allowances on disposal, structures and buildings
       allowance, cars by CO₂ band;
   - trading losses: carry forward (streaming rules), carry back 12 months, group
     relief **out of scope for phase 1**;
   - property and non-trading loan relationship income;
   - chargeable gains (manual input in phase 1);
   - marginal relief with associated companies and short periods;
   - **CT600A** s455 charge on loans to participators outstanding 9 months after
     period end, with relief on repayment;
   - computation output as **iXBRL** tagged with HMRC's CT computational taxonomy.
5. **CT600 and filing (`lib/ct/rti-ct.lua`, i.e. the GovTalk client):**
   - CT600 main return plus supplementary pages as needed: CT600A in phase 1;
     CT600L (R&D) and others later and marked roadmap.
   - Built from the computation, XSD-validated, IRmark, with iXBRL accounts and
     computation attached.
   - Submit → poll → response; replay-safe (DB claim, as VAT's AI job).
   - **Sender:** the company's Government Gateway credentials, or the practice's agent
     credentials with the client authorised (verify HMRC's current CT agent
     authorisation route and record which is used). Credentials only in the vault.
   - Store the submission XML, the HMRC receipt (IRmark receipt) and correlation id.
6. **Companies House accounts filing (optional phase):**
   - The Companies House software filing (XML gateway) for the iXBRL accounts needs a
     presenter account, the company authentication code (vault) and Companies House
     test-mode credentials.
   - Show it as "File accounts at Companies House" with its own status.
   - Mind identity verification requirements for directors and presenters, which are
     changing under the Economic Crime and Corporate Transparency Act. Verify the
     current rules.
7. **Payments:** CT liability, due date, payment reference (UTR + suffix as HMRC
   specifies), and a reminder schedule. QIP schedule for large companies. Interest is
   shown as an estimate only, with a link to HMRC.

## 2. API (`/api/v2/corporation-tax`, auth + namespace + RBAC)

- companies (+ Companies House import);
- periods;
- trial balance (from ledger, lock/unlock with an audit row);
- year-end journals;
- adjustments (list, AI suggest, accept/reject);
- fixed assets and pools;
- losses;
- accounts (generate, preview PDF, iXBRL download, validate, approve);
- computation (generate, explain each figure with its source lines, iXBRL);
- CT600 (build, validate, approve, submit, poll);
- Companies House filing (submit, poll);
- deadlines;
- reports.

Emit webhooks: `ct.return.accepted`, `ct.return.rejected`, `ct.accounts.filed`.

## 3. Edge cases to test

- a 15-month period of account split into 12 + 3;
- a period straddling 1 April with a rate change;
- profits between the small and main thresholds with 2 associated companies;
- AIA on a short period;
- disposal giving a balancing charge;
- a car with mixed CO₂ bands;
- trading loss carried back;
- director's loan overdrawn at year end and repaid within 9 months (no s455), and not
  repaid (s455 charge);
- a dormant company (nil return path);
- iXBRL validation failure surfaced in plain English.

## 4. Dashboard and Daybook

- **Dashboard** (`opsapi-dashboard/app/dashboard/corporation-tax/**`):
  - company overview with deadlines;
  - the year-end wizard: books → adjustments review (AI suggestions with reasons, one
    click to accept) → allowances → losses → accounts preview → computation → CT600
    preview → director approval → submit;
  - submissions history;
  - practice view across companies.
- **Daybook demo:** a `companies` vertical (`daybook-companies`):
  - a 2-director consultancy Ltd near the marginal relief band with an overdrawn DLA;
  - a café Ltd with van and equipment additions;
  - a dormant company.

  All filings go to the Local Test Service only.
- **Mobile** (`PROMPT_PAYROLL_MOBILE.md` app): directors can see deadlines and the tax
  due, and approve accounts and returns after re-authentication.

## Done means

- [ ] Engine tests pass HMRC's examples for the seeded years.
- [ ] Every CT600 and iXBRL file validates before sending, and is replay-safe.
- [ ] No rate in code.
- [ ] Live filing stays off until recognition.
- [ ] Daybook copy says "files through HMRC's Corporation Tax online service" only once
      Test-in-Live has passed, and never "HMRC approved".
