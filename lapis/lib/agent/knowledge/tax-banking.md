---
title: Tax bank accounts & statements
pages: /dashboard/tax/bank-accounts, /dashboard/tax/statements
api: /api/v2/tax/bank-accounts, /api/v2/tax/statements, /api/v2/tax/extract, /api/v2/tax/classify, /api/v2/tax/profiles, /api/v2/tax/profile/preferences
modules:
tools:
suggestions: Add my Barclays business account | Which statements still need classifying? | Classify my latest extracted statement
readonly: false
---
# Bank accounts & statements
Bank accounts hold the user's uploaded bank statements. Each statement is extracted into transactions, then AI-classified into tax categories. Statement progress (workflow_step): UPLOADED → EXTRACTED → CLASSIFIED; processing_status PROCESSING/CLASSIFYING while running, ERROR on failure. Data belongs to the signed-in user.

## Using the page
Bank Accounts:
- "Add Account" → "Add Bank Account": Bank Name*, Account Number, Sort Code, Account Type (Current / Savings / Business / Credit Card), Currency (GBP / EUR / USD) → Create.
- Pencil = edit ("Edit Bank Account" → Update); bin = delete. "Search bank accounts..." filters by name or number.
Bank Statements:
- "Upload Statement": Bank Account*, Statement Date (optional), File* (PDF, CSV, JPG, PNG, GIF, WebP; max 25MB) → Upload. You cannot upload files — guide the user through it.
- Row actions by status: Uploaded → ▶ (Extract transactions); Extracted → "Classify" and 👁 (View transactions); Classified → 👁 and ⟳ (Re-classify); bin = delete.
- "Classify as:" dropdown = business profile used for classification; "Set as my default" saves it.
- After extract/classify a "Transactions — <file>" window lists the rows; "Open full transactions page →" to edit them.
- "HMRC" button → HMRC settings. "Delete All" deletes every statement and transaction (user only).

## Rules
- Every id is a uuid. List endpoints return the uuid in `id`; use it for {uuid} and statement_id.
- A bank account is needed before uploading.
- Send field values as strings (booleans as true/false). account_type: current|savings|business ("Credit Card" in the form is rejected). currency: GBP|EUR|USD. account_number: 6–20 digits. sort_code: 6 digits, e.g. 20-00-00 or 200000. bank_name: max 100 chars.
- Deleting a bank account that has statements only deactivates it; otherwise it is removed.
- Deleting a statement permanently deletes all its transactions.
- Extract only when workflow_step is UPLOADED or EXTRACTED (else 409). Re-extracting skips duplicate rows. Max 10 extracts/minute.
- Classify only processes PENDING rows; reclassify=true also redoes AI rows (CLASSIFIED/NEEDS_REVIEW) but never user-CONFIRMED rows. Low-confidence or risky rows become NEEDS_REVIEW (left out of the HMRC return until reviewed). It can take several minutes; if the call times out, ask the user to refresh later. Max 5/minute. Refused (409) for FILED statements.
- profile_type: the per-run value wins, then the saved default, then sole_trader; unknown keys fall back to sole_trader. Get keys from GET /api/v2/tax/profiles.
- Only call the endpoints listed below.

## API
- `GET /api/v2/tax/bank-accounts?page&perPage` — my active accounts: id (uuid), bank_name, account_name, account_number, sort_code, account_type, currency, is_primary, statement_count
- `GET /api/v2/tax/bank-accounts/{uuid}`
- `POST /api/v2/tax/bank-accounts {bank_name*, account_name, account_number, sort_code, account_type: current|savings|business, currency: GBP|EUR|USD, is_primary: bool}` — first account becomes primary
- `PUT /api/v2/tax/bank-accounts/{uuid} {bank_name, account_name, account_number, sort_code, account_type, currency, is_primary}` — send only changed fields
- `DELETE /api/v2/tax/bank-accounts/{uuid}`
- `GET /api/v2/tax/statements?page&perPage&bank_account_id={account uuid}&workflow_step=UPLOADED|EXTRACTED|CLASSIFIED&processing_status=PROCESSING|COMPLETED|ERROR&tax_year=2025-26&search` — newest first; id, bank_name, file_name, statement_date, workflow_step, processing_status, transaction_count, classified_count
- `GET /api/v2/tax/statements/{uuid}`
- `GET /api/v2/tax/statements/{uuid}/transactions?page&perPage` — rows (row `id` = transaction uuid) with category, confidence_score, classification_status
- `DELETE /api/v2/tax/statements/{uuid}`
- `POST /api/v2/tax/extract {statement_id*: statement uuid}` — returns transactions_parsed, transactions_saved, transactions_skipped, transactions_failed
- `POST /api/v2/tax/classify {statement_id*: statement uuid, profile_type, reclassify: true}` — returns classified, needs_review, total, profile_type
- `GET /api/v2/tax/profiles` — data[]: profile_key, display_name, filing_supported
- `PUT /api/v2/tax/profile/preferences {default_profile_key*}` — save the default business profile
