---
title: All Namespaces
pages: /dashboard/namespaces
api: /api/v2/admin/namespaces
modules:
tools:
suggestions: How many workspaces are suspended? | Show the stats for this workspace | List the roles in this workspace
readonly: true
---
# All Namespaces
Platform-admin view of every workspace (namespace / tenant) on this server. Only users with the platform "administrative" role can use it; everyone else sees "Access Restricted". The assistant is read-only here.

## Using the page
- Stat cards: Total Namespaces, Active, Pending, Suspended. Search box and status filter (All Statuses, Active, Pending, Suspended, Archived).
- Table: Namespace, Status, Plan, Members, Stores, Created. Row menu: View Details, Edit Namespace, Archive Namespace. Create Namespace button in the header.
- Details (/dashboard/namespaces/{uuid}): header with Edit and API keys, stats, members, settings and activity cards.
- Edit (/dashboard/namespaces/{uuid}/edit): Routing (Default landing page after login) and Plan & Limits (Status, Plan, Max Users, Max Stores) → Reset / Save.
- Members (/dashboard/namespaces/{uuid}/members): members and pending invitations.
- Creating, editing, archiving, transferring ownership and changing members: the user does these with the page buttons.

## API (read-only)
- `GET /api/v2/admin/namespaces?page&per_page&search&status=active|pending|suspended|archived&order_by=name|slug|status|plan|created_at|updated_at&order_dir=asc|desc` — all workspaces
- `GET /api/v2/admin/namespaces/{id}` — one workspace incl. member_count ({id} = uuid from the URL, or numeric id)
- `GET /api/v2/admin/namespaces/{id}/stats` — total_members, total_stores, total_products, total_orders, total_customers, total_revenue
- `GET /api/v2/admin/namespaces/{id}/roles` — roles with member counts
- `GET /api/v2/admin/namespaces/{id}/invitations?status&search` — invitations
