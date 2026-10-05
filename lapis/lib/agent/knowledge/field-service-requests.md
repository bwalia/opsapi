---
title: Service Requests
pages: /dashboard/field-service/requests
api: /api/v2/field-service/service-requests, /api/v2/field-service/fault-categories, /api/v2/field-service/engineers, /api/v2/field-service/job-types, /api/v2/field-service/sites
modules: fs_service_requests, fs_jobs
tools: find_customer, create_customer
suggestions: Show urgent open requests | Which requests have breached SLA? | Convert SR-0012 to a job for Sam tomorrow 9am
readonly: false
---
# Service Requests
The intake queue: a customer complaint / fault report (SR-0001…) is logged, triaged, given a manager and converted into one or more jobs. Status: new, triaged, assigned, in_progress, on_hold, resolved, closed, rejected, duplicate. "Open" = new/triaged/assigned/in_progress/on_hold. SLA dates (respond by / resolve by) flag breaches.

## Using the page
- List: **Log request** button, search (number, title, customer), filters Status (default Open requests), Priority, SLA (breached). Row icons edit / delete; click a row to open.
- "New service request" form: What's the problem?* (title), Details, Customer & location (Customer, Site, Service address, Postcode), Equipment (Product, Unit serial / reference), Logging details (Priority, Reported via, Fault category, Reported by), SLA (Respond by, Resolve by).
- Request page: **Edit**, delete, **Convert to job** (Job title, Job type, Engineer, First visit, Service manager, Due date), status buttons (Mark triaged, Mark assigned, Start work, Put on hold, Resolve, Close, Reject, Mark duplicate, Reopen — Resolve/Reject/Duplicate ask for notes). Panels: Details, Jobs, Summary (jobs, visits, labour, invoiced), Timeline.

## Rules
- Transitions: new→triaged|assigned|in_progress|on_hold|rejected|duplicate; triaged→assigned|in_progress|on_hold|rejected|duplicate; assigned→in_progress|on_hold|triaged|resolved; in_progress→on_hold|resolved; on_hold→assigned|in_progress|resolved; resolved→closed|in_progress; closed→in_progress; rejected/duplicate are final. GET returns `allowed_transitions`.
- Assigning a manager moves new/triaged to assigned and stamps first response. The manager must be a workspace member.
- Convert to job needs fs_service_requests.update + fs_jobs.create; not for closed/rejected/duplicate. Unset fields copy from the request. Passing engineer_uuid books their first visit (scheduled_start, default now) so the job shows in their My Work; the request moves to in_progress.
- Reading the queue: fs_service_requests.read or fs_jobs.read. Sites can be created by fs_service_requests.update (a site must belong to a customer).
- Resolve names: customers with find_customer (create_customer if new), engineers/managers with `GET /api/v2/field-service/engineers` (user uuids), sites with `GET /api/v2/field-service/sites?customer_uuid=`.

## API
- `GET /api/v2/field-service/service-requests?status=open|new|triaged|assigned|in_progress|on_hold|resolved|closed|rejected|duplicate&priority=low|normal|high|urgent&customer_uuid&manager_uuid&sla=breached&search&page&per_page` — omit status for all (urgent first, then newest)
- `GET /api/v2/field-service/service-requests/{uuid}` — + linked jobs, totals, allowed_transitions
- `POST /api/v2/field-service/service-requests {title*, description, fault_category, channel: phone|app|email|portal|web|other (default phone), reported_by, priority (default normal), customer_uuid, site_uuid, product_uuid, product_ref, service_address, service_postcode, assigned_manager_uuid, sla_response_due_at, sla_resolve_due_at: ISO datetime}`
- `PUT /api/v2/field-service/service-requests/{uuid} {same fields except assigned_manager_uuid, + resolution_notes}`
- `POST /api/v2/field-service/service-requests/{uuid}/status {status*, resolution_notes}`
- `POST /api/v2/field-service/service-requests/{uuid}/assign {manager_uuid*}`
- `POST /api/v2/field-service/service-requests/{uuid}/convert-to-job {title, description, priority, job_type_uuid, customer_uuid, site_uuid, product_uuid, service_address, service_manager_uuid, due_date: YYYY-MM-DD, engineer_uuid, scheduled_start: ISO datetime}` — returns job_uuid, job_number
- `DELETE /api/v2/field-service/service-requests/{uuid}` — spawned jobs are kept
- `GET /api/v2/field-service/fault-categories` — categories already in use
- `GET /api/v2/field-service/engineers?search`, `GET /api/v2/field-service/job-types`
- `GET /api/v2/field-service/sites?customer_uuid&search`
- `POST /api/v2/field-service/sites {name*, customer_uuid*, address_line1, address_line2, city, county, postal_code, country, contact_name, contact_phone, access_notes}`
