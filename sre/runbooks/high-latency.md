# Runbook: High Latency

**Alerts:** `OpsAPIHighLatencyP95`, `LatencyBudgetBurnFast`, `OpsAPIConnectionsWaiting` · **Severity:** P2/P3

## Description
P95 latency exceeds the 200ms SLO (`opsapi:http_latency:p95`), and/or the share
of requests slower than 200ms is burning the latency budget, and/or nginx has
many waiting connections.

## Impact
Slow responses; degraded UX; risk of cascading timeouts and connection
exhaustion. Latency-budget burn at 14.4× is **P2**.

## Diagnosis
1. Grafana → **OpsAPI · Golden Signals** → P50/P95/P99. Is P99 ≫ P95 (tail) or
   the whole distribution shifted?
2. Per-endpoint breakdown — which endpoint regressed?
3. Saturation panels: CPU, memory, **DB connection pool**, waiting connections.
   Latency under load is usually saturation somewhere.
4. Database: slow queries? See `SlowDatabaseQueries` and
   [postgres-saturation.md](postgres-saturation.md) (`api_database_query_duration_seconds`).
5. Traces: open a slow trace in Tempo; find the dominant span (DB? external API?
   LLM/Ollama? lock contention?).
6. Downstream: Ollama/LLM, HMRC, Stripe, MinIO — a slow dependency drags P95.

## Mitigation
- **Saturation (CPU/conn):** scale out replicas; raise worker/connection limits.
- **DB-bound:** identify and kill/optimise the slow query; add/restore an index;
  check connection-pool exhaustion.
- **Downstream slow:** add/lower timeouts so one slow dependency can't pin
  workers; degrade the feature.
- **Traffic spike:** confirm it's legitimate (not DDoS — [ddos-attack.md](ddos-attack.md)); autoscale.

## Verify
P95 < 200ms sustained; latency burn-rate < 1×; waiting connections back to baseline.

## Escalation
DB on-call for query issues; eng lead if scaling doesn't help within 1h.
