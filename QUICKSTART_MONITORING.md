# 🚀 QUICK START GUIDE - Prometheus & Grafana

## One-Command Setup

```bash
cd lapis && bash ../setup-monitoring.sh
```

## Manual Setup (3 Steps)

### 1. Enable Metrics
Edit `lapis/config.lua`:
```lua
code_cache = "on"  # REQUIRED for metrics
```

### 2. Start Services
```bash
cd lapis
docker-compose up -d
```

### 3. Access Dashboards
- **Grafana**: http://127.0.0.1:3000 (admin/admin)
- **Prometheus**: http://127.0.0.1:9090
- **Metrics**: http://127.0.0.1:4010/metrics

## 📊 Dashboard Panels

Your pre-configured Grafana dashboard includes:

✅ Request rate & latency
✅ Error tracking (4xx, 5xx)
✅ DDoS detection (Top IPs)
✅ Security monitoring (Suspicious patterns)
✅ Business metrics (Payments, Cart conversion)
✅ Database performance
✅ Cache hit rates
✅ Product popularity

## 🚨 Pre-configured Alerts

- DDoS Attack (>1000 req/min from IP)
- High Error Rate (>5%)
- Payment Failures (>10%)
- Slow Response Time (>2s)
- Credential Stuffing
- Service Down

View alerts: http://127.0.0.1:9090/alerts

## 🔍 Quick Checks

### Is Everything Working?
```bash
# Check containers
docker-compose ps

# Check metrics
curl http://127.0.0.1:4010/metrics | head -20

# Check Prometheus targets
curl -s http://127.0.0.1:9090/api/v1/targets | grep health
```

### Generate Test Data
```bash
# Create some traffic
for i in {1..50}; do curl -s http://127.0.0.1:4010/api/v2/products > /dev/null; done

# View metrics update
curl http://127.0.0.1:4010/metrics | grep nginx_http_requests_total
```

## 📝 Essential Commands

```bash
# View logs
docker-compose logs -f prometheus grafana

# Restart services
docker-compose restart prometheus grafana

# Stop services
docker-compose down

# Reload Prometheus config (after editing prometheus.yml)
curl -X POST http://127.0.0.1:9090/-/reload
```

## 🎯 Sample Queries (Use in Prometheus or Grafana)

### Performance
```promql
# Request rate per second
rate(nginx_http_requests_total[5m])

# 95th percentile latency
histogram_quantile(0.95, rate(nginx_http_request_duration_seconds_bucket[5m]))
```

### Security
```promql
# Top 10 IPs by request rate
topk(10, rate(nginx_http_requests_by_ip_total[1m]))

# Suspicious requests
sum by (reason) (rate(nginx_http_suspicious_requests_total[5m]))
```

### Business
```promql
# Cart conversion rate
sum(rate(ecommerce_cart_operations_total{operation="checkout"}[1h])) /
sum(rate(ecommerce_cart_operations_total{operation="add"}[1h]))
```

## ⚠️ Troubleshooting

### "Prometheus metrics not available"
**Fix**: Enable `code_cache = "on"` in `lapis/config.lua`, then restart:
```bash
docker-compose restart lapis
```

### Grafana shows "No Data"
**Fix**: 
1. Check time range (top right, set to "Last 5 minutes")
2. Generate traffic: `curl http://127.0.0.1:4010/`
3. Verify Prometheus: http://127.0.0.1:9090/targets

### Port Already in Use
**Fix**: 
```bash
# Find what's using the port
lsof -i :9090  # Prometheus
lsof -i :3000  # Grafana

# Or change port in docker-compose.yml
```

## 📚 Full Documentation

- **PROMETHEUS_GRAFANA_INTEGRATION_SUMMARY.md** - Complete overview
- **PROMETHEUS_GRAFANA_SETUP.md** - Detailed setup guide
- **METRICS_GUIDE.md** - All 40+ metrics explained
- **DDOS_MITIGATION_GUIDE.md** - Security monitoring
- **DOCKER_COMPOSE_REFERENCE.md** - All docker commands

## 🎯 URLs Reference

| Service | URL | Credentials |
|---------|-----|-------------|
| OpsAPI | http://127.0.0.1:4010 | - |
| Metrics Endpoint | http://127.0.0.1:4010/metrics | IP-restricted |
| Prometheus | http://127.0.0.1:9090 | None |
| Grafana | http://127.0.0.1:3000 | admin/admin |

## 📦 What's Monitoring?

### 40+ Metrics Including:
- HTTP requests (rate, latency, size)
- Error tracking (4xx, 5xx by endpoint)
- DDoS indicators (requests per IP)
- Security patterns (SQL injection, path traversal)
- Business KPIs (payments, orders, cart operations)
- Database performance
- Cache effectiveness
- Authentication attempts

### Real-time Alerts:
- Performance degradation
- Security threats
- Business anomalies
- System availability

## 🔧 Customization

### Add New Alert
Edit `devops/alert_rules.yml`, then:
```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

### Create Custom Dashboard
1. Build in Grafana UI
2. Export as JSON
3. Save to `devops/grafana-dashboard.json`
4. Restart: `docker-compose restart grafana`

### Add Business Metrics in Code
```lua
local business_metrics = require("lib.business_metrics")

-- Track events
business_metrics.track_payment_operation("stripe", "success")
business_metrics.track_cart_operation("add", "success")
business_metrics.track_product_view(product_id)
```

## ✅ Success Checklist

- [ ] Code cache enabled in config.lua
- [ ] All containers running (`docker-compose ps`)
- [ ] Metrics endpoint responding (curl check)
- [ ] Prometheus target UP (check /targets)
- [ ] Grafana dashboard showing data
- [ ] Test alerts working

## 🎉 You're Done!

Your monitoring stack is ready. Navigate to **Grafana → Dashboards** to see your metrics!

---

**Need help?** Check the full documentation or run:
```bash
docker-compose logs [service_name]
```
