local config = require("lapis.config")

config("development", {
  server = "nginx",
  code_cache = "on", -- Required for Prometheus metrics to work properly
  num_workers = "1",
  session_name = "opsapi_session",
  secret = "your-secret-key-here-change-in-production",
  session_options = {
    lifetime = 3600 * 24 * 7, -- 7 days
    regen = 900, -- 15 minutes
    storage = "cookie",
    cookie = {
      persistent = true,
      renew = 600,
      lifetime = 3600 * 24 * 7,
      path = "/",
      domain = nil,
      secure = false,
      httponly = true,
      samesite = "Lax"
    }
  },
  postgres = {
    host = "172.71.0.10",
    user = "pguser",
    password = "pgpassword",
    database = "opsapi"
  }
})
