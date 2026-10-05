---
title: Invoices
pages: /dashboard/invoices
api: /api/v2/invoices, /api/v2/timesheets/lookups/customers
modules: invoices, payments, tax_rates_config
tools: list_invoices, create_invoice, find_customer
suggestions: Show my overdue invoices | Create an invoice for Acme Ltd | Record a payment on INV-0012
readonly: false
---
# Invoices
Create and track customer invoices. Lifecycle: `draft` → `sent` → `paid` (set automatically when payments cover the total); any non-void invoice can be voided. Only draft, sent, paid and void are ever stored — "overdue" means status `sent`, due date in the past and balance_due > 0. Numbers (INV-0001…) and totals are computed by the server.

## Using the page
- List: cards Total Invoiced, Paid, Outstanding, Overdue; search (invoice #, customer name, email); status filter; From/To dates; click a row to open the invoice.
- **Create Invoice**: Customer Name*, Customer Email, Issue Date*, Due Date* (auto = issue date + Payment Terms (days), default 30), Currency (USD, EUR, GBP, CAD, AUD, INR), Notes. It creates an empty draft — open it and use **Add Item**.
- **From Timesheets**: pick a Customer and From/To dates; it previews that customer's approved, billable, not-yet-invoiced hours (Date, Work, Hours, Rate, Amount); **Generate Invoice** makes one draft with a line per entry.
- Invoice page: Preview, Download PDF, Edit (draft), **Send** (draft; emails the PDF to the customer email and marks it sent), Record Payment (sent), Void, Delete (draft). Line Items: **Add Item** (Description*, Quantity*, Unit Price*, Tax Rate (%)) and a remove icon (draft only). Payments section lists payments.

## Rules
- Create needs `customer_name`. Currency defaults to GBP when omitted (the form defaults to USD) — confirm the currency with the user. Confirm items and amounts before creating.
- Delete and send only drafts. Header fields can be edited on draft or sent; add/change/remove line items only on drafts.
- Line total = quantity × unit_price, minus discount_percent %, plus tax_rate % on the discounted amount. Rates are percents (20 = 20% VAT).
- Payments: not allowed on draft or void invoices; amount > 0 and not more than balance_due. When balance_due reaches 0 the invoice becomes `paid`; deleting a payment reopens it as `sent`. Needs the `payments` permission.
- Void cannot be undone. Emailing the PDF happens in the browser: ask the user to click **Send** on the invoice page (needs a customer email). Through the API you can only mark it sent.
- From-customer bills approved timesheet entries that have a rate (entry → timesheet → the hourly_rate you pass); entries already invoiced are skipped.
- Responses return the uuid as `id` (invoices, line items, payments). Find an invoice by number with `search`.
- Customer lookup `q` matches one of first name, last name or email — search one word.

## API
- `GET /api/v2/invoices?page&perPage&status=draft|sent|paid|void&search&from_date&to_date` — list (dates YYYY-MM-DD on issue date; note camelCase `perPage`, max 500)
- `GET /api/v2/invoices/dashboard/stats` — total invoiced/paid/outstanding/overdue, overdue_count, by_status
- `GET /api/v2/invoices/{uuid}` — invoice with line_items[] and payments[]
- `POST /api/v2/invoices {customer_name*, customer_email, customer_address, issue_date: YYYY-MM-DD (default today), due_date: YYYY-MM-DD, currency: ISO code, payment_terms_days: int, notes, line_items: [{description*, quantity: number (default 1), unit_price: decimal, tax_rate: percent, discount_percent: percent}]}` — create a draft
- `PUT /api/v2/invoices/{uuid} {customer_name, customer_email, customer_address, issue_date, due_date, currency, payment_terms_days, notes}` — update
- `DELETE /api/v2/invoices/{uuid}` — delete a draft
- `POST /api/v2/invoices/{uuid}/send` — mark a draft as sent (no email)
- `POST /api/v2/invoices/{uuid}/void` — void
- `POST /api/v2/invoices/{uuid}/items {description*, quantity, unit_price, tax_rate, discount_percent}` — add line item
- `PUT /api/v2/invoices/items/{item_uuid} {description, quantity, unit_price, tax_rate, discount_percent}` — update line item
- `DELETE /api/v2/invoices/items/{item_uuid}` — remove line item
- `GET /api/v2/invoices/{uuid}/payments` — list payments
- `POST /api/v2/invoices/{uuid}/payments {amount*: decimal, payment_date: YYYY-MM-DD (default today), payment_method: bank_transfer|credit_card|cash|check|paypal|other, reference_number, notes}` — record payment
- `DELETE /api/v2/invoices/payments/{payment_uuid}` — delete a payment
- `GET /api/v2/invoices/customer-billable?customer_uuid*&from&to&hourly_rate` — preview un-invoiced billable hours
- `POST /api/v2/invoices/from-customer {customer_uuid*, period_start: YYYY-MM-DD, period_end: YYYY-MM-DD, hourly_rate, due_date, currency}` — generate a draft from approved timesheets
- `GET /api/v2/invoices/tax-rates` — configured tax rates (name, rate %)
- `GET /api/v2/timesheets/lookups/customers?q=` — customers (uuid, first_name, last_name, email)
