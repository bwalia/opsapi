# Build prompt: Payroll in the iPhone and Android apps

Add payroll to the mobile apps for three kinds of user: **employees**, **employers and
managers**, and **practice payroll staff**. The apps call the `payroll` API in
`PROMPT_PAYROLL.md`; read it first.

**Where:** extend the existing Flutter app in `../diy-tax-return-uk/ios_app/`. It
targets iOS and Android, uses Riverpod and Dio, and already handles OpsAPI sign-in, OTP,
PIN/app lock and push. Don't start a second app. The apps are white-labelled per
practice (Daybook's "your brand, not ours" promise), so payroll must follow the app's
existing theme/flavour mechanism. If there is no flavour mechanism yet:

- propose the smallest one (build-time flavour with the name, icon, theme colours and
  API base URL, as `--dart-define`s or a flavour config);
- add a **Daybook** flavour using `DAYBOOK_DEMO_SPEC.md`'s navy/gold palette.

Confirm the approach with the user before restructuring the app.

---

## 0. Ground rules

- **The app never calculates pay** or shows a figure the API didn't return.
- **Sensitive data:**
  - payslips and P60s are downloaded to app-private storage, encrypted, and deleted on
    sign-out;
  - no NINO or bank details are shown unmasked without re-authentication (PIN or
    biometrics, via the existing app lock);
  - no PII in logs or crash reports;
  - screenshots are blocked on payslip screens on Android (`FLAG_SECURE`).
- **Approvals on mobile:** an employer can approve a pay run from the phone only:
  - after re-authentication;
  - with the same totals and warnings the dashboard shows (`PROMPT_PAYROLL_UI.md` §0);
  - with a user who has `payroll_approve`.

  Submitting to HMRC also happens after approval, as a separate action.
- **Push** (existing `fcm-push` / `apns-push` helpers on the server):
  - payslip published;
  - leave request decided;
  - run awaiting approval;
  - FPS rejected;
  - HMRC deadline in 3 days.

  Notification text carries no amounts.
- **Offline:** cache the last 12 payslips (encrypted) for viewing; every action needs a
  connection.
- **Accessibility:** Dynamic Type / font scaling, screen reader labels on every money
  figure (read as "one thousand two hundred pounds and fifty pence"), and contrast AA.
- **Store compliance:** privacy nutrition labels / Data safety form updated for payroll
  data (financial info, identifiers). Account deletion in the app stays working.

## 1. Screens

**Employee (`payroll_self`):**

- My pay: next pay date, latest payslip summary, YTD.
- Payslips list → payslip detail (same layout as the PDF), "Explain this payslip" (AI
  explanation from the API), share/save PDF.
- P60s and P45.
- Tax code and what it means.
- Leave: balance, request holiday, report sickness (with fit note photo upload),
  request statutory leave (opens a form for the employer).
- Timesheets: submit hours if the employer uses `timesheets`.
- Bank details change (re-auth + server re-verification + email confirmation).
- Pension: scheme, contribution rate, opt-out information (link to the provider; the
  app does not process opt-outs itself unless the API supports it).

**Employer / manager:**

- Today: next run, status, approvals waiting, leave requests, HMRC liability due.
- Approve pay run (totals, warnings, per-employee drill-down, re-auth, approve).
- Leave and timesheet approvals.
- Employees list (masked) and add a starter (basic details + invite to the app; P45
  photo upload goes to payroll staff).

**Practice payroll staff (bureau):**

- Employer switcher.
- Runs due this week across clients.
- RTI rejections to fix.
- HMRC notices to apply (apply needs re-auth).

## 2. Engineering

- **Packages:**
  - `lib/payroll/` with `payroll_api.dart` (Dio, through the existing auth
    interceptor), Riverpod providers, models with `fromJson`, and views per screen;
  - reuse `components/` and `theme/`.
- **Money:** integer pence from the API, formatted with `intl` `en_GB`. Never `double`
  arithmetic.
- **Deep links** from push to the right screen (`/payroll/payslip/<id>`,
  `/payroll/run/<id>/approve`).
- **Tests:** widget tests for payslip rendering and masked fields; integration tests
  against a stubbed API for approve-with-re-auth and the leave request flow.
- **Release:** the existing fastlane lanes, with a version bump and a TestFlight /
  internal testing track first.

## 3. Daybook demo and videos

- The demo flavour points at `demo-api.daybook.co.uk`, namespace `daybook-payroll`.
- Read-only users see action buttons with a "Read-only demo" note.
- Record the mobile videos in `devops/daybook-videos` with these scenes:
  - employee views payslip and asks "explain";
  - manager approves a run;
  - sickness report with fit note.
