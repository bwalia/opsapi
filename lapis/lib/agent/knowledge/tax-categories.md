---
title: Tax categories
pages: /dashboard/tax/categories
api: /api/v2/tax/categories
modules: tax_categories
tools:
suggestions: List my custom categories | Add an expense category for coworking | Which categories are tax deductible?
readonly: false
---
# Tax categories
Categories label transactions as income or expense. Global categories (badge "Global", read-only) are the built-in set mapped to HMRC boxes and shared by everyone. Custom categories belong to the current workspace and can be edited or deleted.

## Using the page
- "Add Category" → "Add Category" window: Name*, Type (Expense / Income), "Tax deductible" checkbox, Description → Create.
- Pencil = edit ("Edit Category" → Update); bin = delete (asks to confirm). Global rows show "Read-only" instead.
- "Search categories..." matches name or description; the type filter has All Types / Income / Expense.

## Rules
- name is required; category_type must be income or expense; is_deductible is a boolean (default false).
- The key is generated from the name (e.g. ns12_coworking); transactions store this key in their category.
- Only this workspace's own categories can be updated or deleted; a global category returns 404.
- Custom categories have no HMRC box: the HMRC Boxes report shows them as Unmapped, and a transaction using one only reaches the HMRC return if its hmrc_category is set on the Transactions page.
- Deleting a category does not change transactions that already use its key.
- Permissions: tax_categories read to list; create/update/delete to change.

## API
- `GET /api/v2/tax/categories` — data[]: uuid, key, name, category_type, is_deductible, description, is_global
- `POST /api/v2/tax/categories {name*, category_type*: income|expense, is_deductible: bool, description}`
- `PUT /api/v2/tax/categories/{uuid} {name, category_type: income|expense, is_deductible: bool, description}` — own categories only
- `DELETE /api/v2/tax/categories/{uuid}` — own categories only
