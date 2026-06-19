# Runbook: Error Budget Burn

**Alerts:** `ErrorBudgetBurnFast` (14.4×), `ErrorBudgetBurnMedium` (6×),
`ErrorBudgetBurnSlow` (3×), `ErrorBudgetBurnChronic` (1×), `ErrorBudgetExhausted`
· **Severity:** P1–P4 by burn speed

## Description
The availability SLO's error budget is being consumed faster than the policy
allows. Burn rate = observed error ratio ÷ budget (0.0005 for 99.95%). See
`../slo/README.md` for the multi-window method.

## Impact
The budget is the buffer between "reliable enough" and "breaking the SLO". Fast
burn (`Fast`/`Medium`) means a live incident → **page**. Slow/chronic burn means
accumulating reliability debt → **ticket**. Exhaustion triggers the **release
freeze** policy.

## Diagnosis
1. Grafana → **OpsAPI · SLO & Error Budget**: budget-remaining gauge + burn-rate
   panel (which window is hot — 1h/6h/1d?).
2. Fast burn is an active incident — pivot to the symptom runbook:
   - 5xx errors → [high-error-rate.md](high-error-rate.md)
   - service down → [service-down.md](service-down.md)
   - dependency → postgres / redis runbooks
3. Slow/chronic burn: look for a low-level steady error (a noisy endpoint, a
   flaky downstream, periodic timeouts). Use Loki to quantify which status/
   endpoint dominates the budget spend.

## Mitigation
- **Fast/Medium (page):** stop the bleeding via the symptom runbook (rollback,
  failover, scale, disable feature). The budget recovers once the SLI does.
- **Slow/Chronic (ticket):** create a tracked reliability item; fix this sprint.
- **Exhausted:** invoke the **error-budget policy** (`../slo/README.md`):
  - Announce a **release freeze** for non-critical changes.
  - Redirect engineering focus to reliability until the budget recovers.
  - Only changes that restore the SLO ship.

## Verify
Burn-rate panel back under the alert threshold; budget-remaining trending up.

## Escalation
For exhaustion, the platform owner decides on the freeze. For fast burn, follow
the symptom runbook's escalation.
