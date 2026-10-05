---
title: File your tax (HMRC)
pages: /dashboard/tax/file
api:
modules:
tools:
suggestions: Walk me through filing my tax return | Why is step 4 blocking my return? | What does the final declaration do?
readonly: true
---
# File your tax
A 6-step guided wizard that files a UK Self Assessment (self-employment) return with HMRC through Making Tax Digital. Steps unlock in order and show as done, active or locked. You only explain: every step talks to HMRC or is legally binding, so the user clicks each button themselves.

## Using the page
- "Tax year" box (top right, e.g. 2025-26). Changing it resets steps 3–5; step 3 normally sets it from HMRC's open period.
1. Connect to HMRC — "Connect to HMRC" (or "Reconnect to HMRC" if expired) opens HMRC's sign-in. Done when the authorisation is active. Sandbox test logins: HMRC settings → Sandbox testing.
2. Select your business — HMRC needs the National Insurance number: type it (e.g. QQ123456C), tick the consent box, click Save ("Change" / "Remove" later). The business is then fetched automatically; if there are several, click one. "Try again" / "Refresh from HMRC" retry; a not-authorised error shows "Reconnect to HMRC".
3. Your filing period — open HMRC obligations load automatically; click a period to choose it (this sets the tax year). No open periods is fine — continue anyway.
4. Check your figures — totals the classified transactions for the year: Rows, In return, Need review, Off-summary, and "Exactly what we'll send to HMRC". A red box lists credits filed as expenses that make a figure negative (HMRC rejects these): pick "Correct this to…" (Business income (sales / turnover), Other business income, Personal / transfer — exclude from return) and click Fix. Amber notes: Pending/Needs-review rows are left out; use of home and capital allowances are not in this summary. "Re-check figures" recalculates. Done when nothing blocks and at least one transaction is in the return.
5. Preview your calculation — "Run preview calculation" sends the figures to HMRC and returns a non-binding calculation (Tax & NICs due, Taxable income, Income tax, Personal allowance, Class 2 NIC, Class 4 NIC). It does not file. It can take a while — keep the page open. In the sandbox the total shows "—" (placeholder).
6. Finalise & declare — the binding final declaration that files the return. Tick "I declare that the information I have given is correct and complete…" then click "Submit final declaration & file". Success shows "Your tax return has been filed with HMRC" and the HMRC calculation reference.

## Rules
- Never perform any step for the user and never claim you did. Only the user connects HMRC, enters the National Insurance number, runs the calculation and submits the declaration. Do not ask for or repeat their National Insurance number.
- The final declaration is legally binding. Before step 6, urge the user to check every figure (ideally with an accountant). Live HMRC refuses a final declaration before the tax year has ended (after 5 April).
- Only CLASSIFIED or CONFIRMED transactions with an HMRC box count. To change figures, fix transactions on Transactions (/dashboard/tax/transactions), then click "Re-check figures".
- "No classified transactions fall in tax year …" means the statements are for another year: upload and classify statements for that year, or choose the matching period in step 3.
- Tax year format is YYYY-YY (e.g. 2025-26).
