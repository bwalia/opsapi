---
title: Shop orders & quotes
pages: /dashboard/shop/orders, /dashboard/shop/quotes
api: /api/v2/shop/admin/orders, /api/v2/shop/admin/quotes, /api/v2/shop/admin/products, /api/v2/namespace/payment-methods
modules: shop
tools:
suggestions: Show paid orders awaiting fulfilment | Which bank transfers are we waiting for? | Mark this order as shipped | Create an invoice for this order
readonly: false
---
# Shop orders & quotes
Orders come from Stripe Checkout (cart or paid quote) or from an authorised Order Authorisation the customer chose to pay by bank transfer (payment_method bank_transfer: the order waits in pending_payment until staff mark it paid); this page fulfils them. Order status: pending_payment, paid, processing, shipped, delivered, cancelled, refunded, payment_failed. Quotes are priced snapshots the customer opens via a link; status: draft, sent, accepted, expired, converted (paid → became an order), cancelled. Numbers look like WSO-2026-00012 / WSQ-2026-00034. Money is integer pence; line prices ex VAT, VAT added per line.

## Using the page
- Orders: search order number/email/company, status filter; click a row.
- Orders: **Bank transfer due** filter (awaiting a bank transfer, oldest first, with days waiting).
- Order detail: **Mark paid** (pending bank-transfer orders: amount prefilled with the total, method Bank transfer, reference = order number, date today), **Create invoice** (paid orders without an invoice; then open the invoice or download its PDF); status buttons "Start processing", "Mark shipped" (asks Carrier, Tracking number, Tracking URL), "Mark delivered", "Cancel order", "Mark refunded"; Lines; Internal notes → "Save notes"; Customer (Ship to / Bill to); Tracking → "Save"; Payment (Stripe links, From quote, Customer link); Print.
- Quotes: search quote number/email/company, status filter, "Create quote".
- Create quote: Lines ("Add line" → Product, Qty, "Unit price override (£ ex VAT)", "Configure options"), Notes (shown to customer), Internal notes, Customer (Name *, Email *, Company, Phone, VAT number, address), Terms (Valid until, Shipping (£ ex VAT)). Then "Save draft" or "Create & mark sent".
- Quote detail: "Next step" panel, one button per state (draft → "Send for authorisation", sent → "Resend", expired → "Revise with a new date", replaced → "Open <revision>", has an order → "Open order"); the rest under "More" (Send test to me, Revise, Create Order Authorisation, customer link, PDF, Print). "Progress" timeline, "Revisions", "Customer PO number" (pencil, copy).
- Quotes list quick filters: Awaiting authorisation, Awaiting payment, Needs supplier PO, Bank transfer due.
- Order detail: "Next step" (paid → "Raise supplier PO", PO draft → "Open PO", PO sent → "Mark received", then "Mark shipped", "Mark delivered"); status changes under "More"; "Progress"; "Customer PO number".
- "Raise supplier PO": Supplier (remembers the last), costs from its price file, lines without a cost highlighted, Bill to / Deliver directly to shown first.

## Rules
- Order transitions (use only these): pending_payment or payment_failed → cancelled; paid → processing|shipped|cancelled|refunded; processing → shipped|cancelled|refunded; shipped → delivered|refunded; delivered → refunded. Never set paid/payment_failed/pending_payment with PUT — Stripe does, or staff use mark-paid for a payment that arrived outside Stripe (bank transfer, cheque, other).
- Mark paid only after the user confirms the money arrived (amount and date). It runs the same paid path as a card payment (stock committed, quote converted). Card orders still in Stripe Checkout can't be marked paid.
- Bank-transfer orders are not cancelled automatically; their stock is held for 14 days. If the customer then pays by card instead, the bank-transfer order is cancelled for them.
- Create invoice makes a draft accounting invoice (lines, discount line, delivery, VAT, the customer's PO number, the default bank account) and is idempotent: a second call returns the same invoice. Needs invoices create permission; 501 when invoicing isn't enabled.
- Cancelling a pending_payment order releases its held stock. Cancelled/refunded only record the status — the refund itself is done in Stripe.
- Marking shipped: send status shipped plus tracking with shipped_at (ISO time). tracking replaces the whole object.
- Quotes: 1–100 lines, qty 1–1000, each line needs product_slug (find it via products?q=). Admin quotes may use draft products and invalid configurations. Omitted option groups use their defaults.
- selections: {group_code: "option_code"} or {group_code: ["code", …]} or {group_code: [{option: "code", qty: 2}]}; codes come from GET products/{uuid}.
- PUT lines replaces ALL lines and re-prices (keep each existing line's uuid); a converted quote's lines cannot change (409). customer replaces the whole customer object.
- Setting status sent does NOT email anyone — the user shares the customer link.
- customer_po_number: the end customer's own PO number (≤ 64 chars). Staff set it on a quote (until it has an order) or on the order; the customer can give it when authorising, then it is locked for them. Copied to the order and printed on the supplier PO as "End customer PO".
- Once a quote has an order (or is converted) its lines, prices, discounts, shipping, customer and delivery can't change (409 QUOTE_HAS_ORDER): raise a new quote. Status and notes still save.
- Revisions are for small corrections (delivery, PO number, contact details, new validity); for different products, quantities or customer create a new quote. Revise needs a reason; draft, sent, expired or accepted without an order. It is numbered <original>-R<n>, starts as a draft (send it); the old one is cancelled and links to it. A revised authorised order needs the customer's new authorisation.
- valid_until is YYYY-MM-DD (default 30 days); draft/sent quotes past it become expired.
- The UI requires customer name and a valid email.

## API
- `GET /api/v2/shop/admin/orders?status&q&limit&offset` — list (q = number, email, name, company; limit ≤200)
- `GET /api/v2/shop/admin/orders/{uuid}` — order with lines, reservations, links
- `GET /api/v2/shop/admin/orders?bank_transfer_due=true` — orders awaiting a bank transfer, oldest first (each has days_waiting; meta.bank_transfer_due_count)
- `POST /api/v2/shop/admin/orders/{uuid}/mark-paid {method: bank_transfer|cheque|other (default bank_transfer), reference, paid_at: YYYY-MM-DD, amount_minor: int pence (default the order total)}` — record a payment received outside Stripe; the order becomes paid
- `POST /api/v2/shop/admin/orders/{uuid}/invoice {payment_method_uuid, due_date: YYYY-MM-DD, payment_terms_days: int, notes}` — draft accounting invoice from the order → {invoice_uuid, invoice_number, existing}
- `GET /api/v2/namespace/payment-methods` — the workspace's bank accounts (How to pay)
- `PUT /api/v2/shop/admin/orders/{uuid} {status, tracking: {carrier, tracking_number, url, shipped_at}, internal_notes, customer_po_number}` — update status / tracking / notes / the customer's PO number
- `GET /api/v2/shop/admin/orders?filter=needs_supplier_po` — paid orders with no supplier PO yet
- `GET /api/v2/shop/admin/quotes?status&q&filter=awaiting_authorisation|awaiting_payment|needs_supplier_po|bank_transfer_due&kind=quote|order&limit&offset` — list (q also matches customer_po_number)
- `GET /api/v2/shop/admin/quotes/{uuid}` — quote incl. public_url (customer link)
- `POST /api/v2/shop/admin/quotes {lines*: [{product_slug*, qty: int, selections: {}, price_override_minor: int pence ex VAT per unit}], customer: {name, email, company, phone, vat_number, address: {line1, line2, city, postal_code, country: "GB"}}, notes, internal_notes, status: draft|sent, valid_until: YYYY-MM-DD, shipping_minor: int}` — create
- `PUT /api/v2/shop/admin/quotes/{uuid} {status, notes, internal_notes, valid_until, customer, lines, shipping_minor, customer_po_number}` — update (partial)
- `POST /api/v2/shop/admin/quotes/{uuid}/revise {reason*, customer, delivery_address, delivery_method, customer_po_number, valid_until}` — revision (201, the new quote: revision_no, revision_of, revisions[])
- `GET /api/v2/shop/admin/orders/{uuid}/purchase-order/preview?supplier_uuid` — the supplier PO before it is raised (supplier details, bill_to, ship_to, lines with cost from the price file, missing_costs, last_supplier_uuid)
- `POST /api/v2/shop/admin/orders/{uuid}/purchase-order {supplier_uuid, supplier_name, supplier_email, supplier_phone, supplier_address, expected_date: YYYY-MM-DD, delivery_method, notes, costs: {line_uuid: "123.45" pounds ex VAT}, include_custom}` — draft the supplier PO (paid orders only)
- `GET /api/v2/shop/admin/products?q&status=active&limit` — find a product's slug/uuid
- `GET /api/v2/shop/admin/products/{uuid}` — option group and option codes
