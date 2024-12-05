-- Lapis Libraries
local lapis = require("lapis")
local json = require("cjson")
local http = require("resty.http")
local oidc = require("resty.openidc")
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
local Global = require "helper.global"

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
  return { json = Json.decode(swaggerJson) }
end)

----------------- Auth Routes --------------------

app:get("/auth/login", function(self)
  local keycloak_auth_url = "https://sso-dev.workstation.co.uk/realms/lapis-opsapi/protocol/openid-connect/auth"
  local client_id = "opsapi"
  local redirect_uri = "https://api-test.brahmstra.org/auth/callback"
  local state = "development"

  -- Redirect to Keycloak's login page
  local login_url = string.format(
    "%s?client_id=%s&redirect_uri=%s&response_type=code&state=%s",
    keycloak_auth_url,
    client_id,
    redirect_uri,
    state
  )

  return { redirect_to = login_url }
end)

app:get("/auth/callback", function(self)
  -- local httpc = http.new()
  -- local token_url = "http://10.24.5.6:6060/realms/lapis-opsapi/protocol/openid-connect/token"
  -- local client_id = "opsapi"
  -- local client_secret = "2HBnKRFhc6Ikt7ZIW3bzK9uGETDjcSCb"
  -- local redirect_uri = "http://localhost:4010/auth/callback"

  -- -- Exchange the authorization code for a token
  -- local res, err = httpc:request_uri(token_url, {
  --   method = "POST",
  --   body = ngx.encode_args({
  --     grant_type = "authorization_code",
  --     code = self.params.code,
  --     redirect_uri = redirect_uri,
  --     client_id = client_id,
  --     client_secret = client_secret,
  --     scope = "openid profile email"
  --   }),
  --   headers = {
  --     ["Content-Type"] = "application/x-www-form-urlencoded"
  --   },
  --   ssl_verify = false
  -- })

  -- if not res then
  --   return { status = 500, json = { error = "Failed to fetch token: " .. (err or "unknown") } }
  -- end

  -- local token_response = json.decode(res.body)
  -- -- Optionally, fetch user info
  -- local userinfo_url = "http://10.24.5.6:6060/realms/lapis-opsapi/protocol/openid-connect/userinfo?schema=openid"
  -- local usrRes, usrErr = httpc:request_uri(userinfo_url, {
  --   method = "GET",
  --   headers = {
  --     Authorization = "Bearer " .. token_response.access_token,
  --     ['Accept'] = 'application/json'
  --   }
  -- })
  
  -- if not usrRes then
  --   return { status = 500, json = { error = "Failed to fetch user info: " .. (usrErr or "unknown") } }
  -- end
  -- ngx.say(json.encode(usrRes.body))
  -- ngx.exit(ngx.HTTP_OK)

  -- local userinfo = json.decode(usrRes.body)
  -- return { json = userinfo }

  local oidc_opts = {
    discovery = "https://sso-dev.workstation.co.uk/realms/lapis-opsapi/.well-known/openid-configuration",
    client_id = "opsapi",
    client_secret = "client_id",
    redirect_uri = "https://api-test.brahmstra.org/callback",
    scope = "openid email profile"
  }

  local res, err = oidc.authenticate(oidc_opts)

  if err then
    self.status = 500
    return { json = { error = "Authentication failed: " .. err } }
  end

  -- Save user information to session or database as needed
  self.session.user = res
  return { json = res }
end)

app:get("/protected", function(self)
  if not self.session.user then
    return { status = 401, json = { error = "Unauthorized" } }
  end

  return { json = { message = "Welcome!", user = self.session.user } }
end)

----------------- User Routes --------------------
app:match("users", "/api/v2/users", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local users = UserQueries.all(self.params)
    return { json = users, status = 200 }
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
      self:write({
        json = {
          lapis = { version = require("lapis.version") },
          error = "User not found! Please check the UUID and try again."
        },
        status = 404
      })
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
      return {
        json = {
          lapis = { version = require("lapis.version") },
          error = "assert_valid was not captured: You cannot update email, username or password directly"
        },
        status = 500
      }
    end
    if not self.params.id then
      return {
        json = {
          lapis = { version = require("lapis.version") },
          error = "assert_valid was not captured: Please pass the uuid of user that you want to update"
        },
        status = 500
      }
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
    return { json = users, status = 200 }
  end,
  POST = function(self)
    local user = UserQueries.SCIMcreate(self.params)
    return { json = user, status = 201 }
  end
}))

app:match("edit_scim_user", "/scim/v2/Users/:id", respond_to({
  before = function(self)
    self.user = UserQueries.show(tostring(self.params.id))
    if not self.user then
      self:write({
        json = {
          lapis = { version = require("lapis.version") },
          error = "User not found! Please check the UUID and try again."
        },
        status = 404
      })
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
    local content_type = self.req.headers["content-type"]
    local body = self.params
    if content_type == "application/json" then
      ngx.req.read_body()
      body = Global.getPayloads(ngx.req.get_post_args())
    end
    local user, status = UserQueries.SCIMupdate(tostring(self.params.id), body)
    return { json = user, status = status }
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
      self:write({
        json = {
          lapis = { version = require("lapis.version") },
          error = "Role not found! Please check the UUID and try again."
        },
        status = 404
      })
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
      self:write({
        json = {
          lapis = { version = require("lapis.version") },
          error = "Role not found! Please check the UUID and try again."
        },
        status = 404
      })
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
      self:write({
        json = {
          lapis = { version = require("lapis.version") },
          error = "Role not found! Please check the UUID and try again."
        },
        status = 404
      })
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
      self:write({
        json = {
          lapis = { version = require("lapis.version") },
          error = "Group not found! Please check the UUID and try again."
        },
        status = 404
      })
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
  local group, status = GroupQueries.addMember(self.params.id, self.params.user_id)
  return { json = group, status = status }
end)

----------------- SCIM Group Routes --------------------
app:match("scim_groups", "/scim/v2/Groups", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local groups = GroupQueries.SCIMall(self.params)
    return { json = groups }
  end,
  POST = function(self)
    local groups = GroupQueries.create(self.params)
    return { json = groups, status = 201 }
  end
}))

app:match("edit_scim_group", "/scim/v2/Groups/:id", respond_to({
  before = function(self)
    self.group = GroupQueries.show(tostring(self.params.id))
    if not self.group then
      self:write({
        json = {
          lapis = { version = require("lapis.version") },
          error = "Group not found! Please check the UUID and try again."
        },
        status = 404
      })
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
    local content_type = self.req.headers["content-type"]
    local body = self.params
    if content_type == "application/json" then
      ngx.req.read_body()
      body = Global.getPayloads(ngx.req.get_post_args())
    end
    local group, status = GroupQueries.SCIMupdate(tostring(self.params.id), body)
    return { json = group, status = status }
  end,
  DELETE = function(self)
    local group = GroupQueries.destroy(tostring(self.params.id))
    return { json = group, status = 204 }
  end
}))
return app
