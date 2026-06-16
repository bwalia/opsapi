# Runbook: PostgreSQL Down / Saturation

**Alerts:** `PostgresDown`, `PostgresConnectionsNearMax`, `SlowDatabaseQueries` · **Severity:** P1/P3

## Description
Postgres is unreachable (`pg_up==0`), its connection pool is >80% of
`max_connections`, or query P95 exceeds 1s. OpsAPI is data-backed, so DB trouble
quickly becomes an availability incident.

## Impact
`PostgresDown` ⇒ near-total outage (**P1**). Connection saturation ⇒ rising
errors/latency. Slow queries ⇒ latency-SLO risk.

## Diagnosis
```bash
# Connections & activity (demo)
docker exec -it sre-demo-postgres psql -U sre -d sre -c \
  "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"
# Longest-running queries
docker exec -it <pg> psql -U <u> -d <db> -c \
  "SELECT pid, now()-query_start AS dur, state, left(query,80) FROM pg_stat_activity \
   WHERE state<>'idle' ORDER BY dur DESC LIMIT 10;"
```
- k3s: `kubectl -n <ns> get pods -l app=postgres`; `kubectl logs <pg-pod>`.
- Check `opsapi:pg_connection_utilization:ratio` and `pg_stat_activity_count` on
  the **Golden Signals** / **Capacity** dashboards.
- Causes: connection leak (clients not releasing), a runaway/locking query,
  vacuum/bloat, disk full on the PG volume, or a **migration drift** (a CRM
  migration drift took acc down for 22h on 2026-05-14 — confirm `PROJECT_CODE`
  scopes migrations correctly; see CLAUDE.md).

## Mitigation
- **Down:** restart/repair the instance; verify the data volume and disk
  (`df -h`); check it isn't OOM/disk-full.
- **Connection saturation:** find and terminate offenders:
  `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state='idle in transaction' AND now()-state_change > interval '5 min';`
  Then fix the leak (pool size, unclosed transactions). Consider read replicas.
- **Slow queries:** `EXPLAIN ANALYZE` the offender; add/restore an index; kill if
  it's blocking. Ensure queries filter by `namespace_id` (tenant scoping).
- **Migration issue:** roll back the deploy; re-run migrations with the correct
  `PROJECT_CODE` (`docker exec -e PROJECT_CODE=<code> -it opsapi lapis migrate`).

## Verify
`pg_up==1`, connection utilisation < 70%, query P95 < 1s, app error ratio normal.

## Escalation
DB on-call. For data-integrity concerns, stop writes and escalate to platform
owner before attempting risky recovery.
