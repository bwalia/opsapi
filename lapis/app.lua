-- Lapis Libraries
local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to

-- Query files
local UserQueries = require "queries.UserQueries"
local RoleQueries = require "queries.RoleQueries"
local ModuleQueries = require "queries.ModuleQueries"

-- Common Openresty Libraries
local Json = require("cjson")

-- Other installed Libraries
local SwaggerUi = require "api-docs.swaggerUi"

-- Helper Files
local File = require "helper.file"

-- Initilising Lapis
local app = lapis.Application()
app:enable("etlua")

----------------- Home Page Route --------------------
app:get("/", function()
  SwaggerUi.generate()
  return { render = "swagger-ui" }
end)
app:get("/swagger/swagger.json", function()
  local swaggerJson = File.readFile("api-docs/swagger.json")
  return {json = Json.decode(swaggerJson)}
end)

----------------- User Routes --------------------
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
      self:write({ json = {
        lapis = { version = require("lapis.version") },
        error = "User not found! Please check the UUID and try again."
      }, status = 404 })
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
    if self.params.email or self.params.username or self.params.password then
      return {json = {
        lapis = { version = require("lapis.version") },
        error = "assert_valid was not captured: You cannot update email, username or password directly"
      }, status = 500}
    end
    if not self.params.id then
      return {json = {
        lapis = { version = require("lapis.version") },
        error = "assert_valid was not captured: Please pass the uuid of user that you want to update"
      }, status = 500}
    end
    local user = UserQueries.update(tostring(self.params.id), self.params)
    return { json = user, status = 204 }
  end,
  DELETE = function(self)
    local user = UserQueries.destroy(tostring(self.params.id))
    return { json = user, status = 204 }
  end
}))

----------------- Role Routes --------------------
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
      self:write({ json = {
        lapis = { version = require("lapis.version") },
        error = "Role not found! Please check the UUID and try again."
      }, status = 404 })
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

----------------- Modules Routes --------------------
app:match("modules", "/api/v2/modules", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local roles = ModuleQueries.all(self.params)
    return { json = roles }
  end,
  POST = function(self)
    local roles = ModuleQueries.create(self.params)
    return { json = roles, status = 201 }
  end
}))

app:match("edit_module", "/api/v2/modules/:id", respond_to({
  before = function(self)
    self.role = ModuleQueries.show(tostring(self.params.id))
    if not self.role then
      self:write({ json = {
        lapis = { version = require("lapis.version") },
        error = "Role not found! Please check the UUID and try again."
      }, status = 404 })
    end
  end,
  GET = function(self)
    local role = ModuleQueries.show(tostring(self.params.id))
    return {
      json = role,
      status = 200
    }
  end,
  PUT = function(self)
    local role = ModuleQueries.update(tostring(self.params.id), self.params)
    return { json = role, status = 204 }
  end,
  DELETE = function(self)
    local role = ModuleQueries.destroy(tostring(self.params.id))
    return { json = role, status = 204 }
  end
}))

return app
