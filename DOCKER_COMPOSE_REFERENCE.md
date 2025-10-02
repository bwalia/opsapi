# Docker Compose Quick Reference - OpsAPI Monitoring

## Start/Stop Commands

### Start All Services
```bash
cd lapis
docker-compose up -d
```

### Start Specific Services
```bash
docker-compose up -d prometheus grafana
```

### Stop All Services
```bash
docker-compose down
```

### Stop and Remove Volumes (⚠️ Deletes Data)
```bash
docker-compose down -v
```

### Restart Services
```bash
docker-compose restart

# Restart specific service
docker-compose restart prometheus
docker-compose restart grafana
docker-compose restart lapis
```

## View Logs

### All Services
```bash
docker-compose logs -f
```

### Specific Service
```bash
docker-compose logs -f prometheus
docker-compose logs -f grafana
docker-compose logs -f lapis
```

### Last 50 Lines
```bash
docker-compose logs --tail=50 prometheus
```

## Service Status

### List Running Containers
```bash
docker-compose ps
```

### Check Service Health
```bash
docker ps | grep opsapi
```

## Configuration Changes

### After Editing prometheus.yml or alert_rules.yml
```bash
# Option 1: Hot reload (recommended)
curl -X POST http://localhost:9090/-/reload

# Option 2: Restart container
docker-compose restart prometheus
```

### After Editing docker-compose.yml
```bash
docker-compose down
docker-compose up -d
```

### After Editing Grafana Dashboard
```bash
# Restart Grafana to reload provisioned dashboards
docker-compose restart grafana
```

## Data Management

### Backup Prometheus Data
```bash
docker run --rm \
  -v lapis_prometheus_data:/prometheus \
  -v $(pwd)/backup:/backup \
  alpine tar czf /backup/prometheus-$(date +%Y%m%d).tar.gz /prometheus
```

### Backup Grafana Data
```bash
docker run --rm \
  -v lapis_grafana_data:/var/lib/grafana \
  -v $(pwd)/backup:/backup \
  alpine tar czf /backup/grafana-$(date +%Y%m%d).tar.gz /var/lib/grafana
```

### View Volume Usage
```bash
docker system df -v | grep lapis
```

### Clean Up Old Data
```bash
# Remove unused volumes (⚠️ careful)
docker volume prune
```

## Troubleshooting

### Container Won't Start
```bash
# Check logs
docker-compose logs prometheus

# Check container status
docker-compose ps

# Force recreate
docker-compose up -d --force-recreate prometheus
```

### Port Already in Use
```bash
# Find what's using the port
lsof -i :9090  # Prometheus
lsof -i :3000  # Grafana

# Stop conflicting service or change port in docker-compose.yml
```

### Reset Everything (⚠️ Nuclear Option)
```bash
# Stop containers
docker-compose down -v

# Remove images
docker-compose rm -f

# Restart fresh
docker-compose up -d
```

## Monitoring Stack URLs

- **OpsAPI**: http://localhost:4010
- **OpsAPI Metrics**: http://localhost:4010/metrics
- **Prometheus**: http://localhost:9090
  - Targets: http://localhost:9090/targets
  - Alerts: http://localhost:9090/alerts
  - Config: http://localhost:9090/config
- **Grafana**: http://localhost:3000
  - Default Login: admin / admin

## Performance Commands

### Check Container Resource Usage
```bash
docker stats
```

### Check Container Resource Usage (Specific)
```bash
docker stats opsapi-prometheus opsapi-grafana
```

### Limit Container Memory
Edit docker-compose.yml:
```yaml
prometheus:
  deploy:
    resources:
      limits:
        memory: 1G
```

## Network Commands

### Inspect Network
```bash
docker network inspect lapis_opsapi-network
```

### Test Connectivity Between Containers
```bash
# From OpsAPI to Prometheus
docker exec opsapi curl http://prometheus:9090/-/healthy

# From Grafana to Prometheus
docker exec opsapi-grafana curl http://prometheus:9090/api/v1/query?query=up
```

## Development Workflow

### Making Changes to Metrics

1. Edit code in `lapis/lib/prometheus_metrics.lua`
2. Restart OpsAPI:
   ```bash
   docker-compose restart lapis
   ```
3. Test metrics:
   ```bash
   curl http://localhost:4010/metrics | grep your_metric
   ```
4. View in Prometheus:
   - Open http://localhost:9090/graph
   - Enter metric name
   - Click Execute

### Creating New Dashboards

1. Create dashboard in Grafana UI
2. Export as JSON
3. Save to `lapis/devops/grafana-dashboard.json`
4. Restart Grafana:
   ```bash
   docker-compose restart grafana
   ```

### Adding New Alert Rules

1. Edit `lapis/devops/alert_rules.yml`
2. Reload Prometheus:
   ```bash
   curl -X POST http://localhost:9090/-/reload
   ```
3. Verify in http://localhost:9090/alerts

## Quick Tests

### Generate Test Traffic
```bash
# Simple load test
for i in {1..100}; do 
  curl -s http://localhost:4010/api/v2/products > /dev/null
done

# Watch metrics increase
watch -n1 'curl -s http://localhost:4010/metrics | grep nginx_http_requests_total | tail -5'
```

### Test DDoS Detection
```bash
# Simulate high traffic
ab -n 10000 -c 100 http://localhost:4010/

# Check if suspicious requests metric increases
curl -s http://localhost:4010/metrics | grep suspicious
```

### Test Alerts
```bash
# Trigger high error rate (make bad requests)
for i in {1..100}; do 
  curl -s http://localhost:4010/nonexistent > /dev/null
done

# Check alerts in Prometheus
open http://localhost:9090/alerts
```

## Production Commands

### Graceful Shutdown
```bash
# Stop accepting new requests, finish current ones
docker-compose stop

# Force stop after timeout
docker-compose down
```

### Update Images
```bash
# Pull latest images
docker-compose pull prometheus grafana

# Recreate with new images
docker-compose up -d --force-recreate prometheus grafana
```

### Scale Workers (if using swarm mode)
```bash
docker-compose up -d --scale lapis=3
```

## Useful One-Liners

```bash
# Quick health check
docker-compose ps && curl -s http://localhost:4010/metrics | head -5

# Restart entire stack
docker-compose down && docker-compose up -d && docker-compose logs -f

# Check Prometheus is scraping
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Top 10 metrics by request count
curl -s http://localhost:4010/metrics | grep nginx_http_requests_total | sort -t'=' -k2 -nr | head -10

# Export all container logs
docker-compose logs > monitoring-logs-$(date +%Y%m%d).log

# Monitor container resources in real-time
watch -n1 'docker stats --no-stream | grep opsapi'
```

## Environment Variables

Set in docker-compose.yml or .env file:

```yaml
# Prometheus
PROMETHEUS_RETENTION_TIME: 15d
PROMETHEUS_STORAGE_TSDB_PATH: /prometheus

# Grafana
GF_SECURITY_ADMIN_USER: admin
GF_SECURITY_ADMIN_PASSWORD: your_password
GF_INSTALL_PLUGINS: plugin-name
GF_SERVER_ROOT_URL: http://your-domain.com
```

## Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| Metrics showing "not available" | Enable `code_cache = "on"` in config.lua |
| Prometheus target is DOWN | Check OpsAPI is running and accessible |
| Grafana shows "No data" | Check time range, verify Prometheus datasource |
| Port already in use | Change port in docker-compose.yml or stop conflicting service |
| Out of disk space | Reduce Prometheus retention or prune old data |
| Container keeps restarting | Check logs: `docker-compose logs [service]` |

## References

- Main setup guide: `PROMETHEUS_GRAFANA_SETUP.md`
- Metrics documentation: `METRICS_GUIDE.md`
- Security guide: `DDOS_MITIGATION_GUIDE.md`
