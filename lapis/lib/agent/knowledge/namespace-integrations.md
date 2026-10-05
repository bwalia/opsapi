---
title: Webhooks & Plugins
pages: /dashboard/namespace/webhooks, /dashboard/namespace/plugins
api: /api/v2/namespace/webhooks, /api/v2/namespace/plugins
modules: webhooks, namespace
tools:
suggestions: Why is my webhook failing? | Pause the ERP webhook | Turn on the Slack plugin for this workspace
readonly: false
---
# Webhooks & Plugins
**Webhooks** send this workspace's events (e.g. invoice.created, invoice.paid, crm deal changes) to your own HTTPS URLs — signed, retried and logged. **Plugins** are installed on the server; each workspace turns them on or off and fills in their settings.

## Using the page
- /dashboard/namespace/webhooks: **Add webhook** opens a form: Endpoint URL *, Description, event picker ("Filter, e.g. invoice or crm"), Active. After creating, the signing secret is shown once. Row icons: **Send a test event**, **Delivery log** (Deliveries modal with a redeliver action), **Edit webhook**, **Rotate signing secret**, **Delete webhook**.
- /dashboard/namespace/plugins: one card per installed plugin with an on/off switch ("Turn on/off <name> for this workspace"), a Settings form with **Save settings**, "Remove the saved value" for secret settings, and its Scheduled jobs.

## Rules
- Webhooks: create and rotate-secret in the page UI, not via chat — they return a signing secret that must never appear in chat. Never repeat secrets.
- URL must be absolute https, public host, no credentials, max 2000 chars. 1-100 events per webhook; you can only pick events whose data you may read; max 25 webhooks per workspace.
- Event names come only from GET .../webhooks/events; never invent them.
- Update is partial: send only url, description, events (full list replaces the old one) or is_active.
- Deliveries are kept 7 days (delivered) / 30 days (failed). Redeliver re-queues one delivery.
- Webhooks need `webhooks` read / create / update / delete; test, redeliver and rotate count as update.
- Plugins: listing needs `namespace` read; changing needs `namespace` update. Turning on fails if a required setting is missing ("<name> needs these settings before it can be turned on").
- Plugin settings are partial: only names sent change; "" or null clears one. Never set a setting with `secret: true` through chat — ask the user to type it into the page. Secret values are never returned (only `is_set`).
- Turning a plugin off hides its pages and its API returns 404 in this workspace.

## API
- `GET /api/v2/namespace/webhooks` — list (uuid, url, description, events, is_active, last_delivery, pending_count, dead_count)
- `GET /api/v2/namespace/webhooks/events` — subscribable events grouped by entity (`allowed` = you may use them)
- `GET /api/v2/namespace/webhooks/{uuid}` — one webhook
- `PUT /api/v2/namespace/webhooks/{uuid} {url, description, events: string[], is_active: bool}` — update
- `DELETE /api/v2/namespace/webhooks/{uuid}` — delete
- `POST /api/v2/namespace/webhooks/{uuid}/test` — send a signed webhook.test ping now (returns delivered, error, response_status)
- `GET /api/v2/namespace/webhooks/{uuid}/deliveries?status=done|dead|pending|running&page&per_page` — delivery log
- `POST /api/v2/namespace/webhooks/{uuid}/deliveries/{delivery_id}/redeliver` — retry one delivery (numeric id)
- `GET /api/v2/namespace/plugins` — plugins with code, name, enabled, settings, jobs
- `PUT /api/v2/namespace/plugins/{code} {enabled: bool, settings: {name: value}}` — turn on/off and/or save non-secret settings
