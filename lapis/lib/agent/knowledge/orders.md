---
title: Orders
pages: /dashboard/orders
api: /api/v2/orders
modules: orders
tools:
suggestions: Show pending orders from this week | How much revenue is still pending? | Mark an order as shipped
readonly: false
---
# Orders
E-commerce store orders. Platform admins see every order on the platform (with seller details); other users see only orders of stores they own. Order status: pending, confirmed, processing, shipped, delivered, cancelled, refunded. Payment status (financial_status): pending, authorized, partially_paid, paid, partially_refunded, refunded, voided. fulfillment_status defaults to unfulfilled.

## Using the page
- Stat cards: Total Orders, Pending, Processing, Delivered, Revenue.
- Filters: search (order #, customer name, email), status, payment status, store ("All Stores"), date From / To; sortable columns, pagination.
- Eye icon "View Order Details": customer, seller (admins), store, order items, summary (subtotal, tax, shipping, discount, total), addresses, notes. The page itself is view-only — status changes go through the assistant/API.

## Rules
- Access is by store ownership, not workspace roles: non-admins get 403 "Access denied" on orders of stores they don't own.
- Status update accepts only pending|confirmed|processing|shipped|delivered|cancelled|refunded; a status change is recorded in the order history with the notes.
- Deleting orders is not offered here.

## API
- `GET /api/v2/orders?page&per_page&status&payment_status&fulfillment_status&store_uuid&search&date_from=YYYY-MM-DD&date_to=YYYY-MM-DD&order_by=created_at|updated_at|order_number|total_amount|status|customer_name&order_dir=asc|desc` — list (total, total_pages)
- `GET /api/v2/orders/stats` — total/pending/processing/delivered/cancelled counts, total_revenue, pending_revenue
- `GET /api/v2/orders/stores` — stores for the filter (uuid, name)
- `GET /api/v2/orders/{uuid}` — order with items, customer, store and delivery info
- `PUT /api/v2/orders/{uuid}/status {status, financial_status, fulfillment_status, notes}` — change status
