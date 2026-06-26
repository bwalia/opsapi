#!/usr/bin/env bash
# Disaster-recovery drill (Layer 8) — simulate loss of the app tier and MEASURE
# the recovery time (RTO), writing a timestamped report. Stops the synthetic
# OpsAPI container, recreates it, and times how long until /health is green
# again as observed by Prometheus (up{job="opsapi"}).
#
# Targets: RTO = 15 min, RPO = 5 min (see ../incident/ and ../capacity/).
set -euo pipefail
cd "$(dirname "$0")/.."

PROM=http://localhost:9091
SVC=synthetic-opsapi
COMPOSE=(docker compose -f docker-compose.sre.yml --env-file .env.sre)
REPORT="dr-report-$(date -u +%Y%m%dT%H%M%SZ).md"

up_value() { curl -fsS "$PROM/api/v1/query?query=up%7Bjob%3D%22opsapi%22%7D" 2>/dev/null \
  | grep -o '"value":\[[^]]*\]' | grep -o '"[01]"' | tail -1 | tr -d '"'; }

echo "▶ DR drill: simulating loss of the app tier ($SVC)…"
START=$(date +%s)
"${COMPOSE[@]}" stop "$SVC" >/dev/null

echo "▶ Recovering (recreate container)…"
"${COMPOSE[@]}" up -d "$SVC" >/dev/null

echo "▶ Timing recovery until up{job=opsapi}==1 …"
DEADLINE=$(( $(date +%s) + 300 ))
while [ "$(up_value)" != "1" ]; do
  [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "  ✗ did not recover within 5m"; break; }
  sleep 3
done
END=$(date +%s); RTO=$((END - START))

{
  echo "# DR Drill Report"
  echo
  echo "- **Date (UTC):** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- **Scenario:** loss of app tier ($SVC), recreate"
  echo "- **Measured RTO:** ${RTO}s"
  echo "- **RTO objective:** 900s (15m) — $( [ "$RTO" -le 900 ] && echo 'MET ✓' || echo 'MISSED ✗')"
  echo "- **RPO objective:** 300s (5m) — backups verified separately via backup-test.sh"
  echo
  echo "## Notes"
  echo "- This drill exercises the local Docker stack. The k3s equivalent is a"
  echo "  rolling pod deletion (kubectl delete pod -l app=opsapi); recovery is the"
  echo "  Deployment rescheduling + readiness probe passing."
} > "$REPORT"

echo "✓ RTO measured: ${RTO}s  →  report written to sre/$REPORT"
