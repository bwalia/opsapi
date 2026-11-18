---
title: Purchase Invoices
pages: /dashboard/purchase-invoices
api: /api/v2/purchase-invoices, /api/v2/purchase-orders
modules: purchase_orders
suggestions: What do we owe suppliers? | Which supplier invoices are overdue? | What did we pay Boston Limited this month?
readonly: true
---
# Purchase Invoices
Every invoice, proforma and credit note from suppliers, across all purchase orders: what the business owes, what is overdue and what is paid. The records live on each purchase order (its supplier panel); this page lists them together.

## Using the page
- Cards: **To pay** (amount still owed and how many invoices), **Overdue** (owed and past the due date), **Paid**. Click a card to filter. Amounts in other currencies are listed under the cards.
- Filters: All, To pay, Overdue, Paid, Proformas, Credit notes; search by invoice number, supplier, PO number, PO reference or the supplier's order reference. Click a row to open its purchase order.
- **Record a supplier invoice**: pick the purchase order it bills (only sent orders), then fill in what it is (proforma, final invoice or credit note), its number, date, due date, net, VAT and total, and attach the PDF if there is one. Suppliers with a portal login can upload their own.

## Rules
- Payments to suppliers are recorded on the purchase order (Payments to the supplier). A payment, or a credit note, pays the order's oldest final invoice first, so a payment made against a proforma still pays the final invoice that follows it.
- States: `paid` (nothing left), `overdue` (money left and the due date has passed), `part_paid`, `unpaid`; proformas and credit notes are listed for the record and never count as owed.
- `GET /api/v2/purchase-invoices` takes `q`, `state` (owed, overdue, paid, unpaid, part_paid, proforma, credit), `from` and `to` (invoice dates, YYYY-MM-DD), `limit` and `offset`; `meta.summary` has the totals per currency.
- This page only reads. To record or remove an invoice, or record a payment, ask the user to do it on the purchase order page.
