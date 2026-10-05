---
title: CRM
pages: /dashboard/crm
api: /api/v2/crm/accounts, /api/v2/crm/contacts, /api/v2/crm/deals, /api/v2/crm/activities, /api/v2/crm/pipelines, /api/v2/crm/dashboard
modules: crm_accounts, crm_contacts, crm_deals, crm_activities, crm_pipelines
tools: create_crm_account, list_crm_accounts, create_contact, create_deal, list_deals
suggestions: Add an account for Acme Ltd | Show open deals | Log a call with a contact tomorrow
readonly: false
---
# CRM
Sales workspace with four record types: **accounts** (companies), **contacts** (people, optionally linked to an account), **deals** (opportunities with value, stage, probability) and **activities** (call, email, meeting, note, task). Deal status is open | won | lost; account/contact status is active | inactive. Records have a `uuid` (URLs) and a numeric `id` (list filters, PUT link fields).

## Using the page
- Header: stat cards Total Accounts, Active Deals, Deal Value; **Refresh** and a create button that follows the tab (Add Account / Add Contact / Add Deal / Add Activity).
- Tabs **Accounts | Contacts | Deals | Activities** with a search box and a status/stage/type filter.
- Click an account row (or the eye icon) to open `/dashboard/crm/{uuid}`: **Edit** (all fields + Status), **Delete**, Contacts/Deals counts, and tabs Contacts | Deals | Activities with an "Add contact/deal/activity" button that links the new record to this account. These tabs are not filtered by account; for only this account's records list with `account_id={id}`.
- Pending activities have a **Complete** icon; the trash icon deletes (confirm dialog).
- Create Contact / Create Deal modals have an "Account UUID" field; Create Activity has "Related To" (Account/Contact/Deal) + "Related UUID". Resolve names to uuids for the user.

## Rules
- Required: account `name`; contact `first_name`; deal `name`; activity `subject` + `activity_type`.
- Any workspace member can use CRM (routes check membership only). Deletes are soft deletes.
- Deal stages in the UI: prospecting, qualification, proposal, negotiation, closed_won, closed_lost (API default stage is `new`). Setting `stage` to `won` or `lost` auto-sets status=won/lost, won_at/lost_at and actual_close_date=today. The UI stages closed_won/closed_lost do NOT change status — also send `"status":"won"`/`"lost"` if the user uses them.
- Activity status is stored as `planned` (shown as "pending"), `completed`, `cancelled`. Filter pending with `status=planned`. Use the complete endpoint to mark done.
- POST bodies accept uuids for links (account_uuid, contact_uuid, pipeline_uuid, related_type+related_uuid). PUT only accepts numeric `account_id`/`contact_id`/`deal_id`/`pipeline_id` — GET the target first to read its `id`.
- Lists: `page` (default 1), `per_page` (default 20, max 500). Deals have no search; filter instead.

## API
- `GET /api/v2/crm/dashboard/stats` — header stats, win_rate, deals_by_stage
- `GET /api/v2/crm/accounts?page&per_page&search&status=active|inactive&owner={user_uuid}` — search matches name/email
- `GET /api/v2/crm/accounts/{uuid}` — includes id, contact_count, deal_count, total_deal_value
- `POST /api/v2/crm/accounts {name*, industry, website, email, phone, address_line1, address_line2, city, state, postal_code, country, annual_revenue: number, employee_count: integer, status: active|inactive}`
- `PUT /api/v2/crm/accounts/{uuid} {any of the POST fields, owner_user_uuid}`
- `DELETE /api/v2/crm/accounts/{uuid}`
- `GET /api/v2/crm/contacts?page&per_page&search&status&account_id={numeric}` — search: first/last name, email. `GET /api/v2/crm/contacts/{uuid}` for one
- `POST /api/v2/crm/contacts {first_name*, last_name, email, phone, mobile, job_title, department, account_uuid, status}`
- `PUT /api/v2/crm/contacts/{uuid} {first_name, last_name, email, phone, mobile, job_title, department, account_id: numeric, owner_user_uuid, status}`
- `DELETE /api/v2/crm/contacts/{uuid}`
- `GET /api/v2/crm/deals?page&per_page&stage&status=open|won|lost&account_id={numeric}&pipeline_id={numeric}&owner={user_uuid}` — `GET /api/v2/crm/deals/{uuid}` for one
- `POST /api/v2/crm/deals {name*, value: number, currency (default USD), stage (default new), probability: 0-100, expected_close_date: YYYY-MM-DD, account_uuid, contact_uuid, pipeline_uuid}`
- `PUT /api/v2/crm/deals/{uuid} {name, value, currency, stage, probability, expected_close_date, actual_close_date, lost_reason, status: open|won|lost, account_id, contact_id, pipeline_id, owner_user_uuid}` — move stage here
- `DELETE /api/v2/crm/deals/{uuid}`
- `GET /api/v2/crm/activities?page&per_page&activity_type&status=planned|completed|cancelled&account_id&contact_id&deal_id` (ids numeric)
- `POST /api/v2/crm/activities {subject*, activity_type*: call|email|meeting|note|task, description, activity_date: YYYY-MM-DD or ISO datetime, duration_minutes: integer, related_type: account|contact|deal, related_uuid, status (default planned)}`
- `PUT /api/v2/crm/activities/{uuid} {activity_type, subject, description, activity_date, duration_minutes, status, account_id, contact_id, deal_id}`
- `POST /api/v2/crm/activities/{uuid}/complete` — mark completed
- `DELETE /api/v2/crm/activities/{uuid}`
- `GET /api/v2/crm/pipelines` — id, uuid, name, stages (array), is_default
- `GET /api/v2/crm/pipelines/{uuid}/deals` — that pipeline's deals grouped by stage
- `POST /api/v2/crm/pipelines {name*, description, stages: ["new","proposal",...], is_default: boolean}`
- `PUT /api/v2/crm/pipelines/{uuid} {name, description, stages, is_default}`
