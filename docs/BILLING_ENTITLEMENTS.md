# Billing & Entitlements — design

Status: **Phase 1 implemented** (no payments). The owner approved every proposal
in §16 on 2026-10-08. Phase 2 (Stripe Connect) follows once Phase 1 is merged.

## 1. What we are building

A client (an OpsAPI workspace) registers **their app**, defines its **features** and
**flat-tier plans**, and lets **their own end users** subscribe. Their app then asks
OpsAPI *"may this customer use this feature?"*:

- **Web/SaaS apps** gate features with a signed entitlement token that they verify
  locally. One SDK call does it.
- **Desktop and self-hosted apps** use **licence keys**, with activations and an
  offline signed licence file.
- **Mobile app-store purchases** are designed for, but not built.

The money goes into the client's **own Stripe account** (Stripe Connect), and the
platform takes a configurable percentage. It runs hosted as a separate deployment
(`PROJECT_CODE=billing`), or self-hosted with the same code.

Fixed decisions:

| Topic | Decision |
|---|---|
| Who collects | The client, via Stripe Connect, plus a platform fee (`STRIPE_PLATFORM_FEE_PERCENT`) |
| App types | Web/SaaS (entitlements), desktop and self-hosted (licences); mobile later |
| Pricing | **Flat tiers only.** A feature is on/off or a numeric limit. No per-seat or usage-based pricing |
| Hosting | A separate deployment with `PROJECT_CODE=billing`, which is the hard module boundary |
| OpsAPI unreachable | **Per-app** `fail_open` / `fail_closed`, with a grace period |
| Customers | **Reuse the existing `customers` table** (extended), not a new one |

## 2. What exists today (and what we reuse)

| Piece | Where | Reuse? |
|---|---|---|
| `billing_plans` (with a `features` JSONB map), `billing_subscriptions` (keyed by OpsAPI `user_uuid`), `billing_payments`, `billing_refunds` (unused), `stripe_webhook_events`, `usage_meters` (unused) | `migrations/billing-system.lua`, keys 700–709, gated on `tax_copilot` | **Yes.** Extend these; don't duplicate them |
| Routes `/api/v2/billing/{plans,checkout,subscription,entitlements,payments}` and `/api/v2/public/billing/{plans,webhook,checkout/return}` | `routes/billing-*.lua`, `load_if("tax_copilot")` | **Keep the contracts unchanged.** The DIY tax frontend (`diy-tax-return-uk/frontend/src/lib/api.ts`) is the only consumer |
| Entitlement snapshot for an OpsAPI user | `helper/entitlement-service.lua` (`forUser`, `can`, `limit`) | **Yes.** Generalise it to customers |
| Single-merchant Stripe client: plans → product/price sync, webhook signature verification and idempotency | `lib/stripe.lua`, `lib/payment-provider.lua`, `BillingPlanQueries.ensureStripeSync`, `StripeWebhookQueries` | **Yes.** Add the `Stripe-Account` header and Connect calls in Phase 2 |
| Committed Stripe Connect code (Express onboarding, `account.updated`, destination charges, `application_fee_*`) | Academy commits `f86afefe` and `4728e291`, removed in `3a0d8240` ("platform-as-merchant") | **As a reference** for Phase 2 |
| `customers` (workspace-scoped, `email`, names, `stripe_customer_id`, `custom_fields`, `user_id`), routes `/api/v2/customers` (RBAC `customers`) | ecommerce migrations 15/31/71–75/166; `routes/customers.lua`; `CustomerQueries` | **Yes**, extended (§4.1) |
| API keys `opsk_…`: SHA-256 hashed, workspace-bound, module scopes; `permits_uri` = the first segment of `/api/v2/<segment>/` must be a scoped module | `helper/api-key.lua`, `routes/api-keys.lua` | **Yes.** These are the client's **secret server key** |
| Outbound webhooks: signed `X-Opsapi-Signature-256`, retries, outbox driven by `PluginEvents.CATALOG` table triggers | `lib/outbound-webhooks.lua`, `helper/plugin-events.lua` | **Yes.** Add billing tables to the catalogue |
| Rate limiting | `middleware/rate-limit.lua` (`RateLimit.check(key, rate, window)`) | **Yes**, keyed per licence or key, not only per IP |
| Asymmetric signing | none. All JWTs are HS256. ES256 building blocks exist (`resty.openssl.pkey`, see `helper/apns-push.lua`) | **New:** ES256 tokens plus a JWKS endpoint (§6) |

Known issues found along the way, fixed in the phase that touches them:

- The billing routes have **no RBAC modules**. Admin actions use `namespace.manage`; everything else is open to any member.
- `STRIPE_SSL_VERIFY` isn't declared in `nginx.conf`, so outbound Stripe TLS verification is effectively off.
- The header comments of `billing-system.lua` and `payment-provider.lua` still describe Connect.

## 3. Concepts

| Concept | Meaning |
|---|---|
| **Workspace** (namespace) | The client's account. Isolation boundary for everything below |
| **App** | One product the client sells (web, desktop, self-hosted, mobile). A workspace can have several |
| **Feature** | Something an app can gate: `advanced_reports` (on/off) or `projects` (limit). Belongs to an app |
| **Plan** | A flat tier of an app: price, interval, trial days, and a value for each feature. The **default plan** is what every customer gets for free |
| **Customer** | The client's end user: a `customers` row with `external_id` (the client's own user id) |
| **Subscription** | A customer on a plan (from Stripe, or manual) |
| **Grant** | Manual access without payment: a comped plan, a trial extension, a single feature, an enterprise deal. Can expire |
| **Licence / activation** | A licence key for desktop or self-hosted software; each machine that uses it is an activation |
| **Entitlements** | A customer's effective features for an app right now (§5) |
| **Keys** | **Secret key** = an `opsk_` API key, server side only. **Publishable key** = `pk_…` per app, safe in browsers and desktop binaries, used only to identify the app on public endpoints |

## 4. Data model

All changes are **additive and idempotent**, with migration keys prefixed `zzbe…` (Lapis
sorts keys as strings). Every new table is workspace-scoped. The retired key `700`
is never reused.

### 4.1 Changes to existing tables

- **`customers`**
  - Add `external_id TEXT`, with a partial unique index on `(namespace_id, external_id) WHERE external_id IS NOT NULL`.
  - Add it to `CustomerQueries.VALID_CUSTOMER_FIELDS`.
  - **Blocker, see §16 Q1:** `customers_email_unique_idx` makes `email` unique **across all workspaces**, so the same person can't be a customer of two clients. Proposed fix: replace it with a per-workspace `(namespace_id, lower(email))` unique index, and scope `CustomerQueries.findByEmail` to the workspace. The ecommerce lookups that rely on it are updated in the same change.
- **`billing_plans`**
  - Add `app_id` (FK `billing_apps`, ON DELETE CASCADE; **NULL = the existing tax plans**).
  - Add `plan_key` (unique per app), `is_default BOOL` (at most one per app, partial unique index), and `is_public BOOL`.
  - `features` stays JSONB and is now validated against the app's feature catalogue.
  - Phase 2 adds `stripe_refs JSONB` (product and price ids per connected account and mode). The existing `stripe_*_id` columns stay for tax.
- **`billing_subscriptions`**
  - Add `app_id` and `customer_id` (FK `customers`, **ON DELETE RESTRICT**: cancel before deleting).
  - Drop NOT NULL on `user_uuid`.
  - Add `CHECK (user_uuid IS NOT NULL OR customer_id IS NOT NULL)`.
  - Add the index `(app_id, customer_id, status)`.
  - Existing rows are untouched.
- **`modules`:** `ADD COLUMN IF NOT EXISTS allowed_actions TEXT`. It is only created under `tax_copilot` today, and the module rows here need it.

### 4.2 New tables

**`billing_apps`**

| Column | Type / notes |
|---|---|
| `id`, `uuid` | |
| `namespace_id` | FK, CASCADE |
| `name` | |
| `slug` | unique per workspace |
| `kind` | `web`, `desktop`, `self_hosted`, `mobile` |
| `mode` | `test` / `live`; default `test` |
| `publishable_key` | `pk_test_…` / `pk_live_…`; unique |
| `offline_policy` | `fail_open` / `fail_closed`; default `fail_closed` |
| `offline_grace_seconds` | default 259200 (72 h) |
| `entitlement_ttl_seconds` | default 900 |
| `past_due_grace_days` | default 7 |
| `allowed_return_urls` | JSONB (checkout redirects) |
| `settings` | JSONB |
| `active`, `deleted_at`, timestamps | |

**`billing_features`**

| Column | Type / notes |
|---|---|
| `id`, `uuid`, `app_id` | `app_id` FK, CASCADE |
| `key` | `[a-z0-9_]{1,64}`, unique per app |
| `name`, `description` | |
| `type` | `boolean` / `limit` |
| `unit` | e.g. "projects" |
| `sort_order`, timestamps | |

**`billing_grants`**

| Column | Type / notes |
|---|---|
| `id`, `uuid`, `namespace_id`, `app_id` | |
| `customer_id` | FK, CASCADE |
| `plan_id` / `features` | grant a whole plan, **or** specific feature values |
| `reason` | |
| `starts_at`, `expires_at` | `expires_at` NULL = no end |
| `granted_by` | user uuid |
| `revoked_at`, timestamps | |

**`billing_licenses`**

| Column | Type / notes |
|---|---|
| `id`, `uuid`, `namespace_id`, `app_id` | |
| `customer_id` | FK, RESTRICT |
| `subscription_id` / `plan_id` | the licence either follows a subscription or carries a fixed plan |
| `key_hash` | SHA-256; UNIQUE |
| `key_prefix` | for display |
| `status` | `active`, `suspended`, `revoked`, `expired` |
| `max_activations` | NULL = unlimited |
| `expires_at` | |
| `metadata`, `revoked_at`, timestamps | |

**`billing_license_activations`**

| Column | Type / notes |
|---|---|
| `id`, `uuid`, `license_id` | `license_id` FK, CASCADE |
| `fingerprint_hash` | SHA-256 of the machine fingerprint the app sends |
| `name`, `platform`, `app_version` | |
| `first_seen_at`, `last_seen_at`, `deactivated_at` | |

Unique on `(license_id, fingerprint_hash) WHERE deactivated_at IS NULL`.

**Phase 2: `billing_connect_accounts`**

| Column | Type / notes |
|---|---|
| `namespace_id` | UNIQUE |
| `stripe_account_id` | |
| `mode` | |
| `charges_enabled`, `payouts_enabled`, `details_submitted` | |
| `onboarding_status` | |
| timestamps | |

This is a new name on purpose: key 708 drops the old `namespace_payment_accounts`.

Licence keys are shown **once** at creation, like API keys. Only `key_hash` and `key_prefix` are stored.

## 5. Entitlement resolution

`Entitlements.resolve(app, customer)` builds the result in this order:

1. Start from the app's **default plan** features. With no default plan, every feature is off.
2. Overlay the newest subscription for this app whose status is `active` or `trialing`, or `past_due` within `past_due_grace_days`.
3. Overlay active grants: whole-plan grants first, then single-feature grants. For booleans the result is OR; for limits it is the maximum (NULL means unlimited and wins).
4. Return:
   - `{ plan, status, features, sources[] }`;
   - `expires_at`: the earliest of the period end, the grant expiry and the TTL;
   - the app's offline policy.

It's deterministic and fast: a few indexed queries, no Stripe calls. Changes to
subscriptions, grants or plans emit `entitlements.changed` (§9).

## 6. Signed tokens and licence files (new ES256 signing)

- **One signing key per deployment:**
  - `BILLING_SIGNING_KEY`: an EC P-256 private key (PEM), from Vault or `.env`, with `BILLING_SIGNING_KEY_ID`;
  - `BILLING_PREVIOUS_PUBLIC_KEYS`: old public keys kept for rotation.
  - Declared in `nginx.conf`.
- **Signing:** via `resty.openssl.pkey`, using the DER→raw conversion already used in `helper/apns-push.lua`.
- **JWKS:** `GET /api/v2/public/billing/jwks.json` publishes the current and previous public keys.
- **Entitlement token** (`typ: opsapi-entitlements+jwt`):
  - claims: `iss` (deployment URL), `aud` (app uuid), `sub` (customer `external_id`), `ns`, `plan`, `status`, `features`, `iat`, `exp` (now + `entitlement_ttl_seconds`), `grace` (`offline_grace_seconds`), `policy`;
  - the SDK verifies it locally (WebCrypto) and caches it until `exp`;
  - past `exp`, and with OpsAPI unreachable, the SDK honours `policy`. `fail_open` keeps the last known entitlements until `exp + grace`; `fail_closed` denies.
- **Licence file** (`typ: opsapi-license+jwt`):
  - claims: `lic`, `aud`, `sub`, `fp` (fingerprint hash), `features`, `exp` (the earlier of the licence expiry and the next check-in), `offline_until`;
  - desktop and self-hosted apps verify it offline with the public key embedded in the app or fetched from JWKS.
- Without `BILLING_SIGNING_KEY`, nothing is signed and nothing silently uses a weak key:
  - the licence endpoints return **503** `not_configured`;
  - the runtime entitlement check still returns the entitlements, but with `"token": null` and a `meta.token` hint. The SDK refuses unsigned answers.

## 7. APIs

The URL's first segment **equals its RBAC module**, so API-key scopes work through the
existing `permits_uri` with no change to it. JSON envelopes are `{ success, data, meta }`.
Lists use `Global.pageParam` / `perPageParam` and `meta.total_pages`.

### 7.1 Management (dashboard JWT, or a scoped secret key)

| Route | Module.action |
|---|---|
| `GET/POST /api/v2/billing/apps`, `GET/PUT/DELETE /api/v2/billing/apps/:uuid` | `billing.read/create/update/delete` |
| `POST /api/v2/billing/apps/:uuid/rotate-key` (publishable key) | `billing.update` |
| `GET/POST /api/v2/billing/apps/:uuid/features`, `PUT/DELETE …/features/:key` | `billing.*` |
| Plans: the **existing** `/api/v2/billing/plans*`, plus `?app=` and the new fields | `billing.*` **or** `namespace.manage` (the existing check, kept so the tax app works unchanged) |
| `GET /api/v2/billing/apps/:uuid/reports` (active subscriptions, MRR, trials, churn in the last 30 days) | `billing.read` |
| `GET /api/v2/subscriptions?app=&customer=&status=`, `GET /api/v2/subscriptions/:uuid` | `subscriptions.read` |
| `POST /api/v2/subscriptions/:uuid/cancel`, `…/change-plan` (**Phase 2**, with checkout) | `subscriptions.update` |
| `GET /api/v2/subscriptions/entitlements?app=&customer=` (a customer's effective entitlements, for the dashboard; no token) | `subscriptions.read` |
| `GET/POST /api/v2/subscriptions/grants`, `DELETE …/grants/:uuid` | `subscriptions.create/delete` |
| `GET/POST /api/v2/licenses`, `GET/PUT /api/v2/licenses/:uuid` | `licenses.read/create/update` |
| `POST /api/v2/licenses/:uuid/revoke`, `DELETE /api/v2/licenses/:uuid/activations/:id` | `licenses.update/delete` |
| Customers: the existing `/api/v2/customers` (module `customers`), with `external_id` now accepted | unchanged |

### 7.2 Runtime (the client's server, with a secret key scoped `entitlements` / `subscriptions`)

| Route | Module.action |
|---|---|
| `PUT /api/v2/entitlements/:app/customers/:external_id` (upsert email and names) | `entitlements.create` |
| `GET /api/v2/entitlements/:app/customers/:external_id` → entitlements plus a signed `token`. An unknown `external_id` gets the default plan, not a 404 | `entitlements.read` |
| `POST /api/v2/subscriptions/checkout` → Stripe Checkout URL (Phase 2) | `subscriptions.create` |
| `POST /api/v2/subscriptions/portal` → Stripe Customer Portal URL (Phase 2) | `subscriptions.create` |

### 7.3 Public (no secret; publishable key or licence key; rate-limited per key and per IP)

| Route | Purpose |
|---|---|
| `GET /api/v2/public/billing/pricing?pk=` | The app's public plans and features, for a pricing page |
| `GET /api/v2/public/billing/jwks.json` | Public signing keys |
| `POST /api/v2/public/licenses/activate`, `/validate`, `/deactivate` (`{pk, license_key, fingerprint, name?, platform?}`) | Desktop and self-hosted licensing; returns the signed licence file |

Every route checks that the app, plan, customer and licence ids belong to
`self.namespace` (404 otherwise), following the tenant-isolation rules of #682.

## 8. RBAC

New modules, in `PROJECT_MODULES.billing` and the `modules` table:

| Module | Covers | Owner | Admin | Member |
|---|---|---|---|---|
| `billing` | Apps, features, plans, reports, Connect settings | manage | manage | none |
| `subscriptions` | Subscriptions, grants, checkout and portal sessions | manage | manage | none |
| `entitlements` | Runtime customer upsert and entitlement checks | manage | manage | none |
| `licenses` | Licences and activations | manage | manage | none |

- They're registered by a migration in the `outbound-webhooks.lua` style: `INSERT … ON CONFLICT DO NOTHING RETURNING`, then `ModuleQueries.propagateToNamespaceAdmins` on first insert only, so later revocations stick.
- Menu items under a **Billing** section use icons already in `ICON_MAP`.
- Nothing bypasses roles; owners get access through the owner role.
- Custom roles, e.g. "Support" with `subscriptions.read/update` and `licenses.read/update` but no `billing`, work automatically.

## 9. Webhooks to the client

- **Catalogue (as built):** `PluginEvents.CATALOG` gains these entities, only where the billing feature is deployed. Table triggers feed the existing signed and retried delivery:
  - `subscription` (`billing_subscriptions`): verbs `activated`, `trialing`, `past_due`, `canceled`;
  - `billing.plan` (`billing_plans`);
  - `billing.grant` (`billing_grants`);
  - `license` (`billing_licenses`, `key_hash` hidden): verbs `suspended`, `revoked`, `expired`;
  - `license.activation` (`billing_license_activations`, fingerprint hidden).

  Each also has `created/updated/deleted`.
- **No computed `entitlements.changed`.** Entitlements are computed from exactly these rows, so an app drops its cache on `subscription.*`, `billing.grant.*` or `billing.plan.*` (SDK: `billing.invalidate()`). Tokens also expire within the app's TTL, 15 minutes by default.
- **Subscribing:** clients subscribe through the existing Webhooks page. Event visibility follows RBAC read on the entity's module.

## 10. Stripe Connect (Phase 2)

- **Onboarding:**
  - `POST /api/v2/billing/connect/onboard` (`billing.manage`) creates or reuses an Express account and returns the onboarding link;
  - `account.updated` refreshes `billing_connect_accounts`.
- **Product and price sync** happens on the connected account via the `Stripe-Account` header, per mode, into `stripe_refs`.
- **Checkout:**
  - destination charges (`transfer_data.destination`, as in the academy reference) with `application_fee_percent` / `application_fee_amount` from `STRIPE_PLATFORM_FEE_PERCENT`;
  - `client_reference_id` and metadata carry `{namespace, app, customer, plan}`;
  - a Stripe Customer is created on first checkout and stored in `customers.stripe_customer_id`;
  - idempotency keys on every create call.
- **Customer Portal sessions** let customers cancel, update their card and download invoices.
- **Webhooks:**
  - a **separate** endpoint for Connect events (`STRIPE_CONNECT_WEBHOOK_SECRET`), routed by `event.account`;
  - same `stripe_webhook_events` idempotency, now recording `stripe_account_id`;
  - same subscription and payment mirroring.
  - The tax app's single-merchant endpoint and flow are untouched.
- **Modes:** each app's `mode` picks the test or live platform keys.
- **TLS:** declare `STRIPE_SSL_VERIFY` and turn verification on.

## 11. Feature gating and deployment

- `FEATURES.BILLING = "billing"`, plus a `billing` preset: `core`, `billing`, `notifications`, `menu`, `themes`.
- **Migrations:**
  - billing-system keys 700–709 → `conditional_array({TAX_COPILOT, BILLING}, …)`;
  - `customers` keys (15, 31, 71–75, 166) → `{ECOMMERCE, BILLING}` (the same OR pattern as keys 54/55);
  - the new `zzbe*` keys → `BILLING`.
- **Routes:** `load_if` in `app.lua` accepts a list (OR). `routes/billing-plans.lua` → `{tax_copilot, billing}`; `routes/customers.lua` → `{ecommerce, billing}`; the new `billing-apps`, `billing-subscriptions` and `billing-licenses` → `billing`. The tax app's checkout, webhook and account routes stay `tax_copilot` only.
- **Without the billing feature** no new column or table is referenced: app-plan fields, `?app=` and the webhook catalogue entries are all behind `isFeatureEnabled("billing")`.
- **`PROJECT_CODE=all`** (workstation int/prod) gets everything; diy (`tax_copilot,services`) is unchanged.
- **Hosted deployment** (Helm values, DNS, the Ring Promoter app) is a follow-up, once the hostname is confirmed.

## 12. Dashboard

A **Billing** section with these pages, all gated with `ProtectedPage`:

| Page | Module | Contents |
|---|---|---|
| Apps | `billing` | Create an app, keys, offline policy, return URLs |
| Features & Plans | `billing` | Per app; default plan; features as on/off or a limit per plan |
| Subscriptions | `subscriptions` | Filter by app and status; cancel and change plan; grants |
| Licences | `licenses` | Issue (key shown once), revoke, activations |
| Payments | `billing.manage` | Connect onboarding (Phase 2) |

The existing Customers page gains a **Billing** tab (subscriptions, grants, licences,
effective entitlements). Built with the existing UI components and services.

## 13. SDK (`@opsapi/client`, new subpath `@opsapi/client/billing`)

| Function | What it does |
|---|---|
| `createBilling({ baseUrl, apiKey, app })` | Server-side helper with the secret key |
| `getEntitlements(externalId)` | Cached until the token expires, verified against JWKS, honours `policy` / `grace` when OpsAPI is unreachable |
| `can(externalId, feature)`, `limit(externalId, feature)` | Simple checks |
| `requireFeature(feature, getCustomerId)` | Express/Connect middleware; 402 `feature_required` with an optional upgrade URL |
| `withFeature(feature, getCustomerId, handler)` | The same for fetch-style handlers (Next.js route handlers, Hono, Bun, Deno) |
| `upsertCustomer(…)`, `invalidate(externalId?)` | Register a customer; drop cached answers (from a webhook) |
| `checkout(…)`, `portal(…)` | Phase 2 |
| `licenses.activate/validate/deactivate({ publishableKey, licenseKey, fingerprint })` and `verifyLicenseFile(file, jwks)` | Desktop and self-hosted; offline verification |

Ships in the same package (a new tsup entry plus an `exports["./billing"]` block), as a
**minor** version, with a README section.

## 14. Backward compatibility, security, testing

**The tax app must not notice anything.**
- Existing billing routes keep the same paths, bodies, responses and permission checks; plan routes only gain the optional `billing.*` alternative.
- Its migrations only gain OR-gating.
- Its single-merchant checkout and webhook are unchanged.
- **Proof:** a differential regression of every `/api/v2/billing/*` route, `main` vs the branch, under `PROJECT_CODE=tax_copilot,services`, in the no-internet sandbox (the API regression sandbox recipe).

**Security**
- Secret keys and licence keys are stored hashed and shown once.
- Card data never touches OpsAPI.
- Public endpoints are rate-limited per key and per IP.
- Signing keys only come from Vault or env.
- Workspace checks on every id.
- `fail_closed` is the default.

**Tests**
- **Lua specs** (house style):
  - entitlement resolution: default plan, subscriptions, `past_due` grace, grants and expiry, limit merging;
  - licences: activation limits, deactivate, revoke, expiry;
  - ES256 sign/verify and JWKS;
  - RBAC: 403 for members without the module;
  - cross-workspace ids → 404;
  - webhook idempotency;
  - gating wiring (routes and migrations load for `billing`, and for `tax_copilot` as before).
- **SDK unit tests:** token verification, caching, fail-open/closed, middleware, licence-file verification.
- **Fresh install** with `PROJECT_CODE=billing`: migrates cleanly and serves only core plus billing.
- **Phase 2:** an end-to-end run on Stripe **test mode** with a test connected account.

**Phase 1 results (2026-10-08)**
- **Tax app untouched:** in a no-internet sandbox, `main` and this branch each migrated an empty database under `PROJECT_CODE=tax_copilot,services`. The results matched:
  - schemas: identical;
  - migration list, modules, menu and webhook sources: identical.
- **Request sweep:** 1,674 requests compared main against the branch, with **0 differences**:
  - every GET path in either spec (562) as anonymous, as a non-member and as the workspace owner;
  - the tax plan flow (25 steps, bodies compared), covering create (also with app fields sent), list, `?app=`, update, sync, public plans, subscription, entitlements, payments, checkout, member 403, the webhook event list and delete;
  - the new route families, which are 404 on both.
- **Fresh `PROJECT_CODE=billing` install:** migrates cleanly, and a re-run only repeats the always-run migrations. Checked on it:
  - the menu shows Billing, Subscriptions, Licences and Customers;
  - an owner can create an app, a feature and a default plan;
  - an `entitlements`-scoped key can upsert a customer and read entitlements, and gets 403 on `billing`;
  - JWKS is empty and licensing returns 503 without a key;
  - tax, kanban, CRM, invoices and orders are 404.
- **Live on `PROJECT_CODE=all`:**
  - the API flows for apps, features, plans (validation and the default switch), grants (merge and expiry), licences (seat limit, suspend, expiry, revoke), reports, tenant isolation and API-key scopes;
  - ES256 tokens and licence files verified against the JWKS, and a server-signed token verified by the SDK;
  - dashboard pages checked in Cypress, desktop and mobile.
- **Specs:**
  - `spec/billing-entitlements_spec.lua`: 34 checks;
  - SDK `test/billing.test.ts`: 16 tests;
  - the existing plugin-platform, openapi-coverage, quality-fixes and tenant-isolation specs still pass.

## 15. Phases

| PR | Contents |
|---|---|
| **Phase 1** | Gating and preset; schema (§4); entitlements engine; ES256 tokens and JWKS; licensing; management, runtime and public APIs (except checkout and portal); RBAC, menu and dashboard; webhook catalogue; SDK billing subpath; tests; docs. Clients can already gate features (default plan, trials, grants, licences) **without payments** |
| **Phase 2** (after Phase 1 merges) | Stripe Connect: onboarding, product and price sync, checkout, portal, Connect webhooks, fees, modes, TLS verification on, end-to-end test-mode run |
| **Later** | Mobile store purchases (an extension point: `billing_subscriptions.provider` gains `apple` / `google`); usage reporting; the hosted deployment; using it for OpsAPI's own AI plans |

## 16. Owner decisions (approved 2026-10-08, all as proposed)

1. **`customers.email` is unique across all workspaces.** OK to change it to unique **per workspace** (and scope `findByEmail` to the workspace)? Without this, reusing `customers` can't work for more than one client.
2. **Several apps per workspace** (proposed), or exactly one app per workspace?
3. **Route families** `billing`, `subscriptions`, `entitlements`, `licenses` (they double as the RBAC modules and API-key scopes) — OK?
4. **One signing key per deployment** (proposed), or one per app?
5. **Platform fee:** one global `STRIPE_PLATFORM_FEE_PERCENT`, or a per-workspace override set by a platform admin?
6. **Defaults:** `fail_closed`, 72 h offline grace, 15 min token TTL, 7-day `past_due` grace. OK?
7. **Billing customers in the existing Customers page:** they share one table, so they'll appear there, with a Billing tab. OK?
