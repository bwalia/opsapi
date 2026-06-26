#!/usr/bin/env bash
# Chaos test (Layer 6/10) — inject a controlled failure and prove the system
# DETECTS it. Pauses the demo Postgres, polls Prometheus until the PostgresDown
# alert is firing, then unpauses and confirms it resolves.
set -euo pipefail
cd "$(dirname "$0")/.."

PROM=http://localhost:9091
PG=sre-demo-postgres

alert_state() { # $1 = alertname → prints "firing"/"pending"/""
  curl -fsS "$PROM/api/v1/alerts" 2>/dev/null \
    | grep -o "\"alertname\":\"$1\"[^}]*\"state\":\"[a-z]*\"" \
    | grep -o '"state":"[a-z]*"' | tail -1 | cut -d'"' -f4 || true
}
wait_state() { # $1 alertname, $2 desired, $3 timeout-sec
  local n=$(( $3 / 3 ))
  while [ "$n" -gt 0 ]; do
    [ "$(alert_state "$1")" = "$2" ] && return 0
    n=$((n-1)); sleep 3
  done
  return 1
}

echo "▶ Baseline: PostgresDown = '$(alert_state PostgresDown)'"
echo "▶ Injecting failure: pausing $PG …"
docker pause "$PG" >/dev/null

echo "▶ Waiting for PostgresDown to fire (the pg exporter loses its target)…"
if wait_state PostgresDown firing 120; then
  echo "  ✓ DETECTED — PostgresDown is firing."
else
  echo "  ✗ alert did not fire within 120s (check exporter/rules)."
fi

echo "▶ Recovering: unpausing $PG …"
docker unpause "$PG" >/dev/null

echo "▶ Waiting for the alert to clear…"
if wait_state PostgresDown "" 120; then
  echo "  ✓ RECOVERED — PostgresDown cleared."
else
  echo "  ⚠ still firing after 120s; check 'make alerts'."
fi
echo "▶ Pages/tickets seen by the sink:"; docker logs sre-alert-logger 2>&1 | tail -10 || true
