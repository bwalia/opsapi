---
title: Timesheets
pages: /dashboard/timesheets
api: /api/v2/timesheets, /api/v2/invoices/from-timesheet
modules: timesheets, timesheet_approvals, invoices
tools: create_timesheet, list_timesheets
suggestions: Log 7.5 hours today | Show my draft timesheets | What's waiting in the approval queue?
readonly: false
---
# Timesheets
Log work time and send it for approval. A timesheet is a container (usually one work date, optional customer and project task); its hours are the SUM of its entries. Status flow: draft -> submitted -> approved or rejected; a rejected one can be reopened to draft. Approved billable hours can be turned into an invoice.

## Using the page
- Header: **Refresh**, **Create Timesheet** (modal "Log Work / New Timesheet": Customer / Client, Task (from a project), Work date, Start time, End time, Billable to client, Hourly rate (optional), Notes (optional)). Worked hours are computed from start/end time.
- Stat cards: Total Hours, Billable Hours, Pending Approval, Approved.
- Tabs: **My Timesheets** (status filter: All Status, Draft, Submitted, Approved, Rejected) and **Approval Queue** (all submitted timesheets, with Approve / Reject / View Details icons).
- Click a row (or View) to open /dashboard/timesheets/{uuid}. Actions there depend on status:
  - Draft: **Add Entry** (Date, Hours, Description, Project Reference, Category, Billable), edit/delete entry icons, **Submit for Approval**, **Delete**.
  - Submitted: **Approve**, **Reject** (asks "Reason for Rejection").
  - Approved: **Generate Invoice** (creates a draft invoice from billable hours).
  - Rejected: shows the Rejection Reason and **Reopen**.

## Rules
- To log "N hours" use the create_timesheet tool (it takes hours). With call_api, POST /api/v2/timesheets computes hours only from start_time/end_time; without times it creates a 0-hour draft — then add an entry.
- Only draft timesheets can be updated, deleted, or have entries added/changed/removed.
- You can only submit your own timesheets; only a draft can be submitted.
- Approve/Reject need `timesheet_approvals` approve/reject (or manage) and only work on submitted timesheets. Reject requires a reason.
- Only rejected timesheets can be reopened.
- Entry hours must be between 0 and 24.
- Seeing other people's timesheets (`all=true`, summary for another user) needs `timesheet_approvals` read or `timesheets` manage.
- Generate Invoice needs `invoices` create, an approved timesheet, and un-invoiced billable entries.
- Resolve customer/task names to uuids with the lookup endpoints first; never invent uuids.

## API
- `GET /api/v2/timesheets?page&per_page&status=draft|submitted|approved|rejected` — my timesheets
- `GET /api/v2/timesheets?all=true&status&user_uuid&period_start&period_end&page&per_page` — everyone's (approvers)
- `GET /api/v2/timesheets/summary?start_date&end_date&user_uuid` — totals and counts by status (dates YYYY-MM-DD)
- `GET /api/v2/timesheets/approval-queue?page&per_page` — submitted timesheets
- `GET /api/v2/timesheets/lookups/customers?q=` — customers (uuid, first_name, last_name, email)
- `GET /api/v2/timesheets/lookups/tasks?q=` — project tasks (task_uuid, title, project_name, customer_uuid)
- `GET /api/v2/timesheets/{uuid}` — one timesheet with entries
- `POST /api/v2/timesheets {work_date*: YYYY-MM-DD, start_time: HH:MM, end_time: HH:MM, customer_uuid, task_uuid, task, is_billable: bool (default true), hourly_rate: number, notes}` — create a draft (work_date or period_start is required)
- `PUT /api/v2/timesheets/{uuid} {same fields}` — update a draft
- `DELETE /api/v2/timesheets/{uuid}` — delete a draft
- `POST /api/v2/timesheets/{uuid}/submit` — submit for approval
- `POST /api/v2/timesheets/{uuid}/approve {comments}` — approve
- `POST /api/v2/timesheets/{uuid}/reject {reason*, comments}` — reject
- `POST /api/v2/timesheets/{uuid}/reopen` — rejected -> draft
- `GET /api/v2/timesheets/{uuid}/entries` — list entries
- `POST /api/v2/timesheets/{uuid}/entries {entry_date*: YYYY-MM-DD, hours*: number, description*, project_reference, category, is_billable: bool}` — add entry (draft only)
- `PUT /api/v2/timesheets/entries/{entry_uuid} {entry_date, hours, description, project_reference, category, is_billable}` — update entry
- `DELETE /api/v2/timesheets/entries/{entry_uuid}` — delete entry
- `POST /api/v2/invoices/from-timesheet {timesheet_uuid*, hourly_rate, due_date: YYYY-MM-DD, currency}` — Generate Invoice
