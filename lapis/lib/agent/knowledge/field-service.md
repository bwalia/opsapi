---
title: Service Jobs
pages: /dashboard/field-service
api: /api/v2/field-service/jobs, /api/v2/field-service/job-phases, /api/v2/field-service/job-items, /api/v2/field-service/visits, /api/v2/field-service/stats, /api/v2/field-service/engineers, /api/v2/field-service/job-types, /api/v2/field-service/sites, /api/v2/field-service/parts
modules: fs_jobs, fs_visits, invoices
tools: find_customer, create_customer
suggestions: Show overdue jobs | Which completed jobs are awaiting invoice? | Create a job for an AC repair at Ward 5
readonly: false
---
# Service Jobs
A job (JOB-0001…) has phases (copied from its job type), site visits (engineer bookings), items (parts, materials, labour, hire), billing and activity. Status: draft → scheduled → in_progress → completed, plus on_hold / cancelled. Booking a visit moves draft→scheduled; check-in/phase start → in_progress.

## Using the page
- List: stat cards (**Overdue** / **Awaiting invoice** filter on click), search, Status / Priority / Job type filters.
- **New job**: Title*, Job type, Priority, Customer, Site, Product, Unit serial, Service manager (default me), Service address, Postcode, Due date, Customer reference / PO, Hourly rate, Est. hours, Description.
- Job page: status buttons (Mark scheduled, Start work, Complete job, Put on hold, Reopen as draft, Cancel job), pencil edit, bin delete, **Job sheet** (printable). Panels: **Phases** (Add phase, Start/Complete/Blocked/Skip/Reopen, checklist ticks), **Site visits** (Book visit, reschedule, cancel, delete), **Parts & materials** (Add item, Approve/Reject), **Quotation** (Preview/PDF/Email), **Billing** (Create invoice), **Activity** (Add a comment). Quote emails, photos and part proposals are done by the user on the page.

## Rules
- Transitions: draft→scheduled|in_progress|on_hold|cancelled; scheduled→draft|in_progress|on_hold|cancelled; in_progress→scheduled|on_hold|completed|cancelled; on_hold→scheduled|in_progress|cancelled; completed→in_progress; cancelled→draft (see `allowed_transitions`).
- Completing fails with unfinished phases or open visits unless `force:true` (confirm with the user). Cancelling also cancels unstarted visits.
- Completed/cancelled jobs lock phases and visits (reopen first). Invoiced jobs can't be deleted.
- Completing a phase needs all checklist items ticked (or force) and `signoff_name` if it requires sign-off. Completed phases can't be removed.
- Parts/materials start `pending` and only invoice once approved; other item types are auto-approved. Invoiced items are locked.
- Invoice: job not draft/cancelled; needs fs_jobs.update + invoices.create; every labour visit needs a rate (visit → job → job type, or pass hourly_rate). Bills everything uninvoiced as one draft invoice.
- Without fs_jobs.update you only see jobs you have a visit on. Engineers/managers = user uuids from `GET /api/v2/field-service/engineers`; customers via find_customer.

## API
- `GET /api/v2/field-service/stats` — counters
- `GET /api/v2/field-service/jobs?status=open|all|draft|scheduled|in_progress|on_hold|completed|cancelled&priority=low|normal|high|urgent&customer_uuid&job_type_uuid&manager_uuid&engineer_uuid&mine=true&overdue=true&uninvoiced=true&search&page&per_page&order_by=created_at|due_date&order_dir=asc|desc`
- `GET /api/v2/field-service/jobs/{uuid}` — + phases, visits, items, activity, totals
- `POST /api/v2/field-service/jobs {title*, job_type_uuid, customer_uuid, site_uuid, product_uuid, product_ref, service_address, service_postcode, priority, service_manager_uuid, customer_reference, due_date: YYYY-MM-DD, estimated_hours, hourly_rate, description, notes}` — draft
- `PUT /api/v2/field-service/jobs/{uuid} {same}` / `DELETE /api/v2/field-service/jobs/{uuid}`
- `POST /api/v2/field-service/jobs/{uuid}/status {status*, reason, force}`
- `POST /api/v2/field-service/jobs/{uuid}/comments {message*}`
- `POST /api/v2/field-service/jobs/{uuid}/phases {name*, description, estimated_hours, requires_visit, requires_signoff, checklist: [{label, done}]}`
- `PUT /api/v2/field-service/jobs/{uuid}/phases/reorder {order*: [phase uuid,...]}`
- `PUT /api/v2/field-service/job-phases/{uuid} {same + notes}` / `DELETE /api/v2/field-service/job-phases/{uuid}`
- `POST /api/v2/field-service/job-phases/{uuid}/status {status*: pending|in_progress|blocked|completed|skipped, signoff_name, force, notes}`
- `POST /api/v2/field-service/job-phases/{uuid}/checklist/{index} {done*}` — index 0-based
- `POST /api/v2/field-service/jobs/{uuid}/items {description*, item_type: part|material|labour|hire|expense|other, quantity (>0), unit_price, tax_rate (0-100), is_billable, part_uuid, phase_uuid, visit_uuid, labour_category: engineer_nt|engineer_ot|mate_nt|mate_ot, days, supplier, part_number}`
- `PUT /api/v2/field-service/job-items/{uuid} {same}` / `DELETE /api/v2/field-service/job-items/{uuid}`
- `POST /api/v2/field-service/job-items/{uuid}/approve` / `POST /api/v2/field-service/job-items/{uuid}/reject {reason}`
- `GET /api/v2/field-service/jobs/{uuid}/invoice-preview?hourly_rate&labour_tax_rate`
- `POST /api/v2/field-service/jobs/{uuid}/invoice {hourly_rate, labour_tax_rate, due_date, notes}`
- `POST /api/v2/field-service/jobs/{uuid}/visits {scheduled_start*: ISO datetime UTC, scheduled_end, engineer_user_uuid, phase_uuid, instructions, is_billable, hourly_rate}`
- `PUT /api/v2/field-service/visits/{uuid} {scheduled_start, scheduled_end, engineer_user_uuid, instructions}` — reschedule/reassign
- `POST /api/v2/field-service/visits/{uuid}/cancel {reason}` / `DELETE /api/v2/field-service/visits/{uuid}`
- Lookups: `GET /api/v2/field-service/engineers?search`, `GET /api/v2/field-service/job-types`, `GET /api/v2/field-service/sites?customer_uuid`, `GET /api/v2/field-service/parts?search`
