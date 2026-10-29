---
title: Apps
pages: /dashboard/apps
api: /api/v2/system/info
modules: dashboard
tools:
suggestions: Which apps does this server run? | Is invoicing available here? | Which apps are plugins?
readonly: true
---
# Apps
The Apps page is a catalog of every OpsAPI module: one tile per app, showing whether this server runs it, what it contains, and a link to open it. It is read-only.

## Using the page
- Filter: All, Deployed, Not deployed. Search matches app names, descriptions and module names.
- Each tile: name, a Deployed / Not deployed badge, a Plugin badge for plugin projects, the app's modules, and Open (links to its page when you can see it in the sidebar).
- The header says how many apps this server runs and its PROJECT_CODE. API docs opens the in-app API reference.

## Rules
- "Not deployed" means this server's PROJECT_CODE leaves the app out: its pages and API don't exist here for anyone. It can't be turned on from the dashboard; it needs a deployment with a PROJECT_CODE that includes it.
- Deployed but no Open link usually means your role has no access to it, or it is a platform service with no pages of its own (navigation, notifications, reviews, vault, bank transactions).
- Plugins are always deployed when installed; a workspace can still switch a plugin off under Plugins.

## API
- `GET /api/v2/system/info` — project_code, enabled_features, and apps: [{ feature, enabled, plugin, modules: [{ machine_name, name, description, category }] }]
