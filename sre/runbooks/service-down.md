# Runbook: Service Down

**Alerts:** `OpsAPIServiceDown`, `BlackboxProbeFailed` · **Severity:** P1

## Description
Prometheus cannot scrape `up{job="opsapi"}` (or the external blackbox probe of
`/health` is failing) for >1–2 minutes. The API is unreachable or not serving.

## Impact
Total or near-total outage — users cannot use the platform. Revenue-impacting.
Declare a **P1** incident immediately.

## Diagnosis
1. Confirm scope — is it the app, the host, or the monitoring?
   - Grafana → **OpsAPI · Service Overview** (API up / Postgres up / Redis up tiles).
   - Hit health directly: `curl -v http://<host>/health`.
2. Check the container/pod:
   - Demo: `docker ps | grep opsapi`, `docker logs --tail=200 opsapi`.
   - k3s: `kubectl -n <ns> get pods -l app=diytaxreturn-lapis`, `kubectl -n <ns> logs <pod> --tail=200`.
3. Common causes: crash loop (bad migration/config), OOMKill, port/ingress
   misroute, dependency down (Postgres) blocking startup, expired TLS.
4. Check dependencies — if `PostgresDown` is also firing, fix that first
   ([postgres-saturation.md](postgres-saturation.md)).

## Mitigation
- **Recent deploy?** Roll back first, diagnose later.
  - k3s: `kubectl -n <ns> rollout undo deployment/diytaxreturn-lapis`.
  - Demo: redeploy the last-good image tag.
- **Crash loop:** read the last 200 log lines for the fatal error; if it's a
  migration, see [postgres-saturation.md](postgres-saturation.md) (migration drift
  took acc down for 22h on 2026-05-14 — scope `PROJECT_CODE` correctly).
- **OOMKilled:** bump memory limits / replicas (`kubectl -n <ns> scale deployment/diytaxreturn-lapis --replicas=N`).
- **Ingress/TLS:** verify ingress + certificate; check `nginx.conf` trusted CA.

## Verify
`up{job="opsapi"}==1`, blackbox `probe_success==1`, `/health` returns
`{"status":"healthy"}`, error ratio back to baseline on the dashboard.

## Escalation
No progress in 30 min → engineering lead → platform owner. Keep the status page
updated every 30 min for P1.
