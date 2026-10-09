# Observability

## Prometheus

Property Deals metrics are exported with the rest of OpsAPI at `/metrics`
(`projects/property-deals/property_deals/metrics.lua`). They are registered on first use and do nothing
where metrics are off (e.g. dev with `lua_code_cache off`).

| Metric | Type | Labels | Updated |
|---|---|---|---|
| `property_deals_tasks_open` | gauge | namespace | every minute (`sla_tick`) |
| `property_deals_tasks_overdue` | gauge | namespace | every minute |
| `property_deals_approvals_pending` | gauge | namespace | every minute |
| `property_deals_money_at_risk` | gauge | namespace | every minute (GBP, active deals) |
| `property_deals_deals_active` | gauge | namespace, health | every minute |
| `property_deals_sla_events_total` | counter | namespace, level (`warned`, `overdue`, `escalated`) | when the SLA engine acts |
| `property_deals_agent_runs_total` | counter | namespace, agent, status | when a run ends |
| `property_deals_agent_cost_usd_total` | counter | namespace, agent | when a run ends |

`namespace` is the workspace slug.

## Grafana

`sre/grafana/dashboards/property-deals.json` (uid `opsapi-property-deals`) has a Workspace selector and these panels:
- headline stats: open and overdue tasks, red deals, approvals waiting, money at risk, AI spend today;
- overdue over time, and deals by health;
- SLA steps per hour, and breaches per day;
- agent runs by outcome and by agent, spend per day, and the failure rate;
- approvals waiting, and money at risk.

## Performance (SPEC §4)

`spec/perf_test.py` loads 5,000 open tasks and 100,000 properties into one workspace, then times the
endpoints. Laptop Docker sandbox, median of 7 calls (2026-10-09):

| Endpoint | Target | Measured |
|---|---|---|
| `GET /today` (operator) | < 300 ms | 11 ms |
| `GET /today` (owner) | < 300 ms | 9 ms |
| `GET /map` radius 25 miles, 100k properties | < 500 ms | 62 ms |
| `GET /map` polygon, 100k properties | < 500 ms | 31 ms |
| `GET /tasks?open=true` | < 300 ms | 16 ms |

What keeps them fast:
- Today and the task list use the indexes on `property_deals_task_details`: `(namespace_id, owner_user_uuid, urgency_score DESC)` and open tasks by due date.
- The map filters by bounding box on `(namespace_id, lat, lng)` before the exact haversine distance, and caps the answer at 2,000 features (`truncated: true`).

## Audit and retention

- Every change to a Property Deals table is an event (`project.lua` `publishes`). The core audit
  subscriber records it with who, before and after; the deal timeline (`GET /deals/{id}/timeline`) reads it.
- Approvals keep every decision with its payload version and SHA-256.
- Agent runs keep the model, tokens, cost, tool calls and the draft, until `retention_agent_run_days`.
- Email bodies are kept until `retention_inbound_days`. Market data is kept until `retention_market_days`.
- Export a workspace's data: `GET /export/{entity}` (API.md §2.11).
