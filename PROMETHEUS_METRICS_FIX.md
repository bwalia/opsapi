# Prometheus Metrics Fix Summary

## Problem
The Prometheus metrics endpoint was throwing errors:
```
attempt to index global 'metric_connections' (a nil value)
Prometheus metrics not initialized in log_by_lua
```

## Root Cause
1. The Prometheus library requires initialization in `init_worker_by_lua_block`
2. Metrics were being accessed in `content_by_lua` and `log_by_lua` phases without proper cross-context sharing
3. **Critical limitation**: Prometheus.init() can ONLY be called from init blocks, not from other nginx phases
4. **Development mode issue**: With `lua_code_cache off`, Lua modules are reloaded on every request, losing the initialized state

## Solution
Created a dedicated metrics module (`/app/lib/prometheus_metrics.lua`) that:
1. Stores Prometheus instances in `package.loaded` for cross-phase access
2. Initializes metrics once in `init_worker_by_lua_block`
3. Provides getter functions for safe access from any phase
4. Handles graceful degradation when metrics aren't available

## Important Limitation
**Prometheus metrics ONLY work with `lua_code_cache on`**

- In development mode (`code_cache = "off"`), metrics will show "# Prometheus metrics not available"
- In production mode (`code_cache = "on"`), metrics work perfectly
- This is a fundamental limitation of the nginx-lua-prometheus library

## Testing
With `code_cache = "on"`:
```bash
curl http://localhost:4010/metrics
```

Returns proper Prometheus metrics:
```
# HELP nginx_http_connections Number of HTTP connections
# TYPE nginx_http_connections gauge
nginx_http_connections{state="reading"} 0
nginx_http_connections{state="waiting"} 0
nginx_http_connections{state="writing"} 1
# HELP nginx_http_request_duration_seconds HTTP request latency
# TYPE nginx_http_request_duration_seconds histogram
...
# HELP nginx_http_requests_total Number of HTTP requests
# TYPE nginx_http_requests_total counter
nginx_http_requests_total{host="localhost",status="200"} 4
```

## Files Modified
1. `/app/lapis/nginx.conf` - Updated metrics initialization and access patterns
2. `/app/lapis/lib/prometheus_metrics.lua` - New module for metrics management
3. `/app/lapis/config.lua` - Added comment about code_cache requirement

## Recommendation
For production deployments, ensure `code_cache = "on"` in the configuration to enable Prometheus metrics.
