---
title: Sales Orders
pages: /dashboard/orders
api: /api/v2/sales-orders, /api/v2/orders
modules: orders, shop
tools:
suggestions: Show orders awaiting payment | How many orders came in by phone this month? | Which orders were delivered this week?
readonly: false
---
# Sales Orders
Every order of the workspace in one list, however it came in: the shop's orders (online checkout, orders staff built for a customer, accepted quotes) and the online stores' orders (Stores & Products: checkout, or created by staff for a phone, email or in-person sale). People see the sources they have access to (shop read, orders read).

Common status (stage): awaiting_payment, confirmed, processing, shipped, delivered, cancelled, refunded, failed. Payment: pending, paid, refunded, failed. Channel: online, phone, in_person, email, pos (a point-of-sale screen), staff (a shop order built by staff), quote.

## Using the page
- Cards: Total orders, Awaiting payment, In progress (confirmed, processing or shipped), Delivered, Paid (per currency). Click a card to filter.
- Filters: search (order number, customer, email, company), status, channel, shop or online stores (when both are in use), date From / To.
- Click a shop order to open its shop order page (deal, supplier POs, delivery, signature); a store order opens its details here.
- **Create order**: a shop order (goes to Shop → Create order: the customer confirms and pays online or by bank transfer), or an online store order: choose the store, how they ordered (phone, in person, email), the customer's email, the products and quantities; shipping, discount, notes and "already paid" are optional. Prices come from the products and stock is checked and taken.

## Rules
- `GET /api/v2/sales-orders` takes `q`, `stage` (or `in_progress`), `source` (shop, store), `channel`, `from`, `to`, `page`, `per_page`; `meta.stats` has the card numbers.
- `POST /api/v2/orders` (orders create) needs `store_uuid`, `customer.email` and `items` [{ `product_uuid`, `quantity` }]; optional `channel` (phone, in_person, email), `shipping_amount`, `discount_amount`, `paid`, notes. Confirm the store, customer, products and quantities with the user before creating.
- Access is by store ownership, not workspace roles: non-admins get 403 "Access denied" on orders of stores they don't own.
- Status update accepts only pending|confirmed|processing|shipped|delivered|cancelled|refunded; a status change is recorded in the order history with the notes.
- Deleting orders is not offered here.

## API
- `GET /api/v2/orders?page&per_page&status&payment_status&fulfillment_status&store_uuid&search&date_from=YYYY-MM-DD&date_to=YYYY-MM-DD&order_by=created_at|updated_at|order_number|total_amount|status|customer_name&order_dir=asc|desc` — list (total, total_pages)
- `GET /api/v2/orders/stats` — total/pending/processing/delivered/cancelled counts, total_revenue, pending_revenue
- `GET /api/v2/orders/stores` — stores for the filter (uuid, name)
- `GET /api/v2/orders/{uuid}` — order with items, customer, store and delivery info
- `PUT /api/v2/orders/{uuid}/status {status, financial_status, fulfillment_status, notes}` — change status
