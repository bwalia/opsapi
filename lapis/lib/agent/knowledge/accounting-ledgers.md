---
title: Sales & Purchase Ledgers
pages: /dashboard/accounting/sales-ledger, /dashboard/accounting/purchase-ledger
api: /api/v2/invoices, /api/v2/accounting/expenses, /api/v2/accounting/dashboard
modules: invoices, payments, accounting
tools: list_invoices
suggestions: Which invoices are more than 30 days overdue? | Which expenses are pending approval? | What is outstanding on the sales ledger?
readonly: false
---
# Sales & Purchase Ledgers
Sales Ledger = customer invoices with amount, paid, balance and age. Purchase Ledger = supplier expenses with VAT and approval status. Both are views: invoices are created/edited on the Invoices page, expenses on Bookkeeping → Expenses or Money Out.

## Using the page
- Sales Ledger: cards Total Invoiced, Outstanding, Overdue, Received This Month (shows all payments received to date); search "invoice #, customer"; status filter; table Date, Invoice #, Customer, Amount, Paid, Balance, Status, Age; click a row to open the invoice. Age from due date: Current, 1-30 days, 31-60 days, 61-90 days, 90+ days.
- Purchase Ledger: cards Expenses This Month, Pending Approval, Total Owed, VAT Reclaimable; search; filters status (Pending, Approved, Rejected, Posted) and category; table Date, Supplier, Description, Category, Amount, VAT ("R" = reclaimable), Status, Age (from expense date).
- Back arrow returns to Bookkeeping.

## Rules
- Invoice statuses stored: draft, sent, paid, void. Overdue = sent, due_date before today and balance_due > 0 — filtering status=overdue returns nothing; list `sent` and compare due_date.
- Record a payment only on sent invoices; amount > 0 and ≤ balance_due; paying the full balance marks it paid. Confirm amount, date and method first.
- Expense amounts are gross (VAT included). The category filter matches the stored category text exactly.
- Approve posts a journal entry (Dr lowest-code expense account / Cr lowest-code liability account); approving twice fails. Reject takes an optional reason (saved into notes).
- Invoice uuid is returned as `id`; expenses have `uuid`.

## API
- `GET /api/v2/invoices?page&perPage&status=draft|sent|paid|void&search&from_date&to_date` — sales ledger rows (camelCase `perPage`)
- `GET /api/v2/invoices/dashboard/stats` — total_invoiced, total_paid, total_outstanding, total_overdue, overdue_count
- `GET /api/v2/invoices/{uuid}` — invoice with line_items and payments
- `POST /api/v2/invoices/{uuid}/payments {amount*: decimal, payment_date: YYYY-MM-DD (default today), payment_method: bank_transfer|credit_card|cash|check|paypal|other, reference_number, notes}` — record a receipt
- `GET /api/v2/accounting/expenses?page&per_page&status=pending|approved|rejected|posted&category&start_date&end_date` — purchase ledger rows
- `GET /api/v2/accounting/expenses/{uuid}` — one expense
- `POST /api/v2/accounting/expenses/{uuid}/approve` — approve
- `POST /api/v2/accounting/expenses/{uuid}/reject {reason}` — reject
- `GET /api/v2/accounting/dashboard/stats` — expenses_this_month, cash_balance, vat_owed, unreconciled_count
