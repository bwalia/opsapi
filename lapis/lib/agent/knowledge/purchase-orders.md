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
Orders the business places with suppliers (builders, merchants), e.g. materials and labour for a renovation. Lifecycle: `draft` → `sent` → `acknowledged` → `partially_received` → `received` → `billed`; `draft`, `sent` and `acknowledged` can be `cancelled`. `sent`/`acknowledged` may go straight to (partially_)received, and a partially received PO can be billed for what has arrived. `billed` and `cancelled` are final. Numbers (PO-000001…) and totals are set by the server.

## Using the page
- List: cards Open (sent/acknowledged/partially received, value), Overdue deliveries (expected date passed), To bill (received), Billed; search (PO #, supplier, reference); status filter; Supplier, From/To (issue date) filters; click a row to open the PO.
- **New Purchase Order**: Supplier Name*, Supplier Email/Phone/Address, Reference, Issue Date, Expected Date, Delivery Address, Currency (default GBP), Project (optional renovation project), Notes, Terms. It creates a draft — open it and use **Add Line**.
- PO page: Download PDF, Edit (draft/sent/acknowledged), **Send** (draft; emails the PDF to the supplier email and marks it sent), Mark Sent (no email), Acknowledged, **Receive Goods** (enter the received quantity per line, or Receive All), **Convert to Bill**, Cancel, Delete (draft). Lines: **Add Line** (Description*, Quantity*, Unit Price, Tax Rate %) and remove (draft only). The linked project links to its board.

## Rules
- Create needs `supplier_name` (or a CRM `supplier_company_uuid`, which fills the supplier details). Confirm the supplier, lines and amounts with the user before creating.
- Lines can be added/changed/removed only on drafts. Header fields can be edited on draft, sent or acknowledged. Only drafts can be deleted; send needs at least one line.
- Line total = quantity × unit_price plus tax_rate % (20 = 20% VAT).
- Receive: `received_quantity` is the running total received for that line (not a delta), between 0 and the ordered quantity. All lines complete → `received`; otherwise `partially_received`.
- Convert to bill: bills received quantity × price (+ tax). When Bookkeeping is enabled it creates a pending expense (vendor = supplier, category `purchases` unless you pass one) in the purchase ledger; its id is saved in the PO's metadata (`expense_uuid`). A PO can be billed once.
- Emailing the PDF happens in the browser: ask the user to click **Send** on the PO page (needs a supplier email). Through the API you can mark it sent or email without the PDF.
- Responses return the uuid as `id`. Find a PO by number with `search`. `project_uuid` must be a project in this workspace (find it with list_projects).

## API
- `GET /api/v2/purchase-orders?page&perPage&status=draft|sent|acknowledged|partially_received|received|billed|cancelled&supplier&project_uuid&from_date&to_date&search` — list (status may be a comma list; dates YYYY-MM-DD on issue date)
- `GET /api/v2/purchase-orders/stats` — open/overdue/to-bill/billed counts and values, by_status
- `GET /api/v2/purchase-orders/{uuid}` — PO with items[] and project
- `POST /api/v2/purchase-orders {supplier_name*, supplier_email, supplier_phone, supplier_address, supplier_company_uuid, reference, issue_date: YYYY-MM-DD, expected_date: YYYY-MM-DD, delivery_address, currency: ISO code (default GBP), notes, terms, project_uuid, items: [{description*, quantity: number, unit_price: decimal, tax_rate: percent}]}` — create a draft
- `PUT /api/v2/purchase-orders/{uuid} {supplier_name, supplier_email, supplier_phone, supplier_address, reference, issue_date, expected_date, delivery_address, currency, notes, terms, project_uuid}` — update
- `DELETE /api/v2/purchase-orders/{uuid}` — delete a draft
- `POST /api/v2/purchase-orders/{uuid}/send` — mark a draft as sent (no email)
- `POST /api/v2/purchase-orders/{uuid}/email {to, message}` — email the supplier (lines in the body); marks a draft sent
- `POST /api/v2/purchase-orders/{uuid}/acknowledge` — supplier confirmed the order
- `POST /api/v2/purchase-orders/{uuid}/receive {items: [{item_uuid*, received_quantity*}], receive_all: boolean, note}` — record goods received
- `POST /api/v2/purchase-orders/{uuid}/convert-to-bill {bill_date: YYYY-MM-DD, category, notes}` — bill it
- `POST /api/v2/purchase-orders/{uuid}/cancel {reason}` — cancel
- `POST /api/v2/purchase-orders/{uuid}/items {description*, quantity, unit_price, tax_rate}` — add line
- `PUT /api/v2/purchase-orders/items/{item_uuid} {description, quantity, unit_price, tax_rate}` — update line
- `DELETE /api/v2/purchase-orders/items/{item_uuid}` — remove line
- `GET /api/v2/kanban/projects` — projects (uuid, name) to link a PO to
- `GET /api/v2/crm/accounts?search` — CRM companies (uuid, name) to use as supplier_company_uuid
