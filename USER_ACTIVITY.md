# User activity & login tracking

OpsAPI records who signed in, when, from where, and what they did, plus an audit trail of which records each person created, changed or deleted, field by field. Platform admins see it in Grafana (**OpsAPI · User Activity**). Workspace admins see their own workspace's slice in the dashboard, under **Activity**.

## What is recorded

| Data | Where | Kept |
|---|---|---|
| Sign-ins and security events: login success and failure (password, Google, OAuth), 2FA challenge, token refresh, logout, password reset request / reset / change, account deactivation. Each has method, reason, client IP, browser and request id. | `auth_events` | 365 days |
| Per user: last login (time, IP, method, browser), login count, failed logins since the last success, last seen. | `user_login_stats` (1:1 with `users`) | while the account exists |
| What signed-in users did: route pattern (`/api/v2/invoices/:id`), action (`invoices.update`), record id, status, duration, workspace, IP, browser, request id. | `user_activity` (partitioned by month) | 90 days |
| Per workspace, day, member and action: changes, requests, failed requests, last time. Feeds the in-app Activity page. | `user_activity_daily` | 90 days |
| Record changes (audit trail): which record was created, updated or deleted, by whom, and the fields before and after. See [Audit trail](#audit-trail-record-changes). | `audit_events` | 365 days |
| Counts only: auth events, active users, pipeline health. | Prometheus (`/metrics`) | your Prometheus retention |

- **Changes vs reads.** Every change (POST / PUT / PATCH / DELETE) is its own row. Identical reads (same user, route, record and status) within a minute are merged into one row with a `hits` count, so background polling doesn't flood the table.
- **Never recorded:** request or response bodies, query strings, tokens, passwords, or `Authorization` headers.
- **Not tracked:** anonymous and public requests, health and metrics endpoints, and `/auth/*`, which is covered by `auth_events` instead.
- **No personal data in `/metrics`.** User ids never appear as Prometheus labels. That would multiply time series without bound and publish personal data to anything that can scrape `/metrics`.

## How it works

- **Capture.** Activity is captured in nginx's log phase, *after* the response has been sent. It's buffered per worker and written to Postgres in batches every 2 seconds, so it adds no latency to requests and can never fail one.
- **Daily counters.** The same statement that writes activity rows also adds them to `user_activity_daily`, so the counters can't drift from the rows. The Activity page reads these counters instead of scanning months of raw rows.
- **Failures.** If the database is unavailable, a batch is retried 3 times, then dropped and counted in `opsapi_activity_dropped_total`. Buffers are bounded, so memory never grows.
- **Sign-in events.** These are written immediately; they're low-volume and matter for security. Rate-limited login floods are only counted in Prometheus, not stored one row per request.
- **Maintenance.** An hourly job, run by one pod at a time:
  - creates next months' partitions;
  - drops partitions past `OPSAPI_ACTIVITY_RETENTION_DAYS`;
  - deletes auth events past `OPSAPI_AUTH_EVENTS_RETENTION_DAYS`.

  Whole partitions are dropped, so there are no expensive row-by-row deletes.

## In the dashboard (workspace admins)

**Activity** in the sidebar (`/dashboard/namespace/activity`) needs the `activity` permission (`read`). Owners and admins get it by default; give it to other roles under **Roles**. It always shows the current workspace only.

- **Overview.** Active members, changes and failed requests for the last 7, 30 or 90 days, as totals and per-day charts. Also the most used areas and the most active members.
- **Members.** Each member's last sign-in (time, method, count), last activity in this workspace, the last 30 days' usage, and failed sign-ins since their last success. Click a member to see their activity log.
- **Activity log.** Every change, and merged reads, newest first. Filter by member, area, changes-only or failed-only, and time range. It shows the route, record id, result, duration, browser and IP.
- **Audit trail.** Record changes, newest first: who, which record, and each changed field as old → new. Filter by member, record type, created / updated / deleted, and time range. Click a record id to see that record's whole history.

Deliberately left out: sign-in IP addresses and the login history. A sign-in isn't tied to one workspace and a person can belong to several, so those stay with platform admins in Grafana.

API (the same `activity.read` check):

```
GET /api/v2/namespace/activity/summary?days=30
GET /api/v2/namespace/activity/members?search=&sort=last_login|name&page=&per_page=
GET /api/v2/namespace/activity?days=7&user_uuid=&area=&kind=changes|errors&limit=50&cursor=
GET /api/v2/namespace/activity/changes?days=30&user_uuid=&entity=&entity_id=&action=created|updated|deleted&limit=50&cursor=
```

The log and the audit trail use cursor paging: pass `meta.next_cursor` as `cursor` to get the next page. Deep pages cost the same as the first. The first page of `/changes` also returns `meta.entities`, the record types that are audited.

## Audit trail: record changes

The activity log says *that* someone called `PUT /api/v2/invoices/:id`. The audit trail says *what changed*: `status: draft → sent`, `total: 120.00 → 150.00`.

**What's audited.** Every table that feeds the event outbox (helper/plugin-events.lua):

- **Core:** customers, employees, invoices and payments, orders, timesheets, workspace members, CRM (accounts, contacts, deals, leads, activities), field-service jobs and visits, kanban projects and tasks, helpdesk tickets.
- **Plugins:** every table a plugin lists in `publishes`, and every `sdk.emit` event, recorded as the event and its data.

`opsapi events` lists them all.

**How it works.**

- **Written by the database.** The table trigger that feeds plugin events also writes the `audit_events` row, in the same transaction as the change. So a change made through any API, a plugin, a background job or plain SQL is recorded, and a rolled-back change leaves nothing behind. There are no delivery rows or timers for it.
- **Updates store only the fields that changed**, before and after. Creates store the new record, deletes the old one.
- **Who did it.** Every database connection a request uses is told who is acting (session settings `opsapi.actor_*`, set by helper/request-context.lua): the user, whether it was a dashboard session or an API key, the client IP, and the request id. Background jobs and `lapis migrate` record **System**; public (signed-out) forms record **Public**. The request id matches the activity log, so you can join "what they called" to "what changed".
- **Secrets are never stored.** Fields a source hides from events are left out, and so is any field whose name contains `password`, `passwd`, `secret`, `token`, `pin_hash`, `api_key` or `private_key`.
- **Retention.** The hourly event-purge job deletes rows older than `OPSAPI_AUDIT_RETENTION_DAYS`, in batches.

**Configuration.**

| Variable | Default | |
|---|---|---|
| `OPSAPI_AUDIT_ENABLED` | `true` | `false` stops recording at the next `lapis migrate`. Existing rows are kept until retention. |
| `OPSAPI_AUDIT_RETENTION_DAYS` | `365` | Minimum 30. |

**Cost.** One extra row per changed record, written by the trigger that already runs for plugin events. Updates that change nothing that's tracked are skipped. Reads are indexed per workspace and time.

## Configuration

| Variable | Default | |
|---|---|---|
| `OPSAPI_ACTIVITY_ENABLED` | `true` | `false` stops recording. Metrics still count. |
| `OPSAPI_ACTIVITY_RETENTION_DAYS` | `90` | Minimum 7. |
| `OPSAPI_AUTH_EVENTS_RETENTION_DAYS` | `365` | Minimum 30. |
| `OPSAPI_ACTIVITY_EXCLUDE` | — | Extra comma-separated Lua URI patterns not to record, e.g. `^/api/v2/kanban/timer`. |
| `OPSAPI_TRUSTED_PROXIES` | — | Comma-separated IPv4 CIDRs of public proxies or CDN in front of OpsAPI (see below). |

**Client IP.** `X-Forwarded-For` is only believed from trusted proxies. The trusted set is private, loopback and link-local ranges, plus `OPSAPI_TRUSTED_PROXIES`. The chain is read from the right, so a client can't spoof its address by prepending one.

If a public edge proxy sits in front of the cluster and isn't listed, its address is recorded instead of the user's. That's never a spoofed value, just a less useful one.

## Grafana (per environment, admins only)

The dashboard is `sre/grafana/dashboards/user-activity.json`. It reads:

- **per-user data** from Postgres, through the `opsapi_reporting` views;
- **aggregates** from Prometheus. The *Environment* dropdown filters by the Prometheus `namespace` label, because one Prometheus serves every environment.

It picks datasources from dashboard variables, so the same JSON works everywhere. The Postgres datasource's **name must contain "OpsAPI"**.

**Keep it admin-only with a separate Grafana organization, not a folder permission.** Grafana OSS lets any signed-in user of an org query that org's datasources through the API, because datasource permissions are Enterprise-only. Put the datasource and dashboard in an org whose only members are admins.

**diytaxreturn environments (int, acc, prod): automatic.** The `diytaxreturn-grafana` chart in the diy-tax-return-uk repo (`opsapiReporting`) does it on every deploy:

- creates the DB login below;
- creates the **OpsAPI** org with its datasources and this dashboard.

To view it, go to Grafana → switch organization → **OpsAPI**.

**Other deployments: by hand.**

1. **Database login.** Run once per database, as a superuser. The migration already created the views. It also created the `NOLOGIN` role `opsapi_reporting_reader`, unless the app user lacked `CREATEROLE`; in that case the migration printed the statements to run.

   ```sql
   CREATE ROLE grafana_opsapi LOGIN PASSWORD '<from your secret store>' IN ROLE opsapi_reporting_reader;
   ALTER ROLE grafana_opsapi SET search_path = opsapi_reporting;
   ALTER ROLE grafana_opsapi SET statement_timeout = '30s';        -- a heavy panel can't hurt production
   ALTER ROLE grafana_opsapi SET default_transaction_read_only = on;
   ```

   This login can read only the reporting views, which exclude password hashes, tokens and the secret vault.

2. **Organization.** Create an org for admins only.
3. **Datasource.** Add a Postgres datasource in that org, named e.g. "OpsAPI Postgres (reporting)": user `grafana_opsapi`, `sslmode` require. Also add your Prometheus datasource.
4. **Dashboard.** Import this JSON into that org.

## Metrics

| Metric | Labels | Use |
|---|---|---|
| `opsapi_auth_events_total` | `event`, `result` (success / failure / rate_limited), `method` | Login and failure rates; alert on spikes. |
| `opsapi_active_users` | `window` = `5m` / `1h` / `24h` | Same value on every pod: use `max()`, not `sum()`. |
| `opsapi_activity_rows_written_total` | — | Pipeline throughput. |
| `opsapi_activity_dropped_total` | `reason` = `buffer_full` / `write_failed` / `not_migrated` | Anything above zero means activity was lost. See the runbook. |
| `opsapi_activity_flush_duration_seconds` | — | Batch write latency. |

### Alerts

`sre/prometheus/rules/user-activity.rules.yml`:

- **`OpsapiActivityDropped`** (P3): any entries dropped in 10 minutes.
- **`OpsapiLoginFailureSpike`** (P2): more than 50 failed sign-ins in 10 minutes.
- **`OpsapiAuthRateLimiting`** (P3): more than 100 rate-limited auth requests in 10 minutes.

All three are grouped by the Prometheus `namespace` label, so each environment alerts on its own.

### Per-IP request metric

`nginx_http_requests_by_ip_total` used to label every client address. That created one series per visitor, and a botnet could fill the metrics store and take every other metric down with it. It now counts the real client IP (see *Client IP* above), but only for heavy hitters: an address gets its own series once it exceeds 60 requests in a minute, and at most 500 addresses do. All other traffic is counted as `ip="other"`.

The DDoS alerts on this metric keep working for the addresses that matter. Per-user detail is in Postgres.

## Runbook: activity is being dropped

- **`write_failed`:** the database refused or was unreachable for more than 3 flush cycles (about 6 seconds). Check Postgres health and `[user-activity] write failed` in the OpsAPI logs. Requests are unaffected; only the activity records for that window are missing.
- **`buffer_full`:** one worker buffered more than 20,000 entries between flushes, meaning writes can't keep up with traffic. Check `opsapi_activity_flush_duration_seconds`. If it's high, look at database load or add the noisiest read endpoints to `OPSAPI_ACTIVITY_EXCLUDE`.

- **`not_migrated`:** the image is running against a database that hasn't had `lapis migrate` yet, so the activity tables don't exist. This happens when a deployment pulls a new image before its next deploy runs migrations. Recording pauses and logs one warning every 5 minutes per worker. Nothing else is affected: logins and requests work normally. It resumes by itself within 5 minutes of the migration.

## Deployments that consume the OpsAPI image

Tracking is a core feature, so every deployment gets it whatever its `PROJECT_CODE`: the tables are created by `lapis migrate`, and recording is on by default.

- **Data stays in that deployment's own database.** Nothing is sent anywhere else.
- **To opt out**, set `OPSAPI_ACTIVITY_ENABLED=false`. The tables still exist but stay empty.
- **Activity in the dashboard.** The Activity module and menu item are added, and owner/admin roles get `activity.read`.
- **Logs.** Error messages from this feature never include SQL, so no emails or IPs reach the logs through it.

## Privacy

- **Personal data.** IP addresses, browser strings and activity histories are personal data under UK GDPR. They're kept for security and service operation, deleted automatically at the end of their retention period, and visible only to Grafana admins (a separate Grafana org). Workspace admins see only their own workspace's activity.
- **Account deletion.** Deleting a user row erases that person's `user_activity` and `auth_events`, whichever code path or SQL deleted it (database trigger `trg_users_forget_activity`). Their `user_login_stats` row cascades. In the audit trail the record changes stay, because they're the workspace's business records, but the person's id, IP and request id are removed (`metadata.actor_erased`). Deactivating an account (soft delete) keeps the history until retention.
- **Privacy policy.** Mention this processing in your privacy policy.
