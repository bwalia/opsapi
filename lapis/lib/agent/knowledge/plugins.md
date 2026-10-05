---
title: Plugins
pages: /dashboard/plugins
api:
modules:
tools:
suggestions: What is this page for? | How do I turn a plugin on or off? | Why can't I see this plugin page?
readonly: true
---
# Plugins
Pages under /dashboard/plugins/{plugin}/{page} come from plugins — add-on projects installed on this server, not built into OpsAPI. Each plugin adds its own sidebar entries. A plugin page is either a generic list + form for one of the plugin's record types, or the plugin's own custom screen shown in a secure embedded frame.

## Using the page
- List pages: the title is the record type, the subtitle the plugin name. "New <item>" (if your role may create), a search box and filters (if the plugin defines them), a sortable table with pages, and per-row Edit (pencil) and Delete (trash, asks to confirm). Form fields, required flags and options come from the plugin.
- Custom pages: work inside the embedded screen; it acts as you and can only reach the plugin's own API.
- Turning a plugin on or off for this workspace, filling in its settings (URLs, API keys…) and seeing its scheduled jobs: a workspace admin does this in My Workspace → Plugins (/dashboard/namespace/plugins). Jobs don't run while a plugin is off.

## Troubleshooting
- "You don't have access to this page": your role lacks read on the plugin's module — ask a workspace admin to grant it in Roles.
- "This page isn't available": the plugin isn't installed on this server, is turned off for this workspace, or no longer offers this page.
- "Couldn't load this page": a server or connection problem — Try again.
- No New / Edit / Delete buttons: your role lacks create / update / delete on the plugin's module.

## Rules
- The assistant cannot read or change plugin records here — explain the page and guide the user to its buttons.
- Plugins are installed by the server operator; a workspace can only turn installed plugins on or off.
