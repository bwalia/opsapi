local config = require("lapis.config")

config("development", {
  server = "nginx",
  code_cache = "off",
  num_workers = "1",
  postgres = {
    host = os.getenv("DB_HOST"),
    user = os.getenv("DB_USER"),
    port = os.getenv("DB_PORT"),
    password = os.getenv("DB_PASSWORD"),
    database = os.getenv("DATABASE")
  },
  sessions = {
    cookie_name = "lapis_session",
    cookie_renew = false,  -- set to true to renew session cookie on each request
    lifetime = 3600, -- session lifetime in seconds
  }
})
