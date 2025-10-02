local CorsMiddleware = {}

function CorsMiddleware.enable(app, pAllowCORSOrigins)
    -- If pAllowCORSOrigins is not provided, try to get it from environment variable
    if not pAllowCORSOrigins then
        local Global = require("helper.global")
        pAllowCORSOrigins = Global.getEnvVar("CORS_ORIGIN")
    end
    app:before_filter(function(self)
        -- Set CORS headers for all requests
        self.res.headers["Access-Control-Allow-Origin"] = pAllowCORSOrigins or "localhost:3133,http://localhost:4010,http://localhost:3000,http://localhost:8080,http://test-opsapi-node.workstation.co.uk,http://api.workstation.co.uk"
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