---
title: Shop
pages: /dashboard/shop
api: /api/v2/shop/admin/dashboard, /api/v2/shop/admin/products, /api/v2/shop/admin/categories, /api/v2/shop/admin/stock, /api/v2/shop/admin/options, /api/v2/shop/admin/knowledge/reindex
modules: shop
tools:
suggestions: Which products are low on stock? | Add 5 units of stock to a product | Create a category called GPUs
readonly: false
---
# Shop
Hardware shop admin. Tabs: Overview, Products, Categories, Stock, Market, Orders, Quotes, Chats, Knowledge. All money is integer pence ("minor units") ex VAT (129900 = £1,299.00); vat_rate is a fraction (0.2 = 20%). Product status: draft (hidden) | active (on sale) | archived. Price mode: fixed | configurable (customer picks options) | quote_only. Unverified prices show as "indicative".

## Using the page
- Overview: KPI tiles (Orders, Revenue (paid, 30d), Open quotes, Quote → order, Low stock, AI chats (7d)) plus Low stock, Latest orders, Latest quotes. "Reindex knowledge" rebuilds the AI search index; "Run reconcile" re-checks pending Stripe payments (UI only).
- Products: search name/SKU/brand, status and type filters, "Low stock only". "New product" opens the editor; click a row to edit; trash icon = "Delete / archive".
- Product editor: Basics (Name *, Slug *, SKU *, Brand, Category, Product type, Status, Tags, Short description, Description (Markdown)), Specs, Attributes JSON, Images (URLs), Option groups & options, Compatibility rules, Pricing (Price mode, Base price (£ ex VAT), VAT rate (%), Price verified), Stock ("Initial stock qty" on new products; existing: "Adjust stock", "History"), Merchandising (Featured, Sort order). Click "Create" / "Save".
- Categories: "New category" → Name *, Slug, Parent, Sort order, Image URL, Description, "Active (visible on the shop)".
- Stock: products and tracked options (On hand, Held by pending checkouts, Available, Low at); All/Products/Options, "Low stock only". −/+ opens "Adjust stock" (Change (±), Reason, Note → Apply); clock icon = movement history.

## Rules
- Create needs sku and name; SKU and slug unique per workspace (409 SKU_TAKEN / SLUG_TAKEN); slug defaults from name. Defaults: status draft, type workstation, price_mode fixed, vat_rate 0.2, low_stock_threshold 2, lead_time_days 10, allow_backorder true.
- product_type: workstation|server|gpu|cpu|memory|storage|networking|peripheral|software|service.
- PUT is partial and NEVER changes stock — use the stock endpoints. Do not send option_groups or rules unless replacing them: they upsert by code and deactivate every group/option/rule missing from the list (GET the product first, resend all). Configurable products need ≥1 option group; prefer the UI for rules.
- Delete: a product used by carts, quotes, orders or as an option component is archived instead.
- Category delete fails (409 CATEGORY_IN_USE) while it has products — move them first.
- Stock delta = non-zero integer (+ add, − remove); reason adjustment|restock|import (default adjustment). Available = on hand − held. An option linked to a component product adjusts that product.
- Look products up with ?q= before acting; never guess uuids/SKUs.

## API
- `GET /api/v2/shop/admin/dashboard` — KPIs + low-stock list
- `GET /api/v2/shop/admin/products?q&status=draft|active|archived&type&category={slug}&brand&featured=true&in_stock=true&low_stock=true&min_price&max_price&sort=price_asc|price_desc|name|featured|newest&limit&offset` — list (prices in pence; limit ≤500, default 24)
- `GET /api/v2/shop/admin/products/{uuid}` — full document incl. option_groups, options (uuid, code), rules, stock
- `POST /api/v2/shop/admin/products {sku*, name*, slug, brand, product_type, price_mode, status, category_uuid|category_slug, short_description, description, base_price_minor: int pence ex VAT, vat_rate: 0.2, stock_qty: int (initial), low_stock_threshold: int, lead_time_days: int, allow_backorder: bool, price_verified: bool, is_featured: bool, sort_order: int, tags: [string], specs: {label: value}, attributes: {}, images: [url], option_groups: [{code*, name, selection: single|multi, required, min_qty, max_qty, options: [{code*, name, price_delta_minor, is_default, stock_qty, component_product_sku}]}], rules}` — create
- `PUT /api/v2/shop/admin/products/{uuid} {...same fields, no stock_qty}` — update (category_uuid: null clears category)
- `DELETE /api/v2/shop/admin/products/{uuid}` — delete or archive
- `GET /api/v2/shop/admin/categories` — all categories (incl. hidden) with product_count
- `POST /api/v2/shop/admin/categories {name*, slug, parent_uuid|parent_slug, description, image_url, sort_order: int, is_active: bool}` — create
- `PUT /api/v2/shop/admin/categories/{uuid} {...same fields}` — update
- `DELETE /api/v2/shop/admin/categories/{uuid}` — delete (must be empty)
- `GET /api/v2/shop/admin/stock?low_only=true` — stock sheet; rows have kind=product|option and uuid
- `GET /api/v2/shop/admin/stock/movements?product_uuid&option_uuid&limit&offset` — movement history
- `POST /api/v2/shop/admin/products/{uuid}/stock {delta*: int, reason: adjustment|restock|import, note}` — adjust product stock
- `POST /api/v2/shop/admin/options/{uuid}/stock {delta*: int, reason, note}` — adjust a tracked option
- `POST /api/v2/shop/admin/knowledge/reindex {sources: ["products","cms_posts"]}` — rebuild the AI search index
