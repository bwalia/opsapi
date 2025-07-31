local CorsMiddleware = {}

function CorsMiddleware.enable(app)
    app:before_filter(function(self)
        -- Set CORS headers for all requests
        self.res.headers["Access-Control-Allow-Origin"] = "http://localhost:3033"
        self.res.headers["Access-Control-Allow-Credentials"] = "true"
        self.res.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        self.res.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-User-Email, X-Public-Browse"
        
        -- Handle preflight OPTIONS requests
        if self.req.method == "OPTIONS" then
            return { status = 200 }
        end
    end)
end

return CorsMiddleware