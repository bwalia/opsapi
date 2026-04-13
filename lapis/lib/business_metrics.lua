-- Business metrics helper for application-level tracking
-- This module provides easy-to-use functions for tracking business KPIs
-- Usage: local business_metrics = require("lib.business_metrics")

local _M = {}

local function get_metrics()
    local ok, metrics = pcall(require, "lib.prometheus_metrics")
    if ok and metrics.is_initialized() then
        return metrics
    end
    return nil
end

-- E-commerce: Track cart operations
function _M.track_cart_operation(operation, status)
    local metrics = get_metrics()
    if not metrics then return end
    
    local metric = metrics.get_metric_cart_operations()
    if metric then
        metric:inc(1, {operation, status or "success"})
    end
end

-- E-commerce: Track order operations
function _M.track_order_operation(operation, status)
    local metrics = get_metrics()
    if not metrics then return end
    
    local metric = metrics.get_metric_order_operations()
    if metric then
        metric:inc(1, {operation, status or "success"})
    end
end

-- E-commerce: Track payment operations
function _M.track_payment_operation(provider, status)
    local metrics = get_metrics()
    if not metrics then return end
    
    local metric = metrics.get_metric_payment_operations()
    if metric then
        metric:inc(1, {provider or "unknown", status or "success"})
    end
end

-- E-commerce: Track product views
function _M.track_product_view(product_id)
    local metrics = get_metrics()
    if not metrics then return end
    
    local metric = metrics.get_metric_product_views()
    if metric then
        metric:inc(1, {tostring(product_id)})
    end
end

-- Database: Track query operations
function _M.track_database_query(operation, duration)
    local metrics = get_metrics()
    if not metrics then return end
    
    local counter = metrics.get_metric_database_queries()
    if counter then
        counter:inc(1, {operation})
    end
    
    if duration then
        local histogram = metrics.get_metric_database_latency()
        if histogram then
            histogram:observe(duration, {operation})
        end
    end
end

-- Cache: Track cache hits
function _M.track_cache_hit(cache_type)
    local metrics = get_metrics()
    if not metrics then return end
    
    local metric = metrics.get_metric_cache_hits()
    if metric then
        metric:inc(1, {cache_type or "default"})
    end
end

-- Cache: Track cache misses
function _M.track_cache_miss(cache_type)
    local metrics = get_metrics()
    if not metrics then return end
    
    local metric = metrics.get_metric_cache_misses()
    if metric then
        metric:inc(1, {cache_type or "default"})
    end
end

-- Security: Track blocked requests
function _M.track_blocked_request(host, reason)
    local metrics = get_metrics()
    if not metrics then return end
    
    local metric = metrics.get_metric_blocked_requests()
    if metric then
        metric:inc(1, {host or ngx.var.host, reason or "security_rule"})
    end
end

-- Security: Track rate limited requests
function _M.track_rate_limited(host, ip)
    local metrics = get_metrics()
    if not metrics then return end
    
    local metric = metrics.get_metric_rate_limited()
    if metric then
        metric:inc(1, {host or ngx.var.host, ip or ngx.var.remote_addr})
    end
end

-- Upstream: Track external service calls
function _M.track_upstream_request(upstream_name, status, duration)
    local metrics = get_metrics()
    if not metrics then return end
    
    local counter = metrics.get_metric_upstream_requests()
    if counter then
        counter:inc(1, {upstream_name, tostring(status)})
    end
    
    if duration then
        local histogram = metrics.get_metric_upstream_latency()
        if histogram then
            histogram:observe(duration, {upstream_name})
        end
    end
end

-- Wrapper for timing operations
function _M.time_operation(operation_fn, metric_fn)
    if not metric_fn then return operation_fn() end
    
    local start_time = ngx.now()
    local result = operation_fn()
    local duration = ngx.now() - start_time
    
    metric_fn(duration)
    return result
end

return _M
