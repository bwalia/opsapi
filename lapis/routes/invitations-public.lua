--[[
    Workspace invitations — the link in the invitation email (core)

    GET  /api/v2/public/invitations/:token          who invited whom, to what, as which role;
                                                    account_exists says which way to accept
    POST /api/v2/public/invitations/:token/accept   {first_name, last_name, password}: create the
                                                    account and join, for an email with no account yet

    The token (64 characters from the CSPRNG) only ever reaches the invited
    address, so holding it proves the person owns that email. An email that
    already has an account accepts signed in instead
    (POST /api/v2/invitations/:token/accept), never by setting a password here.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local RateLimit = require("middleware.rate-limit")

local function json(status, body)
    return { status = status, json = body }
end

local GONE = json(404, { success = false, error = "This invitation link isn't valid any more. Ask for a new one.",
    code = "invitation_invalid" })

-- A pending, unexpired invitation to an active workspace, or nil.
local function pending(token)
    if type(token) ~= "string" or not token:match("^[%w]+$") or #token < 32 or #token > 128 then return nil end
    return db.query([[
        SELECT ni.id, ni.namespace_id, ni.email, ni.message, ni.expires_at, n.name AS namespace_name,
               n.logo_url AS namespace_logo, nr.role_name, nr.display_name AS role_display_name,
               NULLIF(TRIM(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, '')), '') AS invited_by_name
        FROM namespace_invitations ni
        JOIN namespaces n ON n.id = ni.namespace_id AND n.status = 'active'
        LEFT JOIN namespace_roles nr ON nr.id = ni.role_id
        LEFT JOIN users u ON u.id = ni.invited_by
        WHERE ni.token = ? AND ni.status = 'pending' AND ni.expires_at > NOW()
    ]], token)[1]
end

local function password_problem(pw)
    if type(pw) ~= "string" or #pw < 12 then return "must be at least 12 characters" end
    if #pw > 128 then return "must be at most 128 characters" end
    if not pw:match("%u") then return "needs an upper-case letter" end
    if not pw:match("%l") then return "needs a lower-case letter" end
    if not pw:match("%d") then return "needs a number" end
end

return function(app)
    app:get("/api/v2/public/invitations/:token", RateLimit.wrap({ rate = 30, window = 60, prefix = "invite_view" },
        function(self)
            local inv = pending(self.params.token)
            if not inv then return GONE end
            local exists = db.query("SELECT 1 FROM users WHERE lower(email) = lower(?) LIMIT 1", inv.email)[1] ~= nil
            local function val(v) return v ~= db.NULL and v or nil end
            return json(200, { success = true, data = {
                email = inv.email,
                workspace = { name = inv.namespace_name, logo_url = val(inv.namespace_logo) },
                role = val(inv.role_display_name) or val(inv.role_name),
                invited_by = val(inv.invited_by_name),
                message = val(inv.message),
                expires_at = inv.expires_at,
                account_exists = exists,
            } })
        end))

    app:post("/api/v2/public/invitations/:token/accept", RateLimit.wrap({ rate = 10, window = 60,
        prefix = "invite_accept" }, function(self)
            local inv = pending(self.params.token)
            if not inv then return GONE end
            if db.query("SELECT 1 FROM users WHERE lower(email) = lower(?) LIMIT 1", inv.email)[1] then
                return json(409, { success = false, code = "sign_in_required",
                    error = "You already have an account. Sign in with " .. inv.email .. " to accept." })
            end

            ngx.req.read_body()
            local ok, b = pcall(cjson.decode, ngx.req.get_body_data() or "")
            if not ok or type(b) ~= "table" then
                return json(400, { success = false, error = "Send a JSON object." })
            end
            local Fields = require("lib.forms.fields")
            local first = Fields.text(b.first_name, 100)
            local last = Fields.text(b.last_name == nil and "" or b.last_name, 100)
            local errors = {}
            if not first or first == "" then errors.first_name = "is required" end
            if not last then errors.last_name = "must be at most 100 characters" end
            errors.password = password_problem(b.password)
            if next(errors) then
                return json(400, { success = false, error = "Please check the highlighted fields.", errors = errors })
            end

            local active = tonumber(db.query([[SELECT COUNT(*) AS n FROM namespace_members
                WHERE namespace_id = ? AND status = 'active']], inv.namespace_id)[1].n)
            local max = tonumber(db.query("SELECT max_users FROM namespaces WHERE id = ?",
                inv.namespace_id)[1].max_users)
            if active >= (max or 10) then
                return json(409, { success = false, code = "workspace_full",
                    error = "This workspace is full. Ask its owner to make room." })
            end

            local UserQueries = require("queries.UserQueries")
            db.query("BEGIN")
            local done, err = pcall(function()
                local claimed = db.query([[UPDATE namespace_invitations SET status = 'accepted', accepted_at = NOW(),
                    updated_at = NOW() WHERE id = ? AND status = 'pending' RETURNING id]], inv.id)[1]
                if not claimed then error("CONFLICT: This invitation was just used.", 0) end
                UserQueries.create({
                    username = UserQueries.uniqueUsername(inv.email),
                    first_name = first, last_name = last, email = inv.email, password = b.password,
                    role = "member", active = true,
                    namespace_id = inv.namespace_id, namespace_role = inv.role_name ~= db.NULL and inv.role_name
                        or "member",
                })
            end)
            if not done then
                pcall(db.query, "ROLLBACK")
                local msg = tostring(err)
                -- The password policy and breach check raise plain messages.
                local policy = msg:match("(This password has appeared[^\n]*)") or msg:match("(Password must[^\n]*)")
                if policy then
                    return json(400, { success = false, error = policy, errors = { password = policy } })
                end
                if msg:match("^CONFLICT: ") then return json(409, { success = false, error = msg:sub(11) }) end
                return require("lib.errors").fromException(self, err)
            end
            db.query("COMMIT")
            return json(201, { success = true, data = { email = inv.email,
                message = "Your account is ready. Sign in with your email and password." } })
        end))
end
