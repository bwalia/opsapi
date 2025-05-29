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
local ProjectQueries = require "queries.ProjectQueries"
local TemplateQueries = require "queries.TemplateQueries"
local DocumentQueries = require "queries.DocumentQueries"
local TagsQueries = require "queries.TagsQueries"

-- Common Openresty Libraries
local cJson = require("cjson")

-- Other installed Libraries
local SwaggerUi = require "api-docs.swaggerUi"
local jwt = require("resty.jwt")

-- Helper Files
local File = require "helper.file"
local Global = require "helper.global"

-- Initilising Lapis
local app = lapis.Application()
app:enable("etlua")

----------------- Home Page Route --------------------
app:get("/", function()
    SwaggerUi.generate()
    return {
        render = "swagger-ui"
    }
end)
app:get("/swagger/swagger.json", function()
    local swaggerJson = File.readFile("api-docs/swagger.json")
    return {
        json = cJson.decode(swaggerJson)
    }
end)

----------------- Auth Routes --------------------

app:post("/auth/login", function(self)
    local email = self.params.username
    local password = self.params.password

    if not email or not password then
        return {
            status = 400,
            json = {
                error = "Email and password are required"
            }
        }
    end

    local user = UserQueries.verify(email, password)

    if not user then
        return {
            status = 401,
            json = {
                error = "Invalid email or password"
            }
        }
    end

    local JWT_SECRET_KEY = os.getenv("JWT_SECRET_KEY")
    local token = jwt:sign(JWT_SECRET_KEY, {
        header = {
            typ = "JWT",
            alg = "HS256"
        },
        payload = {
            userinfo = user,
            token_response = {}
        }
    })

    -- You can also return a JWT token here
    return {
        status = 200,
        json = {
            user = {
                id = user.uuid,
                email = user.email,
                name = user.name
            },
            token = token
        }
    }
end)

app:get("/auth/login", function(self)
    local keycloak_auth_url = os.getenv("KEYCLOAK_AUTH_URL")
    local client_id = os.getenv("KEYCLOAK_CLIENT_ID")
    local redirect_uri = os.getenv("KEYCLOAK_REDIRECT_URI")

    self.cookies.redirect_from = self.params.from

    local session, sessionErr = require "resty.session".new()
    session:set("redirect_from", self.params.from)
    session:save()

    -- Redirect to Keycloak's login page
    local login_url = string.format("%s?client_id=%s&redirect_uri=%s&response_type=code&scope=openid+profile+email",
        keycloak_auth_url, client_id, redirect_uri)
    return {
        redirect_to = login_url
    }
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
        return {
            status = 500,
            json = {
                error = "Failed to fetch token: " .. (err or "unknown")
            }
        }
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
        return {
            status = 500,
            json = {
                error = "Failed to fetch user info: " .. (usrErr or "unknown")
            }
        }
    end

    local userinfo = cJson.decode(usrRes.body)
    if userinfo.email ~= nil and userinfo.sub ~= nil then
        local session, sessionErr = require "resty.session".start()
        session:set(userinfo.sub, cJson.encode(token_response))
        session:save()

        local JWT_SECRET_KEY = os.getenv("JWT_SECRET_KEY")
        local token = jwt:sign(JWT_SECRET_KEY, {
            header = {
                typ = "JWT",
                alg = "HS256"
            },
            payload = {
                userinfo = userinfo,
                token_response = token_response
            }
        })
        local redirectURL = self.cookies.redirect_from or ngx.redirect_uri
        local externalUrl = redirectURL .. "?token=" .. ngx.escape_uri(token)
        ngx.redirect(externalUrl, ngx.HTTP_MOVED_TEMPORARILY)
    end
    return {
        json = userinfo
    }
end)

app:post("/auth/logout", function(self)
    local payloads = self.params
    if not payloads then
        return {
            status = 400,
            json = {
                error = "Refresh and Access Tokens are required."
            }
        }
    end

    local refreshToken, accessToken = nil, nil
    if payloads then
        refreshToken = payloads.refreshToken
        accessToken = payloads.accessToken

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
                return {
                    status = 500,
                    json = {
                        error = "Failed to connect to Keycloak",
                        details = err
                    }
                }
            end
            if res.status == 200 then
                return {
                    status = 200,
                    json = {
                        message = "Logout successful!",
                        body = res.body
                    }
                }
            else
                return {
                    status = res.status,
                    json = {
                        error = "Logout failed",
                        details = res.body
                    }
                }
            end
        else
            return {
                status = 500,
                json = {
                    error = "Session Data for token not found."
                }
            }
        end
    else
        return {
            status = 500,
            json = {
                error = "Session Data not found."
            }
        }
    end
end)

----------------- User Routes --------------------
app:match("users", "/api/v2/users", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local users = UserQueries.all(self.params)
        return {
            json = users,
            status = 200
        }
    end,
    POST = function(self)
        local user = UserQueries.create(self.params)
        return {
            json = user,
            status = 201
        }
    end
}))

app:match("edit_user", "/api/v2/users/:id", respond_to({
    before = function(self)
        self.user = UserQueries.show(tostring(self.params.id))
        if not self.user then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
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
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "assert_valid was not captured: You cannot update email, username or password directly"
                },
                status = 500
            }
        end
        if not self.params.id then
            return {
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "assert_valid was not captured: Please pass the uuid of user that you want to update"
                },
                status = 500
            }
        end
        local user = UserQueries.update(tostring(self.params.id), self.params)
        return {
            json = user,
            status = 204
        }
    end,
    DELETE = function(self)
        local user = UserQueries.destroy(tostring(self.params.id))
        return {
            json = user,
            status = 204
        }
    end
}))

----------------- SCIM User Routes --------------------
app:match("scim_users", "/scim/v2/Users", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local users = UserQueries.SCIMall(self.params)
        return {
            json = users,
            status = 200
        }
    end,
    POST = function(self)
        local user = UserQueries.SCIMcreate(self.params)
        return {
            json = user,
            status = 201
        }
    end
}))

app:match("edit_scim_user", "/scim/v2/Users/:id", respond_to({
    before = function(self)
        self.user = UserQueries.show(tostring(self.params.id))
        if not self.user then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
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
        return {
            json = user,
            status = status
        }
    end,
    DELETE = function(self)
        local user = UserQueries.destroy(tostring(self.params.id))
        return {
            json = user,
            status = 204
        }
    end
}))

----------------- Role Routes --------------------
app:match("roles", "/api/v2/roles", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local roles = RoleQueries.all(self.params)
        return {
            json = roles
        }
    end,
    POST = function(self)
        local roles = RoleQueries.create(self.params)
        return {
            json = roles,
            status = 201
        }
    end
}))

app:match("edit_role", "/api/v2/roles/:id", respond_to({
    before = function(self)
        self.role = RoleQueries.show(tostring(self.params.id))
        if not self.role then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
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
        return {
            json = role,
            status = 204
        }
    end,
    DELETE = function(self)
        local role = RoleQueries.destroy(tostring(self.params.id))
        return {
            json = role,
            status = 204
        }
    end
}))

----------------- Modules Routes --------------------
app:match("modules", "/api/v2/modules", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local roles = ModuleQueries.all(self.params)
        return {
            json = roles
        }
    end,
    POST = function(self)
        local roles = ModuleQueries.create(self.params)
        return {
            json = roles,
            status = 201
        }
    end
}))

app:match("edit_module", "/api/v2/modules/:id", respond_to({
    before = function(self)
        self.role = ModuleQueries.show(tostring(self.params.id))
        if not self.role then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
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
        return {
            json = role,
            status = 204
        }
    end,
    DELETE = function(self)
        local role = ModuleQueries.destroy(tostring(self.params.id))
        return {
            json = role,
            status = 204
        }
    end
}))

----------------- Permission Routes --------------------
app:match("permissions", "/api/v2/permissions", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local roles = PermissionQueries.all(self.params)
        return {
            json = roles
        }
    end,
    POST = function(self)
        local roles = PermissionQueries.create(self.params)
        return {
            json = roles,
            status = 201
        }
    end
}))

app:match("edit_permission", "/api/v2/permissions/:id", respond_to({
    before = function(self)
        self.role = PermissionQueries.show(tostring(self.params.id))
        if not self.role then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
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
        return {
            json = role,
            status = 204
        }
    end,
    DELETE = function(self)
        local role = PermissionQueries.destroy(tostring(self.params.id))
        return {
            json = role,
            status = 204
        }
    end
}))

----------------- Group Routes --------------------
app:match("groups", "/api/v2/groups", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local groups = GroupQueries.all(self.params)
        return {
            json = groups
        }
    end,
    POST = function(self)
        local groups = GroupQueries.create(self.params)
        return {
            json = groups,
            status = 201
        }
    end
}))

app:match("edit_group", "/api/v2/groups/:id", respond_to({
    before = function(self)
        self.group = GroupQueries.show(tostring(self.params.id))
        if not self.group then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
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
        return {
            json = group,
            status = 204
        }
    end,
    DELETE = function(self)
        local group = GroupQueries.destroy(tostring(self.params.id))
        return {
            json = group,
            status = 204
        }
    end
}))

app:post("/api/v2/groups/:id/members", function(self)
    local group, status = GroupQueries.addMember(self.params.id, self.params.user_id)
    return {
        json = group,
        status = status
    }
end)

----------------- SCIM Group Routes --------------------
app:match("scim_groups", "/scim/v2/Groups", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local groups = GroupQueries.SCIMall(self.params)
        return {
            json = groups
        }
    end,
    POST = function(self)
        local groups = GroupQueries.create(self.params)
        return {
            json = groups,
            status = 201
        }
    end
}))

app:match("edit_scim_group", "/scim/v2/Groups/:id", respond_to({
    before = function(self)
        self.group = GroupQueries.show(tostring(self.params.id))
        if not self.group then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
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
        return {
            json = group,
            status = status
        }
    end,
    DELETE = function(self)
        local group = GroupQueries.destroy(tostring(self.params.id))
        return {
            json = group,
            status = 204
        }
    end
}))

----------------- Secrets Routes --------------------

app:match("secrets", "/api/v2/secrets", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local secrets = SecretQueries.all(self.params)
        return {
            json = secrets,
            status = 200
        }
    end,
    POST = function(self)
        local user = SecretQueries.create(self.params)
        return {
            json = user,
            status = 201
        }
    end
}))

app:match("edit_secrets", "/api/v2/secrets/:id", respond_to({
    before = function(self)
        self.user = SecretQueries.show(tostring(self.params.id))
        if not self.user then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
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
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "assert_valid was not captured: You cannot update email, username or password directly"
                },
                status = 500
            }
        end
        if not self.params.id then
            return {
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "assert_valid was not captured: Please pass the uuid of user that you want to update"
                },
                status = 500
            }
        end
        local user = SecretQueries.update(tostring(self.params.id), self.params)
        return {
            json = user,
            status = 204
        }
    end,
    DELETE = function(self)
        local user = SecretQueries.destroy(tostring(self.params.id))
        return {
            json = user,
            status = 204
        }
    end
}))

app:get("/api/v2/secrets/:id/show", function(self)
    local group, status = SecretQueries.showSecret(self.params.id)
    return {
        json = group,
        status = status
    }
end)

----------------- Projects Routes --------------------

app:match("projects", "/api/v2/projects", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local projects = ProjectQueries.all(self.params)
        return {
            json = projects,
            status = 200
        }
    end,
    POST = function(self)
        local project = ProjectQueries.create(self.params)
        return {
            json = project,
            status = 201
        }
    end
}))

app:match("edit_projects", "/api/v2/projects/:id", respond_to({
    before = function(self)
        self.project = ProjectQueries.show(tostring(self.params.id))
        if not self.project then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "Project not found! Please check the UUID and try again."
                },
                status = 404
            })
        end
    end,
    GET = function(self)
        local project = ProjectQueries.show(tostring(self.params.id))
        return {
            json = project,
            status = 200
        }
    end,
    PUT = function(self)
        if not self.params.id then
            return {
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "assert_valid was not captured: Please pass the uuid of project that you want to update"
                },
                status = 500
            }
        end
        local project = ProjectQueries.update(tostring(self.params.id), self.params)
        return {
            json = project,
            status = 204
        }
    end,
    DELETE = function(self)
        local project = ProjectQueries.destroy(tostring(self.params.id))
        return {
            json = project,
            status = 204
        }
    end
}))

----------------- Templates Routes --------------------

app:match("templates", "/api/v2/templates", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local templates = TemplateQueries.all(self.params)
        return {
            json = templates,
            status = 200
        }
    end,
    POST = function(self)
        local project = TemplateQueries.create(self.params)
        return {
            json = project,
            status = 201
        }
    end
}))

app:match("edit_templates", "/api/v2/templates/:id", respond_to({
    before = function(self)
        self.project = TemplateQueries.show(tostring(self.params.id))
        if not self.project then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "Project not found! Please check the UUID and try again."
                },
                status = 404
            })
        end
    end,
    GET = function(self)
        local project = TemplateQueries.show(tostring(self.params.id))
        return {
            json = project,
            status = 200
        }
    end,
    PUT = function(self)
        if not self.params.id then
            return {
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "assert_valid was not captured: Please pass the uuid of project that you want to update"
                },
                status = 500
            }
        end
        local project = TemplateQueries.update(tostring(self.params.id), self.params)
        return {
            json = project,
            status = 204
        }
    end,
    DELETE = function(self)
        local project = TemplateQueries.destroy(tostring(self.params.id))
        return {
            json = project,
            status = 204
        }
    end
}))

----------------- Document Routes --------------------

app:get("/api/v2/all-documents", function(self)
    local keycloak_auth_url = os.getenv("KEYCLOAK_AUTH_URL")
    self.params.timestamp = true
    local records = DocumentQueries.allData()
    return {
        json = records,
        status = 200
    }
end)

app:match("documents", "/api/v2/documents", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local records = DocumentQueries.all(self.params)
        return {
            json = records,
            status = 200
        }
    end,
    POST = function(self)
        local record = DocumentQueries.create(self.params and self.params or self.POST)
        return {
            json = record,
            status = 201
        }
    end
}))

app:match("edit_documents", "/api/v2/documents/:id", respond_to({
    before = function(self)
        self.record = DocumentQueries.show(tostring(self.params.id))
        if not self.record then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "Project not found! Please check the UUID and try again."
                },
                status = 404
            })
        end
    end,
    GET = function(self)
        local record = DocumentQueries.show(tostring(self.params.id))
        return {
            json = record,
            status = 200
        }
    end,
    PUT = function(self)
        if not self.params.id then
            return {
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "assert_valid was not captured: Please pass the uuid of document that you want to update"
                },
                status = 500
            }
        end
        local record = DocumentQueries.update(tostring(self.params.id), self.params)
        return {
            json = record,
            status = 204
        }
    end,
    DELETE = function(self)
        local record = DocumentQueries.destroy(tostring(self.params.id))
        return {
            json = record,
            status = 204
        }
    end
}))

----------------- Tags Routes --------------------

app:match("tags", "/api/v2/tags", respond_to({
    GET = function(self)
        self.params.timestamp = true
        local records = TagsQueries.all(self.params)
        return {
            json = records,
            status = 200
        }
    end,
    POST = function(self)
        local record = TagsQueries.create(self.params)
        return {
            json = record,
            status = 201
        }
    end
}))

app:match("edit_tags", "/api/v2/tags/:id", respond_to({
    before = function(self)
        self.record = TagsQueries.show(tostring(self.params.id))
        if not self.record then
            self:write({
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "Project not found! Please check the UUID and try again."
                },
                status = 404
            })
        end
    end,
    GET = function(self)
        local record = TagsQueries.show(tostring(self.params.id))
        return {
            json = record,
            status = 200
        }
    end,
    PUT = function(self)
        if not self.params.id then
            return {
                json = {
                    lapis = {
                        version = require("lapis.version")
                    },
                    error = "assert_valid was not captured: Please pass the uuid of document that you want to update"
                },
                status = 500
            }
        end
        local record = TagsQueries.update(tostring(self.params.id), self.params)
        return {
            json = record,
            status = 204
        }
    end,
    DELETE = function(self)
        local record = TagsQueries.destroy(tostring(self.params.id))
        return {
            json = record,
            status = 204
        }
    end
}))

return app
