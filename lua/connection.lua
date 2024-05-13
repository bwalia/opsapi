local pgmoon = require("pgmoon")

local connection = {}
function connection.connectPgsql()
  local hostname = os.getenv("Host")
  if hostname == nil then
    hostname = "172.18.0.10"
  end
  local port = os.getenv("Port")
  if port == nil then
    port = 5432
  end
  local database = os.getenv("Database")
  if database == nil then
    database = "webimpetus-api"
  end
  local user = os.getenv("Username")
  if user == nil then
    user = "pguser"
  end
  local password = os.getenv("Password")
  if password == nil then
    password = "pgpassword"
  end

  local pg = pgmoon.new({
    host = hostname,
    port = port,
    database = database,
    user = user,
    password = password,
  })
  assert(pg:connect())
  return pg
end

function connection.connectMysql()
  local mysql = require "resty.mysql"
  local hostname = os.getenv("Host")
  if hostname == nil then
    hostname = "172.18.0.11"
  end
  local port = os.getenv("Port")
  if port == nil then
    port = 3306
  end
  local database = os.getenv("Database")
  if database == nil then
    database = "webimpetus-api"
  end
  local user = os.getenv("Username")
  if user == nil then
    user = "msuser"
  end
  local password = os.getenv("Password")
  if password == nil then
    password = "mspassword"
  end

  local db, err = mysql:new()
  if not db then
    ngx.say("failed to instantiate mysql: ", err)
    return
  end

  db:set_timeout(1000) -- 1 sec

  local ok, err, errcode, sqlstate = db:connect {
    host = hostname,
    port = port,
    database = database,
    user = user,
    password = password,
    charset = "utf8",
    max_packet_size = 1024 * 1024 * 256,
  }

  if not ok then
    ngx.say("failed to connect: ", err, ": ", errcode, " ", sqlstate)
    return
  end

return db
end

return connection
