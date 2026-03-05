local respond_to = require("lapis.application").respond_to
local UserQueries = require("queries.UserQueries")
local Validation = require("helper.validations")
local jwt = require("resty.jwt")
local Global = require("helper.global")

return function(app)
    app:match("register", "/api/v2/register", respond_to({
        POST = function(self)
            local params = self.params

            -- Accept common registration roles; default to "member" if not provided
            local allowed_roles = {
                member = true, buyer = true, seller = true,
                delivery_partner = true, tax_client = true
            }
            if not params.role or params.role == "" then
                params.role = "member"
            end
            if not allowed_roles[params.role] then
                return { json = { error = "Invalid registration role" }, status = 400 }
            end

            local success, err = pcall(function()
                Validation.createUser(params)
            end)

            if not success then
                return { json = { error = "Validation failed: " .. tostring(err) }, status = 400 }
            end

            local existing_user = UserQueries.findByEmail(params.email)
            if existing_user then
                return { json = { error = "Email already registered" }, status = 409 }
            end

            local user = UserQueries.create(params)
            user.password = nil

            -- Generate JWT token for immediate authentication
            local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
            if not JWT_SECRET_KEY then
                ngx.log(ngx.ERR, "JWT_SECRET_KEY not configured")
                return { json = { error = "Server configuration error" }, status = 500 }
            end

            local jwt_payload = {
                userinfo = {
                    uuid = user.uuid,
                    id = user.id,
                    email = user.email,
                    username = user.username,
                    role = user.role
                },
                exp = ngx.time() + (60 * 60) -- 1 hour expiry (matches DEFAULT_EXPIRATION)
            }

            local jwt_token = jwt:sign(JWT_SECRET_KEY, {
                header = { typ = "JWT", alg = "HS256" },
                payload = jwt_payload
            })

            return {
                json = {
                    user = user,
                    token = jwt_token,
                    message = "Registration successful"
                },
                status = 201
            }
        end
    }))
end
