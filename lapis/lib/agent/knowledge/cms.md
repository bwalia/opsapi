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
- Tabs: Blog Posts, Pages, Categories, Tags, Webhooks.
- Blog Posts: search, status filter (Draft, Published, Scheduled, Archived), New Post, row Edit / Delete.
- Post editor (/dashboard/cms/posts/new or /dashboard/cms/posts/{uuid}): Title, Slug, Excerpt, Content (rich editor; images by URL, YouTube/Vimeo embeds, HTML source), SEO settings (SEO title, Meta description, Keywords); side cards Publish (Status, Publish date when Scheduled, Visibility, Featured post), Categories (checkboxes), Tags (type + Enter), Featured image (URL), Author (defaults to you). Buttons: Save draft, Save / Publish. After publishing, a "Notify webhooks?" dialog lets you trigger webhooks (never automatic).
- Pages: search, New Page, row Edit / Delete. Page editor: Title, Slug, Excerpt, Content, SEO settings; Publish (Status, Show in site navigation, Menu order); Template (Default (raw content) or a page layout); Featured image.
- Categories: New Category (Name, Description). Tags: type a name in "Add a tag…" and click +. Both have Delete.
- Webhooks tab (URL, events, signing secret, Trigger now): UI only.
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
