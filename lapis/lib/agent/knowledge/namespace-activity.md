---
title: Workspace Activity
pages: /dashboard/namespace/activity
api: /api/v2/namespace/activity
modules: activity
tools:
suggestions: Who hasn't signed in this month? | What did Sam change in the last 7 days? | Show failed requests from today
readonly: true
---
# Workspace Activity
Who signed in and what they did in this workspace, for owners/admins (needs `activity` read). Read-only: nothing here can be changed. Request logs are kept for a limited retention window (default 90 days).

## Using the page
- Tabs: **Overview**, **Members**, **Activity log**, **Audit trail**.
- Overview: range Last 7 / 30 / 90 days; charts "Active members per day", "Changes and failed requests per day"; lists "Most used areas", "Most active members".
- Members: "Search by name or email", sort by last login or name; shows last sign-in, sign-in count, failed sign-ins (warning badge), last active, changes and requests in the last 30 days.
- Activity log: range Last 24 hours / 7 / 30 / 90 days; filter Everything / Changes / Failed; member picker ("All members").
- Audit trail: record changes (Created / Updated / Deleted) with fields before -> after; filter All / Created / Updated / Deleted and by member; "Show this record's full history" per row.

## Rules
- GET only. Resolve a person's name to user_uuid with the members endpoint first.
- `days` is clamped to 1..retention. `limit` max 200 (default 50); `per_page` max 100 (default 25).
- Log and audit trail are newest first and keyset-paginated: pass the previous response's meta.next_cursor as `cursor` for the next page.
- `area` is the first part of an action name (e.g. invoices, crm). `kind=changes` = non-GET requests; `kind=errors` = HTTP status >= 400.
- `entity` is an audited record type like invoice or crm.deal; `entity_id` narrows to one record.

## API
- `GET /api/v2/namespace/activity/summary?days=30` — totals, per-day series, top areas, top members
- `GET /api/v2/namespace/activity/members?search&sort=last_login|name&page&per_page` — members with sign-in stats (user_uuid, email, name, last_login_at, login_count, failed_login_count, last_active_at)
- `GET /api/v2/namespace/activity?days=7&user_uuid&area&kind=changes|errors&cursor&limit` — request log
- `GET /api/v2/namespace/activity/changes?days=30&user_uuid&entity&entity_id&action=created|updated|deleted&cursor&limit` — audit trail of record changes
