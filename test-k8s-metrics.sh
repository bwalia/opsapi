#!/bin/bash

# Test OpsAPI Metrics in Kubernetes
export KUBECONFIG=/Users/balinderwalia/.kube/k3s0-over-vpn.yaml

echo "================================================"
echo "  Testing OpsAPI Metrics in Kubernetes"
echo "================================================"
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check kubeconfig
echo "Step 1: Checking Kubernetes connection..."
if kubectl cluster-info &>/dev/null; then
    echo -e "${GREEN}✓ Connected to Kubernetes cluster${NC}"
else
    echo -e "${RED}✗ Cannot connect to Kubernetes cluster${NC}"
    echo "Check your kubeconfig at: /Users/balinderwalia/.kube/k3s0-over-vpn.yaml"
    exit 1
fi

# Check namespaces
echo ""
echo "Step 2: Checking namespaces..."
for ns in test acc prod; do
    if kubectl get namespace $ns &>/dev/null; then
        echo -e "${GREEN}✓ Namespace $ns exists${NC}"
    else
        echo -e "${YELLOW}⚠ Namespace $ns does not exist${NC}"
    fi
done

# Check services
echo ""
echo "Step 3: Checking OpsAPI services..."
for ns in test acc prod; do
    echo "  Namespace: $ns"
    kubectl get svc -n $ns | grep -E "(opsapi|NAME)" || echo "    No opsapi services found"
done

# Test metrics endpoint
echo ""
echo "Step 4: Testing metrics endpoint..."
echo "Creating test pod to check internal connectivity..."

kubectl run metrics-test --image=curlimages/curl --rm -it --restart=Never -n test -- sh -c "
echo 'Testing /health endpoint...'
curl -s -w 'Status: %{http_code}\n' http://opsapi-svc.test.svc.cluster.local/health

echo ''
echo 'Testing /metrics endpoint...'
curl -s -w 'Status: %{http_code}\n' http://opsapi-svc.test.svc.cluster.local/metrics | head -10

echo ''
echo 'Testing /openapi.json endpoint...'
curl -s -w 'Status: %{http_code}\n' http://opsapi-svc.test.svc.cluster.local/openapi.json | head -5
"

# Check ServiceMonitors
echo ""
echo "Step 5: Checking ServiceMonitors..."
for ns in test acc prod; do
    echo "  Namespace: $ns"
    kubectl get servicemonitor -n $ns | grep -E "(opsapi|NAME)" || echo "    No ServiceMonitors found"
done

# Check if Prometheus Operator is running
echo ""
echo "Step 6: Checking Prometheus Operator..."
if kubectl get pods -A | grep -q prometheus-operator; then
    echo -e "${GREEN}✓ Prometheus Operator is running${NC}"
else
    echo -e "${YELLOW}⚠ Prometheus Operator not found${NC}"
    echo "ServiceMonitors require Prometheus Operator to work"
fi

# Port forward for local testing
echo ""
echo "Step 7: Setting up port forwarding for local testing..."
echo "You can test locally by running:"
echo "  kubectl port-forward -n test svc/opsapi-svc 4010:80"
echo ""
echo "Then test with:"
echo "  curl http://localhost:4010/health"
echo "  curl http://localhost:4010/metrics"
echo "  curl http://localhost:4010/openapi.json"

echo ""
echo "================================================"
echo "  Kubernetes Metrics Test Complete"
echo "================================================"
