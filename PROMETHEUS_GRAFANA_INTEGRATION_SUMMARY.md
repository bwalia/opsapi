# Prometheus & Grafana Integration - Complete Summary

## ✅ What Was Added to docker-compose.yml

### New Services

#### 1. Prometheus (Port 9090)
- **Image**: `prom/prometheus:latest`
- **Container**: `opsapi-prometheus`
- **Purpose**: Metrics collection, storage, and alerting engine
- **IP**: 172.71.0.15
- **Volume**: `prometheus_data` (persistent storage)

**Configuration Files**:
- `devops/prometheus.yml` - Main configuration
- `devops/alert_rules.yml` - Alert definitions

**Features**:
- Scrapes OpsAPI metrics every 10 seconds
- Stores time-series data
- Evaluates alert rules
- Web UI for querying metrics

#### 2. Grafana (Port 3000)
- **Image**: `grafana/grafana:latest`
- **Container**: `opsapi-grafana`
- **Purpose**: Metrics visualization and dashboards
- **IP**: 172.71.0.16
- **Volume**: `grafana_data` (persistent storage)

**Configuration Files**:
- `devops/grafana-datasources.yml` - Prometheus datasource config
- `devops/grafana-dashboards-provisioning.yml` - Dashboard auto-loading
- `devops/grafana-dashboard.json` - Pre-built monitoring dashboard

**Features**:
- Auto-configured Prometheus datasource
- Pre-loaded OpsAPI monitoring dashboard
- Admin credentials: admin/admin

### New Volumes
```yaml
volumes:
  prometheus_data:  # Stores Prometheus metrics data
  grafana_data:     # Stores Grafana dashboards and settings
```

## 📁 New Configuration Files Created

### 1. Prometheus Configuration
**File**: `devops/prometheus.yml`
- Defines scrape targets (OpsAPI)
- Sets scrape intervals (10s for OpsAPI)
- Loads alert rules
- Configures retention and storage

### 2. Alert Rules
**File**: `devops/alert_rules.yml`
- 15+ pre-configured alerts
- Categories: DDoS, Performance, Business, Availability
- Severity levels: Critical, Warning

### 3. Grafana Datasource
**File**: `devops/grafana-datasources.yml`
- Auto-configures Prometheus as default datasource
- No manual setup required

### 4. Grafana Dashboard Provisioning
**File**: `devops/grafana-dashboards-provisioning.yml`
- Automatically loads dashboards on startup
- Makes dashboard available immediately

### 5. Pre-built Dashboard
**File**: `devops/grafana-dashboard.json`
- 16 visualization panels
- Complete monitoring coverage
- Ready to use out-of-the-box

## 📚 Documentation Created

### 1. PROMETHEUS_GRAFANA_SETUP.md
Complete setup and usage guide:
- Quick start instructions
- Configuration details
- Troubleshooting
- Production deployment tips
- Security recommendations

### 2. DOCKER_COMPOSE_REFERENCE.md
Quick reference for docker-compose commands:
- Start/stop/restart commands
- Log viewing
- Data backup/restore
- Troubleshooting common issues
- One-liner utilities

### 3. setup-monitoring.sh
Automated setup script:
- Checks prerequisites
- Enables code_cache if needed
- Starts all services
- Verifies configuration
- Provides access URLs

## 🚀 Quick Start (3 Steps)

### Step 1: Enable Metrics
```bash
# Edit lapis/config.lua
code_cache = "on"  # Change from "off"
```

### Step 2: Run Setup Script
```bash
cd lapis
bash ../setup-monitoring.sh
```

### Step 3: Access Dashboards
- **Grafana**: http://localhost:3000 (admin/admin)
- **Prometheus**: http://localhost:9090
- **Metrics**: http://localhost:4010/metrics

## 📊 What You Get

### Pre-configured Dashboard Panels

1. **Performance Monitoring**
   - Request rate by endpoint
   - Response time (P50, P95, P99)
   - Error rates (4xx, 5xx)
   - Database query latency
   - Cache hit rates

2. **Security & DDoS Detection**
   - Top IPs by request rate
   - Suspicious request patterns
   - Authentication failures
   - Blocked requests
   - Path traversal attempts

3. **Business Analytics**
   - Payment success rates
   - Cart-to-checkout conversion
   - Top 10 viewed products
   - Order flow analysis
   - API endpoint usage

4. **Infrastructure**
   - Active connections
   - Bandwidth usage
   - Upstream service health

### Alert Rules (15+)

**Critical Alerts**:
- ❗ DDoS Attack (>1000 req/min from single IP)
- ❗ High Error Rate (>5%)
- ❗ Payment Failures (>10%)
- ❗ Service Down
- ❗ Credential Stuffing Attack

**Warning Alerts**:
- ⚠️ Slow Response Time (>2s)
- ⚠️ Suspicious Activity Spike
- ⚠️ Low Conversion Rate
- ⚠️ Slow Database Queries
- ⚠️ High Connection Usage

## 🔧 Common Operations

### View Metrics
```bash
curl http://localhost:4010/metrics
```

### Restart After Config Changes
```bash
# Prometheus
curl -X POST http://localhost:9090/-/reload

# Grafana
docker-compose restart grafana
```

### View Logs
```bash
docker-compose logs -f prometheus
docker-compose logs -f grafana
```

### Check Service Status
```bash
docker-compose ps
```

### Backup Data
```bash
# Prometheus
docker run --rm -v lapis_prometheus_data:/prometheus -v $(pwd)/backup:/backup \
  alpine tar czf /backup/prometheus-$(date +%Y%m%d).tar.gz /prometheus

# Grafana
docker run --rm -v lapis_grafana_data:/var/lib/grafana -v $(pwd)/backup:/backup \
  alpine tar czf /backup/grafana-$(date +%Y%m%d).tar.gz /var/lib/grafana
```

## 🎯 Key Features

### Automatic Configuration
✅ Prometheus auto-discovers OpsAPI
✅ Grafana pre-configured with datasource
✅ Dashboard auto-loads on startup
✅ Alert rules pre-configured
✅ No manual setup required

### Persistent Storage
✅ Prometheus data survives container restarts
✅ Grafana dashboards and settings preserved
✅ Historical metrics retained (configurable)

### Production-Ready
✅ Comprehensive alerting rules
✅ Security monitoring
✅ Performance tracking
✅ Business analytics
✅ DDoS detection

## 📈 Sample Queries

### Performance
```promql
# Request rate
rate(nginx_http_requests_total[5m])

# P95 latency
histogram_quantile(0.95, rate(nginx_http_request_duration_seconds_bucket[5m]))

# Error rate
sum(rate(nginx_http_errors_total[5m]))
```

### Security
```promql
# Top attacking IPs
topk(20, rate(nginx_http_requests_by_ip_total[1m]))

# Suspicious patterns
sum by (reason) (rate(nginx_http_suspicious_requests_total[5m]))
```

### Business
```promql
# Conversion rate
sum(rate(ecommerce_cart_operations_total{operation="checkout"}[1h])) /
sum(rate(ecommerce_cart_operations_total{operation="add"}[1h]))

# Payment success rate
sum(rate(ecommerce_payment_operations_total{status="success"}[1h])) /
sum(rate(ecommerce_payment_operations_total[1h]))
```

## 🔐 Security Considerations

### Default Configuration
- Prometheus accessible on localhost:9090
- Grafana accessible on localhost:3000
- Metrics endpoint IP-restricted

### Production Recommendations
1. Change Grafana admin password
2. Enable HTTPS with valid certificates
3. Add authentication to Prometheus
4. Restrict network access
5. Enable Grafana auth (disable anonymous)

## 📊 Resource Requirements

### Prometheus
- **Memory**: 500MB - 1GB
- **CPU**: <5%
- **Disk**: ~1GB per week (adjustable)

### Grafana
- **Memory**: ~200MB
- **CPU**: <2%
- **Disk**: Minimal

## 🔄 Integration Points

### With OpsAPI
- Scrapes `/metrics` endpoint every 10s
- Collects 40+ different metrics
- Tracks performance, security, business KPIs

### With Grafana
- Prometheus configured as default datasource
- Real-time dashboard updates
- Alert visualization

### Future Integrations (Optional)
- AlertManager for notifications (Slack, PagerDuty, Email)
- Node Exporter for system metrics
- PostgreSQL Exporter for database metrics
- Redis Exporter for cache metrics

## 🎓 Learning Resources

### Access Points
- **Prometheus Web UI**: http://localhost:9090
  - Graph: Query and visualize metrics
  - Alerts: View active/pending alerts
  - Targets: Check scrape status
  - Config: View configuration

- **Grafana**: http://localhost:3000
  - Dashboards: Pre-built visualizations
  - Explore: Ad-hoc metric queries
  - Alerting: Configure alert rules
  - Datasources: Manage connections

### Documentation
- `PROMETHEUS_GRAFANA_SETUP.md` - Complete setup guide
- `METRICS_GUIDE.md` - All metrics explained
- `DDOS_MITIGATION_GUIDE.md` - Security monitoring
- `DOCKER_COMPOSE_REFERENCE.md` - Command reference

## 🐛 Troubleshooting

### Metrics Not Showing
**Problem**: "Prometheus metrics not available"
**Solution**: Enable `code_cache = "on"` in `lapis/config.lua`

### Prometheus Target DOWN
**Problem**: OpsAPI target shows as DOWN
**Solution**: 
```bash
# Check OpsAPI is running
docker ps | grep opsapi

# Check metrics endpoint
curl http://localhost:4010/metrics

# Check logs
docker logs opsapi | grep -i prometheus
```

### Grafana "No Data"
**Problem**: Dashboard shows no data
**Solutions**:
1. Check time range (top right)
2. Verify Prometheus datasource (Configuration → Data Sources)
3. Generate some traffic to OpsAPI
4. Check Prometheus has data: http://localhost:9090

### Port Already in Use
**Problem**: Port 9090 or 3000 already in use
**Solution**:
```bash
# Find what's using the port
lsof -i :9090
lsof -i :3000

# Stop conflicting service or change port in docker-compose.yml
```

## 📦 Files Modified/Added

### Modified
- ✅ `lapis/docker-compose.yml` - Added Prometheus & Grafana services

### Created
- ✅ `devops/prometheus.yml` - Prometheus configuration
- ✅ `devops/alert_rules.yml` - Alert definitions
- ✅ `devops/grafana-datasources.yml` - Grafana datasource config
- ✅ `devops/grafana-dashboards-provisioning.yml` - Dashboard provisioning
- ✅ `PROMETHEUS_GRAFANA_SETUP.md` - Complete setup guide
- ✅ `DOCKER_COMPOSE_REFERENCE.md` - Command reference
- ✅ `setup-monitoring.sh` - Automated setup script

### Existing (Pre-configured)
- ✅ `devops/grafana-dashboard.json` - OpsAPI monitoring dashboard
- ✅ `lapis/lib/prometheus_metrics.lua` - Metrics collection module
- ✅ `lapis/lib/business_metrics.lua` - Business metrics helper

## 🎉 Benefits

### For DevOps
- Real-time infrastructure monitoring
- Automatic alerting on issues
- Historical metrics for capacity planning
- Quick troubleshooting with detailed metrics

### For Security
- DDoS detection and mitigation
- Attack pattern recognition
- Authentication failure tracking
- Suspicious activity alerts

### For Business
- Customer behavior analytics
- Conversion funnel tracking
- Revenue metrics (payments)
- Product popularity insights

## 🚀 Next Steps

1. **Start the stack**: Run `setup-monitoring.sh`
2. **View dashboard**: Open Grafana and explore
3. **Set up alerts**: Configure AlertManager (optional)
4. **Integrate business metrics**: Add tracking in application code
5. **Customize dashboards**: Create team-specific views
6. **Production deployment**: Apply security recommendations

## 📞 Support

For issues or questions:
1. Check documentation in the files above
2. View service logs: `docker-compose logs [service]`
3. Test metrics endpoint: `curl http://localhost:4010/metrics`
4. Check Prometheus targets: http://localhost:9090/targets

## 🎯 Success Criteria

✅ All containers running: `docker-compose ps`
✅ Metrics endpoint responding: `curl http://localhost:4010/metrics`
✅ Prometheus scraping successfully: http://localhost:9090/targets shows UP
✅ Grafana dashboard loading: http://localhost:3000 shows data
✅ Alerts configured: http://localhost:9090/alerts shows rules

---

**Your monitoring stack is now complete and ready to use!** 🎉
