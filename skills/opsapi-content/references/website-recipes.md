# Website recipes: OpsAPI content on a site

Working starting points for the common stacks. All of them read the public API from **server code** (build,
server components, SSR), because OpsAPI only answers browsers on origins its operator allowed. Configuration in
every recipe:

```bash
OPSAPI_URL=https://int-opsapi.workstation.co.uk   # the OpsAPI base URL
OPSAPI_WORKSPACE=acme                              # the workspace slug
OPSAPI_WEBHOOK_SECRET=…                            # only if the site receives website webhooks
```

Contents: [Next.js (App Router)](#nextjs-app-router) · [Astro](#astro) · [Any stack: build-time
fetch](#any-stack-build-time-fetch) · [Python](#python) · [Checklist](#checklist)

## Next.js (App Router)

Works with Next.js 15 and 16 (where `params` is a Promise). Pages are static and refreshed every 5 minutes, or at
once when OpsAPI's website webhook calls `/api/opsapi-update`.

### `lib/opsapi.ts`

```ts
const BASE = `${process.env.OPSAPI_URL}/api/v2/public/cms/${process.env.OPSAPI_WORKSPACE}`;
const REVALIDATE = 300; // seconds; the webhook route below makes changes show at once

export type Term = { uuid: string; name: string; slug: string };
export type PostSummary = {
  uuid: string; title: string; slug: string; excerpt?: string; featured_image_url?: string;
  author_name?: string; published_at?: string; reading_minutes?: number; is_featured?: boolean;
  category?: Term; categories: Term[]; tags: Term[];
};
export type Post = PostSummary & {
  content_html?: string; view_count?: number; seo_title?: string; seo_description?: string; seo_keywords?: string;
};
export type PageSummary = { uuid: string; title: string; slug: string; excerpt?: string; published_at?: string; updated_at?: string };
export type Page = PageSummary & {
  content_html?: string; rendered_html?: string; template?: string; featured_image_url?: string;
  seo_title?: string; seo_description?: string; seo_keywords?: string;
};
export type NavItem = { uuid: string; title: string; slug: string; menu_order: number; parent_id?: number };
export type ListMeta = { total: number; page: number; perPage: number; totalPages: number };

async function get<T>(path: string): Promise<{ data: T; meta?: ListMeta } | null> {
  const res = await fetch(BASE + path, { next: { revalidate: REVALIDATE, tags: ["opsapi"] } });
  if (res.status === 404) return null; // unpublished or unknown
  if (!res.ok) throw new Error(`OpsAPI ${res.status} on ${path}`);
  return res.json();
}

/** OpsAPI dates are UTC without a zone ("2026-10-26 15:45:14.248539"). */
export const toDate = (s?: string) => (s ? new Date(s.replace(" ", "T").replace(/(\.\d{3})\d+/, "$1") + "Z") : undefined);

export async function listPosts(page = 1, filter: { category?: string; tag?: string; search?: string } = {}) {
  const qs = new URLSearchParams({ page: String(page), perPage: "12" });
  for (const [k, v] of Object.entries(filter)) if (v) qs.set(k, v); // category/tag are slugs
  const r = await get<PostSummary[]>(`/posts?${qs}`);
  return { posts: r?.data ?? [], meta: r?.meta ?? { total: 0, page, perPage: 12, totalPages: 0 } };
}

export async function allPostSlugs() {
  const slugs: string[] = [];
  for (let page = 1; ; page++) {
    const r = await get<PostSummary[]>(`/posts?page=${page}&perPage=50`);
    slugs.push(...(r?.data ?? []).map((p) => p.slug));
    if (!r?.meta || page >= r.meta.totalPages) return slugs;
  }
}

export const getPost = async (slug: string) => (await get<Post>(`/posts/${encodeURIComponent(slug)}`))?.data ?? null;
export const listPages = async () => (await get<PageSummary[]>("/pages"))?.data ?? [];
export const getPage = async (slug: string) => (await get<Page>(`/pages/${encodeURIComponent(slug)}`))?.data ?? null;
export const getNav = async () => (await get<NavItem[]>("/nav"))?.data ?? [];
export const listCategories = async () => (await get<(Term & { post_count: number })[]>("/categories"))?.data ?? [];
```

### `app/blog/page.tsx`: the index, with paging and a category filter

```tsx
import Link from "next/link";
import { listPosts, toDate } from "@/lib/opsapi";

export default async function Blog({ searchParams }: { searchParams: Promise<{ page?: string; category?: string }> }) {
  const sp = await searchParams;
  const page = Math.max(1, Number(sp.page) || 1);
  const { posts, meta } = await listPosts(page, { category: sp.category });
  return (
    <main>
      <h1>Blog</h1>
      {posts.length === 0 && <p>No posts yet.</p>}
      {posts.map((p) => (
        <article key={p.uuid}>
          {p.featured_image_url && <img src={p.featured_image_url} alt="" />}
          <h2><Link href={`/blog/${p.slug}`}>{p.title}</Link></h2>
          <p>{toDate(p.published_at)?.toLocaleDateString()} · {p.reading_minutes ?? 1} min read</p>
          {p.excerpt && <p>{p.excerpt}</p>}
        </article>
      ))}
      <nav>
        {page > 1 && <Link href={`/blog?page=${page - 1}`}>Newer</Link>}
        {page < meta.totalPages && <Link href={`/blog?page=${page + 1}`}>Older</Link>}
      </nav>
    </main>
  );
}
```

### `app/blog/[slug]/page.tsx`: one post with SEO metadata

```tsx
import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { allPostSlugs, getPost, toDate } from "@/lib/opsapi";

type Props = { params: Promise<{ slug: string }> };

export async function generateStaticParams() {
  return (await allPostSlugs()).map((slug) => ({ slug }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const post = await getPost((await params).slug);
  if (!post) return {};
  return {
    title: post.seo_title || post.title,
    description: post.seo_description || post.excerpt,
    keywords: post.seo_keywords,
    openGraph: { images: post.featured_image_url ? [post.featured_image_url] : [] },
  };
}

export default async function PostPage({ params }: Props) {
  const post = await getPost((await params).slug);
  if (!post) notFound();
  return (
    <article>
      <h1>{post.title}</h1>
      <p>
        {post.author_name && <>{post.author_name} · </>}
        {toDate(post.published_at)?.toLocaleDateString()}
        {post.tags.map((t) => <span key={t.uuid}> #{t.name}</span>)}
      </p>
      {post.featured_image_url && <img src={post.featured_image_url} alt="" />}
      {/* Editors write this HTML. Sanitise first (e.g. sanitize-html) if they aren't fully trusted. */}
      <div dangerouslySetInnerHTML={{ __html: post.content_html ?? "" }} />
    </article>
  );
}
```

### `app/[slug]/page.tsx`: static pages (About, Contact…)

```tsx
import { notFound } from "next/navigation";
import { getPage, listPages } from "@/lib/opsapi";

type Props = { params: Promise<{ slug: string }> };

export async function generateStaticParams() {
  return (await listPages()).map((p) => ({ slug: p.slug }));
}

export async function generateMetadata({ params }: Props) {
  const page = await getPage((await params).slug);
  return page ? { title: page.seo_title || page.title, description: page.seo_description || page.excerpt } : {};
}

export default async function CmsPage({ params }: Props) {
  const page = await getPage((await params).slug);
  if (!page) notFound();
  return (
    <main>
      <h1>{page.title}</h1>
      <div dangerouslySetInnerHTML={{ __html: page.rendered_html ?? page.content_html ?? "" }} />
    </main>
  );
}
```

A site that already has routes like `/blog` should make sure a page slug can't shadow them (e.g. put CMS pages
under `/p/[slug]`, or skip reserved slugs in `generateStaticParams`).

### Navigation (in `app/layout.tsx` or a header component)

```tsx
import Link from "next/link";
import { getNav } from "@/lib/opsapi";

export async function SiteNav() {
  const items = (await getNav()).filter((i) => !i.parent_id); // top level; children carry parent_id
  return (
    <nav>
      <Link href="/blog">Blog</Link>
      {items.map((i) => <Link key={i.uuid} href={`/${i.slug}`}>{i.title}</Link>)}
    </nav>
  );
}
```

### `app/sitemap.ts`

```ts
import type { MetadataRoute } from "next";
import { allPostSlugs, listPages } from "@/lib/opsapi";

const SITE = process.env.SITE_URL ?? "https://www.example.com";

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const [slugs, pages] = await Promise.all([allPostSlugs(), listPages()]);
  return [
    { url: `${SITE}/blog` },
    ...slugs.map((s) => ({ url: `${SITE}/blog/${s}` })),
    ...pages.map((p) => ({ url: `${SITE}/${p.slug}` })),
  ];
}
```

### `app/api/opsapi-update/route.ts`: refresh at once when OpsAPI says so

Register `https://<site>/api/opsapi-update` as a website webhook in OpsAPI (dashboard → Content → Website
updates, or `POST /api/v2/cms/webhooks`), and put its secret in `OPSAPI_WEBHOOK_SECRET`.

```ts
import crypto from "node:crypto";
import { revalidateTag } from "next/cache";

export async function POST(req: Request) {
  const raw = await req.text(); // the RAW body: the signature covers these exact bytes
  const expected = "sha256=" + crypto.createHmac("sha256", process.env.OPSAPI_WEBHOOK_SECRET!).update(raw).digest("hex");
  const given = req.headers.get("x-opsapi-signature-256") ?? "";
  if (given.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))) {
    return new Response("bad signature", { status: 401 });
  }
  const { timestamp } = JSON.parse(raw);
  if (Math.abs(Date.now() - Date.parse(timestamp)) > 5 * 60_000) return new Response("too old", { status: 401 });
  // Every OpsAPI fetch above carries this tag. { expire: 0 } = expire now (Next.js 16, the form its docs give for
  // webhooks); on Next.js 15 the call is revalidateTag("opsapi").
  revalidateTag("opsapi", { expire: 0 });
  return Response.json({ ok: true });
}
```

On a fully static export (`output: "export"`) there's no server to revalidate: point the webhook at the host's
deploy hook (Vercel, Netlify, Cloudflare Pages) so publishing triggers a rebuild.

## Astro

```astro
---
// src/pages/blog/[slug].astro (static build; rebuild via a deploy-hook webhook)
const BASE = `${import.meta.env.OPSAPI_URL}/api/v2/public/cms/${import.meta.env.OPSAPI_WORKSPACE}`;

export async function getStaticPaths() {
  const BASE = `${import.meta.env.OPSAPI_URL}/api/v2/public/cms/${import.meta.env.OPSAPI_WORKSPACE}`;
  const paths = [];
  for (let page = 1; ; page++) {
    const { data, meta } = await (await fetch(`${BASE}/posts?page=${page}&perPage=50`)).json();
    paths.push(...data.map((p) => ({ params: { slug: p.slug } })));
    if (page >= meta.totalPages) break;
  }
  return paths;
}

const res = await fetch(`${BASE}/posts/${Astro.params.slug}`);
if (!res.ok) return Astro.redirect("/404");
const { data: post } = await res.json();
---
<article>
  <h1>{post.title}</h1>
  {post.featured_image_url && <img src={post.featured_image_url} alt="" />}
  <Fragment set:html={post.content_html ?? ""} />
</article>
```

`getStaticPaths` runs in its own scope in Astro, which is why `BASE` is declared inside it too.

## Any stack: build-time fetch

For Hugo, Eleventy, Jekyll, a plain HTML site or anything else, pull the content into files before the build and
let the generator render them. Run with Node 18+: `node fetch-opsapi.mjs`.

```js
// fetch-opsapi.mjs: writes content/posts/<slug>.json, content/pages/<slug>.json, content/nav.json
import { mkdir, writeFile } from "node:fs/promises";

const BASE = `${process.env.OPSAPI_URL}/api/v2/public/cms/${process.env.OPSAPI_WORKSPACE}`;
const get = async (path) => {
  const res = await fetch(BASE + path);
  if (!res.ok) throw new Error(`OpsAPI ${res.status} on ${path}`);
  return (await res.json());
};

await mkdir("content/posts", { recursive: true });
await mkdir("content/pages", { recursive: true });
for (let page = 1; ; page++) {
  const { data, meta } = await get(`/posts?page=${page}&perPage=50`);
  for (const p of data) await writeFile(`content/posts/${p.slug}.json`, JSON.stringify((await get(`/posts/${p.slug}`)).data, null, 2));
  if (page >= meta.totalPages) break;
}
for (const p of (await get("/pages")).data) {
  await writeFile(`content/pages/${p.slug}.json`, JSON.stringify((await get(`/pages/${p.slug}`)).data, null, 2));
}
await writeFile("content/nav.json", JSON.stringify((await get("/nav")).data, null, 2));
console.log("OpsAPI content written to content/");
```

Each full fetch adds a view to each post's `view_count`; that's expected for builds.

## Python

```python
# opsapi_content.py: server-side reads for Django, Flask, FastAPI or a static generator
import os
from datetime import datetime, timezone

import requests

BASE = f"{os.environ['OPSAPI_URL']}/api/v2/public/cms/{os.environ['OPSAPI_WORKSPACE']}"


def _get(path, **params):
    r = requests.get(BASE + path, params=params, timeout=10)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.json()


def list_posts(page=1, per_page=12, category=None, tag=None, search=None):
    body = _get("/posts", page=page, perPage=per_page, category=category, tag=tag, search=search)
    return body["data"], body["meta"]


def get_post(slug):
    body = _get(f"/posts/{slug}")
    return body and body["data"]


def to_datetime(s):
    """OpsAPI dates are UTC without a zone: '2026-10-26 15:45:14.248539'."""
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc) if s else None
```

In Django templates render the body with `{{ post.content_html|safe }}`, in Jinja with `{{ post.content_html | safe }}`
(sanitise first with `bleach`/`nh3` if editors aren't fully trusted). Requests with `None` values drop those
parameters, so the optional filters can be passed straight through.

## Checklist

- Base URL and workspace slug come from config, not the code.
- Every optional field has a fallback (missing keys, not nulls).
- Dates parsed as UTC.
- `content_html` rendered as HTML, sanitised when editors aren't trusted; pages use `rendered_html` first.
- Lists page through `meta.totalPages`.
- 404 from OpsAPI becomes the site's 404 page.
- Freshness decided: a revalidate timer, a webhook receiver that verifies the signature, or a deploy hook.
- No `opsk_` key anywhere in the site: reading published content needs none.
