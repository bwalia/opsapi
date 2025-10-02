-- Prometheus metrics module for sharing metrics across nginx contexts
-- NOTE: Prometheus metrics require lua_code_cache to be ON
-- With lua_code_cache OFF (development mode), metrics will not be available
local _M = {}

local DICT_NAME = "prometheus_metrics"

-- Initialize prometheus - must be called from init_worker_by_lua_block
function _M.init()
    if package.loaded._prometheus_instance then
        -- Already initialized
        return true
    end
    
    local ok, prometheus_lib = pcall(require, "prometheus")
    if not ok then
        ngx.log(ngx.ERR, "Failed to load prometheus library: ", prometheus_lib)
        return false
    end
    
    local ok2, prometheus = pcall(prometheus_lib.init, DICT_NAME)
    if not ok2 then
        ngx.log(ngx.ERR, "Failed to initialize prometheus: ", prometheus)
        return false
    end
    
    if not prometheus then
        ngx.log(ngx.ERR, "Prometheus init returned nil")
        return false
    end
    
    -- Store in package.loaded which persists when lua_code_cache is ON
    package.loaded._prometheus_instance = prometheus
    
    -- Basic HTTP metrics
    package.loaded._metric_requests = prometheus:counter("nginx_http_requests_total", "Number of HTTP requests", {"host", "status", "method", "endpoint"})
    package.loaded._metric_latency = prometheus:histogram("nginx_http_request_duration_seconds", "HTTP request latency", {"host", "method", "endpoint"})
    package.loaded._metric_connections = prometheus:gauge("nginx_http_connections", "Number of HTTP connections", {"state"})
    
    -- Request size metrics for bandwidth monitoring
    package.loaded._metric_request_size = prometheus:histogram("nginx_http_request_size_bytes", "HTTP request size in bytes", {"host", "method"})
    package.loaded._metric_response_size = prometheus:histogram("nginx_http_response_size_bytes", "HTTP response size in bytes", {"host", "method", "status"})
    
    -- Error tracking
    package.loaded._metric_errors = prometheus:counter("nginx_http_errors_total", "Number of HTTP errors", {"host", "status", "endpoint"})
    package.loaded._metric_4xx_errors = prometheus:counter("nginx_http_4xx_errors_total", "Number of 4xx client errors", {"host", "status", "endpoint"})
    package.loaded._metric_5xx_errors = prometheus:counter("nginx_http_5xx_errors_total", "Number of 5xx server errors", {"host", "status", "endpoint"})
    
    -- DDoS / Security metrics
    package.loaded._metric_requests_per_ip = prometheus:counter("nginx_http_requests_by_ip_total", "Requests per IP address", {"ip", "host"})
    package.loaded._metric_suspicious_requests = prometheus:counter("nginx_http_suspicious_requests_total", "Suspicious request patterns", {"host", "reason"})
    package.loaded._metric_blocked_requests = prometheus:counter("nginx_http_blocked_requests_total", "Blocked requests", {"host", "reason"})
    package.loaded._metric_rate_limited = prometheus:counter("nginx_http_rate_limited_total", "Rate limited requests", {"host", "ip"})
    
    -- Business / API metrics
    package.loaded._metric_api_calls = prometheus:counter("api_calls_total", "API endpoint calls", {"endpoint", "method", "status"})
    package.loaded._metric_auth_attempts = prometheus:counter("api_auth_attempts_total", "Authentication attempts", {"result", "type"})
    package.loaded._metric_auth_failures = prometheus:counter("api_auth_failures_total", "Authentication failures", {"reason"})
    package.loaded._metric_database_queries = prometheus:counter("api_database_queries_total", "Database query count", {"operation"})
    package.loaded._metric_database_latency = prometheus:histogram("api_database_query_duration_seconds", "Database query latency", {"operation"})
    
    -- E-commerce specific metrics
    package.loaded._metric_cart_operations = prometheus:counter("ecommerce_cart_operations_total", "Cart operations", {"operation", "status"})
    package.loaded._metric_order_operations = prometheus:counter("ecommerce_order_operations_total", "Order operations", {"operation", "status"})
    package.loaded._metric_payment_operations = prometheus:counter("ecommerce_payment_operations_total", "Payment operations", {"provider", "status"})
    package.loaded._metric_product_views = prometheus:counter("ecommerce_product_views_total", "Product page views", {"product_id"})
    
    -- Cache metrics
    package.loaded._metric_cache_hits = prometheus:counter("api_cache_hits_total", "Cache hits", {"cache_type"})
    package.loaded._metric_cache_misses = prometheus:counter("api_cache_misses_total", "Cache misses", {"cache_type"})
    
    -- Upstream / External service metrics
    package.loaded._metric_upstream_requests = prometheus:counter("nginx_upstream_requests_total", "Upstream service requests", {"upstream", "status"})
    package.loaded._metric_upstream_latency = prometheus:histogram("nginx_upstream_response_time_seconds", "Upstream response time", {"upstream"})
    
    ngx.log(ngx.NOTICE, "Prometheus metrics initialized successfully with enhanced monitoring")
    return true
end

function _M.get_prometheus()
    return package.loaded._prometheus_instance
end

-- Basic HTTP metrics
function _M.get_metric_requests()
    return package.loaded._metric_requests
end

function _M.get_metric_latency()
    return package.loaded._metric_latency
end

function _M.get_metric_connections()
    return package.loaded._metric_connections
end

function _M.get_metric_request_size()
    return package.loaded._metric_request_size
end

function _M.get_metric_response_size()
    return package.loaded._metric_response_size
end

-- Error metrics
function _M.get_metric_errors()
    return package.loaded._metric_errors
end

function _M.get_metric_4xx_errors()
    return package.loaded._metric_4xx_errors
end

function _M.get_metric_5xx_errors()
    return package.loaded._metric_5xx_errors
end

-- Security / DDoS metrics
function _M.get_metric_requests_per_ip()
    return package.loaded._metric_requests_per_ip
end

function _M.get_metric_suspicious_requests()
    return package.loaded._metric_suspicious_requests
end

function _M.get_metric_blocked_requests()
    return package.loaded._metric_blocked_requests
end

function _M.get_metric_rate_limited()
    return package.loaded._metric_rate_limited
end

-- Business / API metrics
function _M.get_metric_api_calls()
    return package.loaded._metric_api_calls
end

function _M.get_metric_auth_attempts()
    return package.loaded._metric_auth_attempts
end

function _M.get_metric_auth_failures()
    return package.loaded._metric_auth_failures
end

function _M.get_metric_database_queries()
    return package.loaded._metric_database_queries
end

function _M.get_metric_database_latency()
    return package.loaded._metric_database_latency
end

-- E-commerce metrics
function _M.get_metric_cart_operations()
    return package.loaded._metric_cart_operations
end

function _M.get_metric_order_operations()
    return package.loaded._metric_order_operations
end

function _M.get_metric_payment_operations()
    return package.loaded._metric_payment_operations
end

function _M.get_metric_product_views()
    return package.loaded._metric_product_views
end

-- Cache metrics
function _M.get_metric_cache_hits()
    return package.loaded._metric_cache_hits
end

function _M.get_metric_cache_misses()
    return package.loaded._metric_cache_misses
end

-- Upstream metrics
function _M.get_metric_upstream_requests()
    return package.loaded._metric_upstream_requests
end

function _M.get_metric_upstream_latency()
    return package.loaded._metric_upstream_latency
end

function _M.is_initialized()
    return package.loaded._prometheus_instance ~= nil
end

return _M
