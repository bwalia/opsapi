---
title: Products
pages: /dashboard/products
api: /api/v2/products
modules: products
tools:
suggestions: Add a product "Filter kit" priced 24.99 | Which products are low on stock? | Change the price of a product
readonly: false
---
# Products
The workspace's product catalogue (e-commerce products / field-service parts). Products belong to a store; if the workspace has none, a default "<workspace> Catalog" store is created with the first product. Prices are decimal amounts (e.g. 24.99) in the catalogue currency, which is stored on the store and chosen with the first product.

## Using the page
- List: search, status filter, currency selector ("Currency for all products in this catalog"). "Add Product" opens a form: Name *, SKU, Price *, Cost price, Stock qty, Low stock at, Currency (first product only), Short description, Description. Click a row to open the product.
- Product page: "Edit" → Name *, SKU, Status (Active / Inactive), Short description, Full description, Price, Compare-at price, Cost price, Quantity, Low-stock threshold, Featured → "Save" (or "Cancel"); "Delete".

## Rules
- name required; price must be > 0. compare_price must be empty or ≥ price.
- PUT: always resend compare_price if the product has one — omitting it clears it. Send only real product fields.
- The list returns active products only (is_active true); inactive ones are reachable by uuid.
- Delete is permanent and also deletes the product's variants and order line items — warn the user.
- Create needs products.create; update/delete need products.update/products.delete or owning the product's store.

## API
- `GET /api/v2/products?page&perPage&search&store_id={store uuid}&min_price&max_price&is_featured=true&orderBy=name|price|sku|inventory_quantity|created_at|updated_at&orderDir=asc|desc` — list active products (perPage ≤100; response also has currency)
- `GET /api/v2/products/{uuid}` — one product
- `POST /api/v2/products {name*, price*: decimal, sku, compare_price: decimal, cost_price: decimal, inventory_quantity: int, low_stock_threshold: int, track_inventory: bool, short_description, description, tags, barcode, weight, is_active: bool, is_featured: bool, currency: "GBP" (first product), store_id: store uuid, category_id: category uuid}` — create
- `PUT /api/v2/products/{uuid} {...same fields}` — update
- `DELETE /api/v2/products/{uuid}` — delete
- `PUT /api/v2/products/currency {currency*: 3-letter code}` — change the catalogue currency (products.update)
