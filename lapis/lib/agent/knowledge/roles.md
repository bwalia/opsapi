---
title: Roles & Permissions
pages: /dashboard/roles, /dashboard/namespace/roles
api: /api/v2/namespace/roles
modules: roles
tools:
suggestions: What can the member role do? | Create a "viewer" role with read on CRM | Give the manager role invoices manage
readonly: false
---
# Roles & Permissions
Workspace roles and what each may do. A role's permissions map module machine names to actions; members get the union of their roles' permissions. Every workspace has system roles owner (full access, cannot be changed), admin and member (the default for new members).

## Using the page
- /dashboard/roles: **Add Role** opens "Create New Role" (Role Name, Description; the name is saved lower-case with underscores). Row icons: **Edit Permissions** / **Edit Role** open "Edit Role Permissions" — a module x action grid; **Delete Role** (not shown for system roles).
- /dashboard/namespace/roles: role cards with member counts and System/Default badges. **Create Role** / **Edit role** modal: Role name, Display Name, Description, Landing page after login (e.g. /dashboard), Default role for new members, and a Permissions grid. **Delete role** asks for confirmation.
- Assign roles to people on Users or Namespace -> Members, not here.

## Rules
- `role_name` is required and unique in the workspace ("Role name already exists in this namespace"); system roles' role_name cannot change.
- Owner role permissions are immutable. System roles (owner, admin, member) cannot be deleted.
- A role assigned to any member cannot be deleted ("Remove role from all members first").
- `permissions` REPLACES the whole map on update: GET the role first, merge your change, then PUT the full object.
- Module names must be active modules (GET .../meta/permissions); unknown module -> error. Actions: create, read, update, delete, manage (manage = all actions); access, reply, deploy exist for specific modules.
- Setting `is_default: true` unsets the default flag on every other role.
- Needs `roles` read / create / update / delete for the matching action.

## API
- `GET /api/v2/namespace/roles` — all roles with member counts (id, uuid, role_name, display_name, permissions, is_system, is_default)
- `GET /api/v2/namespace/roles/meta/permissions` — modules enabled here and the valid actions
- `GET /api/v2/namespace/roles/{uuid}` — one role plus up to 10 of its members (numeric id also accepted)
- `POST /api/v2/namespace/roles {role_name*, display_name, description, permissions: {module: [actions]}, is_default: bool, priority: int, landing_path: "/dashboard/..."}` — create
- `PUT /api/v2/namespace/roles/{uuid} {display_name, description, permissions, is_default, priority, landing_path}` — update (send only these fields)
- `DELETE /api/v2/namespace/roles/{uuid}` — delete an unused non-system role

Example permissions: `{"customers": ["read","create"], "invoices": ["manage"]}`
