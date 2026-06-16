#!/usr/bin/env bash
# Remove the OpsAPI SRE observability stack from k3s.
set -euo pipefail
cd "$(dirname "$0")"
NS=monitoring

kubectl delete -f manifests/ --ignore-not-found
kubectl -n "$NS" delete configmap -l grafana_dashboard=1 --ignore-not-found
for r in otel-collector tempo promtail loki monitoring; do
  helm uninstall "$r" -n "$NS" 2>/dev/null || true
done
echo "✓ Uninstalled. (Namespace '$NS' and PVCs left intact — delete manually if desired.)"
