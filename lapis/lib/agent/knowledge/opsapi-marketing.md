---
title: Marketing Cloud
pages: /dashboard/opsapi-marketing
api: /api/v2/opsapi-marketing
modules: opsapi_marketing_campaigns, opsapi_marketing_lists, opsapi_marketing_templates, opsapi_marketing_consent, opsapi_marketing_analytics, opsapi_marketing_conversations, opsapi_marketing_ai, opsapi_marketing_settings
tools: mkt_campaign_overview, mkt_audience_preview, mkt_draft_campaign, mkt_classify_reply, mkt_check_eligibility
suggestions: Summarise campaign performance this month | Draft an email campaign for our newsletter list | Is this contact eligible for SMS? | Classify this reply: not interested thanks
readonly: false
---
# Marketing Cloud
Multi-channel marketing (email + SMS) on CRM contacts. Consent, suppression and quiet hours are enforced in code by `can_send` — AI cannot override them. Opens are always estimated.

## Pages
- **Overview** (/dashboard/opsapi-marketing/overview): campaign + delivery snapshot.
- **Campaigns** (/dashboard/opsapi-marketing/campaigns): draft → validate → approve → schedule → send. A/B and max_deliveries supported.
- **Studio** (/dashboard/opsapi-marketing/studio): TipTap email + SMS composers with merge fields.
- **Conversations** (/dashboard/opsapi-marketing/conversations): inbound replies and classifications.
- **Getting started** (/dashboard/opsapi-marketing/guide): live checklist + step-by-step help for beginners.
- **Lists** (/dashboard/opsapi-marketing/lists): make a list, then "Add people to this list" three ways, each ending in one check screen.
- **Suppressions**: everyone who unsubscribed (/dashboard/plugins/opsapi-marketing/suppressions). The unsubscribe link in each email opens a page; only pressing its button unsubscribes (link-checking robots can't), and the page offers "Subscribe again". Mail apps' own unsubscribe button works too. Links never expire.
- **Settings** (/dashboard/opsapi-marketing/settings): "How your emails are sent" (SMTP, From, test mode, daily limit).

## How to (answer beginners in these plain steps, and link the guide section)
- **Connect email** (guide#connect-email): Workspace → Email → fill Server/Port/Security/Username/Password, From address + From name → "Use this server" on → Save → "Send test". Gmail: smtp.gmail.com 587 STARTTLS + an app password; ~500/day (Workspace ~2,000).
- **Business address / test mode / limits** (guide#business-address, guide#test-mode): Workspace → Plugins → Marketing Cloud → "Business name and postal address", "Test mode: don't really send" (on = nothing leaves, test emails included), "Emails per day", "Emails sent at once" → Save settings.
- **Make a list** (guide#make-list): Lists → "Make a new list" → name → "Create list".
- **Add people** (guide#add-people): click the list → "Type emails" / "Upload a file" / "From my contacts" → Next → "1. Who are these people?" (nothing pre-chosen: "People who asked to get my emails" = consent, any address incl. Gmail; "Businesses I want to tell about my products" = legitimate interest, personal Gmail/Hotmail left out in UK/EU) → "2. Check and add": tick the box → "Add N people to the list". If it says "Nobody can be added yet" for personal addresses, the button "Yes, they asked to get my emails" fixes it.
- **Import a CSV/Excel/PDF** (guide#import-file): one person per row, an Email column is enough; .xlsx, .csv or PDF up to 7 MB; old .xls must be re-saved as .xlsx; "Download an example file" on the Lists page.
- **Templates** (guide#templates): Studio → "Add ready-made templates" → edit like a document, picture button uploads images, Merge fields → First name → Save draft → Publish.
- **Write an email** (guide#write-email): list → "Write an email to them" (or Campaigns → name → Create draft) → Content: "Choose a design" (11 ready-made email designs — welcome, newsletter, offer, event, review request, come back, reminder… — or "Create one with AI": describe the email, pick a tone, "Create my design", then "Use this design" or "Save as a design"; [square brackets] are for them to fill in), Subject ("+ First name"), "Your email" in the Easy editor (picture button, "Personalise…", "Button"; "HTML code" switch for experts) → Save content. Preview line, sender and plain text are under "More options". Unsubscribe link and business address are added automatically.
- **Send** (guide#send): Audience tab → "Who gets this email" (saves when chosen) → "Send yourself a test" (own email pre-filled; any address works, not added to the list, no consent needed but unsubscribed addresses never get it; needs test mode off to arrive) → optional "More options": "Per batch" + "Minutes between batches" (e.g. 400 / 60) → "Check it" (top right) → "Send now" or "Schedule…". "More" menu: ask for approval, make a copy, cancel this email. Quiet hours 21:00–08:00 hold marketing until morning.
- **List has no "Add people"** (guide#problems): it is a smart list (list_type dynamic, sparkle icon) that fills itself from rules (fields: email, names, company, job title, phone, status — no city). Button "Make it a regular list" on the list switches it to static.
- **Nothing arrived** (guide#problems): test mode on? email connected? daily limit reached? quiet hours? spam folder?

## Answers
- Workspace snapshot: `GET /api/v2/opsapi-marketing/analytics/overview`
- Campaign breakdown: `GET /api/v2/opsapi-marketing/analytics/campaigns/{uuid}`
- Contact timeline: `GET /api/v2/opsapi-marketing/analytics/contacts/{contact_uuid}`
- Replies: `GET /api/v2/opsapi-marketing/replies`
- Classify preview: `POST /api/v2/opsapi-marketing/replies/classify-preview`
- Audience preview: `POST /api/v2/opsapi-marketing/campaigns/{uuid}/audience-preview`

## Rules
- Never send, schedule, approve, or remove suppressions for the user — point them to the campaign page.
- Draft campaigns only; always remind that validate → approve → schedule is required.
- Label opens as estimated.
- Never invent consent; never auto-reply from a classification.
- Prefer tools `mkt_*` over inventing API bodies.
