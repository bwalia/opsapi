---
title: Content
pages: /dashboard/cms
api: /api/v2/cms/posts, /api/v2/cms/pages, /api/v2/cms/categories, /api/v2/cms/tags, /api/v2/render-templates
modules: cms
tools:
suggestions: Draft a blog post about our new service | List my unpublished posts | Create an About Us page
readonly: false
---
# Content
The workspace's website content: blog posts (with categories and tags) and static pages (About, Contact…). Only content with status published (and, for posts, visibility public) appears on the public site.

## Using the page
- Tabs: Blog Posts, Pages, Categories, Tags, Website updates.
- Blog Posts: search, status filter (Draft, Published, Scheduled, Archived), New Post, row Edit / Delete.
- Post editor (/dashboard/cms/posts/new or /dashboard/cms/posts/{uuid}): Title, Slug, Excerpt, Content (rich editor; images by URL, YouTube/Vimeo embeds, HTML source), SEO settings (SEO title, Meta description, Keywords); side cards Publish (Status, Publish date when Scheduled, Visibility, Featured post), Categories (checkboxes), Tags (type + Enter), Featured image (URL), Author (defaults to you). Buttons: Save draft, Save / Publish. After publishing, an "Update your website now?" dialog offers to update the connected websites (never automatic; "Not now" leaves them for later).
- Pages: search, New Page, row Edit / Delete. Page editor: Title, Slug, Excerpt, Content, SEO settings; Publish (Status, Show in site navigation, Menu order); Template (Default (raw content) or a page layout); Featured image.
- Categories: New Category (Name, Description). Tags: type a name in "Add a tag…" and click +. Both have Delete.
- Website updates tab (developers call these webhooks): connects a website so it refreshes when content changes here. Nothing is sent automatically: the user presses "Update website now" on a website's card, or "Update website" after publishing.
  - Setup, in plain words: (1) get the website's update address from the developer, or the "Deploy Hook" URL from the host (Vercel, Netlify, Cloudflare Pages); (2) "Add website" (Name, Update address, On); (3) the setup guide shows a secret key: the developer saves it on the website as OPSAPI_WEBHOOK_SECRET so the website can check the update came from OpsAPI (a host's Deploy Hook doesn't need it); "Copy a message for your developer" copies everything but the key, which should be sent separately; (4) "Send a test update".
  - Reopen it any time with "Setup guide & secret key" on the card. The card shows whether the last update worked and, if not, why: HTTP 401/403 = the website's saved key doesn't match; 404 = wrong address; 5xx = an error on the website; "couldn't reach" = address wrong or site offline.
  - For developers: a POST with JSON {event, namespace_id, data: {uuid, slug, status}, timestamp} and header X-Opsapi-Signature-256 = "sha256=" + HMAC-SHA256 (hex) of the raw body with the key; the guide has Next.js, Express and Flask code.
  - Never ask for or repeat a secret key in chat; point to the setup guide.
- Page layouts are managed in Templates → Layouts & Formats (/dashboard/templates?tab=layouts).

## Rules
- Post: title required; status draft|published|scheduled|archived (default draft); visibility public|private (default public). Scheduled only stores scheduled_at — it is NOT auto-published; set status published to go live. published_at is stamped the first time it is published.
- category_uuids = uuids of EXISTING categories (replaces the set). tags = tag NAMES (replaces the set; unknown names are created).
- Slugs come from the title when omitted and are made unique (-2, -3…).
- Page: title required; status draft|published|archived; template = a cms_page layout slug or "default"; show_in_nav + menu_order (int) drive the public navigation; parent_uuid nests it under another page.
- Category / tag: name required; a tag slug already in use → 409.
- Deletes are soft. No file upload: images are URLs.

## API
- `GET /api/v2/cms/posts?page&perPage&status&category={category uuid}&tag={tag slug}&search&featured=true` — list posts
- `GET /api/v2/cms/posts/{uuid}` — one post
- `POST /api/v2/cms/posts {title*, slug, excerpt, content_html, status, visibility, is_featured: bool, category_uuids: [uuid], tags: [name], featured_image_url, author_name, scheduled_at: ISO datetime, seo_title, seo_description, seo_keywords}` — create
- `PUT /api/v2/cms/posts/{uuid} {any create field}` — update (e.g. {status: "published"} to publish)
- `DELETE /api/v2/cms/posts/{uuid}`
- `GET /api/v2/cms/pages?status&search` — list pages
- `GET /api/v2/cms/pages/{uuid}`
- `POST /api/v2/cms/pages {title*, slug, excerpt, content_html, status, template, show_in_nav: bool, menu_order: int, parent_uuid, featured_image_url, seo_title, seo_description, seo_keywords}` — create
- `PUT /api/v2/cms/pages/{uuid} {any create field}` — update
- `DELETE /api/v2/cms/pages/{uuid}`
- `GET /api/v2/cms/categories?search` · `POST /api/v2/cms/categories {name*, slug, description, parent_uuid, position: int}`
- `PUT /api/v2/cms/categories/{uuid} {name, slug, description, parent_uuid, position}` · `DELETE /api/v2/cms/categories/{uuid}`
- `GET /api/v2/cms/tags?search` · `POST /api/v2/cms/tags {name*, slug}`
- `PUT /api/v2/cms/tags/{uuid} {name, slug}` · `DELETE /api/v2/cms/tags/{uuid}`
- `GET /api/v2/render-templates?type=cms_page` — page layouts (use the `slug` as a page's template)
