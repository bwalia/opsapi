# Build prompt: Payroll UI (opsapi-dashboard, and opsapi-ui if still in use)

Build the payroll screens on top of the `payroll` API in `PROMPT_PAYROLL.md`. Read that
first. The API contract there is the source of truth; if the UI needs something it
doesn't offer, add it to the API, not a workaround in the browser.

**Where:**

- **Primary:** `opsapi-dashboard/` (Next.js 16 App Router, React 19, Tailwind v4,
  Zustand). Tax and VAT already live there, and it is what the Daybook demo
  (`demo.daybook.co.uk`) runs.
- **`../opsapi-ui`** (React-Admin + Vite; last change Oct 2025): ask the user whether it
  is still deployed before building anything there. If it is, add the read-only
  resources only (employers, employees, runs, submissions) as React-Admin
  `<Resource>`s using its existing data provider, and link "Open in dashboard" for
  actions.

---

## 0. Ground rules

- **Follow the dashboard's conventions:**
  - `services/payroll.service.ts` through `lib/api-client.ts` (JWT + namespace
    headers);
  - pages under `app/dashboard/payroll/**`;
  - the backend-driven menu (add the menu items in a migration, gated on `payroll`,
    like `tax-menu-file-my-tax.lua`);
  - `PermissionsContext` checks for `payroll`, `payroll_approve`, `payroll_bureau`
    and `payroll_self`.
- **The browser never calculates pay.** It shows what the API returns. A "preview"
  is an API calculate call on a draft.
- **Sensitive fields:** NINO and bank details are masked by default. A "Reveal" button
  calls the API, which audits the view; don't cache the revealed value. No PII in
  console logs, URLs or analytics.
- **Approval is deliberate:**
  - The approve dialog shows totals (gross, net, employer cost, HMRC liability,
    pension), the employee count, and differences against the last run over 10%.
  - It needs a checkbox, and is disabled for users without `payroll_approve`.
  - Submit-to-HMRC is a separate step after approval.
- **Plain English for HMRC errors:** map RTI error codes to messages with a "what to
  do" line. Show the raw code in a details row.
- **Accessibility:** WCAG 2.2 AA. Tables are keyboard navigable (reuse
  `useGridNavigation`).
- **Theming:** use theme tokens only, so the Daybook theme (navy/gold, see
  `DAYBOOK_DEMO_SPEC.md`) and any practice's white-label theme apply automatically.

## 1. Screens

| Route | Who | What |
|---|---|---|
| `/dashboard/payroll` | payroll staff | Overview per employer: next pay date, run status, RTI status (FPS/EPS due/sent/accepted), HMRC liability due, unapplied HMRC notices, pension tasks, NMW warnings |
| `/dashboard/payroll/employers` (+`/[id]`) | bureau | Employer list (bureau mode shows CRM account link), setup wizard: PAYE ref + Accounts Office ref → schedules → pay elements → pension scheme → RTI sender (self/agent, credentials stored in vault) → opening YTD import |
| `/dashboard/payroll/employees` (+`/[id]`) | staff | List with filters; profile tabs: personal (masked), employment, tax code history, NI category, loans, pension, leave, payslips, documents, audit. Starter wizard (P45 upload/fields or starter declaration A/B/C) and leaver wizard (P45) |
| `/dashboard/payroll/import` | staff | CSV import of employees and opening YTD, with a column mapper, validation report and dry run |
| `/dashboard/payroll/runs` (+`/[id]`) | staff | Create run → grid of employees × elements (editable on draft, hours pulled from approved timesheets with a link) → Calculate → review: per-employee drill-down with each deduction explained, warnings (NMW, negative net, big change) → Approve → Submit FPS → Payment file (BACS/CSV) → Mark paid → Close. Status timeline |
| `/dashboard/payroll/rti` | staff | All submissions (FPS/EPS/EYU/NVREP/CIS300) with status, polling state, HMRC response, resubmit where allowed |
| `/dashboard/payroll/notices` | staff | DPS inbox: P6/P9/SL1/SL2/PGL/NINO replies; apply with one click (audited) |
| `/dashboard/payroll/eps` | staff | Monthly EPS builder: recoveries, EA, levy, no payment for period |
| `/dashboard/payroll/leave` | staff, managers | Calendar + requests; statutory pay calculators show the API's figures and evidence uploads |
| `/dashboard/payroll/pensions` | staff | Assessment results, enrolment communications status, opt-out window, contribution files to download, re-enrolment date, declaration of compliance reminder |
| `/dashboard/payroll/cis` | staff | Subcontractors, verification results, monthly CIS300 builder and statements |
| `/dashboard/payroll/year-end` | staff | Checklist with deadlines: final FPS/EPS, P60 publish, P11D(b), EYU corrections |
| `/dashboard/payroll/reports` | staff, owner | Summary, liabilities calendar, cost by department, pension contributions, NI by category, gender pay gap data; CSV/PDF export |
| `/dashboard/payroll/settings` | owner | Legislation table viewer (read-only per year, with source URLs), fee plans (bureau), payslip template branding |
| `/dashboard/my-pay` | every employee (`payroll_self`) | Payslips (PDF), P60s, tax code, YTD, leave balance and requests, bank details change (re-verify), "Explain my payslip" (AI explains lines the API returned, no new figures) |

Bureau mode adds an employer switcher in the header, which persists per user. A member
sees only their assigned employers.

## 2. Components to build once

- `PayslipView`: the same layout as the PDF.
- `MoneyCell`: pence-exact, tabular figures.
- `DeductionExplainer`: shows the API's `explanation` array.
- `RunStatusTimeline`.
- `HmrcStatusBadge`.
- `MaskedField`: reveal + audit.
- `DeadlineCalendar`: shared with VAT/CT.

## 3. Tests

- **Cypress e2e (`cypress/e2e/payroll/*.cy.ts`):**
  - set up employer → add 3 employees → run → approve → FPS on the Local Test Service
    (or a stubbed API in CI);
  - payslip visible to the employee only;
  - a member without `payroll_approve` can't approve;
  - masked fields stay masked in the DOM until revealed.
- `npm run lint`, `npm run type-check` and the build all pass.

## 4. Daybook demo

The `payroll` vertical in `DAYBOOK_DEMO_SPEC.md` (namespace `daybook-payroll`) must look
right:

- every screen above renders with seeded data for the read-only viewer;
- write buttons show a tooltip "Read-only demo" instead of failing silently on a 403.
