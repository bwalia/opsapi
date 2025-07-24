local respond_to = require("lapis.application").respond_to
local UserQueries = require("queries.UserQueries")
local Validation = require("helper.validations")

return function(app)
    app:match("register", "/api/v2/register", respond_to({
        POST = function(self)
            local params = self.params

            if not params.role or (params.role ~= "seller" and params.role ~= "buyer") then
                return { json = { error = "Role must be 'seller' or 'buyer'" }, status = 400 }
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

            return { json = { user = user, message = "Registration successful" }, status = 201 }
        end
    }))
end
