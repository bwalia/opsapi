local http = require("resty.http")
local jwt = require("resty.jwt")
local cJson = require("cjson")
local lapis = require("lapis")
local UserQueries = require "queries.UserQueries"
local Global = require "helper.global"

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

        local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
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
        local keycloak_auth_url = Global.getEnvVar("KEYCLOAK_AUTH_URL")
        local client_id = Global.getEnvVar("KEYCLOAK_CLIENT_ID")
        local redirect_uri = Global.getEnvVar("KEYCLOAK_REDIRECT_URI")

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
        local token_url = Global.getEnvVar("KEYCLOAK_TOKEN_URL")
        local client_id = Global.getEnvVar("KEYCLOAK_CLIENT_ID")
        local client_secret = Global.getEnvVar("KEYCLOAK_CLIENT_SECRET")
        local redirect_uri = Global.getEnvVar("KEYCLOAK_REDIRECT_URI")

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

        local userinfo_url = Global.getEnvVar("KEYCLOAK_USERINFO_URL")
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

            local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
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

            local keycloakAuthUrl = Global.getEnvVar("KEYCLOAK_AUTH_URL") or ""
            local client_id = Global.getEnvVar("KEYCLOAK_CLIENT_ID")
            local client_secret = Global.getEnvVar("KEYCLOAK_CLIENT_SECRET")
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
end
