---
title: Point of Sale
pages: /dashboard/pos
api: /api/v2/pos/products, /api/v2/pos/summary
modules: orders
suggestions: How much did the till take today? | How many sales were paid by card today? | Which products are out of stock at the till?
readonly: true
---
# Point of Sale
The till for selling in person from one of the workspace's stores (Stores & Products): any goods or services. A sale is a normal order with the channel "Point of sale": paid and handed over at once, stock taken, payment recorded, and listed in Sales Orders.

## Using the page
- Choose the store (top right, remembered on this device). The day's total shows next to it: sales and money by payment method, in the store's time zone.
- Tap a product to add it, or scan its barcode (a scanner types the code and presses Enter; an exact barcode or SKU goes straight into the sale). Out-of-stock products can't be added.
- In the sale: change quantities with − and +, remove a line, add a discount, and optionally the customer's email for the receipt.
- Payment: Cash (type the cash given or tap a quick amount; the change is shown), Card (optional terminal reference) or Other. **Complete sale** saves it.
- After the sale: Print receipt, email the receipt, or start a New sale.

## Rules
- Selling needs the orders create permission; the day's totals and receipts need orders read.
- Prices come from the products and tax from the store's rate; the server checks the cash given against the total and refuses too little.
- A sale is completed once: a double click or a retry never makes two sales.
- `GET /api/v2/pos/summary` takes `store_uuid` and `date` (YYYY-MM-DD, default today in the store's time zone). `GET /api/v2/pos/products` takes `store_uuid` and `q` (name, SKU or barcode).
- This assistant only reads. Ask the user to make sales on the till itself.
