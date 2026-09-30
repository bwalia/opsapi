# User activity & login tracking

OpsAPI records who signed in, when, from where, and what they did. Platform admins see it in Grafana (**OpsAPI · User Activity**). Workspace admins see their own workspace's slice in the dashboard, under **Activity**.

## What is recorded

| Data | Where | Kept |
|---|---|---|
| Sign-ins and security events: login success and failure (password, Google, OAuth), 2FA challenge, token refresh, logout, password reset request / reset / change, account deactivation. Each has method, reason, client IP, browser and request id. | `auth_events` | 365 days |
| Per user: last login (time, IP, method, browser), login count, failed logins since the last success, last seen. | `user_login_stats` (1:1 with `users`) | while the account exists |
| What signed-in users did: route pattern (`/api/v2/invoices/:id`), action (`invoices.update`), record id, status, duration, workspace, IP, browser, request id. | `user_activity` (partitioned by month) | 90 days |
| Counts only: auth events, active users, pipeline health. | Prometheus (`/metrics`) | your Prometheus retention |

- **Changes vs reads.** Every change (POST / PUT / PATCH / DELETE) is its own row. Identical reads (same user, route, record and status) within a minute are merged into one row with a `hits` count, so background polling doesn't flood the table.
- **Never recorded:** request or response bodies, query strings, tokens, passwords, or `Authorization` headers.
- **Not tracked:** anonymous and public requests, health and metrics endpoints, and `/auth/*`, which is covered by `auth_events` instead.
- **No personal data in `/metrics`.** User ids never appear as Prometheus labels. That would multiply time series without bound and publish personal data to anything that can scrape `/metrics`.

## How it works

- **Capture.** Activity is captured in nginx's log phase, *after* the response has been sent. It's buffered per worker and written to Postgres in batches every 2 seconds, so it adds no latency to requests and can never fail one.
- **Failures.** If the database is unavailable, a batch is retried 3 times, then dropped and counted in `opsapi_activity_dropped_total`. Buffers are bounded, so memory never grows.
- **Sign-in events.** These are written immediately; they're low-volume and matter for security. Rate-limited login floods are only counted in Prometheus, not stored one row per request.
- **Maintenance.** An hourly job, run by one pod at a time:
  - creates next months' partitions;
  - drops partitions past `OPSAPI_ACTIVITY_RETENTION_DAYS`;
  - deletes auth events past `OPSAPI_AUTH_EVENTS_RETENTION_DAYS`.

  Whole partitions are dropped, so there are no expensive row-by-row deletes.

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

Datasources are chosen from dashboard variables, so the same JSON works in every environment.

**1. Database login for Grafana.** Run once per environment database, as a DBA. The migration already created the views and the `NOLOGIN` role `opsapi_reporting_reader`. If the app user lacked `CREATEROLE`, the migration printed the statements to create it.

```sql
CREATE ROLE grafana_opsapi LOGIN PASSWORD '<from your secret store>' IN ROLE opsapi_reporting_reader;
ALTER ROLE grafana_opsapi SET search_path = opsapi_reporting;
ALTER ROLE grafana_opsapi SET statement_timeout = '30s';   -- a heavy panel can't hurt production
```

This login can read only the reporting views, which exclude password hashes, tokens and the secret vault. It can't write anything.

**2. Datasource.** A Postgres datasource per environment Grafana:

```yaml
- name: OpsAPI Postgres (reporting)
  type: grafana-postgresql-datasource
  url: <env opsapi postgres host>:5432
  user: grafana_opsapi
  jsonData: { database: <opsapi db>, sslmode: require, postgresVersion: 1400, maxOpenConns: 5 }
  secureJsonData: { password: $GRAFANA_OPSAPI_DB_PASSWORD }
```

**3. Dashboard.** Provision the JSON into its own folder, for example "OpsAPI Activity". Give only the **Admin** role access to that folder, since the dashboard shows personal data. Anonymous access must stay disabled.

## Metrics

| Metric | Labels | Use |
|---|---|---|
| `opsapi_auth_events_total` | `event`, `result` (success / failure / rate_limited), `method` | Login and failure rates; alert on spikes. |
| `opsapi_active_users` | `window` = `5m` / `1h` / `24h` | Same value on every pod: use `max()`, not `sum()`. |
| `opsapi_activity_rows_written_total` | — | Pipeline throughput. |
| `opsapi_activity_dropped_total` | `reason` = `buffer_full` / `write_failed` | Anything above zero means activity was lost. See the runbook. |
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

## Privacy

- **Personal data.** IP addresses, browser strings and activity histories are personal data under UK GDPR. They're kept for security and service operation, deleted automatically at the end of their retention period, and visible only to platform admins in Grafana. Workspace admins see only their own workspace's activity.
- **Account deletion.** Deleting a user row erases that person's `user_activity` and `auth_events`, whichever code path or SQL deleted it (database trigger `trg_users_forget_activity`). Their `user_login_stats` row cascades. Deactivating an account (soft delete) keeps the history until retention.
- **Privacy policy.** Mention this processing in your privacy policy.
