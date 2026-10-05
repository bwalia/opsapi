---
title: Workspace & Members
pages: /dashboard/namespace, /dashboard/namespace/members
api: /api/v2/namespace/members, /api/v2/namespace/invitations, /api/v2/namespace/roles, /api/v2/namespace/stats, /api/v2/user/namespace-settings
modules: users, roles, namespace
tools: invite_member
suggestions: Invite priya@acme.com as an admin | Who are the members here? | Show pending invitations
readonly: false
---
# Workspace & Members
A namespace (workspace) is your tenant: its members, roles and data are isolated from other workspaces. The overview page shows the workspace's details and counts; the Members page manages who belongs and with which roles.

## Using the page
- /dashboard/namespace (overview): stat cards (Members, Stores, Products, Orders); **Set as Default** (which workspace opens at login); **Settings** (owner only); quick links Manage Members, Roles & Permissions, API Keys, Activity, Settings; Namespace Information (Name, Slug, Description, Plan, Status, Created, Custom Domain); "Your Other Namespaces" with a star to set the default.
- /dashboard/namespace/members ("Namespace Members"): "Search members..." box; table with roles (Owner badge), status (active / invited / suspended); row icons **Edit roles** and **Remove member** (not on the owner). **Invite Member** (shown to owner or `users` manage) opens "Invite New Member": Email, Assign Role (or Default Role), **Send Invitation** — this adds an EXISTING account by email; someone without an account needs an invitation.

## Rules
- To bring in someone new, create an invitation (invite_member tool or POST /api/v2/namespace/invitations). It stays pending for 7 days (expires_in_days) and the person accepts it after signing in with that email. Errors: "User is already a member of this namespace", "An invitation is already pending for this email".
- Member cap: active members + pending invitations cannot exceed the plan's max users ("Namespace has reached maximum member limit").
- `role_id` / `role_ids` must be ids from GET /api/v2/namespace/roles. `role_ids` on PUT REPLACES all the member's roles. With no role, the default role is assigned.
- Member `{id}` accepts the member uuid (or numeric id) — not the user uuid.
- You cannot remove yourself. Only pending invitations can be revoked; only pending or expired ones can be resent (resets the 7-day expiry).
- Permissions: view `users` read; invite/add/resend `users` create; change roles/status `users` update; remove/revoke `users` delete.
- Set as Default affects only the current user.

## API
- `GET /api/v2/namespace/stats` — counts for the overview
- `GET /api/v2/namespace/members?search&status=active|invited|suspended&role_id&page&per_page` — members (`uuid` = member uuid, user_uuid, email, roles)
- `GET /api/v2/namespace/members/{member_uuid}` — one member
- `POST /api/v2/namespace/members {email* (or user_id), role_ids: number[]}` — add an existing account
- `PUT /api/v2/namespace/members/{member_uuid} {role_ids: number[], status: active|suspended}` — change roles / suspend
- `DELETE /api/v2/namespace/members/{member_uuid}` — remove from workspace (login kept)
- `GET /api/v2/namespace/invitations?status=pending|accepted|expired|revoked&search&page&per_page` — invitations
- `POST /api/v2/namespace/invitations {email*, role_id: number, message, expires_in_days: number}` — invite by email
- `POST /api/v2/namespace/invitations/{uuid}/resend` — resend
- `DELETE /api/v2/namespace/invitations/{uuid}` — revoke a pending invitation
- `GET /api/v2/namespace/roles` — roles (id, role_name, display_name)
- `GET /api/v2/user/namespace-settings` — my default workspace
- `PUT /api/v2/user/namespace-settings {default_namespace_id*: id or uuid}` — Set as Default (must be a member)
