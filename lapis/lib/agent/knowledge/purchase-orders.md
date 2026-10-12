---
title: Purchase Orders
pages: /dashboard/purchase-orders
api: /api/v2/purchase-orders, /api/v2/kanban/projects, /api/v2/crm/accounts
modules: purchase_orders
tools: list_projects, list_crm_accounts
suggestions: Which purchase orders are waiting for delivery? | Raise a PO to Bob Builders for 10 sheets of plasterboard | What is ready to bill?
readonly: false
---
# Purchase Orders
Orders the business places with suppliers (builders, merchants), e.g. materials and labour for a renovation. Lifecycle: `draft` → `sent` → `acknowledged` → `partially_received` → `received` → `billed`; `draft`, `sent` and `acknowledged` can be `cancelled`. `sent`/`acknowledged` may go straight to (partially_)received. A PO can have several bills: each bills what has arrived and isn't billed yet, and the PO stays open for more deliveries; it is `billed` once everything is received and billed, or after it is **closed short** (no more goods coming). Voiding a bill reopens a `billed` PO to `received`. `cancelled` is final. Numbers (PO-000001…) and totals are set by the server.

## Using the page
- List: cards Open (sent/acknowledged/partially received, value), Overdue deliveries (expected date passed), To bill (goods received, not billed — part-received POs too), Billed; values are shown per currency; search (PO #, supplier, reference); status filter; Supplier, From/To (issue date) filters; click a row to open the PO.
- **New Purchase Order**: Supplier Name*, Supplier Email/Phone/Address, Reference, Issue Date, Expected Date, Delivery Address, Currency (default GBP), Project (optional renovation project), Notes, Terms. It creates a draft — open it and use **Add Line**.
- PO page: Download PDF, Edit (draft/sent/acknowledged; currency only while draft), **Send** (draft; emails the PDF to the supplier email and marks it sent), Mark Sent (no email), Acknowledged, **Receive Goods** (enter what arrived in this delivery per line, or Receive All for everything outstanding), **Bill Received Goods** (shows what the bill covers), **Close Short** (partially received; reason required), Cancel, Delete (draft). Bills list with **Void** per bill. Lines: **Add Line** (Description*, Quantity*, Unit Price, Tax Rate %) and remove (draft only). The linked project links to its board.

## Rules
- Create needs `supplier_name` (or a CRM `supplier_company_uuid`, which fills the supplier details). Confirm the supplier, lines and amounts with the user before creating.
- Lines can be added/changed/removed only on drafts. Header fields can be edited on draft, sent or acknowledged. Only drafts can be deleted; send needs at least one line.
- Line total = round(quantity × unit_price, 2) plus round(that × tax_rate %, 2) (20 = 20% VAT). unit_price has at most 2 decimals, quantity at most 3, tax_rate at most 2 — more is refused, not rounded.
- Currency: a 3-letter ISO code (default GBP); it can't change once the PO is sent.
- Receive: `quantity` is what arrived **now** for that line; it is added to what was received before and can't exceed what is still outstanding. `received_quantity` (old running-total field) is refused. All lines complete → `received`; otherwise `partially_received`.
- Bill (convert-to-bill): bills what is received and not yet billed. When Bookkeeping is enabled it creates a pending expense (vendor = supplier, category `purchases` unless you pass one) in the purchase ledger and needs the accounting create permission too. The purchase ledger is GBP-only: a bill for a non-GBP PO isn't posted there (the bill's `ledger_note` says so). Bills are in `metadata.bills[]` (uuid, net, tax, gross, lines, expense_uuid); the response's `bill` is the new one.
- Void a bill: only while its ledger expense is pending (or was rejected); an approved expense must be reversed in Bookkeeping first. Its quantities can then be billed again. Needs the accounting delete permission when Bookkeeping is on.
- Close short: only `partially_received`, with a reason; nothing more can be received. Unbilled goods → `received` (bill them), otherwise → `billed`.
- Emailing the PDF happens in the browser: ask the user to click **Send** on the PO page (needs a supplier email). Through the API you can mark it sent or email without the PDF. An email is queued (or handed to the workspace's mail server), not confirmed delivered; `to` is one address.
- Server-owned metadata (receipts, bills, closed, *_reason) can't be set through create/update.
- Responses return the uuid as `id`. Find a PO by number with `search`. `project_uuid` must be a project in this workspace (find it with list_projects).

## API
- `GET /api/v2/purchase-orders?page&perPage&status=draft|sent|acknowledged|partially_received|received|billed|cancelled&supplier&project_uuid&from_date&to_date&search` — list (status may be a comma list; dates YYYY-MM-DD on issue date)
- `GET /api/v2/purchase-orders/stats` — open/overdue/to-bill/draft counts; values per currency in by_currency[] (open_value, to_bill_value, billed_value, total_value); by_status counts
- `GET /api/v2/purchase-orders/{uuid}` — PO with items[] and project
- `POST /api/v2/purchase-orders {supplier_name*, supplier_email, supplier_phone, supplier_address, supplier_company_uuid, reference, issue_date: YYYY-MM-DD, expected_date: YYYY-MM-DD, delivery_address, currency: ISO code (default GBP), notes, terms, project_uuid, items: [{description*, quantity: number, unit_price: decimal, tax_rate: percent}]}` — create a draft
- `PUT /api/v2/purchase-orders/{uuid} {supplier_name, supplier_email, supplier_phone, supplier_address, reference, issue_date, expected_date, delivery_address, currency, notes, terms, project_uuid}` — update
- `DELETE /api/v2/purchase-orders/{uuid}` — delete a draft
- `POST /api/v2/purchase-orders/{uuid}/send` — mark a draft as sent (no email)
- `POST /api/v2/purchase-orders/{uuid}/email {to: one email (default: the supplier email), subject, message}` — email the supplier (lines in the body); marks a draft sent; 20 per 10 minutes per user
- `POST /api/v2/purchase-orders/{uuid}/acknowledge` — supplier confirmed the order
- `POST /api/v2/purchase-orders/{uuid}/receive {items: [{item_uuid*, quantity*: received now}], receive_all: boolean, note}` — record a delivery
- `POST /api/v2/purchase-orders/{uuid}/convert-to-bill {bill_date: YYYY-MM-DD, category, notes}` — bill what is received and not billed
- `POST /api/v2/purchase-orders/{uuid}/bills/{bill_uuid}/void {reason}` — void a bill (expense still pending)
- `POST /api/v2/purchase-orders/{uuid}/close {reason*}` — close a partially received PO short
- `POST /api/v2/purchase-orders/{uuid}/cancel {reason}` — cancel
- `POST /api/v2/purchase-orders/{uuid}/items {description*, quantity, unit_price, tax_rate}` — add line
- `PUT /api/v2/purchase-orders/items/{item_uuid} {description, quantity, unit_price, tax_rate}` — update line
- `DELETE /api/v2/purchase-orders/items/{item_uuid}` — remove line
- `GET /api/v2/kanban/projects` — projects (uuid, name) to link a PO to
- `GET /api/v2/crm/accounts?search` — CRM companies (uuid, name) to use as supplier_company_uuid
