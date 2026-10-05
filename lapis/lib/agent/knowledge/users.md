---
title: Users
pages: /dashboard/users
api: /api/v2/users, /api/v2/namespace/members, /api/v2/namespace/roles
modules: users, roles
tools: invite_member, add_team_member
suggestions: Who are the users in this workspace? | Change Alex's role to admin | Deactivate jo@acme.com
readonly: false
---
# Users
The people with a login in this workspace (its active members) and their workspace roles. Accounts are global — one person can belong to several workspaces — so this workspace can only fully edit people who belong to no other workspace.

## Using the page
- Header: **Add User** (needs `users` create) opens "Add New User": First Name, Last Name, Email, Username, Role, Password (12+ chars with upper, lower and a number), Phone Number, Address.
- "Search users..." filters the current page; columns are sortable.
- Row icons: **Change role** (pick workspace roles), **Edit profile**, **Delete** (confirm "Delete User").
- Click a row to open /dashboard/users/{uuid} (User Details: profile, workspace roles with **Manage**, namespaces). **Edit** goes to /dashboard/users/{uuid}/edit: First Name, Last Name, Email Address, Username, Phone Number, Address, Account Active.

## Rules
- The assistant cannot set passwords. To add someone, use invite_member (pending invitation they accept after signing in with that email) or add_team_member (creates the login now; its temporary password is only shown when done via Employees -> Add team member).
- `:id` in /api/v2/users/{id} is the user's uuid. Changing roles uses the member uuid (`member_uuid` in the list), not the user uuid.
- `role_ids` REPLACES all the member's roles — include every role they should keep. Get ids from GET /api/v2/namespace/roles.
- Changing email, username or active status, or deleting the account, is refused (403) if the person also belongs to another workspace — then remove them from this workspace instead (DELETE member).
- You cannot delete your own account. Delete is permanent; removing the membership is usually what's wanted.
- Permissions: list/view `users` read, edit/change role `users` update, delete `users` delete.

## API
- `GET /api/v2/users?page&per_page&order_by=id|first_name|last_name|email|username|active|created_at|updated_at&order_dir=asc|desc` — workspace users with roles and member_uuid
- `GET /api/v2/namespace/members?search&status=active|suspended&role_id&page&per_page` — find a member by name/email (`uuid` = member uuid, `user_uuid` = user)
- `GET /api/v2/users/{uuid}?detailed=true` — one user with details
- `PUT /api/v2/users/{uuid} {first_name, last_name, email, username, phone_no, address, active: bool}` — edit profile (send only changed fields)
- `DELETE /api/v2/users/{uuid}` — delete the account
- `GET /api/v2/namespace/roles` — roles (id, role_name, display_name)
- `PUT /api/v2/namespace/members/{member_uuid} {role_ids*: number[]}` — set the member's roles
- `DELETE /api/v2/namespace/members/{member_uuid}` — remove from this workspace (login kept)
