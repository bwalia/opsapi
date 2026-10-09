---
title: Forms
pages: /dashboard/forms
api: /api/v2/forms
modules: forms, customers, crm_accounts, users
tools: create_form, list_forms, get_form, update_form, summarize_form_responses, publish_form
suggestions: Create a contact form that makes each person a lead | How many responses did my forms get this week? | Publish my latest form
readonly: false
---
# Forms
Build a form, publish it, and share its public link. Anyone with the link can fill it in; each response is saved and can create records in this workspace.

## Concepts
- A form is a **draft** until published. Publishing makes the current draft a new live **version**; later edits stay in the draft ("Unpublished changes") until published again. Responses keep the labels of the version they answered.
- Status: draft -> published -> closed (stops taking responses; can be reopened). Deleting removes the public link at once.
- **Create records** (targets): customer (needs Customers), lead (needs CRM), user (emails an invitation; the account is created when they accept). Each adds the name and email fields it needs and locks them (always required, can't be deleted). An email that already exists is linked, never changed.
- Field types: short_text, long_text, email, phone, number, date, time, url, single_select, radio, multi_select, boolean, rating, consent, name, address, hidden, heading, paragraph. `maps_to` (phone, company, job_title, address, notes, marketing_consent) copies an answer onto the record a target creates.
- Responses: complete, needs_attention (a record couldn't be created: retry it), spam (bot checks failed; "Not spam" processes it).

## Using the page
- /dashboard/forms: the list (title, status, responses), **New form** (blank, a template, or "Describe it, AI drafts it"), **Custom domain** (form links on the workspace's own domain: two DNS records, a CNAME/A to the platform's edge and a TXT proof), **Spam protection** (Turnstile keys), and per form Edit, Share, Duplicate, Close/Reopen, Delete.
- /dashboard/forms/{uuid}: tabs **Build** (field palette, drag to reorder, field settings, the Create records card, Preview, **Publish**), **Settings** (thank-you message, redirect, close date, response limit, notification emails, auto-reply, retention), **Share** (link, embed code, QR code, prefilled link), **Responses** (table, filters, detail with linked records, Retry, Spam, Delete, Export CSV), **Insights** (views, starts, responses, steps, sources, AI summary).
- Every form shows "Powered by OpsAPI"; for now no plan can hide it.

## Rules
- Create forms with create_form and change them with update_form: both only touch the draft. Never publish unless the user asks; publish_form asks them to confirm.
- For "what did people say" use summarize_form_responses (exact counts + a summary), not call_api over every response.
- Don't add name/email fields for create_records yourself: they are added and locked automatically.
- Adding a target needs that module's create permission (customers.create, crm_accounts.create, users.create); you can only invite people with a role you could give yourself.
- Resolve a form by title with list_forms or get_form before acting on it; never invent uuids.
- Answers are personal data: summarise them, don't paste many responses verbatim.

## API
- `GET /api/v2/forms?status=draft|published|closed&q&cursor&limit` — list forms
- `GET /api/v2/forms/targets` — the create-records options here and the roles you may give
- `GET /api/v2/forms/templates` — starter forms
- `GET /api/v2/forms/{uuid}` — one form with its draft fields and settings
- `POST /api/v2/forms {title*, description, template, fields: [{label*, type*, required, options, help}], targets: [{type: customer|lead|user, role}], settings}` — create a draft
- `PUT /api/v2/forms/{uuid} {title, description, fields, targets, settings, expected_updated_at}` — change the draft
- `POST /api/v2/forms/{uuid}/publish` — publish the draft
- `POST /api/v2/forms/{uuid}/close` — stop taking responses
- `POST /api/v2/forms/{uuid}/reopen` — take responses again
- `POST /api/v2/forms/{uuid}/duplicate` — copy as a new draft
- `GET /api/v2/forms/{uuid}/analytics?days` — views, starts, responses, conversion, step funnel, sources
- `DELETE /api/v2/forms/{uuid}` — delete the form
- `GET /api/v2/forms/domain` — the workspace's custom domain, its status and the DNS records to add
- `PUT /api/v2/forms/domain {domain*}` — connect a custom domain (replaces the current one)
- `POST /api/v2/forms/domain/check` — check its DNS records now
- `GET /api/v2/forms/{uuid}/submissions?status=complete|needs_attention|spam|all&from&to&q&cursor&limit` — responses (newest first)
- `GET /api/v2/forms/{uuid}/submissions/{submission_uuid}` — one response
- `PUT /api/v2/forms/{uuid}/submissions/{submission_uuid} {status*: spam|complete}` — mark spam / not spam
- `POST /api/v2/forms/{uuid}/submissions/{submission_uuid}/retry` — retry records that failed
- `DELETE /api/v2/forms/{uuid}/submissions/{submission_uuid}` — delete a response
