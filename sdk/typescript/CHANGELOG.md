# Changelog

All notable changes to `@opsapi/client`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [SemVer](https://semver.org/). Until 1.0, a minor version may contain breaking changes; they are listed here.

## 1.1.0

- New subpath `@opsapi/client/billing` for OpsAPI's Billing & Entitlements module. It needs an OpsAPI server with that module and `BILLING_SIGNING_KEY` set.
  - `createBilling()`: `getEntitlements()`, `can()`, `limit()`, `upsertCustomer()` and `invalidate()`. Answers are ES256-signed tokens, checked against the server's JWKS and cached until they expire. Each app's offline policy (fail open within a grace period, or fail closed) is followed when OpsAPI can't be reached.
  - `requireFeature()` (Express/Connect) and `withFeature()` (fetch-style handlers) answer 402 `feature_required`.
  - `createLicensing()` (`activate`, `validate`, `deactivate`) with a publishable key, and `verifyLicenseFile()` for offline checks of signed licence files.
  - `BillingError`, `verifyToken()` and `sha256Hex()`.
- Typed paths for the new endpoints: `/api/v2/billing/apps*`, `/api/v2/subscriptions*`, `/api/v2/entitlements/{app}/customers/{external_id}`, `/api/v2/licenses*`, and the public pricing, JWKS and licence endpoints.

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
