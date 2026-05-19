local Validation = {}
local validate = require("lapis.validate")

-- Minimum length lifted from 8 → 12 to match NIST 800-63B's
-- "memorised secret" guidance and to clear zxcvbn score ≥ 3 on
-- typical strings (the frontend gates submit on the same score, so a
-- shorter password rarely reaches us, but we enforce it server-side
-- as the authoritative gate).
local MIN_PASSWORD_LENGTH = 12

-- Password strength validation
function Validation.validatePasswordStrength(password)
    if not password or #password < MIN_PASSWORD_LENGTH then
        error("Password must be at least " .. MIN_PASSWORD_LENGTH .. " characters long")
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

    -- Have I Been Pwned check — k-anonymity, plaintext never leaves
    -- this process. Wrapped in pcall so a HIBP outage doesn't lock
    -- users out of signup; the helper logs internally on failure.
    local ok_req, HIBP = pcall(require, "helper.hibp")
    if not ok_req then
        ngx.log(ngx.WARN, "[validations] HIBP module load failed: ", tostring(HIBP))
    elseif not HIBP or not HIBP.check_password then
        ngx.log(ngx.WARN, "[validations] HIBP module shape unexpected")
    else
        -- pcall returns (true, ret1, ret2, ...) on success. Capture both
        -- return values so a soft-fail (nil, "reason") doesn't lose the
        -- diagnostic. Don't call HIBP.check_password twice — the cosocket
        -- has timing-sensitive state and a second call inside a log line
        -- has segfaulted before on this image.
        local ok_call, count, fetch_err = pcall(HIBP.check_password, password)
        if not ok_call then
            ngx.log(ngx.WARN, "[validations] HIBP raised: ", tostring(count))
        elseif type(count) == "number" then
            ngx.log(ngx.NOTICE, "[validations] HIBP hit count=", count)
            if count > 0 then
                error(
                    "This password has appeared in known data breaches and is unsafe. "
                    .. "Please choose a different one."
                )
            end
        else
            ngx.log(
                ngx.NOTICE,
                "[validations] HIBP unreachable; allowing. err=",
                tostring(fetch_err)
            )
        end
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
            min_length = MIN_PASSWORD_LENGTH,
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
