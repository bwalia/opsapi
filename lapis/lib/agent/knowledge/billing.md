---
title: Billing
pages: /dashboard/billing
api: /api/v2/billing, /api/v2/subscriptions, /api/v2/licenses
modules: billing, subscriptions, licenses
tools:
suggestions: Which coupons are close to their limit? | Who bought Lifetime this month? | Which licences are on their device limit?
readonly: true
---
# Billing
Selling the workspace's own apps (Billing & Entitlements): **apps** with features and plans, **purchases** and **subscriptions**, **grants** (access given by hand), **licence keys** for desktop and self-hosted apps, **coupons**, **upgrade paths** and **payments** through the workspace's own Stripe account. Read-only here: you can look things up and explain them, but changes (sales, refunds, revokes, new keys, coupons, Stripe setup) are done by the user on the page.

## Using the page
- Tabs: **Apps & plans | Subscriptions | Licences | Coupons | Payments** (each follows its own permission: billing, subscriptions, licenses).
- Apps & plans → an app (`/dashboard/billing/apps/{uuid}`): Overview (keys, hosted pricing/account page links, settings), Plans, Features, Upgrades.
- Subscriptions: tabs Subscriptions | Purchases | Grants | History. Purchases paid through Stripe have a **Refund** action; any active purchase can be **revoked**.
- Licences: issue a key (shown once), open one to see its devices, suspend, revoke, reissue a lost key.
- Payments: connect the workspace's Stripe account (Express onboarding); shows whether it can take payments and the platform fee.

## Rules
- Plans have a purchase type: `recurring` (subscription), `one_time` (lifetime, updates for `updates_days` or forever) or `fixed_term` (`term_days` of access or of updates; buying again extends from the current end).
- What a customer may use is the union of: the app's default plan, their newest live subscription, their active purchases (features released before `updates_until`), and active grants. Limits: the largest wins, null = unlimited.
- Keys are never shown again after they are issued; a lost key is **reissued** (the old key stops working, devices are kept).
- Never suggest refunding, revoking, rotating a key or deleting on the user's behalf: describe where to do it and what will happen (refunds follow the app's `refund_policy`).
- Amounts are in minor units (pence/cents) with a 3-letter currency.

## API
- `GET /api/v2/billing/apps` — the workspace's apps
- `GET /api/v2/billing/apps/{app}` — one app (uuid or slug) with its effective settings
- `GET /api/v2/billing/apps/{app}/features` — the feature catalogue (key, type boolean|limit, released_at)
- `GET /api/v2/billing/apps/{app}/upgrades` — upgrade paths (from/to plan, pricing difference|fixed|free)
- `GET /api/v2/billing/apps/{app}/reports` — active/trialing/past-due subscriptions, MRR, licences, devices, grants
- `GET /api/v2/billing/plans?app={app}` — the app's plans (needs billing read)
- `GET /api/v2/billing/settings-schema` — every app setting with its meaning and default
- `GET /api/v2/billing/coupons?page&per_page` — coupons (code, discount, limits, redemptions_count)
- `GET /api/v2/billing/coupons/{uuid}/redemptions` — every use of a coupon
- `GET /api/v2/billing/connect` — the Stripe account: connected, charges_enabled, payouts_enabled, platform_fee_percent
- `GET /api/v2/subscriptions?app&customer&status&page&per_page` — subscriptions (status active|trialing|past_due|canceled)
- `GET /api/v2/subscriptions/{uuid}` — one subscription
- `GET /api/v2/subscriptions/purchases?app&customer&status&source&page&per_page` — purchases (status active|refunded|revoked; source stripe|manual|app_store|play_store|external)
- `GET /api/v2/subscriptions/grants?app&customer&page&per_page` — grants
- `GET /api/v2/subscriptions/plan-changes?app&customer&kind&page&per_page` — plan history (new|upgrade|downgrade|renewal|cancel)
- `GET /api/v2/subscriptions/entitlements?app={app}&customer={customer_uuid}` — what one customer may use now, and from which sources
- `GET /api/v2/licenses?app&status&page&per_page` — licences (key prefix only, status active|suspended|expired|revoked)
- `GET /api/v2/licenses/{uuid}` — one licence with its devices
