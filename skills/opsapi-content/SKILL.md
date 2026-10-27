---
name: opsapi-content
description: >-
  Use OpsAPI as a headless CMS: show a workspace's blog posts and pages on any website (Next.js, Astro, React,
  Vue, Python, a static build…) through the public content API, and write, edit, publish or unpublish posts,
  pages, categories, tags and images in a chosen OpsAPI workspace (namespace) through the OpsAPI MCP tools or the
  REST API with an opsk_ key. Use this skill whenever the task involves OpsAPI content or CMS, a blog or website
  fed by OpsAPI, /api/v2/public/cms or /api/v2/cms, an opsk_ key, an OpsAPI workspace or namespace slug, the
  "Website update" webhook or X-Opsapi-Signature-256, or MCP tools such as create_post, update_post, list_posts,
  create_page, upload_image or notify_website, even if the user only says "add a blog to my site from OpsAPI" or
  "publish this article in our workspace".
---

# OpsAPI website content

OpsAPI is a multi-tenant backend. Each **workspace** (also called a **namespace**) has its own website content:
blog **posts**, static **pages** (About, Contact…), **categories**, **tags** and **images**. There are two jobs,
and they use different doors:

| Job | Door | Credentials |
|---|---|---|
| **Show** published content on a website | public REST API `/api/v2/public/cms/<workspace-slug>/…` | none |
| **Write** content (create, edit, publish, unpublish) | MCP tools (best for an AI agent) or REST `/api/v2/cms/…` | an `opsk_` key with `cms` access |

Exact fields, parameters and errors for every endpoint are in [references/api.md](references/api.md). Complete
website code (Next.js, Astro, plain build script, Python) is in
[references/website-recipes.md](references/website-recipes.md). Read the one you need.

## First, get three facts (ask; never guess them)

1. **API base URL**, e.g. `https://int-opsapi.workstation.co.uk` (local dev is usually `http://127.0.0.1:4010`).
   `GET <url>/health` answers 200. Keep it in config (`OPSAPI_URL`).
2. **Workspace slug**, e.g. `acme`. Public URLs carry it in the path. A signed-in user sees their workspaces with
   `GET /api/v2/user/namespaces`; otherwise ask whoever runs the workspace. Keep it in config (`OPSAPI_WORKSPACE`).
3. **For writing only: a key.** In the OpsAPI dashboard: avatar menu → **My API keys** → **Create key** → choose
   **Website content** (gives `{"cms":["read","create","update"]}`, never more than the person's own role). The key
   (`opsk_` + 48 hex) is shown once. Treat it like a password: an env var or secret store, never the repo, never
   browser code, never pasted back into chat output.

A key belongs to exactly one workspace, so it needs no workspace header. If you do send `X-Namespace-Slug` or
`X-Namespace-Id`, it must be that same workspace or the call gets 403.

## Job 1: show content on a website

```
GET /api/v2/public/cms/<ws>/posts?page=1&perPage=12[&category=<cat-slug>][&tag=<tag-slug>][&search=text]
GET /api/v2/public/cms/<ws>/posts/<post-slug>      one post with content_html and SEO fields
GET /api/v2/public/cms/<ws>/pages                  published pages (no body)
GET /api/v2/public/cms/<ws>/pages/<page-slug>      one page with content_html and rendered_html
GET /api/v2/public/cms/<ws>/nav                    pages marked "show in navigation", in menu order
GET /api/v2/public/cms/<ws>/categories             with post_count
GET /api/v2/public/cms/<ws>/tags                   with post_count
```

Every answer is `{ "success": true, "data": …, "meta": { total, page, perPage, totalPages } }` (meta on the post
list only). Read `data`. Only items that are **published and public** ever appear here; a draft is a 404.

What trips people up, and why:

- **Fetch on the server, not in the browser.** OpsAPI answers cross-origin browser requests only from origins its
  operator allowed (`CORS_ALLOWED_ORIGINS` / `CORS_ALLOWED_DOMAINS`; localhost is always allowed, so it "works on
  my machine" and then breaks in production). Fetch at build time, in server components, SSR or an API route. If
  the site truly must call from the browser, the OpsAPI operator has to add the site's origin.
- **Empty fields are left out, not `null`.** A post without an image has no `featured_image_url` key at all. Code
  every optional field defensively (`post.featured_image_url ?? fallback`).
- **Dates are UTC without a zone marker**: `"2026-10-26 15:45:14.248539"`. Parse with
  `new Date(s.replace(' ', 'T') + 'Z')`, or they shift by the reader's offset.
- **Bodies are HTML.** Render `content_html` as HTML (`dangerouslySetInnerHTML`, `set:html`, `|safe`). Workspace
  editors write it; if those editors are not fully trusted, sanitise it (e.g. `sanitize-html`) before rendering.
  For pages, prefer `rendered_html` (the page placed in its chosen layout template) and fall back to `content_html`.
- **The title is the page's `<h1>`.** Bodies start at `<h2>`; use `seo_title`/`seo_description` for metadata,
  falling back to `title`/`excerpt`.
- **Opening a single post counts a view** (`view_count`). Fine for builds and ISR; don't poll it.
- **Page sizes:** public post lists allow `perPage` up to 50 (default 12). Loop over `meta.totalPages` to get all
  of them, e.g. for `generateStaticParams` or a sitemap.
- **Freshness:** OpsAPI never pushes changes by itself. Either revalidate on a timer (e.g. every 5 minutes), or
  add a **website webhook** that someone (or the agent, via `notify_website`) fires after publishing. The receiver
  must check the `X-Opsapi-Signature-256` signature over the raw body; copy the verifier from
  [scripts/verify_webhook.js](scripts/verify_webhook.js) or [scripts/verify_webhook.py](scripts/verify_webhook.py).

The smallest working fetch (Next.js server code; any `fetch` looks the same):

```ts
const base = `${process.env.OPSAPI_URL}/api/v2/public/cms/${process.env.OPSAPI_WORKSPACE}`;
export async function getPost(slug: string) {
  const res = await fetch(`${base}/posts/${encodeURIComponent(slug)}`, { next: { revalidate: 300 } });
  if (res.status === 404) return null;           // not published, or wrong slug
  if (!res.ok) throw new Error(`OpsAPI ${res.status}`);
  return (await res.json()).data;                // { title, content_html, published_at, tags, … }
}
```

For a whole site (blog index with paging, post page with metadata, static pages, navigation, categories,
sitemap, webhook route) use [references/website-recipes.md](references/website-recipes.md) rather than inventing
one.

## Job 2: write and publish content

### With the MCP tools (preferred when you are the agent)

If tools like `create_post` are available, use them: they resolve category names, validate ids and explain errors.
If not, the user can add the OpsAPI MCP server (it lives in `mcp/` of
[bwalia/opsapi](https://github.com/bwalia/opsapi); one server covers kanban and content):

```bash
git clone https://github.com/bwalia/opsapi && cd opsapi/mcp && npm ci && npm run build
claude mcp add opsapi -s user -e OPSAPI_URL=https://int-opsapi.workstation.co.uk \
  -e OPSAPI_API_KEY=opsk_their_key -- node "$PWD/dist/index.js"
# or, where a shared MCP service runs:
claude mcp add --transport http opsapi https://<mcp-host>/mcp --header "Authorization: Bearer opsk_their_key"
```

The tools appear in the **next** Claude Code session. The user should run the command themselves, since it
contains their key.

| tool | use it to |
|---|---|
| `list_posts`, `get_post` | find posts (drafts too; filter by status, category, tag, text) and read one in full |
| `create_post`, `update_post` | write a post; publish with `status: "published"`, unpublish with `"draft"` or `"archived"` |
| `list_pages`, `get_page`, `create_page`, `update_page` | the same for static pages (`show_in_nav`, `menu_order`) |
| `list_categories_and_tags`, `create_category` | see what exists; make a category (tags are created on the fly) |
| `upload_image` | put an image on the public website storage and get its URL |
| `notify_website` | fire the workspace's website webhooks so the site rebuilds |

There is deliberately no delete tool. To take something down, unpublish it.

### With the REST API (scripts, CI, other backends)

```bash
curl -s -X POST "$OPSAPI_URL/api/v2/cms/posts" \
  -H "Authorization: Bearer $OPSAPI_KEY" -H "Content-Type: application/json" \
  -d '{"title":"Spring opening hours","content_html":"<p>From 1 April we open at 8am.</p>",
       "excerpt":"New opening hours from April.","tags":["news"],"author_name":"The Acme team"}'
# → 201 {"success":true,"data":{"uuid":"…","slug":"spring-opening-hours","status":"draft",…}}

curl -s -X PUT "$OPSAPI_URL/api/v2/cms/posts/<uuid>" \
  -H "Authorization: Bearer $OPSAPI_KEY" -H "Content-Type: application/json" -d '{"status":"published"}'
```

`PUT` changes only the fields you send. Pages are the same under `/api/v2/cms/pages`. All fields, filters,
category/tag endpoints, image upload and webhooks: [references/api.md](references/api.md).

### Writing a good post: the workflow

1. **Look before you write.** List categories and tags and reuse them: categories must already exist (a post
   naming an unknown one is refused), and reusing tag spellings keeps tag pages tidy. Check `list_posts` for a post
   on the same topic so you update it rather than create a duplicate.
2. **Draft first.** Create with the default `draft` status unless the user clearly asked to publish now. Share the
   dashboard link the tool returns so they can review it.
3. **Write clean HTML.** `<h2>`/`<h3>` sections, `<p>`, lists, `<a href>`, `<img src alt>`, `<blockquote>`. No
   `<h1>` (the site prints the title), no inline styles, no scripts. Images: `upload_image`, then use the URL as
   `featured_image_url` or an `<img src>`.
4. **Fill the parts sites and search engines show:** `excerpt` (one or two sentences), `seo_description` (about
   155 characters), and `author_name`. Set `author_name` on purpose: left empty, OpsAPI fills in the key owner's
   name, or their login (sometimes an email address), and that appears on the public site.
5. **Publish when asked**: `status: "published"`. The first publish stamps `published_at`. `scheduled` only
   records `scheduled_at`; nothing publishes it later, so say so if the user expects a timed release.
6. **Tell the website.** Webhooks never fire on their own. After publishing, changing or unpublishing something
   the site shows, call `notify_website` (or `POST /api/v2/cms/webhooks/<uuid>/trigger`), unless the site
   revalidates on a timer anyway.
7. **Don't rename the slug of a published post**: existing links and search results break.

## When something fails

| You see | It means | Do this |
|---|---|---|
| 401 `Missing Authorization header` / `Invalid API key` / `has expired` | no key, wrong key, revoked or expired | ask for a fresh **Website content** key |
| 403 `Permission denied`, `required: {module: cms, action: …}` | the key (or the person's role) lacks that action, e.g. `delete` | use an allowed action (unpublish instead of delete) or ask an owner |
| 403 `API key is not valid for the requested namespace` | a workspace header names another workspace | drop the header; the key already knows its workspace |
| 404 on every `/api/v2/cms/…` call, for everyone | this OpsAPI deployment has no content module | ask the operator; content needs `PROJECT_CODE` `cms` or `all` |
| 404 `Namespace not found` on a public URL | wrong workspace slug | check the slug |
| 404 `Post not found` on a public URL | not published, private, or wrong slug | publish it (`status`), check `visibility: public` |
| 400 `No category matches…` / `title is required` | invalid input; nothing was saved | fix the input; the message names what exists |
| 503 on image upload | the server has no public image storage set up | use an image URL hosted elsewhere, or ask the operator |
| 502 on a webhook trigger | the website's receiver failed or returned an error | check the receiver; a wrong secret is the usual cause |
