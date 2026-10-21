#!/usr/bin/env bash
# Install / upgrade Stakater Reloader on k3s1 (idempotent).
#   KUBECONFIG=~/.kube/k3s1.yaml devops/k8s/reloader/install.sh
# Verify: kubectl -n reloader logs deploy/reloader-reloader | tail
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CHART_VERSION="${RELOADER_CHART_VERSION:-2.2.18}" # app v1.4.22
helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null 2>&1 || true
helm repo update stakater >/dev/null
helm upgrade --install reloader stakater/reloader \
  --version "$CHART_VERSION" \
  --namespace reloader --create-namespace \
  -f "$HERE/values.yaml" \
  --wait --timeout 5m
kubectl -n reloader rollout status deploy/reloader-reloader --timeout=2m
