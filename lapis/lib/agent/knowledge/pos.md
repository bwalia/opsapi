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
- "Selling from" shows the store whose products the till sells (Stores & Products) and links to Products, where products, prices, SKUs, barcodes, stock and variations are managed. The day's total shows next to it: sales and money by payment method, in the store's time zone. "How it works" shows a short guide.
- Filter by category, or "In stock only". Tap a product to add it, or scan its barcode (a scanner types the code and presses Enter; an exact barcode or SKU, of a product or a variation, goes straight into the sale). Out-of-stock products are greyed out and can't be added; once everything in stock is in the sale, + is disabled and it says so.
- A product with variations (sizes, colours…) asks which one; each has its own price and stock.
- Take a product back out with − on its tile or in the sale (the bin removes the line); Clear empties the sale. Add a discount and optionally the customer's email for the receipt.
- "Today at this till" lists the day's latest sales with their receipts.
- Payment: Cash (type the cash given or tap a quick amount; the change is shown), Card (optional terminal reference) or Other. **Complete sale** saves it.
- After the sale: Print receipt, email the receipt, or start a New sale.

## Rules
- Selling needs the orders create permission; the day's totals and receipts need orders read.
- Products: Stores & Products → Products (name, price, SKU, barcode, track stock + quantity); a product's page has Variations (each with SKU, price, stock, on/off).
- Prices come from the products and tax from the store's rate; the server checks the cash given against the total and refuses too little.
- A sale is completed once: a double click or a retry never makes two sales.
- `GET /api/v2/pos/summary` takes `store_uuid` and `date` (YYYY-MM-DD, default today in the store's time zone). `GET /api/v2/pos/products` takes `store_uuid` and `q` (name, SKU or barcode).
- This assistant only reads. Ask the user to make sales on the till itself.
