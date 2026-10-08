# Changelog

All notable changes to `@opsapi/client`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [SemVer](https://semver.org/). Until 1.0, a minor version may contain breaking changes; they are listed here.

## 0.1.1

- Fixed: `auth.login()`, `auth.verify2fa()`, `auth.refresh()` and `auth.logout()` now send form fields, which is what OpsAPI reads on `/auth/*`. In 0.1.0 sign-in failed with "identifier required".
- README: what OpsAPI is, how to run your own server from Docker Hub (local trial and production checklist), first sign-in, creating an API key, and troubleshooting.

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
