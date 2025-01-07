local config = require("lapis.config")

config("development", {
  server = "nginx",
  code_cache = "off",
  num_workers = "1",
  session_name = "session",
  postgres = {
    host = "172.71.0.10",
    user = "pguser",
    password = "pgpassword",
    database = "opsapi"
  }
})
