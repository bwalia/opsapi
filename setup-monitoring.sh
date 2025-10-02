#!/bin/bash

# OpsAPI Monitoring Setup Script
# This script sets up Prometheus and Grafana for OpsAPI monitoring

set -e  # Exit on error

echo "================================================"
echo "  OpsAPI Monitoring Stack Setup"
echo "================================================"
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running from lapis directory
if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}Error: Please run this script from the lapis directory${NC}"
    exit 1
fi

# Step 1: Check code_cache setting
echo "Step 1: Checking lua_code_cache setting..."
if grep -q 'code_cache = "off"' config.lua; then
    echo -e "${YELLOW}Warning: code_cache is OFF. Metrics will not work!${NC}"
    echo "Would you like to enable it now? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        # Backup config.lua
        cp config.lua config.lua.backup
        sed -i '' 's/code_cache = "off"/code_cache = "on"/' config.lua
        echo -e "${GREEN}✓ Enabled code_cache in config.lua${NC}"
        echo "  (Backup saved to config.lua.backup)"
    else
        echo -e "${YELLOW}⚠ Continuing with code_cache OFF. Metrics will not be available!${NC}"
    fi
else
    echo -e "${GREEN}✓ code_cache is already ON${NC}"
fi
echo ""

# Step 2: Check required files
echo "Step 2: Checking required configuration files..."
REQUIRED_FILES=(
    "devops/prometheus.yml"
    "devops/alert_rules.yml"
    "devops/grafana-datasources.yml"
    "devops/grafana-dashboards-provisioning.yml"
    "devops/grafana-dashboard.json"
)

MISSING_FILES=0
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo -e "${RED}✗ Missing: $file${NC}"
        MISSING_FILES=$((MISSING_FILES + 1))
    else
        echo -e "${GREEN}✓ Found: $file${NC}"
    fi
done

if [ $MISSING_FILES -gt 0 ]; then
    echo -e "${RED}Error: Missing required files. Please ensure all configuration files are in place.${NC}"
    exit 1
fi
echo ""

# Step 3: Stop existing containers
echo "Step 3: Stopping existing containers (if any)..."
docker-compose down 2>/dev/null || true
echo -e "${GREEN}✓ Stopped existing containers${NC}"
echo ""

# Step 4: Start services
echo "Step 4: Starting all services..."
echo "This may take a few minutes on first run..."
docker-compose up -d

# Wait for services to be ready
echo ""
echo "Waiting for services to start..."
sleep 10

# Check service status
echo ""
echo "Step 5: Checking service status..."
SERVICES=("opsapi" "opsapi-prometheus" "opsapi-grafana")
ALL_UP=true

for service in "${SERVICES[@]}"; do
    if docker ps | grep -q "$service"; then
        echo -e "${GREEN}✓ $service is running${NC}"
    else
        echo -e "${RED}✗ $service is not running${NC}"
        ALL_UP=false
    fi
done

if [ "$ALL_UP" = false ]; then
    echo ""
    echo -e "${RED}Some services failed to start. Check logs with:${NC}"
    echo "  docker-compose logs"
    exit 1
fi

echo ""
echo "Step 6: Verifying metrics endpoint..."
sleep 5  # Give OpsAPI a moment to initialize

if curl -s http://localhost:4010/metrics | head -1 | grep -q "HELP"; then
    echo -e "${GREEN}✓ Metrics endpoint is responding${NC}"
else
    echo -e "${YELLOW}⚠ Metrics endpoint may not be ready yet${NC}"
    echo "  Check: curl http://localhost:4010/metrics"
fi

echo ""
echo "Step 7: Checking Prometheus targets..."
sleep 3

# Check if Prometheus is scraping
if curl -s http://localhost:9090/api/v1/targets | grep -q "opsapi"; then
    echo -e "${GREEN}✓ Prometheus is configured to scrape OpsAPI${NC}"
else
    echo -e "${YELLOW}⚠ Prometheus may not be ready yet${NC}"
fi

echo ""
echo "================================================"
echo "  Setup Complete! 🎉"
echo "================================================"
echo ""
echo "Access your monitoring stack:"
echo ""
echo -e "  ${GREEN}OpsAPI Metrics:${NC}    http://localhost:4010/metrics"
echo -e "  ${GREEN}Prometheus:${NC}        http://localhost:9090"
echo -e "  ${GREEN}Grafana:${NC}           http://localhost:3000"
echo ""
echo "Grafana credentials:"
echo "  Username: admin"
echo "  Password: admin"
echo ""
echo "Pre-configured dashboard:"
echo "  Go to Grafana → Dashboards → Browse"
echo "  Open: 'OpsAPI - Complete Monitoring Dashboard'"
echo ""
echo "Useful commands:"
echo "  View logs:          docker-compose logs -f"
echo "  View metrics:       curl http://localhost:4010/metrics"
echo "  Restart services:   docker-compose restart"
echo "  Stop services:      docker-compose down"
echo ""
echo "For more information, see:"
echo "  - PROMETHEUS_GRAFANA_SETUP.md"
echo "  - METRICS_GUIDE.md"
echo "  - DDOS_MITIGATION_GUIDE.md"
echo ""
echo "================================================"
