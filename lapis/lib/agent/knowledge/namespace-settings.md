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
- **Sign-in code (MFA)** card: a switch, on by default. On = everyone in this workspace enters a 6-digit code from their email after their password. It saves at once (turning it off asks to confirm) and only the owner can change it. Even when it's off, someone who also belongs to another workspace that asks for a code still gets one, and platform administrators always do.

## Rules
- Name is required ("Namespace name is required").
- Only the owner can change slug or domain; for anyone else those fields are ignored. Errors: "Slug is already taken", "Domain is already in use".
- Saving needs `namespace` update.
- Send ONLY the fields listed below. Anything else (plan, status, limits, settings, owner, ids, MFA) is refused with 403 and nothing is saved: plan, status and limits are the platform administrator's.
- Only use GET /api/v2/namespace and PUT /api/v2/namespace on this page; do not call other /api/v2/namespace/* paths here.
- Logo/Banner must be URLs (https://...); the assistant cannot upload images.
- Never change the sign-in code (MFA) setting yourself: explain it and point to the switch on this page.

## API
- `GET /api/v2/namespace` — current workspace (name, slug, description, logo_url, banner_url, domain, plan, status, max_users, max_stores) plus my membership and permissions
- `PUT /api/v2/namespace {name, description, logo_url, banner_url, business_type, domain}` — save (send only changed fields; domain and slug: owner only)
