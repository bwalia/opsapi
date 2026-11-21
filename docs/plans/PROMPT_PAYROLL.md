# Build prompt: UK Payroll with RTI filing (OpsAPI module `payroll`)

Build a **complete UK payroll system** in OpsAPI that files Real Time Information (RTI)
to HMRC. It serves two kinds of customer from the same code:

- **An employer** runs payroll for its own staff. The employer is the namespace.
- **An accountancy practice runs a payroll bureau** for many employer clients. Each
  client employer is a **CRM account** (`routes/crm-accounts.lua`) in the practice's
  namespace, and the practice bills payroll fees through Invoicing.

Payroll is a **key feature of Daybook** (`docs/plans/PROMPT_DAYBOOK_SITE.md`,
`docs/plans/DAYBOOK_DEMO_SPEC.md`). The prompts for the other parts are:

- dashboard: `PROMPT_PAYROLL_UI.md`;
- mobile apps: `PROMPT_PAYROLL_MOBILE.md`;
- Corporation Tax, which consumes payroll journals through the ledger:
  `PROMPT_CORPORATION_TAX.md`.

---

## 0. Ground rules

- **Follow OpsAPI's module pattern** (`CLAUDE.md`):
  - migration → model/queries → routes;
  - feature `payroll` gated identically in `app.lua` and `migrations.lua`;
  - RBAC modules in `helper/project-config.lua`;
  - a dashboard service.

  Add it to the presets `all`, `business` and `tax_copilot`, plus a feature-only code
  so `PROJECT_CODE=core_only,payroll` works.
- **The numbers come from rules, never from AI.** PAYE, NI, student loans, pensions and
  statutory payments are computed by a deterministic engine (`lib/payroll/*.lua`)
  driven by **versioned legislation tables per tax year**. AI may only:
  - explain a payslip line;
  - suggest which pay element an imported line maps to;
  - draft a message to an employee.

  It never produces a figure that is paid or filed (same rule as `lib/vat-return.lua`).
- **A person approves every pay run** before RTI is sent or payment files are made.
  Approval records the user and time; a changed run needs re-approval.
- **No hard-coded rates.** Every threshold, rate and limit lives in a
  `payroll_legislation` row keyed by tax year and region (rUK, Scotland, Wales). Seed
  them from GOV.UK "Rates and thresholds for employers <year>" and cite the URL in the
  seed file.
  - The new tax year's table must be loadable before 6 April without a deploy (an admin
    import plus review).
  - Every rate in this prompt that has a date is **to be re-verified on GOV.UK at build
    time**.
- **HMRC software recognition:**
  - RTI uses the **Transaction Engine (GovTalk XML)**, not the MTD REST APIs.
  - Read HMRC's current RTI technical specifications and schemas ("Software developers:
    PAYE Real Time Information" on GOV.UK) and implement against **their** XSDs, stored
    in `lapis/lib/payroll/rti/schemas/<year>/`.
  - Test with HMRC's Local Test Service, then Test-in-Live, before applying for payroll
    software recognition.
  - Until recognised, `PAYROLL_RTI_LIVE` stays `false` and live submissions are refused
    with a clear error.
  - Don't claim recognition anywhere until HMRC lists the product.
- **Tenant isolation:**
  - every table has `namespace_id`;
  - bureau tables also have `employer_id`;
  - a member sees only the employers they are assigned to.
- **Sensitive data:** NINOs, bank details, salaries and medical/leave reasons.
  - Encrypt NINO and bank details at rest (reuse the vault/secret encryption helper).
  - Mask them in lists and log no PII.
  - Every view of an unmasked value is audited.
  - Payslips are only visible to the employee, payroll staff, and the owner.
- **Secrets:** Government Gateway credentials (employer or agent) live in the vault
  only, are never logged, and are used only at submit time.
- **Tests:** a Lua test suite (`lapis/lib/payroll/*_test.lua`, same style as
  `tax-calc-full_test.lua`) that reproduces **HMRC's published PAYE/NI test cases and
  worked examples** for the seeded tax year, plus the edge cases in §3. CI runs it.

## 1. Data model (all with `namespace_id`, timestamps, uuid)

| Table | Holds |
|---|---|
| `payroll_employers` | Name, `crm_account_id` (bureau) or null (own staff), PAYE reference, Accounts Office reference, HMRC office number, Corporation Tax/SA UTR, pay frequencies, Employment Allowance claim, apprenticeship levy flag, pension scheme(s), RTI sender: `self` or `agent` with a vault ref |
| `payroll_employees` | Links `employees.id` (core directory). Personal details, NINO (encrypted), DOB, gender per HMRC, address, starter declaration (A/B/C), student/postgrad loan plans, director flag + NI method (annual/alternative), start/leave dates, payroll ID (and changes), irregular-payment flag, bank (encrypted) |
| `payroll_tax_codes` | Code history per employee: code, basis (cumulative / week1-month1), source (P45, starter, DPS notice, manual), effective date |
| `payroll_pay_elements` | Per employer: basic, hourly, overtime, bonus, commission, holiday pay, salary sacrifice, BIK (payrolled), expenses, deductions, attachments. Each has flags: taxable, NIable, pensionable, NMW-relevant, and its RTI field mapping |
| `payroll_schedules` | Frequency (weekly, 2-weekly, 4-weekly, monthly, plus quarterly/annual for directors), pay day, period calendar including week 53 |
| `payroll_runs` | Employer, schedule, tax year, period number, pay date. Status `draft → calculated → approved → submitted → paid → closed`. Approved_by/at |
| `payroll_run_lines` | Per employee per run: elements, gross, taxable pay, tax, employee/employer NI by category letter, student/PG loan, pension EE/ER, statutory payments, net pay, YTD snapshot |
| `payroll_ytd` | Per employee per tax year per NI category (recomputable from lines; stored for P60/EPS) |
| `payroll_leave` | Holiday (with irregular-hours accrual), sickness (SSP), maternity/paternity/adoption/shared parental/bereavement/neonatal (SMP/SPP/SAP/ShPP/SPBP/SNCP), with evidence docs (MinIO) |
| `payroll_pension_schemes` / `payroll_pension_enrolments` | Provider, basis (relief at source / net pay / salary sacrifice), qualifying vs pensionable earnings, rates, assessment results, postponement, opt-out window, re-enrolment date, contribution files |
| `payroll_rti_submissions` | Type (FPS, EPS, EYU, NVREP, plus the agent variants), run/period, XML (stored compressed), IRmark, correlation id, poll URL/interval, status, HMRC response/errors |
| `payroll_hmrc_notices` | DPS messages pulled from HMRC: P6/P9 tax codes, SL1/SL2 student loans, PGL1/PGL2, NINO verification replies, generic notices. Applied state + who applied |
| `payroll_documents` | Payslips, P45, P60, P11D(b), with links to PDF files |
| `payroll_journals` | The ledger posting per run (see §5) |
| `payroll_audit` | Every calculation input change, approval, submission, unmasking |

## 2. Calculation engine (`lib/payroll/`)

- `legislation.lua`: loads the year's table (rUK/Scottish/Welsh income tax bands,
  personal allowance, K-code regulatory limit, NI thresholds and rates by category,
  student loan plans 1/2/4/5 and postgraduate, Employment Allowance, levy allowance, SSP
  and statutory payment rates, NMW/NLW bands, auto-enrolment thresholds).
- `paye.lua`: the tax code parser (suffix codes, K codes, S/C prefixes, BR, D0, D1, NT,
  0T) and cumulative and week1/month1 tax using HMRC's tax table method.
  - Implement exactly as in HMRC's "Specification for PAYE Tax Table Routines" for the
    year. Rounding rules matter.
- `ni.lua`: per-period and director annual/alternative methods; all category letters
  in the year's table (including freeport/investment zone and veterans); employer NI;
  Employment Allowance offset tracking.
- `loans.lua`: student and postgraduate loan deductions per plan, with thresholds per
  period.
- `statutory.lua`:
  - SSP: rules as current for the year. SSP rules changed from April 2026; verify.
  - SMP, SPP, SAP, ShPP, SPBP, SNCP: average weekly earnings, qualifying weeks, rates.
  - Recovery percentages for the EPS (small employers' relief).
- `pensions.lua`: worker assessment (eligible / non-eligible / entitled), qualifying
  earnings bands, the three bases, salary sacrifice, contribution schedules, and
  provider export (PAPDIS CSV; NEST and others as named connectors only when built).
- `holiday.lua`: statutory entitlement, and irregular-hours/part-year accrual (12.07%
  rolled-up holiday pay where the rules allow; verify).
- `nmw.lua`: flags any worker whose pay for time worked falls below NMW/NLW for their
  age band. It warns; it doesn't block.
- `run.lua`:
  1. Builds lines from elements, timesheets (`routes/timesheets.lua`, approved hours
     only) and leave.
  2. Calculates in the correct order (salary sacrifice → pensions per basis → tax/NI →
     loans → post-tax deductions → net).
  3. Writes the YTD and is **idempotent**: recalculating a draft gives the same
     result.
- Starters (with P45 or starter declaration), leavers (P45 generation, payments after
  leaving), directors, re-hires, tax code changes mid-year, week 53, and corrections to
  earlier periods (with an EYU after year end).

## 3. Edge cases the test suite must cover

K code at the 50% limit; emergency code; Scottish and Welsh codes; week1/month1 to
cumulative; director annual NI mid-year appointment; NI category change mid-year;
student loan plan 2 plus postgraduate; SSP linked periods; SMP with a pay rise in the
reference period; salary sacrifice taking pay below NMW (flag); leaver paid after the
P45; week 53 on a weekly schedule; a negative net pay situation (refuse and explain);
Employment Allowance exhausted mid-year.

## 4. RTI and HMRC (`lib/payroll/rti/`)

- **Build the XML from the run** against the year's XSD, with the IRmark computed per
  HMRC's spec. Validate against the XSD before sending.
- **Submissions:**
  - **FPS** on or before pay day for each run;
  - **EPS** by the 19th after the tax month, for statutory payment recovery,
    Employment Allowance, levy, no-payment periods and final submission;
  - **EYU** for prior-year corrections;
  - **NVREP** for NINO verification.
- **Transaction Engine client:** submit → poll per the returned interval → response or
  error. Keep the correlation id. Handle business errors (show them in plain English on
  the run) and transport errors (retry with backoff, never double-submit: a run's FPS
  is claimed in the DB first, like `vat_registrations.ai_job_started_at`).
- **Credentials:**
  - **Employer as sender:** the employer's Government Gateway credentials.
  - **Practice as agent:** the practice's agent credentials and the client's PAYE agent
    authorisation. Check HMRC's current agent authorisation route for PAYE, and record
    which is used.
- **DPS:** scheduled pull of notices per employer. Show them in an inbox, and have a
  person apply tax code changes. Auto-apply is allowed only for P6/P9 with an audit
  row.
- **Environment switch:** `PAYROLL_RTI_ENV=lts|til|live` and `PAYROLL_RTI_LIVE` (live
  needs both). HMRC's test endpoints are documented in the tech pack.
- **Year end:** final FPS/EPS flags, P60s by 31 May, P11D/P11D(b) (or payrolled
  benefits; mandatory payrolling of benefits is announced for a later year, so verify
  the date and build for it), and a year-end checklist with HMRC deadlines.

## 4a. CIS for contractors (phase 5, needed for the Daybook "trades" vertical)

Construction Industry Scheme, contractor side:

- **Subcontractor verification** with HMRC: gross, net at 20%, or higher rate at 30%.
- **Deductions** on the labour part of each payment (materials excluded).
- **Payment and deduction statements.**
- **Monthly CIS300 return** by the 19th, through the Transaction Engine, with its own
  XSD and nil returns.
- **Recovery:** CIS deductions suffered by a limited company are reclaimed through the
  EPS.

Same rules: rates in the legislation table, a person approves, and `PAYROLL_RTI_LIVE`
gating applies. The subcontractor side (deductions suffered) already exists for Self
Assessment; link it, don't duplicate it.

## 5. Payments, ledger and billing

- **Net pay:** BACS Standard 18 file export per employer, plus a CSV for bank bulk
  upload. Open Banking payouts are **roadmap**.
- **HMRC payment:** the monthly/quarterly PAYE liability (tax + NI + loans − recoveries
  − EA) with the Accounts Office reference and payment reference, shown on a calendar.
- **Ledger:** post a journal per run into the accounting module
  (`lib/accounting-engine.lua`):
  - gross wages, employer NI and employer pension as expense;
  - PAYE/NI liability, pension liability and net wages control as liabilities.

  Corporation Tax (`PROMPT_CORPORATION_TAX.md`) reads these from the ledger.
- **Bureau billing:** a per-employer fee plan (per run / per payslip) creates invoices
  through `routes/invoices.lua` when a run closes.

## 6. API (all under `/api/v2/payroll`, auth + namespace + `payroll.*` RBAC)

Endpoints:

- employers CRUD;
- employees CRUD (+ import CSV, + import P45);
- pay elements;
- schedules;
- runs: create, calculate, line edit, approve, submit FPS, mark paid, close;
- EPS/EYU/NVREP;
- notices (list, apply);
- leave;
- pensions (assess, export);
- documents (payslip PDF via `helper/pdf-generator.lua`, P45, P60);
- reports (payroll summary, liabilities, NI by category, pension contributions, cost
  per employee/department, gender pay gap data);
- employee self-service (`/api/v2/payroll/me/*`: payslips, P60s, tax code, leave
  requests, bank details change with a re-verification step).

RBAC modules:

- `payroll` (manage employers/runs);
- `payroll_approve` (approve/submit);
- `payroll_reports`;
- `payroll_self` (employees, own data only);
- `payroll_bureau` (multi-employer).

Emit webhooks (`WEBHOOKS.md`) for `payroll.run.approved`, `payroll.fps.accepted`,
`payroll.fps.rejected`, `payroll.payslip.published`.

## 7. Phases and acceptance

1. **Engine:** legislation tables, PAYE/NI/loans, and the test suite passing HMRC's
   examples for the current year.
2. **Runs:** employers/employees/elements/schedules/runs, payslip PDFs, ledger journal,
   self-service read.
3. **RTI on the Local Test Service, then Test-in-Live:** FPS/EPS/EYU/NVREP and the DPS
   inbox.
4. **Pensions and statutory payments:** auto-enrolment, PAPDIS export, leave and
   statutory pay.
5. **Year end and bureau:** P60/P45/P11D, multi-employer bureau, billing, agent
   submission.
6. **Recognition:** apply for HMRC payroll software recognition. Flip
   `PAYROLL_RTI_LIVE` only after HMRC lists the product.

Done means:

- [ ] All phases tested.
- [ ] No rate in code.
- [ ] Every submission is XSD-valid and replay-safe.
- [ ] The Daybook demo has a seeded payroll vertical (`verticals/payroll.lua`: a café
      with 8 staff, a builder with 3 CIS workers + 2 PAYE, a director-only company)
      running against the Local Test Service only.
