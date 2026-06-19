# Incident Severity Matrix

> Layer 5. Severity drives **who responds, how fast, and how loud**. It is set
> by the Incident Commander at declaration and can be revised as understanding
> changes. Alert `priority` labels (P1–P4) map directly to these levels and
> Alertmanager routes accordingly (`../alertmanager/alertmanager.yml`).

| Severity | Name | Definition | Examples | Response time | Notify | Comms |
|----------|------|------------|----------|---------------|--------|-------|
| **P1** | Critical | Revenue or data loss; platform down or unusable for most tenants | API down, Postgres down, payment failures >10%, active DDoS, error budget burning at 14.4× | **Page immediately, 24/7** | On-call paged + IC + eng lead | Status page + #incidents, exec update if >30m |
| **P2** | Major | Major degradation; a core module broken or severe partial outage | Redis down, latency SLO burning at 6×, one tenant fully down, error budget exhausted | **Page (business hours), <15m** | On-call paged | Status page + #incidents |
| **P3** | Minor | Minor degradation; SLO at risk but not breached for users | P95 latency > 200ms, slow DB queries, disk filling in <4d, 3× slow burn | **Ticket, next business day** | #alerts channel | Internal only |
| **P4** | Informational | No user impact; reliability debt / early warning | Chronic 1× budget erosion, capacity trend warnings | **Backlog** | #alerts channel | Internal only |

## Mapping alert priority → severity

The `priority` label on every alert rule (see `../prometheus/rules/`) is the
severity. `severity: page` alerts are P1/P2 (they wake someone); `severity:
ticket` alerts are P3/P4 (they create work, not pages).

## Escalation

If the on-call cannot make progress within **30 minutes** (P1) / **1 hour**
(P2), escalate to the engineering lead, then to the platform owner. Anyone may
escalate; nobody is penalised for escalating early.

## When in doubt

Declare **higher** severity and downgrade later. Under-calling an incident costs
more than over-calling one.
