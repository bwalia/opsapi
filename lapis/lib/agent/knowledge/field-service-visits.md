---
title: Site Visits
pages: /dashboard/field-service/visits, /dashboard/field-service/my-work
api: /api/v2/field-service/visits, /api/v2/field-service/jobs, /api/v2/field-service/job-phases, /api/v2/field-service/job-items, /api/v2/field-service/engineers, /api/v2/field-service/parts
modules: fs_visits, fs_jobs
tools:
suggestions: What visits do I have today? | Show unassigned visits this week | Check out of my current visit with 2 hours
readonly: false
---
# Site Visits & My Work
A visit is one engineer booked onto a job (optionally a phase) for a time slot. Status: scheduled → en_route → on_site (check-in) → completed (check-out); no_access; cancelled. **Site Visits** is the dispatcher's schedule; **My Work** is the engineer's phone-first list, and opening a visit there is the guided on-site screen.

## Using the page
- Site Visits: **My visits / All visits** toggle (All only for dispatchers), **Day / Week** range with Previous/Next, Engineer filter (All engineers, Unassigned, a name), Status filter. Click a visit to open it.
- Visit page: **En route**, **Check in**, **Check out** (form "Check out & work report": Work carried out*, labour hours, sign-off name, complete phase, "Log hours to my timesheet", "Follow-up visit required"), **No access** (What happened?), **Cancel visit** (dispatchers), **Log to timesheet** (completed visit not yet logged). Also the phase checklist, F-Gas / refrigerant card and "Parts used on this visit".
- My Work: buckets In progress / Overdue / Later today / Coming up. Guided visit button changes with state: **On my way** → **I've arrived** → **Finish job** (outcomes Finished / Coming back / No access). Tiles: Labour, Replace part (photo needed — use the page), Hire, Refrigerant.

## Rules
- The assigned engineer may work their own visit; anyone else needs fs_visits.update. Without fs_visits.update the list only returns your own visits.
- En route only from scheduled; check-in from scheduled/en_route; check-out and no-access from scheduled/en_route/on_site; cancel only scheduled/en_route (fs_visits.update).
- Check-out: labour_hours 0-24, required if never checked in (otherwise defaults to time since check-in). complete_phase also needs the phase checklist ticked and sign-off name if required — otherwise it returns a warning. Hours log to the engineer's timesheet by default (log_timesheet).
- Reschedule/reassign only while scheduled or en_route. An engineer without fs_visits.update may only edit report + F-Gas fields; labour_hours only after completion. Billing fields lock once invoiced.
- Delete (fs_visits.delete) not allowed when on site, logged to a timesheet or invoiced — cancel instead.
- Booking needs an open job (not completed/cancelled); double bookings are allowed but returned as `conflicts`.
- engineer uuids are user uuids from `GET /api/v2/field-service/engineers`; find job uuids with `GET /api/v2/field-service/jobs?search=`.

## API
- `GET /api/v2/field-service/visits?mine=true&engineer_uuid=<uuid>|unassigned&job_uuid&status=open|all|scheduled|en_route|on_site|completed|cancelled|no_access&from&to (ISO datetime, on scheduled_start, to exclusive)&follow_up=true&search&page&per_page&order_dir=asc|desc`
- `GET /api/v2/field-service/visits/{uuid}` — visit + job/site + phase checklist + items
- `POST /api/v2/field-service/jobs/{job_uuid}/visits {scheduled_start*: ISO datetime UTC, scheduled_end, engineer_user_uuid, phase_uuid, instructions, is_billable (default true), hourly_rate}`
- `PUT /api/v2/field-service/visits/{uuid} {scheduled_start, scheduled_end, engineer_user_uuid, phase_uuid, instructions, is_billable, hourly_rate, labour_hours, work_summary, follow_up_required, follow_up_notes, customer_signoff_name, refrigerant_type, refrigerant_added_kg, refrigerant_recovered_kg (0-1000), leak_check_result: pass|fail|na, leak_check_notes, fgas_cylinder_ref}`
- `DELETE /api/v2/field-service/visits/{uuid}`
- `POST /api/v2/field-service/visits/{uuid}/en-route`
- `POST /api/v2/field-service/visits/{uuid}/check-in {latitude, longitude}`
- `POST /api/v2/field-service/visits/{uuid}/check-out {work_summary, labour_hours, customer_signoff_name, follow_up_required, follow_up_notes, complete_phase, force_phase, log_timesheet}`
- `POST /api/v2/field-service/visits/{uuid}/no-access {reason}`
- `POST /api/v2/field-service/visits/{uuid}/cancel {reason}`
- `POST /api/v2/field-service/visits/{uuid}/log-timesheet`
- `POST /api/v2/field-service/job-phases/{uuid}/checklist/{index} {done*: bool}` — index 0-based
- `POST /api/v2/field-service/job-phases/{uuid}/status {status*: in_progress|blocked|completed, signoff_name}`
- `POST /api/v2/field-service/jobs/{job_uuid}/items {description*, item_type: labour|part|hire|material|expense, quantity, unit_price, tax_rate, visit_uuid, part_uuid, labour_category: engineer_nt|engineer_ot|mate_nt|mate_ot, days, supplier, part_number}`
- `PUT /api/v2/field-service/job-items/{uuid}` / `DELETE /api/v2/field-service/job-items/{uuid}` — own items, not invoiced
- `POST /api/v2/field-service/jobs/{job_uuid}/comments {message*}`
- Lookups: `GET /api/v2/field-service/engineers?search`, `GET /api/v2/field-service/jobs?search&status=open`, `GET /api/v2/field-service/parts?search`
