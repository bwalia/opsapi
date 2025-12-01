local respond_to = require("lapis.application").respond_to

return function(app)
    -- Test endpoint to verify logging works
    app:match("test_logs", "/api/v2/test-logs", respond_to({
        GET = function(self)
            ngx.log(ngx.INFO, "=== TEST LOG ENDPOINT CALLED ===")
            ngx.log(ngx.INFO, "Request method: " .. ngx.var.request_method)
            ngx.log(ngx.INFO, "Request URI: " .. ngx.var.request_uri)
            ngx.log(ngx.INFO, "User agent: " .. (ngx.var.http_user_agent or "none"))
            
            return { json = { 
                message = "Test logs generated successfully",
                timestamp = os.time(),
                logs_written = "Check error.log for INFO level logs"
            }}
        end
    }))
end