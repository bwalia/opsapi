---
title: Parts
pages: /dashboard/field-service/parts
api: /api/v2/field-service/parts
modules: fs_parts
tools:
suggestions: Which parts are low on stock? | Add a part: Compressor 1HP, sells at 250 | Deactivate part CMP-100
readonly: false
---
# Parts
The namespace's parts / products catalogue used on jobs. Engineers pick catalogue parts when logging items or proposing a replacement; a part line copies its price and tax. Stock is tracked: approving a catalogue part on a job consumes `stock_quantity`, rejecting/removing gives it back, and dropping to `reorder_level` logs a low-stock warning on the job.

## Using the page
- **New part** opens the form: Part name*, Part code (SKU), Category, Unit cost (buy), Unit price (sell), VAT %, Stock qty, Reorder level, Description, Active.
- Search (name, SKU, category) and status filter (Active & inactive / Active only / Inactive only). Columns: Part, Category, Sell price, Stock, Status. Row icons: Edit part, Delete part.

## Rules
- name is required; tax_rate must be 0-100.
- Reading the catalogue: fs_parts read, or fs_jobs/fs_visits read (for the job part picker). Create/update/delete need fs_parts create/update/delete.
- Delete is a soft delete; job items keep their copied description and price. Prefer deactivating (is_active false) a part that is no longer sold.
- The list returns active parts only unless is_active or include_inactive is given.
- Low stock = stock_quantity at or below reorder_level (compare them in the list).

## API
- `GET /api/v2/field-service/parts?search&category&is_active=true|false&include_inactive=true&page&per_page`
- `GET /api/v2/field-service/parts/{uuid}`
- `POST /api/v2/field-service/parts {name*, sku, description, category, unit_cost, unit_price, tax_rate, stock_quantity, reorder_level, is_active (default true)}`
- `PUT /api/v2/field-service/parts/{uuid} {same fields}`
- `DELETE /api/v2/field-service/parts/{uuid}`
