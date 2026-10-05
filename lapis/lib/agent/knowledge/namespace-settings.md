---
title: Workspace Settings
pages: /dashboard/namespace/settings
api: /api/v2/namespace
modules: namespace
tools:
suggestions: Rename this workspace to Acme Ltd | Update the workspace description | What plan and user limit do we have?
readonly: false
---
# Workspace Settings
Edit the current workspace's profile: name, description, logo, banner and custom domain. Plan, status, max users and max stores are shown read-only ("Managed by your platform administrator").

## Using the page
- Only namespace owners can use this page; others see "Access Restricted — Only namespace owners can change these settings."
- Fields: Namespace Name (required), Slug (read-only), Description, Logo URL, Banner URL, Domain.
- Bottom bar: "You have unsaved changes." with **Reset** and **Save Changes**. Header link **API Keys** goes to /dashboard/namespace/api-keys.

## Rules
- Name is required ("Namespace name is required").
- Only the owner can change slug or domain; for anyone else those fields are ignored. Errors: "Slug is already taken", "Domain is already in use".
- Saving needs `namespace` update.
- Send ONLY the fields listed below — never plan, status, max_users, max_stores, settings or ids. Unknown fields make the save fail.
- Only use GET /api/v2/namespace and PUT /api/v2/namespace on this page; do not call other /api/v2/namespace/* paths here.
- Logo/Banner must be URLs (https://...); the assistant cannot upload images.

## API
- `GET /api/v2/namespace` — current workspace (name, slug, description, logo_url, banner_url, domain, plan, status, max_users, max_stores) plus my membership and permissions
- `PUT /api/v2/namespace {name, description, logo_url, banner_url, domain}` — save (send only changed fields)
