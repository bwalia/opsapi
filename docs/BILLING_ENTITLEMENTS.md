# Billing & Entitlements — design (v2)

Status:
- **v2, approved 2026-10-08** with the owner's changes in §21. It is built on PR #694: Phase 1 first, then Phase 2 in the same PR.
- v2 It adds the 2026-10-08 addendum (lifetime and fixed-term purchases, apps with no back end, hosted pages, an open licence format, store purchases, privacy, scale) to the approved v1.
- The licence and token format is specified in **[LICENCE_FORMAT.md](LICENCE_FORMAT.md)**, with test vectors.
- v1's Phase 1 is built in PR #694, which is not merged yet. §19 lists what v2 changes in it.
- No v2 code is written until this document and LICENCE_FORMAT.md are approved. Decisions needed are in §21.

## 1. What we are building

A client (an OpsAPI workspace) registers **the apps it sells**, defines their **features** and **flat-tier
plans**, and sells them to **its own customers**. The client's apps then ask *"may this customer, or this
machine, use this feature?"*, and verify the signed answer themselves.

| Kind of app | Typical stack | How it checks access |
|---|---|---|
| **Web/SaaS** | A back end of its own | Its server calls OpsAPI with a secret key and caches the signed **entitlement token** |
| **Desktop** | Native (Swift, C#, Kotlin, Rust, Electron), sold as a direct download or through app stores, **often as a lifetime licence**, usually **without a back end** | The app holds a **licence key** and an offline **licence file**. It talks to OpsAPI only with the app's **publishable key** |
| **Self-hosted** | A server the customer runs | The same as desktop, per installation |
| **Mobile / store** | App Store, Play Store | The client's server records verified store purchases. They resolve to the same entitlements (§12) |

Everything is **generic and data-driven**:
- Purchase types, prices, features, limits, offline behaviour, branding, rate limits and privacy are **per-app data** (§4), validated against a declared settings schema.
- No client-specific code, names, prices or URLs.
- Money goes into the client's own Stripe account through Stripe Connect, and the platform takes a configurable percentage (Phase 2).

Fixed decisions (v1, unchanged):

| Topic | Decision |
|---|---|
| Who collects | The client, through Stripe Connect, plus a platform fee (`STRIPE_PLATFORM_FEE_PERCENT`) |
| Pricing | **Flat tiers only.** A feature is on/off or a numeric limit. No per-seat or usage-based pricing |
| Hosting | A separate deployment with `PROJECT_CODE=billing` (the hard module boundary), or self-hosted |
| Offline | Per app, `fail_open` or `fail_closed`, with a grace period |
| Customers | The existing `customers` table, extended. `email` is unique per workspace |
| Store receipts | Apple and Google receipt validation is **not** built. There's an extension point (§12) |
| Card data | Never touches OpsAPI. Stripe Checkout and the Customer Portal handle it |

## 2. What we reuse

| Piece | Where | Use |
|---|---|---|
| `billing_plans`, `billing_subscriptions`, `billing_payments`, `stripe_webhook_events` | `migrations/billing-system.lua` (700–709) | Extended. The tax app's contracts stay byte-identical (proven in #694, §20) |
| `customers` | ecommerce migrations, `routes/customers.lua` | Extended with `external_id`; billing customers appear on the Customers page |
| API keys `opsk_…` (hashed, module-scoped; the first URL segment = the scope) | `helper/api-key.lua` | The client's **secret server key** |
| Event outbox: table triggers, a delivery queue claimed with `SKIP LOCKED`, exponential backoff, dead letters | `helper/plugin-events.lua` | **Every** webhook and every billing email goes through it, never inline (§14) |
| Outbound webhooks (signed, retried) | `lib/outbound-webhooks.lua` | Clients subscribe to billing events |
| Mail (SMTP, templates) | `helper/mail.lua` | Billing emails, sent from an outbox job (§10) |
| Redis cache-aside with explicit busting, falling back to the DB | `helper/permission-cache.lua` | The pattern for the entitlement cache and shared rate limits (§15) |
| Typed settings validation | `PluginWorkspaces.checkSettings` and `plugin-sdk.validate` | The app settings schema (§4) |
| Stripe client (Checkout `mode`, `automatic_tax`, idempotency keys, webhook verification) | `lib/stripe.lua` | Phase 2, with a `Stripe-Account` header for Connect |
| ES256 signing and JWKS | `lib/billing-signing.lua` (#694) | Unchanged mechanism; claims become format v1 |

New building blocks:
- an AES-256-GCM helper for short-lived key delivery (`Global.encryptSecret` is AES-CBC, not authenticated);
- a core outbox subscriber (`core.billing`) for billing emails and jobs;
- a "computed" event source, so webhooks can subscribe to `license.issued` (§14).

## 3. Concepts

| Concept | Meaning |
|---|---|
| **App** | A product the client sells. It has a kind (`web`, `desktop`, `self_hosted`, `mobile`), a mode (`test`/`live`), a **publishable key** (`pk_test_…`/`pk_live_…`; it identifies the app and is safe to ship in a binary) and **settings** (§4) |
| **Feature** | Something the app gates: on/off (`export_pdf`) or a limit (`projects`). It has an optional **`released_at`** date (§6) |
| **Plan** | A flat tier: price, a value for each feature, and a **purchase type** (below). The app's **default plan** is what everyone gets for free |
| **Purchase type** | `recurring`: a subscription. `one_time`: a lifetime purchase, optionally with N days of updates. `fixed_term`: one payment for N days of **access** or of **updates**. It doesn't renew, and buying again **stacks** |
| **Purchase** | A paid (or manually recorded) `one_time` / `fixed_term` purchase with `access_until` and `updates_until` windows. `null` = unbounded |
| **Subscription** | A customer on a recurring plan (Stripe, or a verified store subscription) |
| **Grant** | Access given by hand: a comped plan or single features, optionally until a date |
| **Licence** | A licence key (shown once; only its hash is kept). It belongs to a customer and a plan, has its own `access_until` / `updates_until`, and a device limit |
| **Activation** | A machine using a licence, identified by a salted **fingerprint hash** sent by the app |
| **Source** | Where a purchase, subscription or licence came from: `stripe`, `manual`, `app_store`, `play_store`, `external` |
| **Access link** | A single-use, 15-minute magic link emailed to a customer. It opens the hosted "my licences" page |
| **Entitlements** | What a customer, or a licence, may use right now (§6) |

## 4. App settings (data, not code)

Every tunable lives in `billing_apps.settings` (JSONB). It is validated against a **declared schema**:
- the schema is code in `lib/billing-settings.lua`, in the plugin-settings style (type, bounds, enum, default per app kind);
- it is published at `GET /api/v2/billing/settings-schema`, so the dashboard renders the form from it;
- unknown keys are rejected;
- missing keys take the default for the app's kind.

Changing settings bumps the app's cache generation (§15).

| Group | Setting | Type and bounds | Default (web / desktop and self-hosted) |
|---|---|---|---|
| Offline | `offline_policy` | `fail_open` \| `fail_closed` | `fail_closed` / `fail_closed` |
| | `token_ttl_seconds` | 60–86400. Entitlement tokens' `exp` | 900 / 900 |
| | `refresh_interval_days` | 1–365. Licence files' `exp` | — / 7 |
| | `grace_days` | 0–365. `grace_until = exp + grace` | 3 / 30 |
| | `past_due_grace_days` | 0–90. How long a failed renewal keeps access | 7 / 7 |
| Licences | `max_activations` | 1–10000, or `null` (unlimited). Default for new licences; each licence can override it | `null` / 3 |
| | `activation_auto_release_days` | 0–3650; 0 = never. Frees activations not seen for N days | 0 / 90 |
| | `fingerprint_salt` | Generated, read-only, public | random 32 hex |
| Public endpoints | `allowed_origins` | List of origins (`https://…`; `http://localhost:*` allowed) for browser CORS | `[]` |
| | `allowed_redirect_urls` | List of URL prefixes (same rules) for checkout success/cancel and access-link returns | `[]` |
| | `rate_limits` | `licence_per_ip_per_min` (30), `licence_per_key_per_min` (20), `app_per_min` (6000), `checkout_per_ip_per_hour` (20), `access_link_per_email_per_hour` (3), `access_link_per_ip_per_hour` (10) | as shown |
| | `lockout` | `failures` (10) bad licence keys from one IP within `window_minutes` (15) lock that IP out of the app's licence endpoints for `lock_minutes` (30) | as shown |
| Customers | `email_collection` | `required` \| `optional` \| `none` | `required` / `optional` |
| | `activation_retention_days` | 0–3650. Deactivated and released activations are deleted after this | 90 |
| Branding | `display_name`, `logo_url` (https), `accent_color` (`#rrggbb`), `support_email`, `terms_url`, `privacy_url` | Strings, validated | app name; others empty |
| Delivery | `email_licence_keys` | bool. Email new and reissued keys (Phase 2) | false / true |
| | `webhook_include_licence_key` | bool. Put the raw key in the `license.issued` webhook. **Off unless the client opts in** | false |
| Payments (Phase 2) | `refund_policy` | `revoke` \| `keep`. What a **full** refund does; partial refunds always keep access | `revoke` |
| | `automatic_tax` | bool. Stripe Tax on checkout | false |
| | `allow_promotion_codes` | bool. Stripe promotion codes on checkout | false |

The app row keeps only its identity in columns: `name`, `slug`, `kind`, `mode`, `publishable_key`,
`active`, `cache_generation`.

## 5. Data model

All changes are additive and idempotent (`zzbe…` migration keys), gated on `billing`. They are workspace-scoped, and every id
in a request is checked against `self.namespace` (404 otherwise).

**Changes to tables from v1 / #694**
- **`billing_apps`**
  - the tunable columns move into `settings` (§4);
  - add `cache_generation BIGINT`.
- **`billing_features`:** add `released_at TIMESTAMPTZ` (null = always available).
- **`billing_plans`** (app plans only):
  - `purchase_type`: `recurring` | `one_time` | `fixed_term`. It sets the legacy `plan_type` and requires `billing_interval` for `recurring`.
  - `term_days` (fixed_term, required) and `term_covers`: `access` | `updates`.
  - `updates_days` (one_time; null = all future updates).
  - `store_products JSONB`, e.g. `{"app_store": "com.acme.pro", "play_store": "pro_yearly"}`. This is data: it maps store products to plans.
  - Phase 2: `stripe_refs JSONB` holds the Stripe product and price ids **per mode** (test/live) and connected account. The amount and currency are one value per plan.
- **`billing_subscriptions`:** add `source` (default `stripe`), `external_transaction_id` and `original_transaction_id`. Unique `(namespace_id, source, original_transaction_id)` where it is not null.
- **`billing_licenses`:** add `access_until`, `updates_until`, `source`, `purchase_id` (the purchase it last fulfilled) and `key_rotated_at`.
- **`billing_license_activations`:**
  - `fingerprint_hash` is the **app-salted hash sent by the client** (64 hex), never a raw id;
  - add `app_version`;
  - `last_seen_at` drives auto-release.

**New tables**

| Table | Columns (besides `id`, `uuid`, timestamps) | Notes |
|---|---|---|
| `billing_purchases` | `namespace_id`, `app_id`, `customer_id` (RESTRICT), `plan_id`, `purchase_type`, `source`, `external_transaction_id`, `original_transaction_id`, `access_until`, `updates_until`, `amount`, `currency`, `status` (`active`/`refunded`/`revoked`), `refunded_amount`, `refunded_at`, `metadata` | `one_time` and `fixed_term` purchases from any source. Unique `(namespace_id, source, external_transaction_id)`. Kept (anonymised) when a customer is deleted, for accounting |
| `billing_access_links` | `namespace_id`, `app_id`, `customer_id`, `token_hash` (set when the email is sent), `expires_at` (+15 min), `used_at` | Magic links. Single use |
| `billing_customer_sessions` | `app_id`, `customer_id`, `token_hash`, `expires_at` (+30 min) | What an access link is exchanged for |
| `billing_key_deliveries` | `license_id` (PK), `ciphertext`, `nonce`, `key_id`, `expires_at` (+24 h), `revealed_at`, `emailed_at` | Phase 2. Deleted when every configured channel has delivered the key, or at 24 h (§10) |
| `billing_idempotency` | `app_id` (or `namespace_id`), `key`, `endpoint`, `request_hash`, `status`, `response`, `expires_at` (+24 h) | Replays mutating calls (§9) |
| `billing_plan_upgrades` | `app_id`, `from_plan_id`, `to_plan_id`, `pricing` (`difference` / `fixed` / `free`), `amount`, `currency`, `active` | Upgrade paths the admin defines (§13). Customers can upgrade at any time |
| `billing_coupons` | `namespace_id`, `app_id` (null = every app), `code` (unique per workspace, case-insensitive), `discount_type` (`percent` / `amount`), `percent_off`, `amount_off`, `currency`, `duration` (`once` / `repeating` / `forever`, for recurring), `duration_months`, `plan_ids` (null = every plan), `max_redemptions`, `per_customer_limit`, `starts_at`, `expires_at`, `active` | Discount coupons the admin creates (§13) |
| `billing_coupon_redemptions` | `coupon_id`, `customer_id`, `purchase_id` / `subscription_id`, `amount_off`, `currency`, `redeemed_at` | Every use of a coupon |
| `billing_plan_changes` | `namespace_id`, `app_id`, `customer_id`, `from_plan_id`, `to_plan_id`, `kind` (`upgrade` / `downgrade` / `new`), `source`, `amount`, `currency`, `coupon_id`, `purchase_id` / `subscription_id`, `actor`, `created_at` | The full history of plan changes, from any source |
| `namespace_mail_settings` (core) | `namespace_id` (unique), `host`, `port`, `security` (`starttls` / `ssl`), `username`, `password_encrypted`, `from_email`, `from_name`, `reply_to`, `enabled`, `last_tested_at`, `last_error` | The workspace's own SMTP (§10). Used instead of the deployment's when enabled |
| `namespace_email_templates` (core) | `namespace_id`, `template_key`, `subject`, `html`, `updated_by` | A workspace's own version of a built-in template (§10)

Purge jobs run on worker 0 of one pod: expired links, sessions, deliveries and idempotency rows; released and
deactivated activations past their retention.

## 6. Entitlement resolution

`Entitlements.resolve(app, customer)` (and `resolveLicense(app, licence)`) combines these sources:

| # | Source | Features it contributes | Window |
|---|---|---|---|
| 1 | The app's **default plan** | all its features | none |
| 2 | The newest **recurring subscription** that entitles (`active`, `trialing`, or `past_due` within `past_due_grace_days`) | **all** features in its plan, including ones released later | `access_until` = period end |
| 3 | Every **active purchase** (`access_until` null or in the future) | its plan's features **released on or before `updates_until`** (no `released_at`, or `updates_until` null → included) | the purchase's |
| 4 | Active **grants** | the granted plan's features, then the granted values | `access_until` = the grant's expiry |
| 5 | For licence files: the **licence's own plan** | as for a purchase, with the licence's `updates_until` | the licence's |

Combining them:
- An on/off feature is on if any source turns it on.
- For a limit, the largest wins, and `null` (unlimited) beats any number.
- Only features in the app's catalogue are returned; each gets a value (`false` / `0` when no source sets it).
- `plan_key`, `status`, `access_until` and `updates_until` in the answer come from the deciding source. The order is subscription, then purchase (newest), then plan grant, then the default plan.

**Fixed-term stacking:**
- Buying a `fixed_term` plan again extends from `max(now, current end) + term_days` on the covered dimension (`access` or `updates`).
- "Current end" is the latest end among the customer's active purchases of that plan in that app.
- With licences, the customer's licence for that plan takes the new window, so the same key keeps working.

**Upgrades** (Phase 2) create a purchase of the target plan whose windows start at the upgrade date (§13).

## 7. Signed tokens and licence files

See **[LICENCE_FORMAT.md](LICENCE_FORMAT.md)** for the exact claims, verification steps, clock rules,
fingerprint derivation, test vectors and the Swift and Python reference verifiers. In short:
- **ES256 only**, with JWKS and key rotation.
- Claims: `ver: 1`, `iss`, `aud` (app), `sub`, `iat`, `exp`, `grace_until`, `plan_key`, `features`, `access_until`, `updates_until`, `offline_policy`; plus `fingerprint_hash` (licence files) or `status` (entitlement tokens).
- A client in any language can verify offline, without the SDK.
- Unsigned answers are never produced: without `BILLING_SIGNING_KEY` the licence endpoints return 503, and entitlement checks return `token: null`.

## 8. APIs

The URL's first segment is its RBAC module, which is also the API-key scope. JSON envelopes are
`{ success, data, meta }`. Lists are paginated (`page`, `per_page`, `meta.total_pages`). Ids from another
workspace or another app return 404.

**Auth columns:**
- **JWT** = a dashboard user, with that role permission.
- **Secret** = an `opsk_` key scoped to that module.
- **PK** = the app's publishable key.
- **Licence** = a licence key.
- **Session** = a customer session from an access link.

### 8.1 Management (JWT or secret key)

| Route | Auth: permission |
|---|---|
| `GET/POST /api/v2/billing/apps`, `GET/PUT/DELETE …/apps/:app`, `POST …/rotate-key`, `GET …/reports` | `billing.read/create/update/delete` |
| `GET /api/v2/billing/settings-schema` | `billing.read` |
| `GET/POST /api/v2/billing/apps/:app/features`, `PUT/DELETE …/features/:key` (now with `released_at`) | `billing.*` |
| `/api/v2/billing/plans*` (+ `purchase_type`, `term_days`, `term_covers`, `updates_days`, `store_products`) | `billing.*`, or `namespace.manage` (the tax app's existing check) |
| `GET /api/v2/subscriptions`, `GET …/:uuid`, grants (`GET/POST …/grants`, `DELETE …/grants/:uuid`), `GET …/entitlements?app=&customer=` | `subscriptions.*` |
| `GET/POST /api/v2/subscriptions/purchases`: list, or record a **manual** sale (`source: manual`) | `subscriptions.read/create` |
| `POST /api/v2/subscriptions/purchases/:uuid/revoke` | `subscriptions.update` |
| `GET/POST /api/v2/licenses`, `GET/PUT …/:uuid`, `POST …/revoke`, `DELETE …/activations/:id` | `licenses.*` |
| `POST /api/v2/licenses/:uuid/reissue`: new key, shown once; the old key stops working; activations are kept | `licenses.update` |
| `GET/POST /api/v2/billing/apps/:app/upgrades`, `PUT/DELETE …/upgrades/:uuid` (upgrade paths) | `billing.*` |
| `GET/POST /api/v2/billing/coupons`, `GET/PUT/DELETE …/coupons/:uuid`, `GET …/coupons/:uuid/redemptions` | `billing.*` |
| `POST /api/v2/subscriptions/upgrade` `{customer, app, to_plan, coupon?}`: an admin upgrades a customer by hand (recorded); `GET /api/v2/subscriptions/plan-changes?app=&customer=` | `subscriptions.update` / `subscriptions.read` |
| `GET/PUT/DELETE /api/v2/namespace/mail-settings`, `POST …/mail-settings/test` (core) | `namespace.read` / `namespace.update` |
| `GET /api/v2/namespace/email-templates`, `PUT/DELETE …/email-templates/:key`, `POST …/:key/preview` (core) | `namespace.read` / `namespace.update` |
| `GET /api/v2/customers/:uuid/billing-export` | `customers.read` **and** `subscriptions.read` |
| `DELETE /api/v2/customers/:uuid/billing-data` (§16) | `customers.delete` **and** `subscriptions.delete` |
| Phase 2: `POST /api/v2/billing/connect/onboard`, upgrade paths `GET/POST/DELETE /api/v2/billing/apps/:app/upgrades` | `billing.manage` / `billing.*` |

### 8.2 Runtime (the client's server, secret key)

| Route | Scope |
|---|---|
| `PUT /api/v2/entitlements/:app/customers/:external_id`: upsert a customer; email per `email_collection` | `entitlements.create` |
| `GET /api/v2/entitlements/:app/customers/:external_id` → entitlements and a signed token. An unknown id gets the default plan | `entitlements.read` |
| `POST /api/v2/entitlements/:app/purchases`: record a **verified external purchase** (`source`, `external_transaction_id`, `original_transaction_id`, `plan_key` or a store product id, `customer` external_id, `purchased_at`, `expires_at` for subscriptions). Idempotent on `(source, transaction id)` | `entitlements.create` |
| `POST /api/v2/entitlements/:app/purchases/verify` `{source, payload}`: runs the source's **verifier** (§12). `app_store` / `play_store` return 501 `not_implemented` | `entitlements.create` |
| Phase 2: `POST /api/v2/subscriptions/checkout`, `POST /api/v2/subscriptions/portal` | `subscriptions.create` |

### 8.3 Public: for apps with no back end, and for hosted pages

| Route | Auth | Purpose |
|---|---|---|
| `GET /api/v2/public/billing/apps/:app` (`:app` = id or `?pk=`) | none | Public app info: branding, `fingerprint_salt`, `email_collection`, public plans and features. Cacheable, with an ETag |
| `GET /api/v2/public/billing/jwks.json` | none | Signing keys. `Cache-Control: max-age=300` |
| `POST /api/v2/public/licenses/activate` `{pk, license_key, fingerprint_hash, app_version, name?, platform?}` | PK + licence | Uses a seat and returns a licence file |
| `POST /api/v2/public/licenses/validate` `{pk, license_key, fingerprint_hash, app_version}` | PK + licence | Refresh. Returns a new licence file, or `license_revoked` / `license_suspended` / `not_activated` / `access_ended` |
| `POST /api/v2/public/licenses/deactivate` `{pk, license_key, fingerprint_hash}` | PK + licence | Frees this machine's seat |
| `POST /api/v2/public/billing/coupons/check` `{pk, code, plan_key}` | PK | Whether a coupon applies, and the price after it. Rate-limited |
| `POST /api/v2/public/billing/access-link` `{pk, email, return_url?}` | PK | Always 202. If the email has billing records in this app, it emails a magic link |
| `POST /api/v2/public/billing/sessions` `{token}` | the link's token | Exchanges a single-use link for a 30-minute session |
| `GET /api/v2/public/billing/me` | Session | The customer's licences (prefix, status, plan, windows, devices), purchases and subscriptions in this app |
| `POST /api/v2/public/billing/me/licenses/:uuid/reissue` | Session | Rotates the key and shows the new one once; activations are kept |
| `DELETE /api/v2/public/billing/me/licenses/:uuid/activations/:id` | Session | Frees a device |
| Phase 2: `POST /api/v2/public/billing/checkout` `{pk, plan_key, email?, success_url, cancel_url, upgrade_from?}` | PK | Returns a Stripe Checkout URL (`mode=subscription` for recurring, `mode=payment` otherwise) |
| Phase 2: `GET /api/v2/public/billing/checkout/:session_id` | the Stripe session id | Order status. Reveals the new licence key **once** (§10) |
| Phase 2: `POST /api/v2/public/billing/me/portal` | Session | Stripe Customer Portal URL for recurring plans |

## 9. Protecting the public endpoints

- **CORS.** A browser request is answered only when its `Origin` is in the app's `allowed_origins` (or is the hosted pages' own origin). That origin is echoed, without credentials. A mutating request with any other `Origin` gets 403 `origin_not_allowed`. Native apps send no `Origin` and are unaffected.
- **Redirects.** `success_url`, `cancel_url` and `return_url` must start with one of `allowed_redirect_urls` (same scheme, host and port). Otherwise: 422 `redirect_not_allowed`. There are no open redirects.
- **Rate limits** are per IP, per app and per licence key, using the app's `rate_limits` settings:
  - Redis-backed, so they are shared across pods, when Redis is configured;
  - otherwise per pod (shared memory), and then they apply per pod.
- **Lockout.** Too many invalid licence keys from one IP lock that IP out of the app's licence endpoints for a while (429 `locked_out`). Licence keys carry 125 random bits, so this is defence in depth, not the main protection.
- **Idempotency.** Every mutating call accepts an `Idempotency-Key` header. The same key and body within 24 h replays the stored response; a different body gets 409. It is **required** on checkout and recommended everywhere else, and the SDKs always send one.
- **Data exposure.** A response carries customer data only to the holder of a valid licence key (that licence), a Stripe session id (that order) or a session (that customer). `access-link` always answers 202, so email addresses can't be enumerated.
- **No IP addresses are stored.** They exist only as rate-limit and lockout counters that expire with their window.

## 10. Fulfilment and key delivery (Phase 2)

**On a paid Checkout session** (Connect webhook `checkout.session.completed`, or the success page, whichever comes first):
- Fulfilment runs **once**, under a row lock on the Stripe session id plus the `stripe_webhook_events` idempotency.
- Desktop and self-hosted apps: a new or extended **licence** (§6, stacking).
- Other kinds: a new or extended **subscription** (recurring), **purchase** (one_time / fixed_term) or grant.

**Delivering the key once:**
1. The raw key is encrypted with **AES-256-GCM**: key from `LICENCE_DELIVERY_KEY` (32 bytes, base64), `LICENCE_DELIVERY_KEY_ID` stored with it, the licence uuid as associated data.
2. It is stored in `billing_key_deliveries` for **at most 24 h**. For rotation, `LICENCE_DELIVERY_PREVIOUS_KEYS` keeps old keys readable until their rows expire.
3. The **success page** reveals it once (`revealed_at`).
4. If `email_licence_keys` is on, the email job decrypts it at send time (`emailed_at`).
5. The row is **deleted** as soon as every configured channel has delivered it, or at 24 h. A purge job enforces this.
6. The raw key is never logged, and never put in an event. The **`license.issued`** webhook carries the licence id, key prefix, plan and customer. The raw key is included only if the app turned on `webhook_include_licence_key`.

**Lost keys:** reissue (from the "my licences" page or `POST /api/v2/licenses/:uuid/reissue`):
- rotates the key on the same licence and revokes the old key immediately;
- keeps every activation;
- emits `license.reissued`.

**Email:**
- Sent by `helper/mail.lua`, called from the **outbox** (`core.billing` subscriber), so it is retried with backoff and visible when it fails.
- **SMTP per workspace:** each workspace can set its own SMTP server, sender, reply-to and password (stored encrypted) in its settings, and send a test email. Without one, the deployment's SMTP is used.
- **Templates:**
  - every email has a **built-in default template**, an `etlua` file in the repo;
  - a workspace can override the subject and body of any template;
  - overrides use `{{placeholder}}` substitution with HTML escaping, never code, so tenant-written templates can't run anything;
  - the variables each template can use are listed for the editor, and there is a preview.
- The app's branding (name, logo, colour, support email) fills the layout.
- Secrets never sit in events: the job generates the magic-link token (storing only its hash), or decrypts the delivery, at send time.

## 11. Hosted pages (no client code needed)

These are public pages in opsapi-dashboard under `{BILLING_HOSTED_BASE_URL}/b/{app_id}/…`, branded from the app's settings:

| Page | Phase | Contents |
|---|---|---|
| `/b/{app}/account` | 1 | "My licences": request an access link; then licences, devices (free one), reissue a key, purchases and subscriptions, plus the Customer Portal (Phase 2) |
| `/b/{app}/pricing` | 2 | Public plans and features → checkout |
| `/b/{app}/success` | 2 | Order status, the licence key revealed once, next steps |

- Clients can link to these pages or embed them (iframe), or build their own on the public API.
- The magic link's token travels in the URL **fragment**, so it never reaches server logs or `Referer` headers.

## 12. Store purchases (extension point; the data model is built now)

- Purchases, subscriptions and licences carry a `source` and transaction ids. Each is unique per workspace and source.
- Plans map store product ids (`store_products`).
- **Recording:** the client's own server verifies a receipt itself, then records it with `POST /api/v2/entitlements/:app/purchases`.
- **Verifier interface:** `lib/billing-verifiers/<source>.lua` exports `verify(app, payload) → normalised purchase | nil, err`.
  - `app_store` and `play_store` are stubs returning `not_implemented`.
  - `external` and `manual` need no verification.
  - Adding a real verifier later is a new file, not a change to callers.
- The result: a customer who bought through any channel resolves to **one** set of entitlements (§6).

## 13. Payments (Phase 2)

- **Checkout:** `mode=subscription` for `recurring`; `mode=payment` for `one_time` and `fixed_term`.
  - Destination charges on the client's connected account, with `application_fee_*` from `STRIPE_PLATFORM_FEE_PERCENT`.
  - `automatic_tax` per app, idempotency keys on every Stripe call, and per-mode prices (`stripe_refs`).
- **Checkout runs on Stripe's hosted Checkout page.** OpsAPI's database is updated from Stripe webhooks; the success page only reads the result.
- **Upgrades (approved).** Admins define upgrade paths per app (`billing_plan_upgrades`, data). A customer can upgrade at any time:
  - **Recurring:** the Stripe subscription switches price with proration.
  - **One-time / fixed-term:** the customer pays the path's price: the `difference` between the plans, a `fixed` amount, or `free`. The buyer proves ownership with a licence key or a session.

  Every change is recorded in `billing_plan_changes`. Admins can also upgrade a customer by hand from the dashboard; it is recorded the same way.
- **Discount coupons (approved).** Admins create coupons per workspace or per app (`billing_coupons`):
  - percent or fixed amount off;
  - limited to some plans, with dates and redemption limits;
  - for recurring plans: once, for N months, or forever.

  Customers enter a code on the hosted pricing page, or pass it to checkout. OpsAPI validates it, then applies it as a Stripe coupon on the connected account. Every use is recorded in `billing_coupon_redemptions`.
- **Refunds** (`charge.refunded`):
  - a full refund applies the app's `refund_policy`: `revoke` marks the purchase refunded, revokes the licence and ends any subscription; `keep` only records it;
  - partial refunds keep access;
  - either way `purchase.refunded` and `license.*` events are emitted and the cache is busted.
- **Connect:** onboarding, `account.updated`, a separate Connect webhook endpoint and secret, and the Customer Portal (unchanged from v1).

## 14. Events and webhooks

These go through the outbox (signed, retried) and only exist where billing is deployed:
- `subscription.*`: `activated`, `trialing`, `past_due`, `canceled`.
- `purchase.*`: `refunded`, `revoked`.
- `billing.grant.*` and `billing.plan.*`.
- `license.*`: `suspended`, `revoked`, `expired`.
- `license.activation.*`.
- **Computed:** `license.issued` and `license.reissued`. These need a new "computed source" in `plugin_event_sources` (no table), emitted by core code.

Payloads never include `key_hash` or `fingerprint_hash`. There is no computed `entitlements.changed`: SDKs drop cached answers on `subscription.*`, `purchase.*`, `billing.grant.*`, `billing.plan.*` and `license.*`.

## 15. Scale

| Hot path | How |
|---|---|
| Licence validate and activate | The app by `publishable_key` (unique), the licence by `key_hash` (unique), the activation by `(license_id, fingerprint_hash)` (unique): all O(1) |
| Entitlements | The customer by `(namespace_id, external_id)` (unique). The resolution and signed token are cached in Redis under `billing:ent:{app}:{cache_generation}:{customer}` with TTL = token TTL |
| Cache busting | Customer-scoped writes (grants, purchases, subscriptions, licences, deletion) delete the key. Plan, feature and settings changes bump `billing_apps.cache_generation`, so every customer's old entry stops being read. Without Redis, every call resolves from the DB |
| JWKS and public app info | `Cache-Control: public, max-age=300` and an ETag that includes the app's generation |
| Webhooks and email | Outbox only, never inline |
| Clients | Verify signed tokens and files locally. They call OpsAPI only to refresh |

## 16. Privacy and data minimisation

- **Email:** `email_collection` per app. With `none`, customers are identified only by `external_id` or licence. Access links then aren't available.
- **Machine fingerprints:** only app-salted SHA-256 hashes, computed on the device (LICENCE_FORMAT.md §6).
- **IP addresses:** never stored. They exist only as rate-limit and lockout counters that expire with their window.
- **Export:** `GET /api/v2/customers/:uuid/billing-export` returns JSON of the customer, their subscriptions, purchases, grants, licences (prefix only) and activations.
- **Delete:** `DELETE /api/v2/customers/:uuid/billing-data`:
  - revokes licences; cancels recurring subscriptions (immediately, in Stripe too, Phase 2);
  - deletes activations, access links, sessions, key deliveries and grants;
  - anonymises the customer (email → `deleted+{uuid}@invalid`, names, phone, addresses and `external_id` cleared);
  - **keeps** purchases and payments (amounts, dates, plan, currency) against the anonymised customer, because accounting law requires them. How long to keep them is the client's legal call. OpsAPI doesn't delete them automatically.

### What a client must disclose

A client can copy this into its privacy policy and app-store privacy answers.

| Data | When | Kept |
|---|---|---|
| Email, name (as the app's settings allow) and your own user id | Per customer | Until the customer or you delete it |
| Purchases, subscriptions, refunds: plan, amount, currency, dates, store transaction ids | Per purchase | For accounting, after deletion too (anonymised) |
| Licence key (only a hash and the first 5 characters), status, dates | Per licence | Until deletion |
| Activations: a salted hash of a machine identifier (not reversible, different in every app), a device name, platform, app version, first and last seen | Per device | Until freed, then `activation_retention_days` (default 90) |
| IP address | Per request | **Not stored.** Only short-lived rate-limit counters (minutes) |

**Processors:**
- Stripe, for payments: Phase 2; card data goes only to Stripe.
- The deployment's email provider, for access links and keys.
- The OpsAPI host.

App stores are processors only for sales made through them. Server access logs follow the hosting deployment's log retention; operators should keep it short.

## 17. RBAC

The modules are unchanged: `billing`, `subscriptions`, `entitlements`, `licenses`, plus `customers`.
- Owner and admin roles get `manage`; members get nothing.
- Custom roles work automatically. Example: "Support" with `subscriptions.read` and `licenses.read`/`update`.
- No owner bypass.
- Privacy operations need two permissions (§8.1).
- Secret keys can never get `namespace`.

## 18. Gating, env and deployment

- **Gating:** everything new is behind `billing` (feature check, routes, migrations, catalogue). `tax_copilot` billing stays unchanged.
- **Env:**

  | Variable | Purpose |
  |---|---|
  | `BILLING_SIGNING_KEY`, `BILLING_SIGNING_KEY_ID`, `BILLING_PREVIOUS_PUBLIC_KEYS` | Token signing (#694) |
  | `LICENCE_DELIVERY_KEY`, `LICENCE_DELIVERY_KEY_ID`, `LICENCE_DELIVERY_PREVIOUS_KEYS` | Key delivery (Phase 2) |
  | `BILLING_HOSTED_BASE_URL` | Hosted pages and email links |
  | `OPSAPI_PUBLIC_URL` | Token `iss` |
  | Phase 2: `STRIPE_PLATFORM_FEE_PERCENT`, `STRIPE_CONNECT_WEBHOOK_SECRET`, `STRIPE_SSL_VERIFY` | Payments |

  All are declared in `nginx.conf` and the deploy templates. None are committed.

## 19. Changes v2 makes to PR #694 (unmerged)

#694 implements v1 Phase 1. Merging it as it stands would ship a licence format, fingerprint input and settings shape that v2
then breaks. So the recommendation is to **extend #694 rather than merge it first** (§21, Q1). The concrete changes:
1. App tunables move into `settings` (§4). Migration `zzbe2` is edited in place; it has never run outside development.
2. Licence endpoints take `fingerprint_hash` (salted, from the client) and `app_version` instead of a raw fingerprint.
3. Tokens and licence files use format v1 claims (`fp` → `fingerprint_hash`, `offline_until` → `grace_until`, `policy` → `offline_policy`, `plan` → `plan_key`, plus `ver`, `access_until`, `updates_until`).
4. `/api/v2/public/billing/pricing` becomes `GET /api/v2/public/billing/apps/:app` (it adds branding and the salt).
5. SDK `@opsapi/client/billing` follows format v1 and adds a fingerprint helper and the public endpoints. 1.1.0 is not released yet, so nobody breaks.

## 20. Tests

**Already passing in #694** (v1):
- tax app untouched: identical schema, and 1,674 requests with 0 differences;
- fresh billing install;
- live API flows; ES256 and licence lifecycle;
- specs and SDK tests;
- Cypress pages.

**Added for v2:**
- **Resolution:**
  - lifetime and fixed-term purchases, with features released **before and after** `updates_until`;
  - recurring subscriptions keep later features;
  - stacking a fixed term twice;
  - store, manual and Stripe sources resolving to one set of entitlements.
- **Format:**
  - the server's tokens and licence files verify with the Python and Swift reference verifiers and the SDK;
  - every case in `licence-format-vectors.json` passes in the SDK test suite and in CI.
- **Public endpoints:**
  - a disallowed `Origin` or redirect URL is refused;
  - lockout after repeated bad keys;
  - rate limits come from the app's settings;
  - idempotent replay, and 409 on a different body;
  - no customer data without a credential;
  - `access-link` gives the same answer for known and unknown emails.
- **Delivery:** a key revealed once and then purged; purged at 24 h; never in logs or events by default. Reissue rotates the key, the old key fails and activations stay.
- **Privacy:** export, and delete (revoked, anonymised, accounting rows kept).
- **End to end, data only:** an app configured purely through the API (settings, features, plans), a manual lifetime sale, a licence, activation through the public endpoint, offline verification with the reference verifier, then revoke and refresh.
- **Regressions:** the tax-app regression sandbox is re-run; a fresh `PROJECT_CODE=billing` install.

## 21. Decisions (approved 2026-10-08)

| # | Decision |
|---|---|
| 1 | **Everything goes on PR #694**, Phase 1 and then Phase 2 |
| 2 | **Upgrades** are admin-defined paths (data). Customers upgrade at any time, and every plan change is recorded. **Discount coupons** are managed by admins and applied at checkout (§13) |
| 3 | **Email:** each workspace can set its own SMTP, falling back to the deployment's. Every email has a built-in default template that a workspace can override (§10) |
| 4 | **Hosted pages** on the dashboard at `{BILLING_HOSTED_BASE_URL}/b/{app_id}/…`. **Checkout is Stripe's hosted page**, and Stripe webhooks update the database |
| 5 | **Rate limits and lockouts** use shared Redis counters (atomic increment with expiry) when Redis is configured, and fall back to per-pod shared memory |
| 6 | Idempotency keys: accepted on every mutating call, required on checkout, replayed for 24 h |
| 7 | Per-kind defaults as in §4 |
| 8 | Access links last 15 minutes and are single-use; sessions last 30 minutes |
| 9 | After a delete, accounting rows are kept (anonymised); activations are kept for 90 days after release |
| 10 | **Phase 1** (no payments): settings; purchase types, purchases and windows; `released_at`; format v1; hardened publishable licence endpoints; access links and the "my licences" page; manual sales; upgrade paths, coupons and plan-change history (managed, and applied to manual sales and upgrades); workspace SMTP and templates; the store data model, record endpoint and verifier stubs; privacy export and delete; rate limits and lockout; the entitlement cache; SDK v1. **Phase 2** (payments): Connect; Stripe Checkout for all three purchase types, with coupons and upgrades; webhook fulfilment and key delivery; the pricing and success pages; refunds; automatic tax; the Customer Portal |
