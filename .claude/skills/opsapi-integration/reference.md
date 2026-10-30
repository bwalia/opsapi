# OpsAPI integration — reference

The endpoint catalogue behind [SKILL.md](SKILL.md). Paths are relative to the deployment's base URL
(`$OPSAPI_URL`). "Authed" means `Authorization: Bearer <opsk_ key | JWT>` **plus** `X-Namespace-Slug`/`-Id`.
For anything not listed, the deployment's own `GET /openapi.json` is authoritative.

## Platform

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/health` | none | 200 when the API is up |
| GET | `/ready`, `/live` | none | k8s probes |
| GET | `/openapi.json` | none | live spec for *this* deployment's `PROJECT_CODE` |
| GET | `/swagger` | none | human docs |

## Namespaces (workspaces)

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/api/v2/user/namespaces` | JWT | every workspace the user belongs to |
| GET | `/api/v2/user/namespaces/:id` | JWT | one (uuid or slug) |
| POST | `/api/v2/user/namespaces` | JWT | create; caller becomes owner (rate-limited) |
| POST | `/api/v2/user/namespaces/:id/switch` | JWT | set default/active (rate-limited) |
| GET | `/api/v2/namespace` | authed | the current namespace + your membership and permissions |

## CMS — public (no auth, namespace slug in the path)

| Method | Path | Returns |
|---|---|---|
| GET | `/api/v2/public/cms/:ns/posts?page&perPage` | published+public post summaries (no body) |
| GET | `/api/v2/public/cms/:ns/posts/:slug` | one post incl. `content_html`, SEO fields |
| GET | `/api/v2/public/cms/:ns/pages` | all published pages |
| GET | `/api/v2/public/cms/:ns/pages/:slug` | one page |
| GET | `/api/v2/public/cms/:ns/nav` | pages flagged for navigation |
| GET | `/api/v2/public/cms/:ns/categories` | categories |
| GET | `/api/v2/public/cms/:ns/tags` | tags |

## CMS — authoring (authed, RBAC module `cms`)

| Method | Path | Action |
|---|---|---|
| GET / POST | `/api/v2/cms/posts` | read / create |
| GET / PUT / DELETE | `/api/v2/cms/posts/:uuid` | read / update / delete |
| GET / POST | `/api/v2/cms/pages` | read / create |
| GET / PUT / DELETE | `/api/v2/cms/pages/:uuid` | read / update / delete |
| GET / POST | `/api/v2/cms/categories` | read / create |
| PUT / DELETE | `/api/v2/cms/categories/:uuid` | update / delete (no GET-by-uuid) |
| GET / POST | `/api/v2/cms/tags` | read / create |
| PUT / DELETE | `/api/v2/cms/tags/:uuid` | update / delete (no GET-by-uuid) |

## Webhooks — two different kinds

OpsAPI has **two** outgoing-webhook systems. They share the header names but **sign differently** — pick the
verifier that matches the one you registered.

### A. CMS "Website update" webhooks (manual)

| Method | Path | Action (`cms`) |
|---|---|---|
| GET / POST | `/api/v2/cms/webhooks` | read / create `{ url, name?, events?, secret?, active? }` |
| GET / PUT / DELETE | `/api/v2/cms/webhooks/:uuid` | read / update / delete |
| POST | `/api/v2/cms/webhooks/:uuid/trigger` | update — fire now `{ event?, uuid?, slug?, status? }` |

- Fired only when a person triggers it. Delivered once, synchronously, no retries.
- `secret` is generated (64 hex) unless you supply one, and is returned in the response.
- Headers: `Content-Type: application/json`, `User-Agent: opsapi-webhooks`, `X-Opsapi-Event`,
  `X-Opsapi-Signature-256: sha256=<hex>`.
- **Signature = HMAC-SHA256(secret, raw_body).**
- Body: `{ "event", "namespace_id", "data": { uuid, slug, status }, "timestamp": "YYYY-MM-DDTHH:MM:SSZ" }`.
- URL may be `http` or `https`, but must resolve to a **public** address (SSRF guard). A `localhost`/LAN
  receiver is refused unless the server sets `OPSAPI_WEBHOOKS_ALLOW_PRIVATE=true` (local dev only) — use a tunnel
  (ngrok, cloudflared) to test a local receiver against a shared environment.

### B. Workspace event webhooks (automatic, e.g. `invoice.updated`, `crm.lead.created`)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/v2/namespace/webhooks/events` | the subscribable event types |
| GET / POST | `/api/v2/namespace/webhooks` | list / create |
| GET / PUT / DELETE | `/api/v2/namespace/webhooks/:id` | |
| POST | `/api/v2/namespace/webhooks/:id/rotate-secret` | new secret |
| POST | `/api/v2/namespace/webhooks/:id/test` | send a test delivery |
| GET | `/api/v2/namespace/webhooks/:id/deliveries` | delivery log |
| POST | `/api/v2/namespace/webhooks/:id/deliveries/:delivery_id/redeliver` | retry one |

- Fired automatically from the event outbox, **retried with backoff** on non-2xx/timeout → receivers must be
  idempotent (dedupe on `X-Opsapi-Delivery` or the body's `id`).
- **https only**, public hosts only (same SSRF guard).
- Headers: `X-Opsapi-Event`, `X-Opsapi-Delivery`, `X-Opsapi-Timestamp`, `X-Opsapi-Signature-256`.
- **Signature = HMAC-SHA256(secret, timestamp + "." + raw_body)** where `timestamp` is the
  `X-Opsapi-Timestamp` header value. Check the timestamp is recent (≤ 5 min).
- Body: `{ "id", "type", "created_at", "namespace": { id, slug }, "data": { "object": {...}, "changes": {...} } }`.

Both verifiers are in [scripts/](scripts/): they pick scheme B when `X-Opsapi-Timestamp` is present, else A.

## API keys

| Method | Path | Who | Notes |
|---|---|---|---|
| POST | `/api/v2/me/api-keys` | any member | `{ name, scopes?, expires_in_days? }` → 201, `data.key` once |
| GET | `/api/v2/me/api-keys` | any member | own keys in this namespace (never the raw key) |
| DELETE | `/api/v2/me/api-keys/:uuid` | any member | revoke own key (404 for others') |
| POST | `/api/v2/api-keys` | owner / `namespace:manage` | `{ user_uuid?, name, scopes, expires_at? }` |
| GET | `/api/v2/api-keys` | owner / `namespace:manage` | all keys in the namespace |
| DELETE | `/api/v2/api-keys/:uuid` | owner / `namespace:manage` | revoke (idempotent) |

Create response: `{ success, data: { key, uuid, name, key_prefix, scopes, expires_at, created_at, user_uuid,
created_via }, meta: { note } }`. Self-service keys are capped per user and creation is rate-limited (429 with
`retry_after`).

## Secrets (platform admin only)

| Method | Path | Notes |
|---|---|---|
| GET / POST | `/api/v2/secrets` | list (values hidden) / create `{ name, description, secret }` |
| GET / PUT / DELETE | `/api/v2/secrets/:id` | metadata (masked) / update / delete |
| GET | `/api/v2/secrets/:id/show` | decrypted value |

## Errors

| Status | Meaning |
|---|---|
| 400 | missing/unknown `X-Namespace-*`, or bad input |
| 401 | no / invalid / expired credential |
| 403 | authed, but role or key scope lacks `module.action`, or not a member |
| 404 | record not in this namespace, **or** module not deployed for this `PROJECT_CODE` |
| 422 | validation failed (`{ error: "..." }`) |
| 429 | rate-limited (`retry_after` seconds) |
