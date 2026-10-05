---
title: Employees
pages: /dashboard/employees, /dashboard/field-service/employees
api: /api/v2/employees, /api/v2/namespace/roles
modules: employees, users
tools: list_employees, add_team_member
suggestions: List our active engineers | Add Sam Patel (sam@acme.com) as a member | Set Jo's job title to Site Lead
readonly: false
---
# Employees
The staff directory: an employee profile (job title, code, phone, region, skills, cost rate, engineer flag) linked to a workspace login. Removing an employee deletes only the profile; their login and workspace membership are untouched. The old /dashboard/field-service/employees page redirects here.

## Using the page
- Header button depends on permissions: **Add team member** (needs `users` create) creates a login + membership + role in one step; otherwise **Add employee** (needs `employees` create) links a profile to someone already in the workspace.
- Filters: search box ("Search name, email, job title, code…"), Everyone / Engineers only, Active & inactive / Active only / Inactive only.
- Row icons: **Edit employee** (pencil) and **Remove employee** (confirm dialog "Remove").
- Add team member modal: First name *, Last name, Email *, Role (this workspace's roles, not owner), Phone, Job title, Field engineer toggle (then F-Gas certificate no., Hourly cost rate, Skills). On success it shows the sign-in email and a **Temporary password** to hand over (copy button), then **Done**.
- Add/Edit employee modal: Workspace member * (only when adding), Job title, Employee code, Phone, Email, Region / team, F-Gas certificate no., Hourly cost rate, Skills (comma-separated), Engineer, Active.

## Rules
- Adding a person with a login: prefer the add_team_member tool (role defaults to "member"). It does not return the temporary password — if the user needs it, tell them to use **Add team member** on this page instead.
- `role_name` must be an existing workspace role (GET /api/v2/namespace/roles); errors: "Someone with this email already has a login", "That role does not exist in this workspace".
- Add employee (link) needs `user_uuid` of an active workspace member (from /candidates); one profile per user ("This user already has an employee profile").
- Edit needs `employees` update; remove needs `employees` delete. Listing is allowed with `employees` read (or field-service job/visit read).
- Look up the employee uuid with the list endpoint before updating or removing.

## API
- `GET /api/v2/employees?search&is_engineer=true|false&is_active=true|false&page&per_page` — list (fields: uuid, user_uuid, user_name, user_email, job_title, is_engineer, is_active…)
- `GET /api/v2/employees/candidates?search` — active workspace members (uuid, email, name, role) for linking
- `GET /api/v2/employees/{uuid}` — one employee
- `POST /api/v2/employees {user_uuid*, job_title, employee_code, phone, email, region, skills: string[] or comma string, hourly_cost_rate: number, fgas_certificate_no, is_engineer: bool, is_active: bool}` — add employee profile for an existing member
- `PUT /api/v2/employees/{uuid} {same fields except user_uuid}` — update (send only changed fields)
- `DELETE /api/v2/employees/{uuid}` — remove profile (login kept)
- `GET /api/v2/namespace/roles` — workspace roles (role_name) for add_team_member
