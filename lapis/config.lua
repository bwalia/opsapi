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
    host = os.getenv("POSTGRES_HOST") or "172.72.0.10",
    user = os.getenv("POSTGRES_USER") or "pguser",
    password = os.getenv("POSTGRES_PASSWORD") or "pgpassword",
    database = os.getenv("POSTGRES_DB") or "opsapi-diytaxreturn",
    -- Enable TLS when POSTGRES_SSL=true. The k3s Zalando Postgres enforces
    -- SSL via pg_hba (`hostnossl all all all reject`), so a plaintext
    -- connection is rejected with "no encryption" and every DB call fails.
    -- ssl_verify=false because Zalando serves a self-signed cert. Docker /
    -- test Postgres leaves POSTGRES_SSL unset and keeps connecting plaintext.
    ssl = os.getenv("POSTGRES_SSL") == "true" or nil,
    ssl_verify = false
  }
})

config("production", {
  port = 80,
  server = "nginx",
  code_cache = "on",
  num_workers = "1",
  session_name = "opsapi_session",
  secret = os.getenv("JWT_SECRET_KEY") or "change-me-in-production",
  postgres = {
    host = os.getenv("POSTGRES_HOST") or "127.0.0.1",
    user = os.getenv("POSTGRES_USER") or "pguser",
    password = os.getenv("POSTGRES_PASSWORD") or "pgpassword",
    database = os.getenv("POSTGRES_DB") or "opsapi",
    port = tonumber(os.getenv("POSTGRES_PORT") or "5432"),
    ssl = os.getenv("POSTGRES_SSL") == "true" or nil,
    ssl_verify = false
  }
})

-- Non-prod deployment environments. Each is a real deployment target
-- (test on 192.168.1.193 docker, int in k3s, acc in k3s) — but from
-- the Lapis process's perspective they all need the same nginx setup
-- as development: listen on 80, use the same postgres connection
-- parameters, same session/cookie scheme. Without these blocks
-- `lapis server` would fall back to its built-in default (port 8080)
-- whenever LAPIS_ENVIRONMENT is "int" / "test" / "acc", which silently
-- broke the docker healthcheck (which curls port 80) — that's what
-- got us here.
--
-- Each block is identical to "development" right now; this is the
-- right shape to hang env-specific overrides off later (e.g. custom
-- postgres host on acc) without losing the port=80 baseline.
local non_prod_envs = { "test", "int", "acc", "local" }
for _, env_name in ipairs(non_prod_envs) do
  config(env_name, {
    port = 80,
    server = "nginx",
    code_cache = "on",
    num_workers = "1",
    session_name = "opsapi_session",
    secret = os.getenv("JWT_SECRET_KEY") or "your-secret-key-here-change-in-production",
    session_options = {
      lifetime = 3600 * 24 * 7,
      regen = 900,
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
      host = os.getenv("POSTGRES_HOST") or "172.72.0.10",
      user = os.getenv("POSTGRES_USER") or "pguser",
      password = os.getenv("POSTGRES_PASSWORD") or "pgpassword",
      database = os.getenv("POSTGRES_DB") or "opsapi-diytaxreturn",
      port = tonumber(os.getenv("POSTGRES_PORT") or "5432"),
      ssl = os.getenv("POSTGRES_SSL") == "true" or nil,
      ssl_verify = false
    }
  })
end
