# Runbooks

> Layer 7. Every alert in `../prometheus/rules/` carries a `runbook_url`
> annotation pointing at one of these files. A runbook turns a 3am page into a
> checklist. Each follows the same shape: **Description · Impact · Diagnosis ·
> Mitigation · Escalation**.

## Alert → runbook index

| Alert (`alertname`) | Severity | Runbook |
|---------------------|----------|---------|
| `OpsAPIServiceDown`, `BlackboxProbeFailed` | P1 | [service-down.md](service-down.md) |
| `ErrorBudgetBurnFast/Medium/Slow/Chronic`, `ErrorBudgetExhausted` | P1–P4 | [error-budget-burn.md](error-budget-burn.md) |
| `HighErrorRate` (5xx) | P1 | [high-error-rate.md](high-error-rate.md) |
| `OpsAPIHighLatencyP95`, `LatencyBudgetBurnFast`, `OpsAPIConnectionsWaiting` | P2/P3 | [high-latency.md](high-latency.md) |
| `PostgresDown`, `SlowDatabaseQueries`, `PostgresConnectionsNearMax` | P1/P3 | [postgres-saturation.md](postgres-saturation.md) |
| `RedisDown`, `RedisMemoryHigh` | P2/P3 | [redis-saturation.md](redis-saturation.md) |
| `DiskWillFillIn4Days`, `DiskSpaceLow`, `MemoryUtilizationHigh`, `OpsAPISaturationCPU` | P3 | [disk-capacity.md](disk-capacity.md) |
| `PossibleDDoSAttack`, `DistributedDDoSAttack`, `CredentialStuffingAttack`, `HighAuthFailureRate` | P1–P3 | [ddos-attack.md](ddos-attack.md) |
| `HighPaymentFailureRate` | P1 | [payment-failures.md](payment-failures.md) |

## Conventions used in the commands

- **Docker (demo / single-host):** `docker exec -it opsapi …`, `docker logs -f opsapi`.
- **k3s (prod):** `kubectl -n <ns> …`. Set `KUBECONFIG` first.
- Dashboards referenced are in Grafana under the **OpsAPI SRE** folder.
- The app exposes `/health`, `/ready`, `/live`, `/metrics` (see `app.lua`).
