-- Lapis Libraries
local lapis = require("lapis")
local http = require("resty.http")
local respond_to = require("lapis.application").respond_to

-- Query files
local UserQueries = require "queries.UserQueries"
local RoleQueries = require "queries.RoleQueries"
local ModuleQueries = require "queries.ModuleQueries"
local PermissionQueries = require "queries.PermissionQueries"
local GroupQueries = require "queries.GroupQueries"
local SecretQueries = require "queries.SecretQueries"

-- Common Openresty Libraries
local cJson = require("cjson")

-- Other installed Libraries
local SwaggerUi = require "api-docs.swaggerUi"
local jwt = require("resty.jwt")

-- Helper Files
local File = require "helper.file"
local Global = require "helper.global"

-- Start Session
local session, sessionErr = require "resty.session".new()
if sessionErr then
  ngx.log(ngx.ERR, cJson.encode({
    message = "Failed to start session",
    details = sessionErr
  }))
end

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
  return { json = cJson.decode(swaggerJson) }
end)

----------------- Auth Routes --------------------

app:get("/auth/login", function(self)
  local keycloak_auth_url = os.getenv("KEYCLOAK_AUTH_URL")
  local client_id = os.getenv("KEYCLOAK_CLIENT_ID")
  local redirect_uri = os.getenv("KEYCLOAK_REDIRECT_URI")
  session:set("redirect_from", self.params.from)
  session:save()

  -- Redirect to Keycloak's login page
  local login_url = string.format(
    "%s?client_id=%s&redirect_uri=%s&response_type=code&scope=openid+profile+email",
    keycloak_auth_url,
    client_id,
    redirect_uri
  )
  return { redirect_to = login_url }
end)

app:get("/auth/callback", function(self)
  local httpc = http.new()
  local token_url = os.getenv("KEYCLOAK_TOKEN_URL")
  local client_id = os.getenv("KEYCLOAK_CLIENT_ID")
  local client_secret = os.getenv("KEYCLOAK_CLIENT_SECRET")
  local redirect_uri = os.getenv("KEYCLOAK_REDIRECT_URI")

  -- Exchange the authorization code for a token
  local res, err = httpc:request_uri(token_url, {
    method = "POST",
    body = ngx.encode_args({
      grant_type = "authorization_code",
      code = self.params.code,
      redirect_uri = redirect_uri,
      client_id = client_id,
      client_secret = client_secret,
      scope = "openid profile email"
    }),
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded"
    },
    ssl_verify = false
  })

  if not res then
    return { status = 500, json = { error = "Failed to fetch token: " .. (err or "unknown") } }
  end

  local token_response = cJson.decode(res.body)

  local userinfo_url = os.getenv("KEYCLOAK_USERINFO_URL")
  local usrRes, usrErr = httpc:request_uri(userinfo_url, {
    method = "GET",
    headers = {
      ["Authorization"] = "Bearer " .. token_response.access_token
    },
    scope = "openid profile email",
    ssl_verify = false
  })

  if not usrRes then
    return { status = 500, json = { error = "Failed to fetch user info: " .. (usrErr or "unknown") } }
  end

  local userinfo = cJson.decode(usrRes.body)
  if userinfo.email ~= nil and userinfo.sub ~= nil then
    local sessionData = session:get_data()

    ngx.say(cJson.encode(sessionData))
    ngx.exit(ngx.HTTP_OK)
    session:set(userinfo.sub, cJson.encode(token_response))
    session:save()

    local JWT_SECRET_KEY = os.getenv("JWT_SECRET_KEY")
    local token = jwt:sign(JWT_SECRET_KEY, {
      header = { typ = "JWT", alg = "HS256" },
      payload = userinfo,
    })
    local redirectURL = sessionData.redirect_from or ngx.redirect_uri
    local externalUrl = redirectURL .. "?token=" .. ngx.escape_uri(token)
    ngx.redirect(externalUrl, ngx.HTTP_MOVED_TEMPORARILY)
  end
  return { json = userinfo }
end)

app:get("/auth/logout", function(self)
  local sub = self.params.sub
  if not sub then
    return { status = 400, json = { error = "Sub ID is required for logout" } }
  end
  local sessionData = session:get_data()
  local loggedSession, refreshToken, accessToken = sessionData[sub], nil, nil
  if loggedSession then
    loggedSession = cJson.decode(loggedSession)
    refreshToken = loggedSession.refresh_token
    accessToken = loggedSession.access_token

    local keycloakAuthUrl = os.getenv("KEYCLOAK_AUTH_URL") or ""
    local client_id = os.getenv("KEYCLOAK_CLIENT_ID")
    local client_secret = os.getenv("KEYCLOAK_CLIENT_SECRET")
    local logoutUrl = keycloakAuthUrl:gsub("/auth$", "/logout")

    if refreshToken ~= nil and accessToken ~= nil then
      local postData = {
        client_id = client_id,
        client_secret = client_secret,
        refresh_token = refreshToken
      }

      local httpc = http.new()
      local res, err = httpc:request_uri(logoutUrl, {
        method = "POST",
        body = ngx.encode_args(postData),
        headers = {
          ["Authorization"] = "Bearer " .. accessToken,
          ["Content-Type"] = "application/x-www-form-urlencoded"
        },
        ssl_verify = false
      })

      if not res then
        return { status = 500, json = { error = "Failed to connect to Keycloak", details = err } }
      end
      if res.status == 200 then
        return { status = 200, json = { message = "Logout successful!", body = res.body } }
      else
        return { status = res.status, json = { error = "Logout failed", details = res.body } }
      end
    else
      return {
        status = 500,
        json = {
          error = "Session Data for token not found.",
        }
      }
    end
  else
    return { status = 500, json = { error = "Session Data not found." } }
  end
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

----------------- Secrets Routes --------------------

app:match("secrets", "/api/v2/secrets", respond_to({
  GET = function(self)
    self.params.timestamp = true
    local secrets = SecretQueries.all(self.params)
    return { json = secrets, status = 200 }
  end,
  POST = function(self)
    local user = SecretQueries.create(self.params)
    return { json = user, status = 201 }
  end
}))

app:match("edit_secrets", "/api/v2/secrets/:id", respond_to({
  before = function(self)
    self.user = SecretQueries.show(tostring(self.params.id))
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
    local user = SecretQueries.show(tostring(self.params.id))
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
    local user = SecretQueries.update(tostring(self.params.id), self.params)
    return { json = user, status = 204 }
  end,
  DELETE = function(self)
    local user = SecretQueries.destroy(tostring(self.params.id))
    return { json = user, status = 204 }
  end
}))

app:get("/api/v2/secrets/:id/show", function(self)
  local group, status = SecretQueries.showSecret(self.params.id)
  return { json = group, status = status }
end)


return app
