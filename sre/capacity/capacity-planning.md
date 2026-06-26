# Capacity Planning

> Layer 9. Run out of headroom *on purpose, on a schedule* — never by surprise.
> Forecasting rules live in `../prometheus/rules/capacity.rules.yml`; the
> **OpsAPI · Capacity Planning** Grafana dashboard shows current vs predicted vs
> threshold for each resource.

## What we track

| Resource | Current metric | Forecast (recording rule) | Threshold |
|----------|----------------|---------------------------|-----------|
| CPU | `opsapi:node_cpu_utilization:ratio` | trend on dashboard | 85% |
| Memory | `opsapi:node_memory_utilization:ratio` | `opsapi:mem_util_predicted_7d:ratio` | 90% |
| Disk | `opsapi:node_disk_utilization:ratio` | `opsapi:disk_util_predicted_30d:ratio`, `opsapi:disk_will_fill_seconds` | 85% / 4-day warning |
| Database size | `pg_database_size_bytes` | `opsapi:pg_database_size_predicted_30d_bytes` | volume size |
| DB connections | `opsapi:pg_connection_utilization:ratio` | trend | 80% |
| Traffic | `opsapi:http_requests:rate5m` | `opsapi:traffic_predicted_30d:rate` | capacity model |

## Method

We use Prometheus `predict_linear()` over a trailing window to extrapolate the
recent trend forward:

```promql
# Will this filesystem fill within the next 4 days, at the current 6h trend?
predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4*24*3600) < 0

# Projected disk utilisation 30 days out, from the last 7 days
1 - (predict_linear(node_filesystem_avail_bytes[7d], 30*24*3600)
     / node_filesystem_size_bytes)
```

Linear projection is deliberately simple and good for weeks-out planning. For
seasonal/holiday traffic, overlay `*_over_time` from the same week last
month/year and plan to the **peak**, not the average.

## Forecast horizons

- **30 days** — operational: provisioning, PVC growth, replica counts.
- **90 days** — tactical: budget for the next quarter's infra.
- **1 year** — strategic: architecture (sharding, read replicas, multi-region).

## Review cadence

- **Weekly:** glance at the Capacity dashboard for any line crossing its
  threshold inside the horizon; file a P3/P4 ticket if so.
- **Monthly:** capacity review — compare actual growth vs last month's forecast;
  recalibrate; decide on scaling actions.
- **Quarterly:** 90-day/1-year outlook + DR test (`../scripts/dr-drill.sh`).

## Scaling triggers (act before the alert pages)

| Signal | Action |
|--------|--------|
| CPU forecast > 85% within 30d | Add replicas / enable HPA (`autoscaling.enabled=true`) |
| Memory forecast > 90% within 7d | Raise limits or scale out; hunt leaks |
| Disk fills within 14d | Expand volume / add retention / prune |
| DB connections > 80% sustained | Tune pool, add read replica |
| Traffic 30d forecast near current peak capacity | Load-test, then scale the tier |

## Headroom policy

Target **steady-state utilisation ≤ 60%** of capacity for CPU/memory so a single
node loss or a traffic spike doesn't immediately breach thresholds (N+1). Disk
keeps ≥ 30% free. These leave room to absorb failure *and* the time it takes to
provision more.
