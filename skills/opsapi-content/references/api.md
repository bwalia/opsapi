# OpsAPI content API reference

The exact contract of the content (CMS) endpoints, as implemented in `lapis/routes/cms-*.lua` of
[bwalia/opsapi](https://github.com/bwalia/opsapi). For anything not listed here, the deployment's own spec is at
`GET <base-url>/openapi.json` (human version at `/swagger`).

Contents: [Conventions](#conventions) · [Public reads](#public-reads-no-auth) · [Posts](#posts) ·
[Pages](#pages) · [Categories and tags](#categories-and-tags) · [Images](#images) · [Webhooks](#webhooks) ·
[Keys](#keys) · [Errors](#errors)

## Conventions

- **Success:** `{ "success": true, "data": …, "meta": … }`. Only post lists carry
  `meta: { total, page, perPage, totalPages }`.
- **Failure:** `{ "success": false, "error": "…" }` from the content routes; auth and permission failures from the
  middleware are `{ "error": "…" }`, sometimes with extra fields (`required`).
- **Missing = empty.** Fields with no value are omitted from the JSON rather than sent as `null`.
- **Dates** are UTC without a zone marker: `"2026-10-26 15:45:14.248539"`. Parse as UTC
  (`new Date(s.replace(' ', 'T') + 'Z')`).
- **Bodies** (POST/PUT) may be JSON (`Content-Type: application/json`) or form-encoded. In JSON, lists are arrays;
  in a form, send a list as a JSON-array string (`["a","b"]`) or a comma-separated string. Booleans accept
  `true/false`, `1/0`, `yes/no`, `on`.
- **Authoring calls** need `Authorization: Bearer opsk_…` (or a signed-in user's JWT plus `X-Namespace-Slug` /
  `X-Namespace-Id`). The RBAC module is `cms`, with actions `read`, `create`, `update`, `delete`.
- **Deletes are soft** (the row is hidden, not erased) and need `cms:delete`.
- **Module presence:** content routes exist only when the deployment's `PROJECT_CODE` includes `cms` (the `cms`
  and `all` presets). Otherwise every content URL is 404 for everyone.

## Public reads (no auth)

`<ws>` is the workspace slug. Only `status = published` and (for posts) `visibility = public` are served.

| Endpoint | Parameters | `data` |
|---|---|---|
| `GET /api/v2/public/cms/<ws>/posts` | `page` (default 1), `perPage` (default 12, max 50), `category` (category **slug**), `tag` (tag **slug**), `search` (title or excerpt) | list of post summaries, newest `published_at` first |
| `GET /api/v2/public/cms/<ws>/posts/<slug>` | | one post (adds 1 to `view_count`) |
| `GET /api/v2/public/cms/<ws>/pages` | | `[{ uuid, title, slug, excerpt?, featured_image_url?, published_at, updated_at }]` in menu order |
| `GET /api/v2/public/cms/<ws>/pages/<slug>` | | one page |
| `GET /api/v2/public/cms/<ws>/nav` | | `[{ uuid, title, slug, menu_order, parent_id? }]`: published pages with `show_in_nav`, by `menu_order` then title |
| `GET /api/v2/public/cms/<ws>/categories` | | `[{ uuid, name, slug, description?, post_count }]` by position then name |
| `GET /api/v2/public/cms/<ws>/tags` | | `[{ uuid, name, slug, post_count }]` by name |

**Post summary** (list items): `uuid, title, slug, excerpt, featured_image_url, author_name, published_at,
reading_minutes, is_featured, category, categories[], tags[]`. `category` is the primary category
`{ uuid, name, slug }`; `categories[]` and `tags[]` are `{ uuid, name, slug }`.

**One post** adds: `content_html, view_count, seo_title, seo_description, seo_keywords`.

**One page:** `uuid, title, slug, excerpt, content_html, rendered_html, featured_image_url, template,
published_at, updated_at, seo_title, seo_description, seo_keywords`. `rendered_html` is the page placed in its
layout `template` (a render template slug); with the default template it equals `content_html`.

Unknown workspace → `404 Namespace not found`. Unpublished, private or unknown slug → `404 Post not found` /
`Page not found`.

Browsers on other origins are refused by CORS unless the deployment allows them (`CORS_ALLOWED_ORIGINS`,
`CORS_ALLOWED_DOMAINS`; localhost is always allowed). Fetch from server code.

## Posts

| Method and path | Action | Notes |
|---|---|---|
| `GET /api/v2/cms/posts` | read | `page`, `perPage` (default 20, max 100), `status`, `category` (category **uuid**), `tag` (tag **slug**), `search` (title or excerpt), `featured=true`. Drafts included. Newest first. |
| `POST /api/v2/cms/posts` | create | `201` with the full post |
| `GET /api/v2/cms/posts/<uuid>` | read | full post |
| `PUT /api/v2/cms/posts/<uuid>` | update | only the fields sent change |
| `DELETE /api/v2/cms/posts/<uuid>` | delete | `{ deleted: true }` |

**Post fields** (create and update):

| Field | Type | Meaning |
|---|---|---|
| `title` | string | required on create |
| `slug` | string | URL part; made from the title when empty; made unique in the workspace (`-2`, `-3`…) |
| `content_html` | string | the body; `reading_minutes` is computed from it (200 words a minute) |
| `excerpt` | string | summary for lists and previews |
| `status` | `draft` · `published` · `scheduled` · `archived` | default `draft`. The first change to `published` stamps `published_at` (kept afterwards). `scheduled` stores `scheduled_at` only: nothing publishes it automatically |
| `visibility` | `public` · `private` | default `public`; private posts never reach the public API |
| `is_featured` | boolean | featured flag |
| `category_uuids` | array of uuids | replaces the post's categories; unknown uuids are ignored; the first valid one becomes the primary `category`. `[]` clears |
| `category_uuid` | uuid | older single-category form, used only when `category_uuids` is absent |
| `tags` | array of names | replaces the post's tags; unknown names are created; trimmed, max 60 chars, case-insensitive duplicates dropped. `[]` clears |
| `featured_image_url` | string | cover image URL |
| `author_name` | string | shown author. When empty on create: the key owner's first + last name, else their username (which can be an email address) |
| `scheduled_at` | ISO date-time | with `status: scheduled` |
| `seo_title`, `seo_description`, `seo_keywords` | string | search-engine metadata |
| `content_json` | string | the dashboard editor's own document format; leave it alone |

Responses on the authoring side carry the full row plus `categories[]`, `tags[]`, `category`.

## Pages

| Method and path | Action | Notes |
|---|---|---|
| `GET /api/v2/cms/pages` | read | `status`, `search` (title). No paging. Ordered by `menu_order`, then title |
| `POST /api/v2/cms/pages` | create | `201` |
| `GET /api/v2/cms/pages/<uuid>` | read | |
| `PUT /api/v2/cms/pages/<uuid>` | update | only the fields sent change |
| `DELETE /api/v2/cms/pages/<uuid>` | delete | |

**Page fields:** `title` (required on create), `slug`, `content_html`, `excerpt`, `status` (`draft` · `published`
· `archived`; no `scheduled`), `show_in_nav` (boolean), `menu_order` (integer, lowest first), `parent_uuid` (a
parent page, for nested navigation), `template` (render template slug), `featured_image_url`, `seo_title`,
`seo_description`, `seo_keywords`.

## Categories and tags

| Method and path | Action | Body |
|---|---|---|
| `GET /api/v2/cms/categories` | read | `?search=` |
| `POST /api/v2/cms/categories` | create | `name` (required), `slug`, `description`, `parent_uuid`, `position` |
| `PUT /api/v2/cms/categories/<uuid>` | update | same fields |
| `DELETE /api/v2/cms/categories/<uuid>` | delete | |
| `GET /api/v2/cms/tags` | read | |
| `POST /api/v2/cms/tags` | create | `name` (required), `slug` |
| `PUT /api/v2/cms/tags/<uuid>` | update | `name`, `slug`; `409` if the slug is taken |
| `DELETE /api/v2/cms/tags/<uuid>` | delete | |

Each item: `{ uuid, name, slug, description?, post_count, … }`. A post names tags directly (created on demand);
categories must be created first and are referenced by uuid.

## Images

`POST /api/v2/cms/media` (needs `cms:update`), `multipart/form-data`:

| Part | Meaning |
|---|---|
| `file` (or `image`, `cover_image`) | the image: jpg, jpeg, png, webp, gif or svg; max 8 MB. The type comes from the file name's extension (or the part's `Content-Type`) |
| `slug` | optional: store as `img/blog/<slug>/<kind>.<ext>` (uploading the same slug and kind again replaces it) |
| `kind` | optional: `cover` (default) for a featured image, e.g. `inline-1` for an image inside the body |

`201` → `data: { url, key, bucket, size, content_type }`. `url` is public and can be used at once as
`featured_image_url` or in `<img src>`. Without `slug`, the file goes to `img/cms/<workspace>/<random>.<ext>`.

`GET /api/v2/cms/media/config` (`cms:read`) → `{ configured, base_url? }`. When `configured` is false, uploads
answer `503`: the deployment has no public image storage (`CMS_PUBLIC_S3_*`). Use an image URL hosted elsewhere.

```bash
curl -s -X POST "$OPSAPI_URL/api/v2/cms/media" -H "Authorization: Bearer $OPSAPI_KEY" \
  -F "file=@cover.jpg" -F "slug=spring-opening-hours"
```

## Webhooks

Webhooks tell a website that content changed. **They are sent only when someone triggers them** (the dashboard
asks after publishing; the MCP tool is `notify_website`). Content changes never send them automatically.

| Method and path | Action | Body |
|---|---|---|
| `GET /api/v2/cms/webhooks` | read | |
| `POST /api/v2/cms/webhooks` | create | `url` (required, must be a public address), `name`, `events` (`post.created`, `post.updated`, `post.deleted`; array or comma string), `secret` (generated when empty), `active` (default true) |
| `GET /api/v2/cms/webhooks/<uuid>` | read | |
| `PUT /api/v2/cms/webhooks/<uuid>` | update | same fields |
| `DELETE /api/v2/cms/webhooks/<uuid>` | delete | |
| `POST /api/v2/cms/webhooks/<uuid>/trigger` | update | optional `event` (default `post.published`), `uuid`, `slug`, `status` |

A webhook answers `{ uuid, name, url, secret, events, active, last_status, last_triggered_at, … }`. The `secret`
is returned so the receiver can be configured; keep it in the receiver's env (`OPSAPI_WEBHOOK_SECRET`).

`trigger` delivers synchronously: `200 { success: true, status: <receiver HTTP status> }`, or `502` with the
reason when the receiver failed or returned 4xx/5xx.

**What the website receives:** `POST <url>` with headers `Content-Type: application/json`,
`User-Agent: opsapi-webhooks`, `X-Opsapi-Event: <event>`,
`X-Opsapi-Signature-256: sha256=<hex HMAC-SHA256 of the raw body with the secret>`, and body:

```json
{ "event": "post.published", "namespace_id": 7,
  "data": { "uuid": "…", "slug": "spring-opening-hours", "status": "published" },
  "timestamp": "2026-10-26T15:45:14Z" }
```

`data` holds only what the trigger was given (it can be `{}`). The receiver must verify the signature over the
**raw** body before parsing it, and should reject a `timestamp` more than about 5 minutes old (replay). Ready
verifiers: [../scripts/verify_webhook.js](../scripts/verify_webhook.js),
[../scripts/verify_webhook.py](../scripts/verify_webhook.py). A Vercel/Netlify/Cloudflare deploy-hook URL can be
used as the webhook URL directly; it ignores the signature because its URL is itself the secret.

## Keys

Keys are created by signed-in people (a key can never create keys). The dashboard page is avatar menu →
**My API keys** (`/dashboard/settings/api-keys`); its **Website content** option makes a `cms` key.

| Endpoint | Who | Body |
|---|---|---|
| `POST /api/v2/me/api-keys` | any active member, for themselves | `name` (required), `scopes` (e.g. `{"cms":["read","create","update"]}`; must be within the person's own permissions), `expires_in_days` (1 to 365) |
| `GET /api/v2/me/api-keys`, `DELETE /api/v2/me/api-keys/<uuid>` | the same member | list, revoke |
| `POST /api/v2/api-keys` | workspace owner (`namespace:manage`) | `name`, `scopes`, `user_uuid` (to act as that member), `expires_at` |

The raw key is in the create response only (`data.key`). A personal key is checked on every request against the
person's current role, so it loses access when they lose it.

## Errors

| Status | Body | Cause |
|---|---|---|
| 400 | `title is required`, `name is required`, `Invalid status…`, `Invalid visibility…`, `url must not point to a private address` | bad input; nothing saved |
| 401 | `Missing Authorization header`, `Invalid API key`, `API key has been revoked`, `API key has expired` | credentials |
| 403 | `Permission denied` + `required: { module, action }` | the key or role lacks that action |
| 403 | `API key is not valid for the requested namespace` | `X-Namespace-*` names another workspace |
| 403 | `API key is not scoped for this endpoint` | the key's scopes don't cover that route (e.g. a `cms` key on a non-content route) |
| 404 | `Namespace not found` / `Post not found` / `Page not found` / `Webhook not found` | wrong slug or uuid, not published, or deleted |
| 404 | (any content URL, everyone) | the deployment has no content module |
| 409 | `A tag with this slug already exists` | |
| 502 | receiver error text | a webhook receiver failed |
| 503 | `Public CMS media is not configured…` | no public image storage on this deployment |
