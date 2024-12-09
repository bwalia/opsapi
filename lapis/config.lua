local config = require("lapis.config")

config("development", {
  server = "nginx",
  code_cache = "off",
  num_workers = "1",
  postgres = {
    host = "172.71.0.10",
    user = "pguser",
    password = "pgpassword",
    database = "opsapi"
  },
  sessions = {
    cookie_name = "lapis_session",
    cookie_renew = false,  -- set to true to renew session cookie on each request
    lifetime = 3600, -- session lifetime in seconds
  }
})
