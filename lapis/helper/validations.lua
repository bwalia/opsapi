local Validation = {}
local validate = require("lapis.validate")
local app_helpers = require("lapis.application")

local capture_errors_json, yield_error = app_helpers.capture_errors_json, app_helpers.yield_error

function Validation.createUser(params)
    return validate.assert_valid(params, {
        { "username", exists = true, min_length = 3, max_length = 25 },
        { "role", exists = true, min_length = 2, max_length = 25 },
        { "password",
            exists = true,
            min_length = 8,
            max_length = 32,
        },
        { "email", exists = true, min_length = 3, matches_pattern = "^[%w._%%+-]+@[%w.-]+%.%a%a+$" },
      })
end
function Validation.updateUser(params)
    yield_error(params.email or params.email ~= nil)
        
    yield_error(params.username or params.username ~= nil)
end

return Validation
