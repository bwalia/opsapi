-- Lapis Libraries
local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to

-- Query files
local UserQueries = require "queries.UserQueries"
local RoleQueries = require "queries.RoleQueries"
local ModuleQueries = require "queries.ModuleQueries"
local PermissionQueries = require "queries.PermissionQueries"
local GroupQueries = require "queries.GroupQueries"

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

----------------- SCIM User Routes --------------------
app:match("scim_users", "/scim/v2/Users", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local users = UserQueries.SCIMall(self.params)
    return { json = users, status = 200}
  end,
  POST = function(self)
    local user = UserQueries.create(self.params)
    return { json = user, status = 201 }
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

----------------- Permission Routes --------------------
app:match("permissions", "/api/v2/permissions", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local roles = PermissionQueries.all(self.params)
    return { json = roles }
  end,
  POST = function(self)
    local roles = PermissionQueries.create(self.params)
    return { json = roles, status = 201 }
  end
}))

app:match("edit_permission", "/api/v2/permissions/:id", respond_to({
  before = function(self)
    self.role = PermissionQueries.show(tostring(self.params.id))
    if not self.role then
      self:write({ json = {
        lapis = { version = require("lapis.version") },
        error = "Role not found! Please check the UUID and try again."
      }, status = 404 })
    end
  end,
  GET = function(self)
    local role = PermissionQueries.show(tostring(self.params.id))
    return {
      json = role,
      status = 200
    }
  end,
  PUT = function(self)
    local role = PermissionQueries.update(tostring(self.params.id), self.params)
    return { json = role, status = 204 }
  end,
  DELETE = function(self)
    local role = PermissionQueries.destroy(tostring(self.params.id))
    return { json = role, status = 204 }
  end
}))

----------------- Group Routes --------------------
app:match("groups", "/api/v2/groups", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local groups = GroupQueries.all(self.params)
    return { json = groups }
  end,
  POST = function(self)
    local groups = GroupQueries.create(self.params)
    return { json = groups, status = 201 }
  end
}))

app:match("edit_group", "/api/v2/groups/:id", respond_to({
  before = function(self)
    self.group = GroupQueries.show(tostring(self.params.id))
    if not self.group then
      self:write({ json = {
        lapis = { version = require("lapis.version") },
        error = "Group not found! Please check the UUID and try again."
      }, status = 404 })
    end
  end,
  GET = function(self)
    local group = GroupQueries.show(tostring(self.params.id))
    return {
      json = group,
      status = 200
    }
  end,
  PUT = function(self)
    local group = GroupQueries.update(tostring(self.params.id), self.params)
    return { json = group, status = 204 }
  end,
  DELETE = function(self)
    local group = GroupQueries.destroy(tostring(self.params.id))
    return { json = group, status = 204 }
  end
}))

app:post("/api/v2/groups/:id/members", function(self)
  local group, status = GroupQueries.addMember(self.params.id, self.params)
  return { json = group, status = status }
end)

----------------- SCIM Group Routes --------------------
app:match("scim_groups", "/scim/v2/Groups", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local groups = GroupQueries.all(self.params)
    return { json = groups }
  end,
  POST = function(self)
    local groups = GroupQueries.create(self.params)
    return { json = groups, status = 201 }
  end
}))

return app
