local config = require("lapis.config")

config("development", {
  port = 80,
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
    host = os.getenv("DB_HOST") or "172.72.0.10",
    user = os.getenv("DB_USER") or "pguser",
    password = os.getenv("DB_PASSWORD") or "pgpassword",
    database = os.getenv("DATABASE") or "opsapi"
  }
})
