#!/usr/bin/env bash
# Install the OpsAPI SRE observability stack on k3s, in dependency order.
# Idempotent (helm upgrade --install). Run with KUBECONFIG pointed at the cluster.
#
#   ./install.sh                 # install everything into the `monitoring` ns
#   DRY_RUN=1 ./install.sh       # render/validate only (helm template + apply --dry-run)
set -euo pipefail
cd "$(dirname "$0")"

NS=monitoring
APP_NS=opsapi
KPS_VER="${KPS_VER:-62.3.0}"        # kube-prometheus-stack chart version
DRY="${DRY_RUN:-0}"

run() { if [ "$DRY" = "1" ]; then echo "DRY: $*"; else "$@"; fi; }

echo "▶ Adding Helm repos…"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

HELM_FLAGS=()
[ "$DRY" = "1" ] && HELM_FLAGS=(--dry-run)

echo "▶ 1/5 kube-prometheus-stack (Prometheus + Alertmanager + Grafana + exporters)"
run helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n "$NS" --create-namespace --version "$KPS_VER" \
  -f values/kube-prometheus-stack.values.yaml "${HELM_FLAGS[@]}"

echo "▶ 2/5 Loki (logs)"
run helm upgrade --install loki grafana/loki -n "$NS" -f values/loki.values.yaml "${HELM_FLAGS[@]}"

echo "▶ 3/5 Promtail (log shipping)"
run helm upgrade --install promtail grafana/promtail -n "$NS" \
  --set "config.clients[0].url=http://loki-gateway.${NS}.svc/loki/api/v1/push" "${HELM_FLAGS[@]}"

echo "▶ 4/5 Tempo (traces) + OpenTelemetry Collector"
run helm upgrade --install tempo grafana/tempo -n "$NS" -f values/tempo.values.yaml "${HELM_FLAGS[@]}"
run helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n "$NS" \
  -f values/otel-collector.values.yaml "${HELM_FLAGS[@]}"

echo "▶ 5/5 OpsAPI CRs: ServiceMonitor, PrometheusRules, AlertmanagerConfig, Gatus, backup"
APPLY=(kubectl apply -f)
[ "$DRY" = "1" ] && APPLY=(kubectl apply --dry-run=client -f)
run "${APPLY[@]}" manifests/opsapi-servicemonitor.yaml
run "${APPLY[@]}" manifests/golden-signals-rules.yaml
run "${APPLY[@]}" manifests/opsapi-slo-rules.yaml
run "${APPLY[@]}" manifests/alertmanager-config.yaml
run "${APPLY[@]}" manifests/gatus.yaml
run kubectl create namespace "$APP_NS" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
run "${APPLY[@]}" manifests/backup-cronjob.yaml

echo "▶ Loading Grafana dashboards as labelled ConfigMaps…"
for f in ../grafana/dashboards/*.json; do
  name="opsapi-dash-$(basename "$f" .json)"
  if [ "$DRY" = "1" ]; then
    echo "DRY: configmap $name from $f"
  else
    kubectl create configmap "$name" -n "$NS" --from-file="$(basename "$f")=$f" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - grafana_dashboard=1 grafana_folder="OpsAPI SRE" -o yaml | \
      kubectl apply -f -
  fi
done

cat <<EOF

✓ Done. Access (port-forward examples):
  kubectl -n $NS port-forward svc/opsapi-monitoring-grafana 3000:80
  kubectl -n $NS port-forward svc/opsapi-monitoring-prometheus 9090:9090
  Gatus: via the Ingress host in manifests/gatus.yaml (status.opsapi.example)

Remember to create the alert secret for real paging:
  kubectl -n $NS create secret generic opsapi-alert-secrets \\
    --from-literal=slack-webhook-url=... --from-literal=pagerduty-routing-key=...
EOF
