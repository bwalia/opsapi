local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to
local UserQueries = require "queries.UserQueries"
local RoleQueries = require "queries.RoleQueries"
local Json = require("cjson")
local SwaggerUi = require "api-docs.swaggerUi"
local File = require "helper.file"
local app = lapis.Application()
app:enable("etlua")

app:get("/", function()
  SwaggerUi.generate()
  return { render = "swagger-ui" }
end)
app:get("/swagger/swagger.json", function()
  local swaggerJson = File.readFile("api-docs/swagger.json")
  return {json = Json.decode(swaggerJson)}
end)

app:match("users", "/api/v2/users", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local users = UserQueries.all(self.params)
    return { json = users, status = 200}
  end,
  POST = function(self)
    local user = UserQueries.create(self.params)
    return { json = user, status = 201 }
  end
}))

app:match("edit_user", "/api/v2/users/:id", respond_to({
  before = function(self)
    self.user = UserQueries.show(tostring(self.params.id))
    if not self.user then
      self:write({ "Not Found", status = 404 })
    end
  end,
  GET = function(self)
    local user = UserQueries.show(tostring(self.params.id))
    return {
      json = user,
      status = 200
    }
  end,
  PUT = function(self)
    local user = UserQueries.update(tostring(self.params.id), self.params)
    return { json = user, status = 204 }
  end,
  DELETE = function(self)
    local user = UserQueries.destroy(tostring(self.params.id))
    return { json = user, status = 204 }
  end
}))

app:match("roles", "/api/v2/roles", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local roles = RoleQueries.all(self.params)
    return { json = roles }
  end,
  POST = function(self)
    local roles = RoleQueries.create(self.params)
    return { json = roles, status = 201 }
  end
}))

app:match("edit_role", "/api/v2/roles/:id", respond_to({
  before = function(self)
    self.role = RoleQueries.show(tostring(self.params.id))
    if not self.role then
      self:write({ "Not Found", status = 404 })
    end
  end,
  GET = function(self)
    local role = RoleQueries.show(tostring(self.params.id))
    return {
      json = role,
      status = 200
    }
  end,
  PUT = function(self)
    local role = RoleQueries.update(tostring(self.params.id), self.params)
    return { json = role, status = 204 }
  end,
  DELETE = function(self)
    local role = RoleQueries.destroy(tostring(self.params.id))
    return { json = role, status = 204 }
  end
}))

return app
