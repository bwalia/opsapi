---
title: Leads
pages: /dashboard/leads
api: /api/v2/crm/leads
modules: crm_accounts
tools: create_lead, list_leads
suggestions: Show new high-priority leads | Add a lead for jane@acme.com | Convert a qualified lead to a deal
readonly: false
---
# Leads
Inbox of every enquiry captured for this workspace: website forms, API/webhook, referrals and manual entries. A lead moves through status new → contacted → qualified → converted (or lost). Converting creates a CRM contact (and optionally a deal) from the lead.

## Using the page
- Header buttons: Refresh, **Notifications** (email / Telegram alerts for new leads; only the workspace owner can save them — point the user to the modal, don't change these yourself), **New Lead**.
- Stat cards: Total, New, Contacted, Qualified, Conversion (%).
- Filters: search box, All Status, All Sources, All Priority.
- Row icons: check-circle toggles **new ⇄ contacted**; arrow **Convert to Contact** (hidden once converted); trash **Delete Lead** (confirm dialog).
- Click a row for **Lead details**: the visitor's Message (stored in `notes`), contact/source info, editable Status, Priority and Message/notes with **Save changes**, plus **Convert** and **Delete**.
- **Convert Lead** modal: creates a contact; tick "Also create a deal" to add Deal Name, Value, Currency (default GBP).
- Website forms submit to the public form endpoint POST /api/v2/public/leads/{workspace-slug} (for the website, not for you to call; no login; 10/min rate limit; same email within 5 min is treated as a duplicate).

## Rules
- Create needs `first_name` or `email` ("first_name or email is required").
- status: new | contacted | qualified | converted | lost. source: website_form | email | social_media | manual | api | referral (default manual). priority: low | medium | high | urgent (default medium). score: integer (default 0).
- Never set status=converted with PUT — use the convert endpoint so the contact is created. Converting an already-converted lead returns 409 "Lead is already converted".
- Convert needs the CRM module deployed (it writes crm_contacts/crm_deals). The new contact is not linked to an account; `company_name` is not turned into an account.
- When marking a lead lost, also set `lost_reason`.
- Any workspace member can manage leads. Delete is a soft delete.

## API
- `GET /api/v2/crm/leads?page&per_page&search&status&source&priority&owner_user_uuid` — search matches first/last name, email, company; per_page default 20, max 500
- `GET /api/v2/crm/leads/stats` — total/new/contacted/qualified/converted/lost counts, conversion_rate, leads_by_source
- `GET /api/v2/crm/leads/{uuid}` — includes converted_contact_uuid / converted_deal_uuid when converted
- `POST /api/v2/crm/leads {first_name*, email* (one of the two), last_name, phone, company_name, job_title, source, channel, campaign, priority, score: integer, notes, status (default new), owner_user_uuid}`
- `PUT /api/v2/crm/leads/{uuid} {any of: first_name, last_name, email, phone, company_name, job_title, source, channel, campaign, referrer_url, landing_page_url, status, lost_reason, owner_user_uuid, score, priority, notes}`
- `POST /api/v2/crm/leads/{uuid}/convert {deal: {name*, value: number, currency (default GBP), stage (default new), pipeline_id: numeric}}` — omit `deal` to create only the contact
- `DELETE /api/v2/crm/leads/{uuid}`
