# Changelog

All notable changes to `@opsapi/client`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [SemVer](https://semver.org/). Until 1.0, a minor version may contain breaking changes; they are listed here.

## Unreleased

- `@opsapi/client/property-deals`: the AI layer (Phase 5) — "Let AI do it" (`POST /tasks/{id}/agent-run`), agent runs, `/ai/agents`, `/ai/routes`, `/ai/usage`, approval retry and booking confirmation, mail connectors and inbound messages, notification preferences, the task contact log; `ApprovalDecision` gains `payload_version` / `payload_sha256`. New named types `Agent`, `AgentConfig`, `AiRoute`, `MailConnector`, `MailConnectorWrite`, `InboundMessage`, `NotificationPreferences`; more events in `PROPERTY_DEALS_EVENTS`.

## 1.2.0

- New subpath `@opsapi/client/property-deals` for the Property Deals plugin (a back office for buying and selling homes; guide: docs/property-deals/API.md). It needs an OpsAPI server with the plugin installed and switched on for the workspace.
  - `createPropertyDealsClient()` is `createClient()` typed with core + Property Deals paths: Today, deals (board, overview, gates, stage moves, health, timeline), tasks, leads, properties, buyers, suppliers, bookings, compliance, documents, approvals (inbox and decisions), workflow templates, map, digest.
  - Named types for the main records (`Deal`, `Task`, `Today`, `DealOverview`, `Approval`, `MapResult`, …), plus `TASK_STATUSES` and `PROPERTY_DEALS_EVENTS`.
- `scripts/generate.mjs --plugin <code>` generates types for one plugin only (`npm run generate:property-deals`).

## 1.1.0

- New subpath `@opsapi/client/billing` for OpsAPI's Billing & Entitlements module. It needs an OpsAPI server with that module and `BILLING_SIGNING_KEY` set. Tokens and licence files use format v1 (docs/LICENCE_FORMAT.md).
  - `createBilling()`: `getEntitlements()`, `can()`, `limit()`, `upsertCustomer()`, `recordPurchase()` (verified App Store, Google Play or external purchases) and `invalidate()`.
    - Answers are ES256-signed tokens, checked against the server's JWKS and cached until they expire.
    - When OpsAPI can't be reached, each app's offline policy applies: fail open within the grace period, or fail closed.
    - One request is shared between concurrent checks.
  - `requireFeature()` (Express/Connect) and `withFeature()` (fetch-style handlers) answer 402 `feature_required`.
  - `createLicensing()` for apps without a back end. It uses the publishable key: `appInfo()`, `activate()`, `validate()`, `deactivate()`, `requestAccessLink()`, `checkout()` (a Stripe Checkout URL, or an upgrade with `licenseKey`) and `order()` (the order for a success page; a new licence key is in it once). Every mutating call sends an Idempotency-Key.
  - Payments on the server: `checkout()` and `portal()` (Stripe Customer Portal). They need an API key with the `subscriptions` scope.
  - `fingerprintHash(salt, machineId)`.
  - `verifyLicenseFile()` returns `state`, `allowed` and `needsCheckIn`. It is protected against the clock being turned back (`highWater`).
  - `tokenState()`, `verifyToken()`, `BillingError` (with the server's `code`) and `sha256Hex()`.
- Typed paths for the billing, subscriptions, entitlements, licences, payments (Stripe Connect, checkout, portal, refunds), workspace-email and public billing endpoints: 932 paths.
- Tested against every case in docs/licence-format-vectors.json, and against a live server.

## 1.0.0

The first stable release. From here the client follows [SemVer](https://semver.org/): breaking changes come only in a new major version.

- Fixed: sign-in. `auth.login()`, `auth.verify2fa()`, `auth.refresh()` and `auth.logout()` now send form fields, which is what OpsAPI reads on `/auth/*`. In 0.1.0 sign-in failed with "identifier required".
- `paginate()` handles every list shape OpsAPI returns: `meta.total_pages`, camelCase `meta.totalPages`, `total` + page size, paging info at the top level, items under `items`, and endpoints that aren't paginated at all. It stops at the last page and never loops; in 0.1.0 a list with no paging info that ignores `?page` was fetched forever. New `options.items` reads items kept elsewhere (e.g. `(r) => r.notifications`). `paginateCursor()` also reads a top-level or camelCase next cursor. `PageResult` and `PageOptions` are exported.
- Verified against a live server: sign-in with 2FA and refresh, API keys, create/read/update/delete, pagination across endpoint shapes, errors (401/403/404/422), and webhook signatures produced by the server.
- README: what OpsAPI is, running your own server from Docker Hub (local trial and production checklist), first sign-in, creating an API key, and troubleshooting.

## 0.1.0

First public release.

- `createClient()`: typed `GET`/`POST`/`PUT`/`PATCH`/`DELETE` for every OpsAPI endpoint, generated from the server's OpenAPI spec: 874 paths, including e-commerce (orders, cart, categories, stores, delivery), the AI assistant and AI usage, notifications, documents, and workspace members and roles.
- Types for the workspace plugin endpoints: `GET /api/v2/namespace/plugins`, `PUT /api/v2/namespace/plugins/{code}` and `POST /api/v2/plugins/{code}/jobs/{job}/run`.
- Sign-in: API keys and JWTs, `auth.login()` with two-factor `auth.verify2fa()`, `auth.refresh()`, `auth.logout()`, `onUnauthorized` token renewal.
- Workspaces by UUID or slug; `setNamespace()` and `setToken()` to switch.
- `OpsApiError` with `status`, `code`, `context`, `details` and `isUnauthorized`/`isForbidden`/`isNotFound`/`isConflict`/`isValidation`.
- Timeouts, and retries with backoff and `Retry-After` for `GET`/`PUT`/`DELETE`.
- `paginate()`, `paginateCursor()` and `collect()` for lists.
- `verifyWebhook()` and `signWebhook()` for webhook deliveries.
- Typed plugin APIs: pass `paths` generated from your own server.
