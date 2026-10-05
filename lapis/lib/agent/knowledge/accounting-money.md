---
title: Money In / Money Out
pages: /dashboard/accounting/money-in, /dashboard/accounting/money-out
api: /api/v2/accounting/bank-transactions, /api/v2/accounting/journal-entries, /api/v2/accounting/accounts
modules: accounting
tools:
suggestions: Record £1,200 received from Acme for consulting | Record a £30 software subscription paid today | Show money in this month
readonly: false
---
# Money In / Money Out
Spreadsheet-style entry of bank receipts (Money In: sales, income) and payments (Money Out: purchases, expenses), in GBP. Each saved row creates a bank transaction and, when a Category account is chosen, a balanced journal entry that splits out VAT. Amounts are gross (VAT-inclusive).

## Using the page
- **Add Row**, then fill Date*, Description*, Customer (Money In) or Supplier (Money Out), Category* (Money In: revenue accounts; Money Out: expense accounts), Amount In / Amount Out*, VAT Rate (0% zero rated, 5% reduced, 20% standard), Reference. VAT Amount fills in automatically.
- Tab = next cell, Enter = save row and move down, Esc = deselect; a row auto-saves when you leave it. The refresh icon reloads.
- Cards: Money In shows Total Received, VAT Collected, Entries; Money Out shows Total Spent, VAT Reclaimable, Entries. The grid lists the latest 50 bank transactions (money in or money out).
- Back arrow returns to Bookkeeping.

## Rules
- Confirm date, amount, category and VAT rate with the user before saving.
- VAT from gross: vat = round(amount × rate / (100 + rate), 2); net = amount − vat.
- The sign of the bank transaction amount sets the direction: positive = money in, negative = money out. For Money Out send a NEGATIVE amount.
- Bank transaction description like the page: "Description (Customer or Supplier) Ref: reference".
- Journal for Money In: Dr bank account gross / Cr chosen revenue account net / Cr VAT account vat (if > 0); description "Sales receipt: <description>".
- Journal for Money Out: Dr chosen expense account net / Dr VAT account vat (if > 0) / Cr bank account gross; description "Purchase: <description>". reference = the Reference.
- Resolve accounts first with GET accounts and use their numeric `id`: bank = asset "Bank Account" (code 1000, else the first asset with a code starting "1"); VAT = liability "VAT Payable" (2100); category = the revenue/expense account the user names. If one is missing, say so and offer to create it — never guess ids.
- Debits must equal credits; each line has debit OR credit, amounts ≥ 0.
- For VAT to count in VAT returns, also store it on the bank transaction: find it (GET bank-transactions with search = description and start_date = end_date = the date), then PUT {vat_rate, vat_amount}.
- Do not also Reconcile a row whose journal you posted here — that books it twice.
- Mistakes: void the journal entry (reason required); bank transactions can't be deleted, only edited.

## API
- `GET /api/v2/accounting/accounts?type=revenue|expense|asset|liability&is_active=true&per_page=200` — account list with numeric `id`, code, name
- `POST /api/v2/accounting/accounts {code*, name*, account_type*: asset|liability|equity|revenue|expense, description}` — create a missing account
- `GET /api/v2/accounting/bank-transactions?page&per_page&start_date&end_date&search&is_reconciled=true|false` — recent transactions
- `POST /api/v2/accounting/bank-transactions/import {transactions*: [{date*: YYYY-MM-DD, description, amount*: signed decimal, category}]}` — create; returns count and batch_id (no uuid)
- `PUT /api/v2/accounting/bank-transactions/{uuid} {vat_rate, vat_amount, category, description, payee, reference}` — update
- `POST /api/v2/accounting/journal-entries {entry_date*: YYYY-MM-DD, description*, reference, lines*: [{account_id*: account id, debit_amount: decimal, credit_amount: decimal, description}]}` — post a journal
- `GET /api/v2/accounting/journal-entries?start_date&end_date&status=posted|void` — list journals
- `POST /api/v2/accounting/journal-entries/{uuid}/void {reason*}` — reverse a journal
