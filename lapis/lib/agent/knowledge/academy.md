---
title: Academy
pages: /dashboard/academy
api: /api/v2/academy/courses, /api/v2/academy/lessons, /api/v2/academy/categories, /api/v2/academy/pending-courses, /api/v2/academy/instructor, /api/v2/academy/creator/profile
modules: courses
tools:
suggestions: List my draft courses | Create a free beginner course on Python | Submit my course for review
readonly: false
---
# Academy
The LMS: courses made of ordered lessons with rich HTML content. Course status: draft → pending_review → published, or archived. Instructors (the "instructor" role) manage only their own courses; the workspace owner / platform admins see all courses and are the only ones who can publish. Lessons are draft|published, but nothing is public until the COURSE is published.

## Using the page
- List: search box, Level and Status filters; table Course, Category, Level, Pricing, Lessons, Status, Updated. Click a row to open the course.
- New Course modal: Title*, Description, Instructor, Category (pick existing or type new), Level, Status, Thumbnail URL, Tags (Enter or comma), "This is a free course"; if paid: Price, Currency, Membership tier. Create Course / Save Changes.
- Row actions: Submit for review (instructors, draft/archived courses), Edit, Delete. "In review" = waiting for an admin.
- Admins get a "Pending review" panel: Approve (goes live) or Reject (back to draft).
- Course page /dashboard/academy/{uuid}: Lessons table, Add Lesson; click a lesson or "Edit content" to edit.
- Lesson editor: Title*, Short description, Content (rich editor; images by URL, YouTube/Vimeo embeds, HTML source), Lesson settings: Status, Duration (seconds), Video S3 key (optional), "Free preview lesson". Create Lesson / Save Lesson.
- Header: My Profile (public instructor profile), Monetization (bank details, membership tiers) and Payouts (platform admins) are UI-only.
- Not an instructor yet: /dashboard/academy/join → "Become an Instructor".

## Rules
- Course: title required; level beginner|intermediate|advanced (default beginner); status draft|pending_review|published|archived (default draft). A non-admin sending status "published" gets pending_review (= submit for review).
- Paid course (is_free false) needs price > 0 in MINOR units (999 = 9.99). currency default USD (UI offers USD, GBP, EUR, INR, AUD, CAD, SGD, AED, JPY, NZD). tier = integer ≥ 1 (default 1): subscribers at that tier or higher can watch.
- tags: array of strings, max 20, each ≤ 40 chars; [] clears them. Slug comes from the title and must be unique (409 "slug may already exist").
- Approve only works on a pending_review course (409 otherwise). Approve, reject and the pending list are owner/platform-admin only (403).
- Lesson: title required; status draft|published (default draft); position auto-appends; is_preview = free sample of a paid course.
- Deleting a course hides it and its lessons. No file upload here: thumbnails/images are URLs, videos are S3 keys.

## API
- `GET /api/v2/academy/courses?page&perPage&search&status&category&level&tag` — list (instructors see only their own)
- `GET /api/v2/academy/categories` — existing category names
- `POST /api/v2/academy/courses {title*, description, instructor, category, level, status, thumbnail_url, tags: [string], is_free: bool, price: int (minor units), currency, tier: int, slug}` — create
- `GET /api/v2/academy/courses/{uuid}` — course + its lessons
- `PUT /api/v2/academy/courses/{uuid} {any create field}` — update; {status: "published"} submits for review / publishes
- `DELETE /api/v2/academy/courses/{uuid}` — delete course
- `GET /api/v2/academy/pending-courses` — review queue (admins)
- `POST /api/v2/academy/courses/{uuid}/approve` — publish (admins)
- `POST /api/v2/academy/courses/{uuid}/reject` — back to draft (admins)
- `GET /api/v2/academy/courses/{uuid}/lessons` — lessons in order
- `POST /api/v2/academy/courses/{uuid}/lessons {title*, description, content_html, status, duration_seconds: int, is_preview: bool, s3_key, position: int}` — add lesson
- `GET /api/v2/academy/lessons/{uuid}` — one lesson
- `PUT /api/v2/academy/lessons/{uuid} {any lesson field}` — update lesson
- `DELETE /api/v2/academy/lessons/{uuid}` — delete lesson
- `GET /api/v2/academy/instructor/status` — am I an instructor
- `POST /api/v2/academy/instructor/register` — become an instructor (no body; joins the Academy workspace)
- `GET /api/v2/academy/creator/profile` — my public instructor profile
- `PUT /api/v2/academy/creator/profile {headline, bio, avatar_url, location, website, socials: {twitter, linkedin, github, youtube}, skills: [string], achievements: [{title, issuer, year}], education: [{degree, institution, year}]}` — update it (omitted fields unchanged)
