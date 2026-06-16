#!/usr/bin/env bash
# Validate every config in the SRE stack WITHOUT a running cluster:
#   • docker compose config       (compose schema)
#   • promtool check config/rules  (Prometheus)
#   • amtool check-config          (Alertmanager)
#   • python json.tool             (Grafana dashboards)
# Uses the pinned images so there is nothing to install locally.
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0
note() { printf '%s %s\n' "$1" "$2"; }

echo "▶ docker compose config"
if docker compose -f docker-compose.sre.yml --env-file .env.sre.example config >/dev/null; then
  note "✓" "compose file is valid"
else
  note "✗" "compose file invalid"; rc=1
fi

echo "▶ promtool check config + rules"
docker run --rm -v "$PWD/prometheus:/p" --entrypoint promtool prom/prometheus:v2.54.1 \
  check config /p/prometheus.yml 2>&1 | sed 's/^/    /' || rc=1
for f in prometheus/rules/*.rules.yml; do
  if docker run --rm -v "$PWD/prometheus:/p" --entrypoint promtool prom/prometheus:v2.54.1 \
       check rules "/p/rules/$(basename "$f")" >/dev/null 2>&1; then
    note "  ✓" "$f"
  else
    note "  ✗" "$f"; rc=1
  fi
done

echo "▶ amtool check-config"
if docker run --rm -v "$PWD/alertmanager:/a" --entrypoint amtool prom/alertmanager:v0.27.0 \
     check-config /a/alertmanager.yml >/dev/null 2>&1; then
  note "✓" "alertmanager.yml is valid"
else
  note "✗" "alertmanager.yml invalid"; rc=1
fi

echo "▶ Grafana dashboard JSON"
for f in grafana/dashboards/*.json; do
  if python3 -m json.tool "$f" >/dev/null 2>&1; then note "  ✓" "$f"; else note "  ✗" "$f"; rc=1; fi
done

echo
[ "$rc" -eq 0 ] && echo "ALL VALID ✓" || echo "VALIDATION FAILED ✗"
exit "$rc"
