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
  }
})
