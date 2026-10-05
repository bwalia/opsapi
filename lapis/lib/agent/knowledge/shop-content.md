---
title: Shop knowledge & market
pages: /dashboard/shop/knowledge, /dashboard/shop/market
api: /api/v2/shop/admin/knowledge, /api/v2/shop/admin/market/overview, /api/v2/shop/admin/market/products, /api/v2/shop/admin/market/sources, /api/v2/shop/admin/market/observations, /api/v2/shop/admin/products
modules: shop
tools:
suggestions: Add an FAQ about our 3-year warranty | Which products are priced above market? | Set this product's price to the market median
readonly: false
---
# Shop knowledge & market
Knowledge = what the shop's AI sales assistant searches: product docs and blog posts (rebuilt by reindex) plus FAQs, manuals and web pages added here, split into ~800-character chunks and embedded. Market = third-party retailer prices for catalogue products (reference only). A background worker fetches each active source; an observation that moves >40% from the previous one is an anomaly until accepted. Market summaries use accepted GBP observations from the last 7 days (latest per active source). Money is integer pence ex VAT.

## Using the page
- Knowledge: "Reindex products", "Reindex blog", "Add document" (Type: FAQ | Manual / doc | Web page, Title *, URL (required for web pages), Content * → "Add & index"); filter by source type; trash icon removes a document.
- Market: table Our price, Market median, Market min, Diff, In stock, Freshness; search, freshness filter (All / Fresh only / Stale only), "|diff| > %", "Pending anomalies only"; "Refresh"; "Add source" (pick a product, then the source form). Click a row for the product drawer: summary, Sources (add / edit / delete), Observation history ("Accept" on anomalies), "Apply price…" (Market median / Market minimum / Custom amount (ex VAT)).
- Source form: Retailer, Currency, Product page URL, Fetch mode (Direct / Firecrawl), Prices include VAT, Source active, Identity check (MPN, GTIN / EAN, Title must include, Variant hint).

## Rules
- Added docs: source_type faq|manual|url; title and content required (content ≤500,000 chars, HTML is stripped). Adding again with the same source_ref (defaults to the slugified title) replaces that document. Removed product/blog docs return on the next reindex; reindex covers active products and published blog posts only.
- Source: product_uuid (or product_sku), name and an http(s) url are required; one source per product + URL (409 SOURCE_EXISTS). Defaults: fetch_mode direct, prices_include_vat true, currency GBP, active.
- Apply price sets the product's base_price_minor (ex VAT) and marks it price verified. median/min need fresh accepted data (409 NO_MARKET_DATA); value needs value_minor (positive int pence ex VAT). Confirm the amount with the user first.
- The assistant cannot trigger a price fetch — the worker runs on its own schedule.

## API
- `GET /api/v2/shop/admin/knowledge?source_type=product|cms_post|faq|manual|url&q&limit&offset` — documents (source_type, source_ref, title, chunks)
- `POST /api/v2/shop/admin/knowledge {source_type*: faq|manual|url, title*, content*, url, source_ref}` — add & index
- `DELETE /api/v2/shop/admin/knowledge/{source_ref}?source_type=` — remove a document's chunks
- `POST /api/v2/shop/admin/knowledge/reindex {sources: ["products"] | ["cms_posts"] | ["products","cms_posts"]}` — reindex
- `GET /api/v2/shop/admin/market/overview?q&stale=true|false&diff_gt={percent}&anomalies=true` — products with sources vs market (diff_pct, pending_anomalies)
- `GET /api/v2/shop/admin/market/products/{product_uuid}?history=100` — sources, summary, observation history
- `GET /api/v2/shop/admin/market/sources?product_uuid&active=true|false` — sources
- `POST /api/v2/shop/admin/market/sources {product_uuid*, name*, url*, fetch_mode: direct|firecrawl, prices_include_vat: bool, currency: "GBP", match: {mpn, gtin, title_must_include: [string], variant_hint}, is_active: bool}` — add source
- `PUT /api/v2/shop/admin/market/sources/{uuid} {...any of the same}` — edit source
- `DELETE /api/v2/shop/admin/market/sources/{uuid}` — delete source
- `POST /api/v2/shop/admin/market/observations/{uuid}/accept` — accept an anomaly
- `POST /api/v2/shop/admin/market/products/{product_uuid}/apply-price {strategy*: median|min|value, value_minor}` — set our price
- `GET /api/v2/shop/admin/products?q` — find a product's uuid
