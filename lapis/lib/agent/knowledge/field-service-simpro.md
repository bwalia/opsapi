---
title: Simpro Sync
pages: /dashboard/field-service/simpro
api: /api/v2/field-service/simpro/status, /api/v2/field-service/simpro/log
modules: simpro_sync
tools:
suggestions: Is the Simpro connection healthy? | How many records are waiting to push? | Show sync errors from the last run
readonly: true
---
# Simpro Sync
Simpro is the system of record. OpsAPI pulls customers, sites, assets and jobs from it and pushes back what changes here (local edits are marked "pending" until pushed). This page shows the connection, per-entity sync counts and the sync log. The assistant only reads it — never runs a test, pull or push.

## Using the page
- Header buttons (only with simpro_sync manage, the Owner by default): **Test** checks the Simpro build answers, **Pull** imports from Simpro, **Push** sends pending records (disabled when push is off for the connection). Tell the user to click these themselves.
- **Connection** card: Build, Mode, Company ID, Pull / push enabled, Last pull, Last push. "No Simpro connection is configured" means nothing is set up yet.
- **Records** table per entity (customers, sites, assets, jobs, quotes, invoices, asset tests): In Simpro (synced), To push (pending), Errors, OpsAPI only (local_only), Total.
- **Sync log**: outcome filter (All outcomes, OK, Conflicts, Errors, Skipped); columns When, Direction (pull/push), Entity, Simpro ID, Operation, Outcome, Detail.

## Rules
- Reading needs simpro_sync read; Test / Pull / Push and changing the connection need simpro_sync manage, because a push writes to the customer's Simpro.
- To explain an error, read the log entry's error_message and http_status, and suggest fixing the record in OpsAPI and pushing again.

## API
- `GET /api/v2/field-service/simpro/status` — connection, per-entity counts (synced, pending, errored, local_only), recent activity
- `GET /api/v2/field-service/simpro/log?status=ok|conflict|error|skipped&entity_type=customer|site|asset|job&batch_uuid&page&per_page` — newest first
