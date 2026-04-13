local Validation = {}
local validate = require("lapis.validate")

-- Password strength validation
function Validation.validatePasswordStrength(password)
    if not password or #password < 8 then
        error("Password must be at least 8 characters long")
    end

    if not string.match(password, "%u") then
        error("Password must contain at least one uppercase letter")
    end

    if not string.match(password, "%l") then
        error("Password must contain at least one lowercase letter")
    end

    if not string.match(password, "%d") then
        error("Password must contain at least one number")
    end

    return true
end

-- User Validations
function Validation.createUser(params)
    -- Validate password strength
    Validation.validatePasswordStrength(params.password)

    return validate.assert_valid(params, {
        { "username", exists = true, min_length = 3, max_length = 25 },
        { "role",     exists = true, min_length = 2, max_length = 25 },
        {
            "password",
            exists = true,
            min_length = 8,
            max_length = 128,
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
        { "name",         exists = true, min_length = 2, max_length = 25 },
        { "priority",     exists = true, min_length = 1 },
    })
end

-- Permissions Validations
function Validation.createPermissions(params)
    return validate.assert_valid(params, {
        { "module_machine_name", exists = true },
        { "role",                exists = true },
        { "permissions",         exists = true },
    })
end

function Validation.createPermissionsWithMName(params)
    return validate.assert_valid(params, {
        { "module_id",   exists = true },
        { "role",        exists = true },
        { "permissions", exists = true },
    })
end

-- Group Validations
function Validation.createGroup(params)
    return validate.assert_valid(params, {
        { "machine_name", exists = true },
        { "name",         exists = true },
    })
end

-- Roles Validations
function Validation.createSecret(params)
    return validate.assert_valid(params, {
        { "secret", exists = true },
        { "name",   exists = true }
    })
end

-- Roles Validations
function Validation.createProject(params)
    return validate.assert_valid(params, {
        { "name",   exists = true },
        { "active", exists = true }
    })
end

-- Roles Validations
function Validation.createTemplate(params)
    return validate.assert_valid(params, {
        { "code",             exists = true },
        { "template_content", exists = true }
    })
end

-- Document Validations
function Validation.createDocument(params)
    return validate.assert_valid(params, {
        { "title",   exists = true },
        { "status",  exists = true },
        { "user_id", exists = true },
        { "content", exists = true }
    })
end

-- Tag Validations
function Validation.createTag(params)
    return validate.assert_valid(params, {
        { "name", exists = true }
    })
end

-- Enquiries Validations
function Validation.createEnquiry(params)
    return validate.assert_valid(params, {
        { "name",     exists = true },
        { "email",    exists = true },
        { "phone_no", exists = true },
    })
end

return Validation
