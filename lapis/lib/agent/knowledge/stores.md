---
title: Stores
pages: /dashboard/stores
api: /api/v2/stores
modules: stores
tools:
suggestions: List the stores in this workspace | Create a store called London Branch | Set a store's contact email
readonly: false
---
# Stores
Stores in this workspace (e-commerce). A store owns its products, categories and orders and holds the catalogue currency, tax rate and shipping settings. Status: active | inactive | suspended.

## Using the page
- Table of stores with contact info; search, status filter (All Status / Active / Inactive), sortable columns, pagination.
- Row icons: pencil (edit page not built yet — ask the assistant to update the store), trash → "Delete Store" confirm. "Add Store" has no form yet — the assistant can create the store.

## Rules
- Create needs name (stores.create); slug defaults from the name.
- tax_rate on create is a PERCENT 0–100 (20 = 20%, default 10%); on update it is stored as sent, so send a fraction (0.2 = 20%).
- shipping_enabled defaults false; when true, shipping_flat_rate and free_shipping_threshold must be ≥ 0.
- Update/delete need stores.update/stores.delete or being the store's owner.
- Delete also deletes ALL the store's products, categories and orders — warn the user clearly.
- currency is the catalogue currency for products.

## API
- `GET /api/v2/stores?page&perPage&orderBy=id|name|slug|status|created_at|updated_at&orderDir=asc|desc` — this workspace's stores
- `GET /api/v2/stores/{uuid}` — one store (with products and categories)
- `POST /api/v2/stores {name*, slug, description, contact_email, contact_phone, address, city, state, country, postal_code, status: active|inactive, currency, timezone, tax_rate: percent, shipping_enabled: bool, shipping_flat_rate: number, free_shipping_threshold: number, can_self_ship: bool, logo_url, banner_url}` — create
- `PUT /api/v2/stores/{uuid} {...same fields; tax_rate as fraction}` — update
- `DELETE /api/v2/stores/{uuid}` — delete store and everything in it
