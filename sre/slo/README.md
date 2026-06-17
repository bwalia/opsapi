# SLOs & Error Budgets

> Layer 1 & 4 of the SRE operating model. **Define "good" before you monitor it.**

`slo-definitions.yaml` is the single source of truth. Every objective there is
compiled into Prometheus rules (`../prometheus/rules/slo-burn-rate.rules.yml`)
and visualised in the SLO/error-budget Grafana dashboard.

## The objectives

| # | Objective | SLI | Target (30d) | Error budget |
|---|-----------|-----|--------------|--------------|
| 1 | Availability | non-5xx ÷ total requests | **99.95%** | 21.6 min/month |
| 2 | Latency | requests < 200ms ÷ total | **99%** (P95 < 200ms) | 1% slow requests |
| 3 | Error rate | non-5xx ÷ total | **99.9%** | 0.1% errors |
| 4 | Database availability | `pg_up` | **99.99%** | 4.32 min/month |
| 5 | Cache availability | `redis_up` | **99.9%** | 43.2 min/month |

## How the SLI is measured

```
                 good events            successful (non-5xx, fast) requests
SLI  =  ───────────────────────  =  ──────────────────────────────────────
                total events                     all requests
```

Availability/error SLIs come from the app's own counters
(`nginx_http_requests_total`, emitted by `lapis/lib/prometheus_metrics.lua`).
Latency uses the histogram bucket at `le="0.2"`. Dependency SLOs are scraped
from the postgres/redis exporters. External availability is double-checked by
blackbox-exporter probing `/health` (defends against "metrics say up, users
say down").

## Error-budget policy

The error budget is the amount of unreliability we are *willing to spend*:

```
error_budget = 1 - SLO_target          (e.g. 0.05% for 99.95%)
budget_remaining = 1 - (errors_observed / errors_allowed)
```

| Budget remaining | Posture |
|------------------|---------|
| > 50% | **Ship freely.** Normal feature velocity. |
| 10–50% | **Caution.** Risky changes get extra review; prioritise reliability bugs. |
| < 10% | **Slow down.** No non-critical releases; reliability work jumps the queue. |
| Exhausted (≤ 0%) | **Release freeze.** Only fixes that restore the SLO ship until budget recovers. |

This is enforced socially (and visibly on the dashboard), not by a robot — but
the `ErrorBudgetExhausted` alert pages the team so the conversation actually
happens.

## Burn-rate alerting (why we don't alert on raw error rate)

A flat "error rate > 0.1%" alert is either too noisy or too slow. Instead we use
Google's **multi-window, multi-burn-rate** method (SRE Workbook ch. 5):

| Severity | Long window | Short window | Burn rate | Budget consumed | Meaning |
|----------|-------------|--------------|-----------|-----------------|---------|
| **page** (P1) | 1h | 5m | 14.4× | 2% in 1h | Fast burn — wake someone |
| **page** (P1) | 6h | 30m | 6× | 5% in 6h | Sustained burn |
| **ticket** (P3) | 24h | 2h | 3× | 10% in 24h | Slow burn — fix this sprint |
| **ticket** (P3) | 3d | 6h | 1× | budget gone over window | Chronic erosion |

The short window is an "is it *still* happening right now" guard so alerts
resolve quickly once the incident is over.

## Editing SLOs

1. Change the target/SLI in `slo-definitions.yaml`.
2. Mirror the change in `../prometheus/rules/slo-burn-rate.rules.yml` (the
   recording rule windows and the burn-rate thresholds) and the k3s
   `PrometheusRule` at `../k3s/manifests/opsapi-slo-rules.yaml`.
3. `promtool check rules` (see top-level README) before committing.
