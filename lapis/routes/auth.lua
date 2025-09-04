local http = require("resty.http")
local jwt = require("resty.jwt")
local cJson = require("cjson")
local lapis = require("lapis")
local UserQueries = require "queries.UserQueries"
local Global = require "helper.global"
local UserRolesQueries = require "queries.UserRoleQueries"

return function(app)
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

        -- Get user with roles
        local userWithRoles = UserQueries.show(user.uuid)
        if not userWithRoles then
            return {
                status = 500,
                json = {
                    error = "Failed to load user data"
                }
            }
        end

        local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
        local token = jwt:sign(JWT_SECRET_KEY, {
            header = {
                typ = "JWT",
                alg = "HS256"
            },
            payload = {
                userinfo = {
                    uuid = userWithRoles.uuid,
                    email = userWithRoles.email,
                    name = (userWithRoles.first_name or "") .. " " .. (userWithRoles.last_name or ""),
                    roles = userWithRoles.roles and userWithRoles.roles[1] and userWithRoles.roles[1].name or "buyer"
                },
            }
        })

        return {
            status = 200,
            json = {
                user = {
                    id = userWithRoles.uuid,
                    email = userWithRoles.email,
                    name = (userWithRoles.first_name or "") .. " " .. (userWithRoles.last_name or ""),
                    role = userWithRoles.roles and userWithRoles.roles[1] and userWithRoles.roles[1].name or "buyer"
                },
                token = token
            }
        }
    end)

    -- Google OAuth Routes
    app:get("/auth/google", function(self)
        local google_client_id = Global.getEnvVar("GOOGLE_CLIENT_ID")
        local google_redirect_uri = Global.getEnvVar("GOOGLE_REDIRECT_URI")
        
        if not google_client_id or not google_redirect_uri then
            return {
                status = 500,
                json = {
                    error = "Google OAuth not configured"
                }
            }
        end

        local redirect_from = self.params.from or "/"
        
        local auth_url = string.format(
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=%s&redirect_uri=%s&response_type=code&scope=openid+profile+email&state=%s",
            google_client_id, ngx.escape_uri(google_redirect_uri), ngx.escape_uri(redirect_from)
        )
        
        return {
            redirect_to = auth_url
        }
    end)

    app:get("/auth/google/callback", function(self)
        local code = self.params.code
        local redirect_from = self.params.state or "/"
        
        if not code then
            return {
                status = 400,
                json = {
                    error = "Authorization code not provided"
                }
            }
        end

        local google_client_id = Global.getEnvVar("GOOGLE_CLIENT_ID")
        local google_client_secret = Global.getEnvVar("GOOGLE_CLIENT_SECRET")
        local google_redirect_uri = Global.getEnvVar("GOOGLE_REDIRECT_URI")

        local httpc = http.new()
        
        -- Exchange code for access token
        local token_res, token_err = httpc:request_uri("https://oauth2.googleapis.com/token", {
            method = "POST",
            body = ngx.encode_args({
                client_id = google_client_id,
                client_secret = google_client_secret,
                code = code,
                grant_type = "authorization_code",
                redirect_uri = google_redirect_uri
            }),
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded"
            },
            ssl_verify = false
        })

        if not token_res then
            return {
                status = 500,
                json = {
                    error = "Failed to exchange code for token: " .. (token_err or "unknown")
                }
            }
        end

        local token_data = cJson.decode(token_res.body)
        if not token_data.access_token then
            return {
                status = 500,
                json = {
                    error = "No access token received"
                }
            }
        end

        -- Get user info from Google
        local user_res, user_err = httpc:request_uri("https://www.googleapis.com/oauth2/v2/userinfo", {
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. token_data.access_token
            },
            ssl_verify = false
        })

        if not user_res then
            return {
                status = 500,
                json = {
                    error = "Failed to get user info: " .. (user_err or "unknown")
                }
            }
        end

        local google_user = cJson.decode(user_res.body)
        if not google_user.email then
            return {
                status = 500,
                json = {
                    error = "No email received from Google"
                }
            }
        end

        -- Find or create user
        local user = UserQueries.findByEmail(google_user.email)
        if not user then
            local names = {}
            if google_user.name then
                names = Global.splitName(google_user.name)
            end
            
            user = UserQueries.createOAuthUser({
                uuid = Global.generateUUID(),
                email = google_user.email,
                username = google_user.email,
                first_name = names.first_name or google_user.given_name or "",
                last_name = names.last_name or google_user.family_name or "",
                password = Global.generateRandomPassword(),
                role = "buyer",
                oauth_provider = "google",
                oauth_id = google_user.id,
                active = true
            })
        end

        -- Get user with roles
        local userWithRoles = UserQueries.show(user.uuid)
        if not userWithRoles then
            return {
                status = 500,
                json = {
                    error = "Failed to load user data"
                }
            }
        end

        -- Generate JWT token
        local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
        local token = jwt:sign(JWT_SECRET_KEY, {
            header = {
                typ = "JWT",
                alg = "HS256"
            },
            payload = {
                userinfo = {
                    uuid = userWithRoles.uuid,
                    email = userWithRoles.email,
                    name = (userWithRoles.first_name or "") .. " " .. (userWithRoles.last_name or ""),
                    roles = userWithRoles.roles and userWithRoles.roles[1] and userWithRoles.roles[1].name or "buyer"
                },
            }
        })

        -- Redirect to frontend with token
        local frontend_url = Global.getEnvVar("FRONTEND_URL") or "http://localhost:3033"
        local final_url = string.format("%s/auth/callback?token=%s&redirect=%s", 
            frontend_url, ngx.escape_uri(token), ngx.escape_uri(redirect_from))
        
        return {
            redirect_to = final_url
        }
    end)

    -- Logout endpoint
    app:post("/auth/logout", function(self)
        -- Clear any session data
        if self.session then
            for k, _ in pairs(self.session) do
                self.session[k] = nil
            end
        end
        
        return {
            json = {
                message = "Logged out successfully"
            },
            status = 200
        }
    end)

    -- OAuth token validation endpoint
    app:post("/auth/oauth/validate", function(self)
        local token = self.params.token
        if not token then
            return {
                status = 400,
                json = {
                    error = "Token is required"
                }
            }
        end

        local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
        local jwt_obj = jwt:verify(JWT_SECRET_KEY, token)
        
        if not jwt_obj.valid then
            return {
                status = 401,
                json = {
                    error = "Invalid token"
                }
            }
        end

        local userinfo = jwt_obj.payload.userinfo
        return {
            status = 200,
            json = {
                user = {
                    id = userinfo.uuid,
                    email = userinfo.email,
                    name = userinfo.name,
                    role = userinfo.roles
                },
                token = token
            }
        }
    end)
end