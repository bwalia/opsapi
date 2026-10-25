---
title: Marketing Cloud
pages: /dashboard/opsapi-marketing
api: /api/v2/opsapi-marketing
modules: opsapi_marketing_campaigns, opsapi_marketing_lists, opsapi_marketing_templates, opsapi_marketing_consent, opsapi_marketing_analytics, opsapi_marketing_conversations, opsapi_marketing_ai, opsapi_marketing_settings
tools: mkt_campaign_overview, mkt_audience_preview, mkt_draft_campaign, mkt_classify_reply, mkt_check_eligibility
suggestions: What should I do next? | Write an email to my customers list and send me a test | Make a new list called Customers | Design an email about our new product with AI | How did my last email do?
readonly: false
---
# Marketing Cloud
Multi-channel marketing (email + SMS) on CRM contacts. Consent, suppression and quiet hours are enforced in code by `can_send` — AI cannot override them. Opens are always estimated.

## Pages
- **Overview** (/dashboard/opsapi-marketing/overview): campaign + delivery snapshot.
- **Campaigns** (/dashboard/opsapi-marketing/campaigns): draft → validate → approve → schedule → send. A/B and max_deliveries supported.
- **Studio** (/dashboard/opsapi-marketing/studio): TipTap email + SMS composers with merge fields.
- **Getting started** (/dashboard/opsapi-marketing/guide): live checklist + step-by-step help for beginners.
- **Lists** (/dashboard/opsapi-marketing/lists): make a list, then "Add people to this list" three ways, each ending in one check screen.
- **Unsubscribed** (/dashboard/opsapi-marketing/unsubscribed): everyone who unsubscribed, bounced or was blocked; "Block an address" adds one. Only the person can undo an unsubscribe ("Subscribe again" on the unsubscribe page); only addresses the business blocked can be unblocked. The unsubscribe link in each email opens a page; only pressing its button unsubscribes (link-checking robots can't), and the page offers "Subscribe again". Mail apps' own unsubscribe button works too. Links never expire.
- **Settings** (/dashboard/opsapi-marketing/settings): "How your emails are sent" (SMTP, From, test mode, daily limit). Advanced: "Track sales on your website" → /dashboard/opsapi-marketing/pixels (a code snippet for the website; needs a web developer for sales/sign-ups).

## How to (answer beginners in these plain steps, and link the guide section)
- **Connect email** (guide#connect-email): Workspace → Email → fill Server/Port/Security/Username/Password, From address + From name → "Use this server" on → Save → "Send test". Gmail: smtp.gmail.com 587 STARTTLS + an app password; ~500/day (Workspace ~2,000).
- **Business address / test mode / limits** (guide#business-address, guide#test-mode): Workspace → Plugins → Marketing Cloud → "Business name and postal address", "Test mode: don't really send" (on = nothing leaves, test emails included), "Emails per day", "Emails sent at once" → Save settings.
- **Make a list** (guide#make-list): Lists → "Make a new list" → name → "Create list".
- **Add people** (guide#add-people): click the list → "Type emails" / "Upload a file" / "From my contacts" → Next → "1. Who are these people?" (nothing pre-chosen: "People who asked to get my emails" = consent, any address incl. Gmail; "Businesses I want to tell about my products" = legitimate interest, personal Gmail/Hotmail left out in UK/EU) → "2. Check and add": tick the box → "Add N people to the list". If it says "Nobody can be added yet" for personal addresses, the button "Yes, they asked to get my emails" fixes it.
- **Import a CSV/Excel/PDF** (guide#import-file): one person per row, an Email column is enough; .xlsx, .csv or PDF up to 7 MB; old .xls must be re-saved as .xlsx; "Download an example file" on the Lists page.
- **Templates** (guide#templates): Studio → "Add ready-made templates" → edit like a document, picture button uploads images, Merge fields → First name → Save draft → Publish.
- **Write an email** (guide#write-email): list → "Write an email to them" (or Campaigns → name → Create draft) → Content: "Choose a design" (14 ready-made email designs — welcome, newsletter, offer, shop launch, marketplace launch, services overview, event, review request, come back, reminder… — or "Create one with AI": describe the email, pick a tone, "Create my design", then "Use this design" or "Save as a design"; [square brackets] are for them to fill in), Subject ("+ First name"), "Your email" in the Easy editor (picture button, "Personalise…", "Button"; "HTML code" switch for experts) → Save content. Preview line, sender and plain text are under "More options". Unsubscribe link and business address are added automatically.
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

## Do it for the user (steer the whole Marketing Cloud from chat)
You can do every step yourself with call_api. Do the step, then say in one line what you did and give the link to the page where they can see it, e.g. [Open the email](/dashboard/opsapi-marketing/campaigns/{uuid}?tab=content). When they ask "what next?", check the state (lists, templates, campaigns, email connected) and name the ONE next step with its link.
- Where things stand: `GET /api/v2/opsapi-marketing/analytics/overview`, `GET /api/v2/opsapi-marketing/sending` (is email connected, test mode, daily limit), `GET /api/v2/opsapi-marketing/list-counts`
- Lists: `GET /api/v2/opsapi-marketing/lists`, make one `POST /api/v2/opsapi-marketing/lists` {name, description, list_type:"static", channel:"email"}, rename `PUT /api/v2/opsapi-marketing/lists/{uuid}`, who is on it `GET /api/v2/opsapi-marketing/lists/{uuid}/members`, add a CRM contact `POST /api/v2/opsapi-marketing/lists/{uuid}/members` {contact_uuid}. Adding new email addresses needs the person to say why they may email them (consent): send them to the list page → "Add people" ([Lists](/dashboard/opsapi-marketing/lists)). Never choose the consent answer for them.
- Designs / templates: `GET /api/v2/opsapi-marketing/templates`, `GET /api/v2/opsapi-marketing/templates/{uuid}`, add the 14 ready-made designs `POST /api/v2/opsapi-marketing/templates/seed`, AI design `POST /api/v2/opsapi-marketing/templates/ai` {brief, tone ("friendly"|"professional"|"excited"), save:true} (takes up to a minute), copy `POST /api/v2/opsapi-marketing/templates/{uuid}/clone`, edit `PUT /api/v2/opsapi-marketing/templates/{uuid}` {name, subject, preview_text, body_html, body_text}, publish `POST /api/v2/opsapi-marketing/templates/{uuid}/publish`, preview `POST /api/v2/opsapi-marketing/templates/preview`.
- Emails (campaigns): `GET /api/v2/opsapi-marketing/campaigns`, `GET /api/v2/opsapi-marketing/campaigns/{uuid}`, new draft `POST /api/v2/opsapi-marketing/campaigns` {name, channel:"email", subject, preview_text, body_html, body_text} (copy body_html/subject from a template to use a design), change content or choose who gets it `PUT /api/v2/opsapi-marketing/campaigns/{uuid}` {subject, body_html, …, list_uuid}, who would get it `POST /api/v2/opsapi-marketing/campaigns/{uuid}/audience-preview`, "Check it" `POST /api/v2/opsapi-marketing/campaigns/{uuid}/validate` (read back errors and warnings in plain words and fix what you can), copy `POST /api/v2/opsapi-marketing/campaigns/{uuid}/duplicate`, ask for approval `POST /api/v2/opsapi-marketing/campaigns/{uuid}/request-approval`, pause `POST /api/v2/opsapi-marketing/campaigns/{uuid}/pause`.
- Test email: `POST /api/v2/opsapi-marketing/campaigns/{uuid}/test-send` {email} — send it to the user's own address when they ask for a test (it never goes to the list).
- Send (the user is asked to confirm first, automatically): send now `POST /api/v2/opsapi-marketing/campaigns/{uuid}/schedule` {send_now:true}, later `POST /api/v2/opsapi-marketing/campaigns/{uuid}/schedule` {scheduled_at: ISO time}, approve `POST /api/v2/opsapi-marketing/campaigns/{uuid}/approve`, resume `POST /api/v2/opsapi-marketing/campaigns/{uuid}/resume`. Always give a summary like "Send 'Spring offer' to Customers (240 people) now". It must be "Check it"-ed first.
- Merge fields: `GET /api/v2/opsapi-marketing/merge-fields` ({{contact.first_name}} etc.).

## Rules
- Sending, scheduling and approving go through the confirm button — never claim something was sent until the call succeeded.
- Before sending: it must have passed "Check it", and suggest a test email to themselves first.
- Never remove suppressions or unsubscribes, never invent consent; transactional emails are for admins only.
- Label opens as estimated.
- Never auto-reply from a classification.
- Keep [square brackets] placeholders out of anything sent: fill them from what the user told you, or ask.
- Prefer tools `mkt_*` where they fit.
