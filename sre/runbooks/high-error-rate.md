# Runbook: High Error Rate (5xx)

**Alerts:** `HighErrorRate`, (feeds) `ErrorBudgetBurnFast` · **Severity:** P1

## Description
The 5xx error ratio is elevated (`opsapi:http_error_ratio:rate5m`). The service
is up but failing a meaningful share of requests.

## Impact
Users see failures; the availability error budget is burning. If burning at
14.4×, the budget is gone in hours — treat as **P1**.

## Diagnosis
1. Grafana → **OpsAPI · Golden Signals** → "5xx error ratio" and per-endpoint
   request rate. Is it one endpoint or platform-wide?
2. Correlate with logs: Grafana → **OpsAPI · Logs** filter status `500/502/503`,
   or `{job="opsapi"} | status =~ "5.."`. Read the actual error.
3. Follow an exemplar trace (Prometheus exemplars → Tempo) to the failing span,
   then to the log line — root cause in minutes.
4. Common causes: bad deploy, dependency failure (DB/Redis/MinIO/HMRC/Stripe),
   unhandled exception, migration mismatch, downstream timeout.
5. Check the error catalog: rows in the shared `error_occurrences` table
   (written by the handler in `app.lua`) show which catalog errors spiked.

## Mitigation
- **Correlates with a deploy?** Roll back (`kubectl -n <ns> rollout undo …`).
- **Single dependency?** See its runbook (postgres / redis / payments).
- **Single endpoint/module?** If feature-gated, consider disabling the feature
  for the affected `PROJECT_CODE` / namespace while you fix forward.
- **External API (HMRC/Stripe) down?** Degrade gracefully; surface a friendly
  error; don't retry-storm.

## Verify
5xx ratio back under 0.1%; burn-rate panel on the SLO dashboard back to <1×.

## Escalation
Owner of the failing module; eng lead if platform-wide. Status page for P1.
