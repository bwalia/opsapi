---
title: Bookkeeping
pages: /dashboard/accounting
api: /api/v2/accounting
modules: accounting
tools:
suggestions: Show unreconciled bank transactions | Add a £45 software expense for today | Run a trial balance as of today
readonly: false
---
# Bookkeeping
Double-entry books (GBP): journal entries against the chart of accounts (asset, liability, equity, revenue, expense); reports read posted entries. Bank transactions are imported, then reconciled to an account. Expenses go pending → approved/rejected. VAT returns are calculated per period (draft), then marked submitted.

## Using the page
- Tabs: **Overview** (cards Cash Balance, Expenses This Month, VAT Owed, Unreconciled; quick actions Import Bank Statement, Add Expense, Create Journal Entry, Generate VAT Return; links to Money In/Out and Sales/Purchase Ledger), **Bank Transactions** (search, All/Reconciled/Unreconciled; row icons AI Suggest Category and Reconcile), **Expenses** (status filter; Approve/Reject icons), **Reports** (sub-tabs Trial Balance, Balance Sheet, P&L, VAT Returns; set dates, click Apply; New VAT Return; Submit), **Chart of Accounts** (Add Account).
- Import Bank Statement: paste CSV whose header has a date column and an `Amount` column (negative = money out); dates DD/MM/YYYY or YYYY-MM-DD.
- Reconcile: pick the Target Account. Add Expense: Date, Amount (gross), Description, Category (expense account name), VAT Rate 0/5/20%, Vendor; AI Categorize suggests category + VAT.
- Create Journal Entry: Date, Reference, Description, at least 2 lines of account + debit or credit.

## Rules
- Journal entries must balance (debits = credits within 0.01) else "Journal entry is unbalanced". Each line: amounts ≥ 0, debit OR credit, never both. Lines use the account's numeric `id` from GET accounts (not uuid) — only ids from this workspace's list, never guessed.
- Entries post immediately, no editing: void (reason required) and re-enter.
- Account codes are unique per workspace. normal_balance defaults to debit for asset/expense, credit otherwise. Accounts with journal lines can't be deleted — set is_active=false instead.
- A new workspace may have no accounts: offer UK defaults (1000 Bank Account asset, 2000 Accounts Payable + 2100 VAT Payable liability, 3000 Owner's Equity, 4000 Sales Revenue, 6xxx expenses e.g. 6070 Software) and create them only after the user agrees.
- Reconcile posts the gross amount between the bank (first asset account with code "1…") and the target: money in Dr bank / Cr target, money out the reverse. Only once per transaction.
- Expenses: amount is gross; vat_amount = amount × rate / (100 + rate); category is required. Approve posts Dr lowest-code expense account / Cr lowest-code liability account (skipped if either is missing); approving twice fails.
- VAT returns: boxes are calculated from approved expenses and bank transactions' vat_amount in the period. Submit only marks it submitted in OpsAPI (nothing is sent to HMRC) and can't be repeated — confirm first.
- Rows carry numeric `id` and `uuid`; URL paths take the `uuid`.

## API
- `GET /api/v2/accounting/dashboard/stats`
- `GET /api/v2/accounting/accounts?page&per_page (default 50, max 500)&type=asset|liability|equity|revenue|expense&is_active=true|false`
- `POST /api/v2/accounting/accounts {code*, name*, account_type*, sub_type, description, normal_balance: debit|credit, parent_id: account id, currency (default GBP)}`
- `GET /api/v2/accounting/accounts/{uuid}`; `PUT /api/v2/accounting/accounts/{uuid}` `{code, name, account_type, sub_type, description, normal_balance, is_active, currency, parent_id}`; `DELETE /api/v2/accounting/accounts/{uuid}`
- `GET /api/v2/accounting/journal-entries?page&per_page&status=posted|void&start_date&end_date`; `GET /api/v2/accounting/journal-entries/{uuid}` (with lines)
- `POST /api/v2/accounting/journal-entries {entry_date*: YYYY-MM-DD, description*, reference, lines*: [{account_id*: account id, debit_amount: decimal, credit_amount: decimal, description}]}`
- `POST /api/v2/accounting/journal-entries/{uuid}/void {reason*}`
- `GET /api/v2/accounting/bank-transactions?page&per_page&is_reconciled=true|false&start_date&end_date&search` (search = description)
- `POST /api/v2/accounting/bank-transactions/import {transactions*: [{date*: YYYY-MM-DD, description, amount*: signed decimal (+ in, − out), balance, category}]}` or `{csv_content*}`
- `PUT /api/v2/accounting/bank-transactions/{uuid} {category, description, vat_rate, vat_amount, payee, reference, user_category}`
- `POST /api/v2/accounting/bank-transactions/{uuid}/reconcile {account_id*: account id}`
- `GET /api/v2/accounting/expenses?page&per_page&status=pending|approved|rejected|posted&category&start_date&end_date`
- `POST /api/v2/accounting/expenses {description*, amount*: gross decimal, category*, expense_date: YYYY-MM-DD (default today), vat_rate: 0|5|20, vat_amount, is_vat_reclaimable: bool, vendor, receipt_url, notes}`; `PUT /api/v2/accounting/expenses/{uuid}` takes the fields; `DELETE /api/v2/accounting/expenses/{uuid}`
- `POST /api/v2/accounting/expenses/{uuid}/approve`; `POST /api/v2/accounting/expenses/{uuid}/reject {reason}`
- `GET /api/v2/accounting/vat-returns`; `POST /api/v2/accounting/vat-returns {period_start*, period_end*}`; `POST /api/v2/accounting/vat-returns/{uuid}/submit`
- `GET /api/v2/accounting/reports/trial-balance?as_of_date`, `/reports/balance-sheet?as_of_date`, `/reports/profit-loss?start_date&end_date` (default this month), `/reports/expense-summary?start_date&end_date` (default year to date)
