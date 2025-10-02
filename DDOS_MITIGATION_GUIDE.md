# DDoS Mitigation & Security Monitoring Guide

## Real-time DDoS Detection Queries

### 1. Identify High-Traffic IPs (Potential DDoS)
```promql
# IPs making more than 1000 requests per minute
rate(nginx_http_requests_by_ip_total[1m]) > 1000

# Top 20 IPs by request rate
topk(20, rate(nginx_http_requests_by_ip_total[1m]))

# Show only IPs with abnormal traffic (>100 req/min)
topk(50, rate(nginx_http_requests_by_ip_total[1m])) > 100
```

### 2. Detect Sudden Traffic Spikes
```promql
# Detect 10x increase in traffic compared to 1 hour ago
rate(nginx_http_requests_total[1m]) / rate(nginx_http_requests_total[1m] offset 1h) > 10

# Request rate deviation from baseline
(rate(nginx_http_requests_total[5m]) - avg_over_time(rate(nginx_http_requests_total[5m])[1h:5m])) / 
  stddev_over_time(rate(nginx_http_requests_total[5m])[1h:5m]) > 3
```

### 3. Suspicious Pattern Detection
```promql
# All suspicious requests by reason
sum by (reason) (rate(nginx_http_suspicious_requests_total[5m]))

# Path traversal attempts
rate(nginx_http_suspicious_requests_total{reason="path_traversal_attempt"}[5m])

# SQL/XSS injection attempts
rate(nginx_http_suspicious_requests_total{reason="injection_attempt"}[5m])

# Requests without User-Agent (likely bots)
rate(nginx_http_suspicious_requests_total{reason="no_user_agent"}[5m])
```

### 4. Error Pattern Analysis
```promql
# IPs generating high error rates (possible scanning)
topk(20, 
  sum by (ip) (rate(nginx_http_4xx_errors_total[5m]))
)

# Endpoints being hammered with 404s
topk(10,
  sum by (endpoint) (rate(nginx_http_4xx_errors_total{status="404"}[5m]))
)

# Sudden spike in 401 errors (credential stuffing attack)
rate(nginx_http_4xx_errors_total{status="401"}[5m]) > 50
```

### 5. Bandwidth Consumption
```promql
# Top bandwidth consuming IPs
topk(20, 
  sum by (ip) (
    rate(nginx_http_request_size_bytes_sum[5m]) + 
    rate(nginx_http_response_size_bytes_sum[5m])
  )
)

# Detect bandwidth spikes
rate(nginx_http_response_size_bytes_sum[5m]) > 10000000  # >10MB/s
```

## Alerting Rules for Production

### Critical Alerts

```yaml
groups:
  - name: ddos_alerts
    interval: 30s
    rules:
      # Layer 7 DDoS Attack
      - alert: PossibleDDoSAttack
        expr: rate(nginx_http_requests_by_ip_total[1m]) > 1000
        for: 2m
        labels:
          severity: critical
          category: security
        annotations:
          summary: "Possible DDoS from IP {{ $labels.ip }}"
          description: "IP {{ $labels.ip }} is making {{ $value }} requests/sec"
          action: "Consider rate limiting or blocking this IP"
      
      # Distributed DDoS (multiple IPs)
      - alert: DistributedDDoSAttack
        expr: sum(rate(nginx_http_requests_total[1m])) > 10000
        for: 5m
        labels:
          severity: critical
          category: security
        annotations:
          summary: "Possible distributed DDoS attack"
          description: "Total request rate: {{ $value }} req/sec"
      
      # Application Layer Attack
      - alert: SuspiciousActivitySpike
        expr: sum(rate(nginx_http_suspicious_requests_total[5m])) > 100
        for: 3m
        labels:
          severity: warning
          category: security
        annotations:
          summary: "High rate of suspicious requests"
          description: "{{ $value }} suspicious requests/sec"
      
      # Credential Stuffing Attack
      - alert: CredentialStuffingAttack
        expr: rate(api_auth_failures_total{reason="invalid_credentials"}[5m]) > 50
        for: 2m
        labels:
          severity: critical
          category: security
        annotations:
          summary: "Possible credential stuffing attack"
          description: "{{ $value }} auth failures/sec"
      
      # Path Scanning
      - alert: PathScanningDetected
        expr: rate(nginx_http_suspicious_requests_total{reason="path_traversal_attempt"}[5m]) > 10
        for: 2m
        labels:
          severity: warning
          category: security
        annotations:
          summary: "Path scanning/enumeration detected"
```

### Performance Alerts

```yaml
      # High Error Rate
      - alert: HighErrorRate
        expr: |
          sum(rate(nginx_http_5xx_errors_total[5m])) / 
          sum(rate(nginx_http_requests_total[5m])) > 0.05
        for: 3m
        labels:
          severity: critical
          category: performance
        annotations:
          summary: "Error rate above 5%"
          description: "Current error rate: {{ $value | humanizePercentage }}"
      
      # Slow Response Times
      - alert: SlowResponseTime
        expr: |
          histogram_quantile(0.95, 
            rate(nginx_http_request_duration_seconds_bucket[5m])
          ) > 2.0
        for: 5m
        labels:
          severity: warning
          category: performance
        annotations:
          summary: "95th percentile response time > 2s"
          description: "P95 latency: {{ $value }}s"
      
      # Database Performance Degradation
      - alert: SlowDatabaseQueries
        expr: |
          histogram_quantile(0.95, 
            rate(api_database_query_duration_seconds_bucket[5m])
          ) > 1.0
        for: 5m
        labels:
          severity: warning
          category: database
        annotations:
          summary: "Database queries are slow"
```

### Business Alerts

```yaml
      # Payment Failures
      - alert: HighPaymentFailureRate
        expr: |
          sum(rate(ecommerce_payment_operations_total{status!="success"}[10m])) /
          sum(rate(ecommerce_payment_operations_total[10m])) > 0.1
        for: 5m
        labels:
          severity: critical
          category: business
        annotations:
          summary: "Payment failure rate above 10%"
          description: "Failure rate: {{ $value | humanizePercentage }}"
      
      # Low Conversion Rate
      - alert: LowCartConversionRate
        expr: |
          sum(rate(ecommerce_cart_operations_total{operation="checkout"}[1h])) /
          sum(rate(ecommerce_cart_operations_total{operation="add"}[1h])) < 0.05
        for: 30m
        labels:
          severity: warning
          category: business
        annotations:
          summary: "Cart conversion rate below 5%"
```

## Incident Response Playbook

### 1. DDoS Attack Response

**Step 1: Identify the attack vector**
```bash
# Check top attacking IPs
curl -s http://localhost:4010/metrics | grep requests_by_ip | sort -t'=' -k2 -nr | head -20

# Check attack pattern
curl -s http://localhost:4010/metrics | grep suspicious
```

**Step 2: Implement immediate mitigation**
```lua
-- Add to nginx.conf access_by_lua_block
local business_metrics = require("lib.business_metrics")
local remote_addr = ngx.var.remote_addr

-- Block known attacking IPs
local blocked_ips = {
    ["1.2.3.4"] = true,
    ["5.6.7.8"] = true,
}

if blocked_ips[remote_addr] then
    business_metrics.track_blocked_request(ngx.var.host, "ddos_blacklist")
    return ngx.exit(403)
end
```

**Step 3: Rate limiting**
```nginx
# Add to nginx http block
limit_req_zone $binary_remote_addr zone=per_ip:10m rate=10r/s;
limit_req_status 429;

# Add to location block
location / {
    limit_req zone=per_ip burst=20 nodelay;
    # ... rest of config
}
```

### 2. Application Attack Response

**Detect and block SQL injection attempts:**
```lua
local uri = ngx.var.uri
local args = ngx.var.args or ""

local sql_patterns = {
    "union.*select", "insert.*into", "delete.*from",
    "drop.*table", "--", "/*", "*/"
}

for _, pattern in ipairs(sql_patterns) do
    if uri:lower():match(pattern) or args:lower():match(pattern) then
        business_metrics.track_blocked_request(ngx.var.host, "sql_injection")
        return ngx.exit(403)
    end
end
```

### 3. Monitoring Dashboard Setup

**Essential panels for DDoS monitoring:**

1. **Request Rate Timeline** - Spot traffic spikes
2. **Top 20 IPs** - Identify potential attackers
3. **Error Rate by Endpoint** - Find targets
4. **Suspicious Patterns** - Security threats
5. **Geographic Map** (if GeoIP enabled) - Attack origin
6. **Connection States** - Resource exhaustion

## Command-Line Monitoring Tools

### Real-time monitoring script:
```bash
#!/bin/bash
# monitor-ddos.sh

while true; do
    clear
    echo "=== DDoS Monitoring Dashboard ==="
    echo "Time: $(date)"
    echo ""
    
    echo "Top 10 IPs by request count:"
    curl -s http://localhost:4010/metrics | \
        grep 'nginx_http_requests_by_ip_total' | \
        sort -t'=' -k2 -nr | head -10
    
    echo ""
    echo "Suspicious requests:"
    curl -s http://localhost:4010/metrics | grep 'suspicious_requests_total'
    
    echo ""
    echo "Error rates:"
    curl -s http://localhost:4010/metrics | \
        grep -E '4xx_errors_total|5xx_errors_total' | tail -5
    
    sleep 5
done
```

### Quick IP blocking:
```bash
#!/bin/bash
# block-ip.sh
IP=$1

if [ -z "$IP" ]; then
    echo "Usage: $0 <IP_ADDRESS>"
    exit 1
fi

# Add to nginx config or use iptables
iptables -I INPUT -s $IP -j DROP
echo "Blocked IP: $IP"

# Log the block
logger "DDoS mitigation: Blocked IP $IP"
```

## Integration with CloudFlare/WAF

### CloudFlare API integration:
```lua
-- Block IP at CloudFlare level
local http = require("resty.http")
local httpc = http.new()

local function block_ip_cloudflare(ip_address)
    local res, err = httpc:request_uri("https://api.cloudflare.com/client/v4/user/firewall/access_rules/rules", {
        method = "POST",
        body = cjson.encode({
            mode = "block",
            configuration = {
                target = "ip",
                value = ip_address
            },
            notes = "Auto-blocked by OpsAPI DDoS protection"
        }),
        headers = {
            ["X-Auth-Email"] = os.getenv("CF_EMAIL"),
            ["X-Auth-Key"] = os.getenv("CF_API_KEY"),
            ["Content-Type"] = "application/json"
        }
    })
    
    return res and res.status == 200
end
```

## Performance Tuning for High Traffic

### Nginx optimizations:
```nginx
# Worker connections
events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

# Keepalive
keepalive_timeout 65;
keepalive_requests 100;

# Buffers
client_body_buffer_size 128k;
client_max_body_size 10m;
client_header_buffer_size 1k;
large_client_header_buffers 4 8k;

# Timeouts
client_body_timeout 12;
client_header_timeout 12;
send_timeout 10;

# Connection limits
limit_conn_zone $binary_remote_addr zone=addr:10m;
limit_conn addr 10;
```

## Recommended Monitoring Stack

1. **Prometheus** - Metrics storage
2. **Grafana** - Visualization
3. **AlertManager** - Alert routing
4. **PagerDuty/Slack** - Incident notifications
5. **ELK Stack** - Log aggregation (optional)

## Testing DDoS Protection

### Simulate high traffic:
```bash
# Use Apache Bench
ab -n 10000 -c 100 http://localhost:4010/

# Use wrk
wrk -t12 -c400 -d30s http://localhost:4010/

# Monitor metrics during test
watch -n1 'curl -s http://localhost:4010/metrics | grep requests_by_ip'
```

## Further Reading

- [OWASP DDoS Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/naming/)
- [Nginx Rate Limiting](https://www.nginx.com/blog/rate-limiting-nginx/)
