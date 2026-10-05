---
title: Audit Logs
pages: /dashboard/reports
api: /api/v2/namespace/audit-logs
modules: namespace, reports
tools:
suggestions: What changed in this workspace this week? | Who changed role permissions recently? | Show plugin changes this month
readonly: true
---
# Audit Logs
The Reports page is the workspace audit trail: who changed what in roles, members, workspace settings and plugins, with before/after values. It is read-only.

## Using the page
- Filters: Entity Type (All Entities, Members, Roles, Namespace), Action (Member Added, Member Role Changed, Member Removed, Role Created, Role Permissions Updated, Role Deleted, Namespace Updated, Ownership Transferred), From and To dates. Changing a filter goes back to page 1.
- Table: Time, User, Action, Entity, Changes (names of the fields that changed). Click a row to expand Previous Values / New Values. 20 rows per page.
- Shown to workspace owners and users with reports or namespace read permission; the API itself needs namespace read.

## Rules
- Nothing can be changed here — only read and summarise.
- Dates filter on created_at. `to_date=YYYY-MM-DD` stops at 00:00 that day, so pass the next day to include a whole day.
- action values: member.added, member.role_changed, member.removed, role.created, role.permissions_updated, role.deleted, namespace.updated, namespace.ownership_transferred, plugin.enabled, plugin.disabled, plugin.settings_updated. entity_type values: namespace_member, namespace_role, namespace, plugin.
- Results are newest first and include user_email, user_first_name, user_last_name, old_values, new_values. Answer in plain words (who, what, when) — don't dump raw JSON.

## API
- `GET /api/v2/namespace/audit-logs?page&per_page (default 50, max 500)&entity_type&action&from_date=YYYY-MM-DD&to_date=YYYY-MM-DD` — list audit entries
