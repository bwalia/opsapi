---
name: opsapi-integration
description: >-
  How to call the OpsAPI backend from any app or site — fetch blog posts and pages for a website, create and
  verify webhooks so a static site rebuilds when content changes, store and read secrets, mint and use API keys,
  and hit any REST module (CRM, invoices, shop, kanban, forms…). Use when building or wiring a frontend, static
  site, script, serverless function, or another service against OpsAPI (bwalia/opsapi, the Lua/Lapis "OLP"
  platform); when the task mentions OpsAPI, an opsapi:/opsk_ key, X-Namespace, a cms/blog webhook, or a
  "Website update" / X-Opsapi-Signature-256; or when fetching published CMS content from a workspace.
metadata:
  version: "1.0.0"
---

# Integrating with OpsAPI

OpsAPI is a multi-tenant REST backend. Everything below is one HTTP API; you talk to it the same way from a
Next.js route, a serverless function, a shell script, or another backend. This skill is the integration contract —
read it, then write the calls. For the fuller endpoint catalogue and copy-paste webhook verifiers, see
[reference.md](reference.md) and [scripts/](scripts/).

## Namespaces (multi-tenancy) — read this first

A **namespace** is a tenant: one workspace with its own data, members, roles and settings. It is THE core concept
in OpsAPI — nothing else makes sense without it. Think of the server as holding many independent workspaces side by
side; a namespace is which one you're acting in.

- **Every business record belongs to exactly one namespace** (each row carries a `namespace_id`). A CRM contact, a
  blog post, an order, an invoice — all live inside one namespace and are invisible to every other. This isolation
  is enforced server-side: you cannot read or change another namespace's data even with a valid credential, and
  trying returns 404/403, not someone else's row.
- **A namespace has two identifiers:** a human **`slug`** (e.g. `acme`) and a **`uuid`**. Use either — the slug is
  friendlier, the uuid is stable if a slug is ever changed.
- **A person can belong to several namespaces** (as owner, admin or member, each with its own role/permissions).
  One sign-in (one JWT) spans all of them; the request header chooses which one a call acts in.
- **An API key is bound to one namespace** (the one it was created in) — a key is a credential *for a specific
  workspace*, so a server integration usually holds one key per workspace it serves.

**Choosing the namespace on a request** — the server resolves it in this order:
1. **`X-Namespace-Slug: acme`** or **`X-Namespace-Id: <uuid>`** header (what you'll use from code — explicit, wins).
2. the JWT's own namespace claim (a token minted for one workspace).
3. the subdomain (e.g. `acme.example.com` → `acme`).

So: **send `X-Namespace-Slug`/`-Id` on every authed call.** Omit it and you get **400** ("provide
X-Namespace-Id or X-Namespace-Slug"). **Public endpoints don't take the header** — they name the namespace in the
path instead (`/api/v2/public/cms/<slug>/...`), because they expose only that workspace's published content.

**Discovering & managing namespaces** (authed, as a user):
```
GET  /api/v2/user/namespaces            # every workspace this user belongs to (uuid, slug, name, is_owner, roles, plan, status)
GET  /api/v2/user/namespaces/<id>       # one of them
POST /api/v2/user/namespaces/<id>/switch# make it the user's default/active one
POST /api/v2/user/namespaces            # create a new workspace (caller becomes owner)
GET  /api/v2/namespace                  # the CURRENT namespace (from your header) + your membership & permissions
```
```bash
# Which workspaces can I act in? Pick a slug, then use it as X-Namespace-Slug on real calls.
curl -s "$OPSAPI_URL/api/v2/user/namespaces" -H "Authorization: Bearer $OPSAPI_JWT"
# → { "data": [ { "uuid": "...", "slug": "acme", "name": "Acme Ltd", "is_owner": true, "roles": [...] }, ... ] }
```
An `opsk_` API key doesn't need to be discovered — it already belongs to its namespace; just send that
namespace's `X-Namespace-Slug`/`-Id` (the key is rejected for any other).

## 1. The three things every call needs

**Base URL.** Per environment, from config — never hard-code a guess. Common ones:
`http://127.0.0.1:4010` (local default), and the deployment's own host in dev/test/acc/prod. Read it from an env
var (e.g. `OPSAPI_URL` / `NEXT_PUBLIC_API_URL`). Health check: `GET /health` → `200`.

**Tenant (namespace).** The workspace this call acts in — see the section above. Authed calls set it with
`X-Namespace-Slug: acme` or `X-Namespace-Id: <uuid>`; public calls name it in the path. Missing it → **400**.

**Auth.** One of:
- **API key** (best for servers/scripts): `Authorization: Bearer opsk_<48 hex>`. The key is bound to the
  workspace it was made in and to scopes (`{module:[actions]}`); it can never do more than its creator's role.
- **JWT** (a signed-in user): `Authorization: Bearer <jwt>`, plus the `X-Namespace-*` header.
- **Nothing** — only the public endpoints in §2.

Status codes: **401** no/invalid auth · **403** authed but the role/scope lacks `module.action` · **404** the
module isn't deployed for this server's `PROJECT_CODE` (or the record isn't yours) · **400** missing/bad
`X-Namespace-*`.

**Response envelope.** The house shape is `{ "success": true, "data": …, "meta": … }`. Lists page with
`?page=1&perPage=20` and return `meta: { total, page, totalPages, perPage }`. Read `data`; don't assume the top
level is the array.

```bash
curl -s "$OPSAPI_URL/api/v2/crm/accounts?page=1&perPage=20" \
  -H "Authorization: Bearer $OPSAPI_KEY" -H "X-Namespace-Slug: acme"
# → { "success": true, "data": [ … ], "meta": { "total": 42, "page": 1, … } }
```

## 2. Public content (blogs & pages) — no auth

Build a public website against these. They expose only **published** content for one workspace, named by slug in
the path. No key, no namespace header.

```
GET /api/v2/public/cms/<slug>/posts?page=1&perPage=12   # blog list (summaries, no body)
GET /api/v2/public/cms/<slug>/posts/<post-slug>         # one post, with content_html
GET /api/v2/public/cms/<slug>/pages                     # published static pages
GET /api/v2/public/cms/<slug>/pages/<page-slug>         # one page
GET /api/v2/public/cms/<slug>/nav                       # pages flagged for site navigation
```

A list item: `{ uuid, title, slug, excerpt, featured_image_url, author_name, published_at, reading_minutes,
is_featured, category, categories[], tags[] }`. A single post adds `content_html, view_count, seo_title,
seo_description, seo_keywords`.

```js
// Next.js: a blog index and post page off OpsAPI (no auth).
const API = process.env.OPSAPI_URL, SLUG = process.env.OPSAPI_NAMESPACE;
export async function listPosts(page = 1) {
  const r = await fetch(`${API}/api/v2/public/cms/${SLUG}/posts?page=${page}&perPage=12`,
    { next: { revalidate: 300 } }); // ISR; or trigger a rebuild via a webhook (§4)
  const { data, meta } = await r.json();
  return { posts: data, meta };
}
export async function getPost(postSlug) {
  const r = await fetch(`${API}/api/v2/public/cms/${SLUG}/posts/${postSlug}`, { next: { revalidate: 300 } });
  if (!r.ok) return null;
  return (await r.json()).data; // has content_html
}
```

Other public reads (storefront): `GET /api/v2/stores`, `/api/v2/products`, `/api/v2/categories`,
`/api/v2/stores/<uuid>/products`, `/api/v2/products/<uuid>/variants`.

## 3. Authoring content (needs a key/JWT + the `cms` module)

```
GET/POST        /api/v2/cms/posts            # list (incl. drafts) / create
GET/PUT/DELETE  /api/v2/cms/posts/<uuid>
… same for /cms/pages, /cms/categories, /cms/tags
```

Create a post (owner/JWT or an `opsk_` key scoped `{"cms":["create"]}`):

```bash
curl -s -X POST "$OPSAPI_URL/api/v2/cms/posts" \
  -H "Authorization: Bearer $OPSAPI_KEY" -H "X-Namespace-Slug: acme" \
  -H "Content-Type: application/json" -d '{
    "title": "Hello world", "content_html": "<p>First post.</p>",
    "status": "published", "visibility": "public",
    "category_uuids": [], "tags": ["news"]
  }'
```

Rules: `title` required; `status` = draft|published|scheduled|archived (default draft — only published+public
shows on the public API); `tags` are names (created if new); `category_uuids` are existing category uuids; a
missing `slug` is derived from the title and made unique.

## 4. Webhooks — tell a site to refresh when content changes

OpsAPI fires a webhook **only when a person triggers it** (after publishing, or from the Content → Website updates
tab). You register a receiver URL; OpsAPI POSTs a **signed** JSON payload to it; your receiver checks the
signature and rebuilds.

**Register** (workspace admin / `cms` scope):
```
POST /api/v2/cms/webhooks   { "name": "Site rebuild", "url": "https://site.com/api/opsapi-update",
                              "events": ["post.created","post.updated","post.deleted"] }
```
The response includes a **`secret`** (shown so you can configure the receiver). Also: `GET /api/v2/cms/webhooks`,
`PUT/DELETE /api/v2/cms/webhooks/<uuid>`, and `POST /api/v2/cms/webhooks/<uuid>/trigger` to fire one now.

**What OpsAPI sends** your URL: a `POST` with
- `Content-Type: application/json`
- `X-Opsapi-Event: <event>`
- `X-Opsapi-Signature-256: sha256=<hex>` — HMAC-SHA256 of the **raw request body** with the webhook secret
- body: `{ "event": "...", "namespace_id": 12, "data": { "uuid", "slug", "status" }, "timestamp": "ISO-8601" }`

**Verify every request** (this is the receiver's whole security — a valid signature is the only proof it came
from OpsAPI). Reject a mismatch, and reject a `timestamp` older than ~5 minutes (replay). The secret lives on the
receiver as an env var, e.g. `OPSAPI_WEBHOOK_SECRET`. A deploy hook from Vercel/Netlify/Cloudflare Pages is a
secret URL on its own and ignores the signature — point the webhook straight at it and skip verification.

```js
// Next.js receiver: verify, then revalidate. Full versions in scripts/.
import crypto from 'crypto';
export async function POST(req) {
  const raw = await req.text();                       // the RAW body, before JSON.parse
  const expected = 'sha256=' + crypto.createHmac('sha256', process.env.OPSAPI_WEBHOOK_SECRET)
    .update(raw).digest('hex');
  const given = req.headers.get('x-opsapi-signature-256') ?? '';
  if (given.length !== expected.length ||
      !crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected)))
    return new Response('bad signature', { status: 401 });
  const { data, timestamp } = JSON.parse(raw);
  if (Math.abs(Date.now() - Date.parse(timestamp)) > 5 * 60_000)
    return new Response('too old', { status: 401 });   // replay
  // revalidatePath('/blog'); if (data?.slug) revalidatePath('/blog/' + data.slug);
  return Response.json({ ok: true });
}
```
Copy-paste verifiers for Node (Express), Python (Flask/FastAPI) and a Next.js route are in
[scripts/](scripts/) (`verify_webhook.js`, `verify_webhook.py`). Delivery status shows on the webhook; a failure
means the receiver returned non-2xx or was unreachable — the usual cause is the secret on the site not matching.

## 5. Secrets

A per-workspace encrypted key/value store, **platform-admin only** (an `administrative` role). Never hand a secret
to a non-admin flow.
```
GET/POST        /api/v2/secrets                 # list (values hidden) / create {name, description, secret}
GET             /api/v2/secrets/<uuid>          # metadata (value masked)
GET             /api/v2/secrets/<uuid>/show     # the decrypted value (admin only)
PUT/DELETE      /api/v2/secrets/<uuid>
```
Don't put a workspace's application secrets here expecting members to read them — it's admin-scoped.

## 6. API keys — the right credential for an integration

Prefer an API key over embedding a user's JWT. A key is bound to its workspace and scopes and is **never stronger
than the role that made it**, re-checked on every request.

- **Self-service** (any member, for themselves): `POST /api/v2/me/api-keys { name, scopes?, expires_in_days? }`.
  `GET /api/v2/me/api-keys`, `DELETE /api/v2/me/api-keys/<uuid>`.
- **On behalf of a user** (workspace owner, `namespace:manage`): `POST /api/v2/api-keys { user_uuid, name, scopes }`.

`scopes` is `{ module: [actions] }`, e.g. `{"cms":["read","create"],"crm_accounts":["read"]}` (actions:
`create|read|update|delete|manage`). The **raw key is returned once** (`opsk_…`) — store it in a secret manager,
never in the repo. Use it as `Authorization: Bearer opsk_…` with the right `X-Namespace-*` header.

```bash
# Mint a read-only CMS key for a build/ISR process, then use it.
KEY=$(curl -s -X POST "$OPSAPI_URL/api/v2/me/api-keys" \
  -H "Authorization: Bearer $OWNER_JWT" -H "X-Namespace-Slug: acme" \
  -H "Content-Type: application/json" -d '{"name":"site-build","scopes":{"cms":["read"]}}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["key"])')
curl -s "$OPSAPI_URL/api/v2/cms/posts?status=draft" -H "Authorization: Bearer $KEY" -H "X-Namespace-Slug: acme"
```

## 7. Any other module

Every module is the same shape: `GET/POST /api/v2/<module>`, `GET/PUT/DELETE /api/v2/<module>/<uuid>`, authed,
namespace-scoped, gated by the key/role's `module.action`. Examples: `crm/accounts`, `crm/contacts`, `invoices`,
`shop/orders`, `kanban/projects`, `employees`, `forms`. A module returns **404 for everyone** when the server's
`PROJECT_CODE` doesn't include its feature — that's deployment config, not permissions. The live catalogue for any
deployment is its OpenAPI spec: **`GET /openapi.json`** (and human docs at `/swagger`). When unsure of an exact
path or body, fetch `/openapi.json` and read it rather than guessing.

## Gotchas

- Read the base URL and namespace slug from config; don't hard-code.
- Send `X-Namespace-Slug`/`-Id` on every authed call, or get 400.
- Webhooks are **manual** (a person triggers them) — don't tell users content syncs "automatically".
- Verify webhook signatures over the **raw** body (before JSON parse); a reformatted body changes the hash.
- §4 covers **CMS** webhooks (`/api/v2/cms/webhooks`). Workspace event webhooks (`/api/v2/namespace/webhooks`,
  e.g. `invoice.updated`) are automatic, retried, https-only, and sign `X-Opsapi-Timestamp + "." + body` — see
  [reference.md](reference.md). The verifiers in `scripts/` handle both.
- Webhook URLs must resolve to a public host (SSRF guard); test a local receiver through a tunnel.
- The secret and the webhook URL should travel separately; treat the secret like a password.
- An `opsk_` key or a JWT in client-side code is a leak — keep both server-side.
