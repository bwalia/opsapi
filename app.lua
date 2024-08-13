local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to
local UserModel = require "model.UserModel"
local RoleModel = require "model.RoleModel"
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
    local users = UserModel.all(self.params)
    return { json = users, status = 200}
  end,
  POST = function(self)
    local user = UserModel.create(self.params)
    return { json = user, status = 201 }
  end
}))

app:match("edit_user", "/api/v2/users/:id", respond_to({
  before = function(self)
    self.user = UserModel.show(tostring(self.params.id))
    if not self.user then
      self:write({ "Not Found", status = 404 })
    end
  end,
  GET = function(self)
    local user = UserModel.show(tostring(self.params.id))
    return {
      json = user,
      status = 200
    }
  end,
  PUT = function(self)
    local user = UserModel.update(tostring(self.params.id), self.params)
    return { json = user, status = 204 }
  end,
  DELETE = function(self)
    local user = UserModel.destroy(tostring(self.params.id))
    return { json = user, status = 204 }
  end
}))

app:match("roles", "/api/v2/roles", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local roles = RoleModel.all(self.params)
    return { json = roles }
  end,
  POST = function(self)
    local roles = RoleModel.create(self.params)
    return { json = roles, status = 201 }
  end
}))

app:match("edit_role", "/api/v2/roles/:id", respond_to({
  before = function(self)
    self.role = RoleModel.show(tostring(self.params.id))
    if not self.role then
      self:write({ "Not Found", status = 404 })
    end
  end,
  GET = function(self)
    local role = RoleModel.show(tostring(self.params.id))
    return {
      json = role,
      status = 200
    }
  end,
  PUT = function(self)
    local role = RoleModel.update(tostring(self.params.id), self.params)
    return { json = role, status = 204 }
  end,
  DELETE = function(self)
    local role = RoleModel.destroy(tostring(self.params.id))
    return { json = role, status = 204 }
  end
}))

return app
