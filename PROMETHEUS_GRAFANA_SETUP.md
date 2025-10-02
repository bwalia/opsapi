# Prometheus & Grafana Setup Guide

## Overview
This setup provides comprehensive monitoring for OpsAPI using Prometheus (metrics collection) and Grafana (visualization).

## Services Added

### Prometheus
- **Port**: 9090
- **Container**: opsapi-prometheus
- **Purpose**: Metrics collection, storage, and alerting
- **Access**: http://localhost:9090

### Grafana
- **Port**: 3000
- **Container**: opsapi-grafana
- **Purpose**: Metrics visualization and dashboards
- **Access**: http://localhost:3000
- **Default Login**: admin / admin

## Quick Start

### 1. Enable Metrics in OpsAPI
**IMPORTANT**: Metrics require code cache to be enabled.

Edit `lapis/config.lua`:
```lua
config("development", {
  code_cache = "on",  -- Change from "off" to "on"
})
```

### 2. Start All Services
```bash
cd lapis
docker-compose up -d
```

### 3. Verify Services

**Check all containers are running:**
```bash
docker-compose ps
```

**Check Prometheus is scraping metrics:**
```bash
# Should see metrics
curl http://localhost:4010/metrics

# Check Prometheus targets
open http://localhost:9090/targets
```

**Access Grafana:**
```bash
open http://localhost:3000
```
- Username: `admin`
- Password: `admin`

### 4. View Pre-configured Dashboard

1. Login to Grafana (http://localhost:3000)
2. Go to **Dashboards** → **Browse**
3. Open **OpsAPI - Complete Monitoring Dashboard**

## Available Dashboards

The pre-configured dashboard includes:

### 🚀 Performance Monitoring
- Request rate by endpoint
- Response time percentiles (P50, P95, P99)
- Error rate breakdown (4xx, 5xx)
- Database query latency
- Cache hit rates

### 🛡️ Security & DDoS Detection
- Top IPs by request rate
- Suspicious request patterns
- Authentication failure tracking
- Blocked requests
- Rate limiting events

### 💼 Business Analytics
- Payment success rates
- Cart-to-checkout conversion
- Top 10 viewed products
- Order flow analysis
- API endpoint usage

### 📊 Infrastructure
- Active connections
- Bandwidth usage (inbound/outbound)
- Upstream service health

## Prometheus Queries

### Quick Health Check
```promql
# Request rate
rate(nginx_http_requests_total[5m])

# Error rate
sum(rate(nginx_http_errors_total[5m]))

# Response time P95
histogram_quantile(0.95, rate(nginx_http_request_duration_seconds_bucket[5m]))
```

### DDoS Detection
```promql
# Top attacking IPs
topk(20, rate(nginx_http_requests_by_ip_total[1m]))

# Suspicious patterns
sum by (reason) (rate(nginx_http_suspicious_requests_total[5m]))
```

### Business Metrics
```promql
# Cart conversion rate
sum(rate(ecommerce_cart_operations_total{operation="checkout"}[1h])) /
sum(rate(ecommerce_cart_operations_total{operation="add"}[1h]))

# Payment success rate
sum(rate(ecommerce_payment_operations_total{status="success"}[1h])) /
sum(rate(ecommerce_payment_operations_total[1h]))
```

## Alerting

Alerts are pre-configured in `devops/alert_rules.yml`:

### Critical Alerts
- **DDoS Attack**: IP making >1000 req/min
- **High Error Rate**: 5xx errors >5%
- **Payment Failures**: Failure rate >10%
- **Service Down**: OpsAPI unavailable

### Warning Alerts
- **Slow Response**: P95 latency >2s
- **Suspicious Activity**: High rate of attack patterns
- **Low Conversion**: Cart conversion <5%
- **Slow Queries**: Database P95 >1s

### View Active Alerts
1. Go to http://localhost:9090/alerts
2. Or in Grafana: **Alerting** → **Alert Rules**

## Configuration Files

### Prometheus Configuration
**File**: `devops/prometheus.yml`

```yaml
# Main scrape config
scrape_configs:
  - job_name: 'opsapi'
    static_configs:
      - targets: ['lapis:8080']
    metrics_path: '/metrics'
    scrape_interval: 10s
```

**Modify scrape interval** (default 10s):
```yaml
scrape_interval: 30s  # Scrape every 30 seconds
```

### Alert Rules
**File**: `devops/alert_rules.yml`

Add custom alerts:
```yaml
- alert: CustomAlert
  expr: your_metric > threshold
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Alert description"
```

### Grafana Datasource
**File**: `devops/grafana-datasources.yml`

Automatically configures Prometheus as the default datasource.

## Common Tasks

### Reload Prometheus Configuration
```bash
# After editing prometheus.yml or alert_rules.yml
curl -X POST http://localhost:9090/-/reload
```

### Create Custom Dashboard

1. Login to Grafana
2. Click **+** → **Dashboard**
3. Click **Add new panel**
4. Enter PromQL query
5. Save dashboard

### Export Dashboard
1. Open dashboard in Grafana
2. Click **Share** → **Export**
3. Save JSON
4. Copy to `devops/` directory

### Add More Scrape Targets

Edit `devops/prometheus.yml`:
```yaml
scrape_configs:
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
```

## Integration with AlertManager (Optional)

To send alerts to Slack, PagerDuty, email, etc:

### 1. Add AlertManager to docker-compose.yml
```yaml
alertmanager:
  image: prom/alertmanager:latest
  container_name: opsapi-alertmanager
  ports:
    - "9093:9093"
  volumes:
    - ./devops/alertmanager.yml:/etc/alertmanager/alertmanager.yml
  networks:
    opsapi-network:
```

### 2. Configure Slack notifications
Create `devops/alertmanager.yml`:
```yaml
global:
  slack_api_url: 'YOUR_SLACK_WEBHOOK_URL'

route:
  receiver: 'slack-notifications'
  group_by: ['alertname', 'severity']
  group_wait: 10s

receivers:
  - name: 'slack-notifications'
    slack_configs:
      - channel: '#alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```

## Troubleshooting

### Metrics Not Appearing in Prometheus

**Check OpsAPI metrics endpoint:**
```bash
curl http://localhost:4010/metrics
```

If you see "Prometheus metrics not available":
- Ensure `code_cache = "on"` in `lapis/config.lua`
- Restart OpsAPI: `docker-compose restart lapis`
- Check logs: `docker logs opsapi | grep -i prometheus`

**Check Prometheus targets:**
```bash
open http://localhost:9090/targets
```

Target should be **UP**. If DOWN:
- Check network connectivity
- Verify service names in prometheus.yml
- Check OpsAPI logs for errors

### Grafana Dashboard Not Loading

**Check datasource:**
1. Go to **Configuration** → **Data Sources**
2. Click on **Prometheus**
3. Click **Save & Test**

Should show "Data source is working".

**Re-import dashboard:**
1. **Dashboards** → **Import**
2. Upload `devops/grafana-dashboard.json`

### No Data in Dashboard

**Common issues:**
1. **Code cache disabled**: Enable in config.lua
2. **No traffic**: Generate some requests to OpsAPI
3. **Time range**: Adjust time picker in Grafana (top right)
4. **Metrics not initialized**: Check OpsAPI logs

### High Memory Usage

**Reduce Prometheus retention:**

Edit docker-compose.yml:
```yaml
prometheus:
  command:
    - '--storage.tsdb.retention.time=7d'  # Keep only 7 days
```

## Performance Considerations

### Resource Usage

**Prometheus**:
- Memory: ~500MB-1GB
- CPU: Low (<5%)
- Disk: ~1GB per week (depends on scrape frequency)

**Grafana**:
- Memory: ~200MB
- CPU: Very low (<2%)
- Disk: Minimal

### Optimization Tips

1. **Increase scrape interval** for low-traffic environments:
   ```yaml
   scrape_interval: 30s  # Instead of 10s
   ```

2. **Reduce retention** if disk space is limited:
   ```yaml
   --storage.tsdb.retention.time=7d
   ```

3. **Disable unused metrics** in OpsAPI if needed

## Backup & Recovery

### Backup Prometheus Data
```bash
docker run --rm \
  -v lapis_prometheus_data:/prometheus \
  -v $(pwd)/backup:/backup \
  alpine tar czf /backup/prometheus-$(date +%Y%m%d).tar.gz /prometheus
```

### Backup Grafana Dashboards
```bash
docker exec opsapi-grafana grafana-cli admin export-dashboard \
  > backup/grafana-dashboards-$(date +%Y%m%d).json
```

### Restore
```bash
# Restore Prometheus
docker run --rm \
  -v lapis_prometheus_data:/prometheus \
  -v $(pwd)/backup:/backup \
  alpine tar xzf /backup/prometheus-YYYYMMDD.tar.gz -C /

# Restart services
docker-compose restart prometheus grafana
```

## Production Deployment

### Security Recommendations

1. **Change default passwords**:
   ```yaml
   grafana:
     environment:
       - GF_SECURITY_ADMIN_PASSWORD=STRONG_PASSWORD
   ```

2. **Enable authentication** in Prometheus (using reverse proxy)

3. **Use HTTPS** with valid certificates

4. **Restrict network access**:
   ```yaml
   ports:
     - "127.0.0.1:9090:9090"  # Only localhost
   ```

5. **Enable Grafana auth**:
   ```yaml
   - GF_AUTH_ANONYMOUS_ENABLED=false
   - GF_AUTH_DISABLE_LOGIN_FORM=false
   ```

### Scaling for Production

1. **Increase Prometheus resources**:
   ```yaml
   deploy:
     resources:
       limits:
         memory: 4G
         cpus: '2'
   ```

2. **Use external storage** (e.g., TimescaleDB, InfluxDB)

3. **Set up AlertManager** for production alerts

4. **Enable Grafana SMTP** for email alerts

## Useful Links

- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000
- **OpsAPI Metrics**: http://localhost:4010/metrics
- **Prometheus Docs**: https://prometheus.io/docs/
- **Grafana Docs**: https://grafana.com/docs/
- **PromQL Guide**: https://prometheus.io/docs/prometheus/latest/querying/basics/

## Quick Commands Reference

```bash
# Start services
docker-compose up -d prometheus grafana

# Stop services
docker-compose stop prometheus grafana

# View logs
docker logs opsapi-prometheus
docker logs opsapi-grafana

# Restart after config changes
docker-compose restart prometheus

# Check metrics endpoint
curl http://localhost:4010/metrics | head -50

# Reload Prometheus config
curl -X POST http://localhost:9090/-/reload

# Clean up (WARNING: deletes data)
docker-compose down -v
```

## Support

For issues or questions, refer to:
- **METRICS_GUIDE.md** - Complete metrics documentation
- **DDOS_MITIGATION_GUIDE.md** - Security monitoring
- **Prometheus logs**: `docker logs opsapi-prometheus`
- **Grafana logs**: `docker logs opsapi-grafana`
