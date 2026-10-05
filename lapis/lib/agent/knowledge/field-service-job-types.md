---
title: Job Types
pages: /dashboard/field-service/job-types
api: /api/v2/field-service/job-types, /api/v2/field-service/phase-templates
modules: fs_job_types
tools:
suggestions: Create a Boiler installation job type with 5 phases | Add a Commission phase with a checklist | Set the default hourly rate to 65
readonly: false
---
# Job Types
A job type is a template for a kind of job: name, colour, default hourly rate and an ordered list of phase templates (each with a checklist, estimated hours, "requires a site visit" and "requires customer sign-off"). When a job is created with a type, its phases are copied from these templates.

## Using the page
- **New job type**: Name*, Description, Default hourly rate, Colour, "Phases (one per line, optional)".
- Select a type on the left to edit it. **Details** card: Name*, Default hourly rate, Colour, Description, "Active (offered when creating jobs)" → **Save details**; **Delete** removes the type. Shows how many jobs use it.
- **Phase templates** card: **Add phase** (Name*, Description, Estimated hours, Requires a site visit, Requires customer sign-off, Checklist one item per line), Move up / Move down, Edit, Remove.

## Rules
- Changes apply to new jobs only — existing jobs keep the phases they were created with.
- name is required (create and edit). Inactive types are hidden from the new-job picker.
- Deleting a job type is a soft delete; jobs keep their phases and lose the type label.
- Create needs fs_job_types create; edits and all phase-template changes need update; deleting the type needs delete. Listing is also allowed with fs_jobs read.
- requires_visit defaults true, requires_signoff false. Checklist is a list of item labels.

## API
- `GET /api/v2/field-service/job-types?include_inactive=true&with_phases=true`
- `GET /api/v2/field-service/job-types/{uuid}` — with phase templates
- `POST /api/v2/field-service/job-types {name*, description, color: #rrggbb, default_hourly_rate, is_active (default true), phases: ["Survey", "Install", ...] or [{name, description, estimated_hours, requires_visit, requires_signoff, checklist: [label,...]}]}`
- `PUT /api/v2/field-service/job-types/{uuid} {name, description, color, default_hourly_rate, is_active}`
- `DELETE /api/v2/field-service/job-types/{uuid}`
- `POST /api/v2/field-service/job-types/{uuid}/phases {name*, description, estimated_hours, requires_visit, requires_signoff, checklist: [label,...], sort_order}` — appended at the end by default
- `PUT /api/v2/field-service/job-types/{uuid}/phases/reorder {order*: [template uuid,...]}`
- `PUT /api/v2/field-service/phase-templates/{uuid} {name, description, estimated_hours, requires_visit, requires_signoff, checklist}`
- `DELETE /api/v2/field-service/phase-templates/{uuid}`
