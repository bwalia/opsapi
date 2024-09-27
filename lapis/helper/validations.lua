local Validation = {}
local validate = require("lapis.validate")

-- User Validations
function Validation.createUser(params)
    return validate.assert_valid(params, {
        { "username", exists = true, min_length = 3, max_length = 25 },
        { "role",     exists = true, min_length = 2, max_length = 25 },
        {
            "password",
            exists = true,
            min_length = 8,
            max_length = 32,
        },
        { "email", exists = true, min_length = 3, matches_pattern = "^[%w._%%+-]+@[%w.-]+%.%a%a+$" },
    })
end

-- Roles Validations
function Validation.createRole(params)
    return validate.assert_valid(params, {
        { "role_name", exists = true, min_length = 2, max_length = 25 }
    })
end

-- Module Validations
function Validation.createModule(params)
    return validate.assert_valid(params, {
        { "machine_name", exists = true, min_length = 2, max_length = 25 },
        { "name", exists = true, min_length = 2, max_length = 25 },
        { "priority", exists = true, min_length = 1 },
    })
end

-- Permissions Validations
function Validation.createPermissions(params)
    return validate.assert_valid(params, {
        { "module_machine_name", exists = true },
        { "role", exists = true },
        { "permissions", exists = true },
    })
end
function Validation.createPermissionsWithMName(params)
    return validate.assert_valid(params, {
        { "module_id", exists = true },
        { "role", exists = true },
        { "permissions", exists = true },
    })
end
return Validation
