#!/usr/bin/env bash
# Bring up the OpsAPI SRE demo stack, wait for health, and print the URL map.
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker-compose.sre.yml --env-file .env.sre)
[ -f .env.sre ] || cp .env.sre.example .env.sre

echo "▶ Building & starting the OpsAPI SRE stack…"
"${COMPOSE[@]}" up -d --build

echo "▶ Waiting for core services to become healthy…"
wait_for() {
  local name="$1" url="$2" tries=60
  until curl -fsS "$url" >/dev/null 2>&1; do
    tries=$((tries - 1))
    [ "$tries" -le 0 ] && { echo "  ✗ $name not ready ($url)"; return 1; }
    sleep 2
  done
  echo "  ✓ $name"
}
wait_for "Prometheus" "http://localhost:9091/-/healthy"      || true
wait_for "Grafana"    "http://localhost:3012/api/health"     || true
wait_for "Alertmgr"   "http://localhost:9093/-/healthy"      || true
wait_for "Gatus"      "http://localhost:8878/health"         || true

GP="$(grep -E '^GRAFANA_PASSWORD=' .env.sre | cut -d= -f2)"; GP="${GP:-admin}"
cat <<EOF

────────────────────────────────────────────────────────────────────
  OpsAPI SRE stack is up. Open:

  Grafana (dashboards)   http://localhost:3012     (admin / ${GP})
      • OpsAPI · Service Overview
      • OpsAPI · Golden Signals
      • OpsAPI · SLO & Error Budget
      • OpsAPI · Capacity Planning
      • OpsAPI · Logs (Loki)
  Prometheus             http://localhost:9091
  Alertmanager           http://localhost:9093
  Gatus (status page)    http://localhost:8878
  Tempo (via Grafana Explore → Tempo)
  Loki  (via Grafana Explore → Loki)

  Next:
    make demo-load     # drive traffic → watch SLO dashboards + budget burn
    make alerts        # see pages/tickets the alert sink received
    make chaos         # pause Postgres → PostgresDown alert fires → recovers
    make backup-test   # prove RPO (pg_dump + restore verify)
    make dr-drill      # measure RTO
────────────────────────────────────────────────────────────────────
EOF
