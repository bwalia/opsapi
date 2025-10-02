# Enhanced Prometheus Metrics Guide

## Overview
This OpsAPI deployment includes comprehensive Prometheus metrics for performance monitoring, business analytics, and DDoS mitigation.

## Prerequisites
**IMPORTANT**: Metrics require `lua_code_cache = "on"` in production configuration.

## Metrics Categories

### 1. Basic HTTP Metrics

#### `nginx_http_requests_total`
- **Type**: Counter
- **Labels**: `host`, `status`, `method`, `endpoint`
- **Description**: Total number of HTTP requests
- **Use Case**: Track overall traffic patterns and API usage

#### `nginx_http_request_duration_seconds`
- **Type**: Histogram
- **Labels**: `host`, `method`, `endpoint`
- **Description**: Request processing latency
- **Use Case**: Identify slow endpoints, set SLA alerts

#### `nginx_http_connections`
- **Type**: Gauge
- **Labels**: `state` (reading, waiting, writing)
- **Description**: Current connection state
- **Use Case**: Monitor connection pool health

### 2. Request/Response Size Metrics

#### `nginx_http_request_size_bytes`
- **Type**: Histogram
- **Labels**: `host`, `method`
- **Description**: Size of incoming requests
- **Use Case**: Bandwidth monitoring, large upload detection

#### `nginx_http_response_size_bytes`
- **Type**: Histogram
- **Labels**: `host`, `method`, `status`
- **Description**: Size of responses sent
- **Use Case**: Bandwidth analysis, CDN optimization planning

### 3. Error Tracking Metrics

#### `nginx_http_errors_total`
- **Type**: Counter
- **Labels**: `host`, `status`, `endpoint`
- **Description**: All HTTP errors (4xx + 5xx)
- **Use Case**: Overall error rate monitoring

#### `nginx_http_4xx_errors_total`
- **Type**: Counter
- **Labels**: `host`, `status`, `endpoint`
- **Description**: Client errors (400-499)
- **Use Case**: Track bad requests, unauthorized access attempts

#### `nginx_http_5xx_errors_total`
- **Type**: Counter
- **Labels**: `host`, `status`, `endpoint`
- **Description**: Server errors (500-599)
- **Use Case**: Application health monitoring, alert on spikes

### 4. DDoS & Security Metrics

#### `nginx_http_requests_by_ip_total`
- **Type**: Counter
- **Labels**: `ip`, `host`
- **Description**: Requests per IP address
- **Use Case**: 
  - DDoS detection: Alert on >1000 req/min from single IP
  - Rate limiting decisions
  - Identify bot traffic

#### `nginx_http_suspicious_requests_total`
- **Type**: Counter
- **Labels**: `host`, `reason`
- **Reasons**: 
  - `no_user_agent`: Missing user agent
  - `path_traversal_attempt`: Contains `..` or `//`
  - `injection_attempt`: SQL/XSS patterns detected
  - `error_403`, `error_404`: Sequential errors
- **Use Case**: Security monitoring, WAF tuning

#### `nginx_http_blocked_requests_total`
- **Type**: Counter
- **Labels**: `host`, `reason`
- **Description**: Requests blocked by security rules
- **Use Case**: Track effectiveness of security measures

#### `nginx_http_rate_limited_total`
- **Type**: Counter
- **Labels**: `host`, `ip`
- **Description**: Rate-limited requests
- **Use Case**: Tune rate limiting thresholds

### 5. Business / API Metrics

#### `api_calls_total`
- **Type**: Counter
- **Labels**: `endpoint`, `method`, `status`
- **Description**: API endpoint usage
- **Use Case**: API analytics, deprecation planning

#### `api_auth_attempts_total`
- **Type**: Counter
- **Labels**: `result` (success/failure), `type` (method)
- **Description**: Authentication attempts
- **Use Case**: Security monitoring, credential stuffing detection

#### `api_auth_failures_total`
- **Type**: Counter
- **Labels**: `reason` (invalid_credentials, forbidden, other)
- **Description**: Failed authentication details
- **Use Case**: Alert on brute force attacks

### 6. Database Metrics

#### `api_database_queries_total`
- **Type**: Counter
- **Labels**: `operation` (SELECT, INSERT, UPDATE, DELETE)
- **Description**: Database query count
- **Use Case**: Query volume monitoring

#### `api_database_query_duration_seconds`
- **Type**: Histogram
- **Labels**: `operation`
- **Description**: Database query latency
- **Use Case**: Identify slow queries, database performance

### 7. E-commerce Metrics

#### `ecommerce_cart_operations_total`
- **Type**: Counter
- **Labels**: `operation` (add, remove, update, checkout), `status`
- **Description**: Shopping cart interactions
- **Use Case**: 
  - Conversion funnel analysis
  - Cart abandonment tracking

#### `ecommerce_order_operations_total`
- **Type**: Counter
- **Labels**: `operation` (create, update, cancel, complete), `status`
- **Description**: Order lifecycle events
- **Use Case**: Order flow analytics, revenue tracking

#### `ecommerce_payment_operations_total`
- **Type**: Counter
- **Labels**: `provider` (stripe, paypal, etc), `status`
- **Description**: Payment processing events
- **Use Case**: 
  - Payment success rate monitoring
  - Provider comparison

#### `ecommerce_product_views_total`
- **Type**: Counter
- **Labels**: `product_id`
- **Description**: Product page views
- **Use Case**: 
  - Popular product identification
  - Recommendation system input

### 8. Cache Metrics

#### `api_cache_hits_total`
- **Type**: Counter
- **Labels**: `cache_type` (redis, memory, etc)
- **Description**: Cache hits
- **Use Case**: Cache effectiveness monitoring

#### `api_cache_misses_total`
- **Type**: Counter
- **Labels**: `cache_type`
- **Description**: Cache misses
- **Use Case**: Cache tuning, hit rate optimization

### 9. Upstream Service Metrics

#### `nginx_upstream_requests_total`
- **Type**: Counter
- **Labels**: `upstream`, `status`
- **Description**: Requests to upstream services
- **Use Case**: External dependency monitoring

#### `nginx_upstream_response_time_seconds`
- **Type**: Histogram
- **Labels**: `upstream`
- **Description**: Upstream service latency
- **Use Case**: Identify slow external services

## Usage in Application Code

### Basic Example (Cart Operation)
```lua
local business_metrics = require("lib.business_metrics")

-- Track cart add operation
business_metrics.track_cart_operation("add", "success")

-- Track failed cart operation
business_metrics.track_cart_operation("checkout", "payment_failed")
```

### Database Query Tracking
```lua
local business_metrics = require("lib.business_metrics")

local start_time = ngx.now()
-- Execute your database query
local result = db:query("SELECT * FROM products WHERE id = ?", product_id)
local duration = ngx.now() - start_time

business_metrics.track_database_query("SELECT", duration)
```

### Payment Processing
```lua
local business_metrics = require("lib.business_metrics")

local success, result = stripe:process_payment(payment_data)
if success then
    business_metrics.track_payment_operation("stripe", "success")
else
    business_metrics.track_payment_operation("stripe", "failed")
end
```

### Product View Tracking
```lua
local business_metrics = require("lib.business_metrics")

-- In your product detail route
business_metrics.track_product_view(product.id)
```

### Cache Usage
```lua
local business_metrics = require("lib.business_metrics")

local cached_data = redis:get("product:" .. product_id)
if cached_data then
    business_metrics.track_cache_hit("redis")
    return cached_data
else
    business_metrics.track_cache_miss("redis")
    -- Fetch from database and cache
end
```

### External API Calls
```lua
local business_metrics = require("lib.business_metrics")

local start_time = ngx.now()
local res = httpc:request_uri("https://api.external.com/data")
local duration = ngx.now() - start_time

business_metrics.track_upstream_request("external_api", res.status, duration)
```

## Alerting Rules Examples

### DDoS Detection
```yaml
- alert: PossibleDDoSAttack
  expr: rate(nginx_http_requests_by_ip_total[1m]) > 1000
  for: 2m
  annotations:
    summary: "Possible DDoS attack from {{ $labels.ip }}"
```

### High Error Rate
```yaml
- alert: HighErrorRate
  expr: rate(nginx_http_5xx_errors_total[5m]) > 10
  for: 2m
  annotations:
    summary: "High server error rate on {{ $labels.endpoint }}"
```

### Suspicious Activity
```yaml
- alert: SuspiciousRequestSpike
  expr: rate(nginx_http_suspicious_requests_total[5m]) > 50
  for: 5m
  annotations:
    summary: "Spike in suspicious requests: {{ $labels.reason }}"
```

### Payment Failures
```yaml
- alert: HighPaymentFailureRate
  expr: |
    rate(ecommerce_payment_operations_total{status="failed"}[10m]) / 
    rate(ecommerce_payment_operations_total[10m]) > 0.1
  for: 5m
  annotations:
    summary: "Payment failure rate above 10%"
```

### Slow Database Queries
```yaml
- alert: SlowDatabaseQueries
  expr: histogram_quantile(0.95, api_database_query_duration_seconds) > 1.0
  for: 5m
  annotations:
    summary: "95th percentile of database queries > 1 second"
```

## Grafana Dashboard Panels

### DDoS Monitoring Panel
```promql
# Top IPs by request rate
topk(10, rate(nginx_http_requests_by_ip_total[5m]))

# Suspicious request rate
sum by (reason) (rate(nginx_http_suspicious_requests_total[5m]))
```

### Business Metrics Dashboard
```promql
# Cart conversion rate
sum(rate(ecommerce_cart_operations_total{operation="checkout"}[1h])) /
sum(rate(ecommerce_cart_operations_total{operation="add"}[1h]))

# Payment success rate
sum(rate(ecommerce_payment_operations_total{status="success"}[1h])) /
sum(rate(ecommerce_payment_operations_total[1h]))

# Top viewed products
topk(10, rate(ecommerce_product_views_total[1h]))
```

### Performance Dashboard
```promql
# Request latency (95th percentile)
histogram_quantile(0.95, 
  rate(nginx_http_request_duration_seconds_bucket[5m]))

# Error rate by endpoint
sum by (endpoint) (rate(nginx_http_errors_total[5m]))

# Cache hit rate
sum(rate(api_cache_hits_total[5m])) /
(sum(rate(api_cache_hits_total[5m])) + sum(rate(api_cache_misses_total[5m])))
```

## Testing Metrics

Enable code cache in config:
```lua
-- config.lua
config("development", {
  code_cache = "on",  -- Required for metrics
})
```

View metrics:
```bash
curl http://localhost:4010/metrics
```

## Performance Impact

- Minimal overhead when `lua_code_cache = "on"`
- Metrics collection adds ~0.5-1ms latency per request
- Shared dictionary uses 50MB memory (configurable)
- No impact on request processing when cache is off (metrics disabled)

## Security Considerations

1. **Metrics Endpoint Access**: Currently restricted to:
   - localhost (127.0.0.1)
   - Private networks (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
   
2. **Sensitive Data**: Metrics do NOT include:
   - User credentials
   - Session tokens
   - Request/response bodies
   - Personal information

3. **Cardinality**: Avoid high-cardinality labels:
   - Product IDs are string-converted (use with care)
   - IP addresses tracked (consider anonymization for GDPR)

## Troubleshooting

**Metrics not appearing:**
1. Check `lua_code_cache = "on"` in config
2. Verify initialization: `docker logs opsapi | grep "Prometheus metrics initialized"`
3. Check metrics endpoint access restrictions

**High memory usage:**
Increase shared dictionary size in nginx.conf:
```nginx
lua_shared_dict prometheus_metrics 100M;  # Default is 50M
```

**Missing business metrics:**
Ensure you're calling business_metrics functions in your Lapis application code.
