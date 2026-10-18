--[[
    ATS — recruiters signing up and signing in from the Snazzy Pro app, without
    the dashboard. Both end with an integration token (snz_…) for one workspace.

      register(): a new account (as /api/v2/register: Validation.createUser,
        UserQueries.create, role "member") and a new workspace for the company
        with the person as its owner (NamespaceQueries.createWithOwner, as
        POST /api/v2/user/namespaces), all in one transaction.
      sign_in(): the password is checked as /auth/login does (UserQueries.verify,
        the same per-account lockout). An account that is asked for a sign-in code
        (MFA) never gets a token here: the person makes one in the dashboard.

    Tokens are never stored raw (AtsQueries.create_token keeps the SHA-256).
]]

local db = require("lapis.db")
local J = require("lib.ats.json")
local T = require("lib.ats.text")
local Activation = require("lib.ats.activation")
local Q = require("queries.AtsQueries")

local R = {}

R.ATS_MODULES = { "ats_jobs", "ats_candidates", "ats_interviews", "ats_kits", "ats_reports", "ats_settings" }
R.WRONG = "Wrong email or password."
R.MFA = "This account uses two-step sign-in: make a token in the dashboard (Hiring › Settings)."

local function v(x) return J.val(x) end

local function str(x, max)
    x = v(x)
    if type(x) ~= "string" then return nil end
    x = T.trim(x)
    if x == "" then return nil end
    return T.prefix(x, max or 200)
end

local function token_name(device_name)
    local d = str(device_name, 80)
    return "Snazzy Pro" .. (d and (" on " .. d) or "")
end

local function random_hex(n)
    local bytes = require("resty.random").bytes(n, true) or require("resty.random").bytes(n)
    return require("resty.string").to_hex(bytes)
end

--- A unique username (3–25 characters) from the email's local part.
local function username_for(email)
    local base = (email:match("^([^@]+)") or "user"):lower():gsub("[^%w%._%-]", ""):sub(1, 14)
    if #base < 3 then base = "recruiter" end
    for _ = 1, 5 do
        local name = base .. "-" .. random_hex(4)
        if not db.select("id FROM users WHERE lower(username) = lower(?) LIMIT 1", name)[1] then return name end
    end
    return "r-" .. random_hex(8)
end

--- Makes sure the owner role can manage every Hiring module (ownership alone
-- doesn't pass permission checks: NamespaceMiddleware.hasPermission).
local function grant_owner_ats(namespace_id)
    local cjson = require("cjson")
    for _, role in ipairs(db.select("* FROM namespace_roles WHERE namespace_id = ? AND role_name = 'owner'",
        namespace_id)) do
        local perms = {}
        local ok, decoded = pcall(cjson.decode, role.permissions or "{}")
        if ok and type(decoded) == "table" then perms = decoded end
        local changed = false
        for _, m in ipairs(R.ATS_MODULES) do
            local has = false
            for _, a in ipairs(type(perms[m]) == "table" and perms[m] or {}) do
                if a == "manage" then has = true end
            end
            if not has then
                perms[m] = { "manage" }
                changed = true
            end
        end
        if changed then
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
            pcall(function() require("helper.permission-cache").invalidateRole(role.id) end)
        end
    end
end

local function token_result(ns, user_uuid, device_name)
    local t = Q.create_token(ns.id, token_name(device_name), user_uuid)
    return {
        token = t.token, namespace = { uuid = ns.uuid, name = ns.name }, active = Activation.is_active(ns.id),
        dashboard_url = Activation.public_url() .. "/dashboard/ats",
        note = "Keep this token: it isn't shown again.",
    }
end

--- A person-readable message from a validation error (a string, or Lapis' {errors} table).
function R.validation_message(err)
    if type(err) == "table" then
        local list = type(err.errors) == "table" and err.errors or err
        err = list[1] or "Check the details and try again."
    end
    local msg = tostring(err):gsub("^.-%.lua:%d+: ", ""):gsub("^VALIDATION: ", "")
    return msg
end

--- @return data | nil, err, status, code
function R.register(data)
    local company = str(data.company, 100)
    local first, last = str(data.first_name, 100), str(data.last_name, 100)
    local email = str(data.email, 254)
    local password = type(v(data.password)) == "string" and data.password or nil
    if not company or T.len(company) < 2 then return nil, "Give your company's name.", 422, "invalid" end
    if not first or not last then return nil, "Give your first and last name.", 422, "invalid" end
    if not email or not password then return nil, "Give your email and a password.", 422, "invalid" end
    email = email:lower()
    local params = { email = email, password = password, first_name = first, last_name = last, role = "member",
        username = username_for(email) }
    local valid, verr = pcall(function() require("helper.validations").createUser(params) end)
    if not valid then return nil, R.validation_message(verr), 422, "invalid" end
    if db.select("id FROM users WHERE lower(email) = ? LIMIT 1", email)[1] then
        return nil, "That email already has an account: sign in instead.", 409, "email_taken"
    end
    local user, ns
    local ok, err = pcall(function()
        db.query("BEGIN")
        user = require("queries.UserQueries").create(params)
        local created, cerr = require("queries.NamespaceQueries").createWithOwner(user.id, { name = company,
            plan = "free", description = "Hiring workspace (Snazzy Pro)" })
        if not created then error({ reason = cerr }) end
        ns = created.namespace
        grant_owner_ats(ns.id)
        Q.settings(ns.id)
        db.query("COMMIT")
    end)
    if not ok then
        pcall(db.query, "ROLLBACK")
        ngx.log(ngx.ERR, "[ats] recruiter registration failed: ",
            type(err) == "table" and tostring(err.reason) or tostring(err))
        return nil, "Couldn't create the account. Please try again.", 500, "failed"
    end
    Q.audit(ns.id, user.uuid, "recruiter_registered", "namespace", ns.uuid, { via = "snazzy_pro" })
    return token_result(ns, user.uuid, data.device_name)
end

-- A bcrypt hash to check against when no account matches, so a wrong email
-- costs the same time as a wrong password.
local dummy_hash
local function burn(password)
    local bcrypt = require("bcrypt")
    dummy_hash = dummy_hash or require("helper.global").hashPassword("not-a-password-" .. random_hex(8))
    pcall(bcrypt.verify, password, dummy_hash)
end

--- The lockout key /auth/login uses for this identifier (shared, so failures count once).
function R.lock_key(identifier)
    local row = db.query("SELECT uuid FROM users WHERE lower(email) = lower(?) OR lower(username) = lower(?) LIMIT 1",
        identifier, identifier)[1]
    return require("helper.auth-throttle").key("login", row and row.uuid or identifier)
end

--- Workspaces where this person may manage Hiring settings (a role of theirs grants ats_settings: manage).
function R.workspaces(user_id)
    local cjson = require("cjson")
    local rows = db.query([[
        SELECT n.id, n.uuid, n.name, r.permissions FROM namespace_members m
        JOIN namespaces n ON n.id = m.namespace_id
        JOIN namespace_user_roles ur ON ur.namespace_member_id = m.id
        JOIN namespace_roles r ON r.id = ur.namespace_role_id
        WHERE m.user_id = ? AND m.status = 'active' AND n.status = 'active'
        ORDER BY n.name, n.id]], user_id)
    local out, seen = {}, {}
    for _, row in ipairs(rows) do
        local ok, perms = pcall(cjson.decode, row.permissions or "{}")
        local acts = ok and type(perms) == "table" and perms.ats_settings
        local manage = false
        for _, a in ipairs(type(acts) == "table" and acts or {}) do
            if a == "manage" then manage = true end
        end
        if manage and not seen[row.id] then
            seen[row.id] = true
            out[#out + 1] = { id = row.id, uuid = row.uuid, name = row.name }
        end
    end
    return out
end

--- @return data | nil, err, status, code, retry_after
function R.sign_in(data)
    local email = str(data.email, 254)
    local password = type(v(data.password)) == "string" and data.password or nil
    if not email or not password then return nil, "Give your email and password.", 400, "bad_request" end
    local Throttle = require("helper.auth-throttle")
    local key = R.lock_key(email)
    local locked, retry = Throttle.blocked(key, Throttle.LOGIN)
    if locked then
        return nil, "Too many failed sign-in attempts. Try again later.", 429, "locked", retry
    end
    local user = require("queries.UserQueries").verify(email, password)
    if not user then
        if not db.select("id FROM users WHERE email = ? OR username = ? LIMIT 1", email, email)[1] then
            burn(password)
        end
        Throttle.hit(key, Throttle.LOGIN.window)
        return nil, R.WRONG, 401, "wrong_credentials"
    end
    Throttle.clear(key)
    -- The same rule as /auth/login: platform admins and anyone in a workspace that asks for a code.
    local full = require("queries.UserQueries").show(user.uuid)
    if require("helper.admin-check").isPlatformAdmin(full)
        or require("queries.NamespaceQueries").mfaRequiredForUser(user.id) then
        return nil, R.MFA, 403, "mfa_required"
    end
    local list = R.workspaces(user.id)
    if #list == 0 then
        return nil, "This account can't manage Hiring in any workspace. Ask a workspace owner for access.", 403,
            "no_workspace"
    end
    local chosen
    local want = str(data.namespace_uuid, 64)
    if want then
        for _, n in ipairs(list) do if n.uuid == want then chosen = n end end
        if not chosen then return nil, "You can't manage Hiring in that workspace.", 403, "no_workspace" end
    elseif #list == 1 then
        chosen = list[1]
    else
        local choose = J.array({})
        for _, n in ipairs(list) do choose[#choose + 1] = { uuid = n.uuid, name = n.name } end
        return { choose = choose }
    end
    local res = token_result(chosen, user.uuid, data.device_name)
    Q.audit(chosen.id, user.uuid, "recruiter_signed_in", "namespace", chosen.uuid, { via = "snazzy_pro" })
    return res
end

return R
