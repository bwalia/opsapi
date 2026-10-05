---
title: Shop orders & quotes
pages: /dashboard/shop/orders, /dashboard/shop/quotes
api: /api/v2/shop/admin/orders, /api/v2/shop/admin/quotes, /api/v2/shop/admin/products
modules: shop
tools:
suggestions: Show paid orders awaiting fulfilment | Mark this order as shipped | Draft a quote for 2 GPUs for jane@acme.com
readonly: false
---
# Shop orders & quotes
Orders come from Stripe Checkout (cart or paid quote); this page fulfils them. Order status: pending_payment, paid, processing, shipped, delivered, cancelled, refunded, payment_failed. Quotes are priced snapshots the customer opens via a link; status: draft, sent, accepted, expired, converted (paid → became an order), cancelled. Numbers look like WSO-2026-00012 / WSQ-2026-00034. Money is integer pence; line prices ex VAT, VAT added per line.

## Using the page
- Orders: search order number/email/company, status filter; click a row.
- Order detail: status buttons "Start processing", "Mark shipped" (asks Carrier, Tracking number, Tracking URL), "Mark delivered", "Cancel order", "Mark refunded"; Lines; Internal notes → "Save notes"; Customer (Ship to / Bill to); Tracking → "Save"; Payment (Stripe links, From quote, Customer link); Print.
- Quotes: search quote number/email/company, status filter, "Create quote".
- Create quote: Lines ("Add line" → Product, Qty, "Unit price override (£ ex VAT)", "Configure options"), Notes (shown to customer), Internal notes, Customer (Name *, Email *, Company, Phone, VAT number, address), Terms (Valid until, Shipping (£ ex VAT)). Then "Save draft" or "Create & mark sent".
- Quote detail: "Edit lines" → "Save & re-price"; "Status, validity & notes" → Save; Customer → Edit → Save; "Customer link" (copy it to send the quote), "Open customer link", "Download PDF".

## Rules
- Order transitions (use only these): pending_payment or payment_failed → cancelled; paid → processing|shipped|cancelled|refunded; processing → shipped|cancelled|refunded; shipped → delivered|refunded; delivered → refunded. Never set paid/payment_failed/pending_payment — Stripe does.
- Cancelling a pending_payment order releases its held stock. Cancelled/refunded only record the status — the refund itself is done in Stripe.
- Marking shipped: send status shipped plus tracking with shipped_at (ISO time). tracking replaces the whole object.
- Quotes: 1–100 lines, qty 1–1000, each line needs product_slug (find it via products?q=). Admin quotes may use draft products and invalid configurations. Omitted option groups use their defaults.
- selections: {group_code: "option_code"} or {group_code: ["code", …]} or {group_code: [{option: "code", qty: 2}]}; codes come from GET products/{uuid}.
- PUT lines replaces ALL lines and re-prices (keep each existing line's uuid); a converted quote's lines cannot change (409). customer replaces the whole customer object.
- Setting status sent does NOT email anyone — the user shares the customer link.
- valid_until is YYYY-MM-DD (default 30 days); draft/sent quotes past it become expired.
- The UI requires customer name and a valid email.

## API
- `GET /api/v2/shop/admin/orders?status&q&limit&offset` — list (q = number, email, name, company; limit ≤200)
- `GET /api/v2/shop/admin/orders/{uuid}` — order with lines, reservations, links
- `PUT /api/v2/shop/admin/orders/{uuid} {status, tracking: {carrier, tracking_number, url, shipped_at}, internal_notes}` — update status / tracking / notes
- `GET /api/v2/shop/admin/quotes?status&q&limit&offset` — list
- `GET /api/v2/shop/admin/quotes/{uuid}` — quote incl. public_url (customer link)
- `POST /api/v2/shop/admin/quotes {lines*: [{product_slug*, qty: int, selections: {}, price_override_minor: int pence ex VAT per unit}], customer: {name, email, company, phone, vat_number, address: {line1, line2, city, postal_code, country: "GB"}}, notes, internal_notes, status: draft|sent, valid_until: YYYY-MM-DD, shipping_minor: int}` — create
- `PUT /api/v2/shop/admin/quotes/{uuid} {status, notes, internal_notes, valid_until, customer, lines, shipping_minor}` — update (partial)
- `GET /api/v2/shop/admin/products?q&status=active&limit` — find a product's slug/uuid
- `GET /api/v2/shop/admin/products/{uuid}` — option group and option codes
