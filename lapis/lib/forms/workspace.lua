--[[
    Workspace-wide forms settings: Cloudflare Turnstile ("I'm not a robot")
    =====================================================================

    A workspace adds its Turnstile site key + secret once (the secret is
    stored encrypted and never returned); each form can then turn the check on
    (settings.captcha). The public page shows the widget and the server
    verifies its token with Cloudflare before accepting the response.

    The platform's own keys (TURNSTILE_SITE_KEY + TURNSTILE_SECRET_KEY) are used
    by every workspace that hasn't added its own, so the check works without
    any set-up. A Turnstile widget only runs on the hostnames listed for it in
    Cloudflare, so a workspace on its own custom domain adds its own keys.
    TURNSTILE_VERIFY_URL overrides Cloudflare's endpoint (tests).
]]

local db = require("lapis.db")
local Global = require("helper.global")

local Workspace = {}

local VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
local KEY = "^[%w_%-]+$"

local function row(namespace_id)
    return db.query("SELECT * FROM form_workspace_settings WHERE namespace_id = ?", namespace_id)[1]
end

local function val(v)
    if v == nil or v == db.NULL then return nil end
    return v
end

local function env(name)
    local v = os.getenv(name)
    return v and v:match(KEY) and v or nil
end

--- The platform's keys, when both are set. @return site_key, secret | nil
local function platform()
    local site, secret = env("TURNSTILE_SITE_KEY"), env("TURNSTILE_SECRET_KEY")
    if site and secret then return site, secret end
end

--- The settings as the API shows them (never a secret). `platform` = the
-- platform's keys cover forms here when the workspace has none of its own.
function Workspace.get(namespace_id)
    local r = row(namespace_id)
    return { turnstile = {
        site_key = r and val(r.turnstile_site_key) or nil,
        has_secret = r ~= nil and val(r.turnstile_secret_encrypted) ~= nil,
        platform = platform() ~= nil,
    } }
end

--- body = { turnstile = { site_key, secret } }: the secret is write-only
-- (omitted = keep, "" = remove).
function Workspace.save(namespace_id, actor_uuid, body)
    local t = type(body) == "table" and body.turnstile
    if type(t) ~= "table" then return nil, "send { turnstile: { site_key, secret } }" end
    local current = row(namespace_id)
    local site = t.site_key == nil and (current and val(current.turnstile_site_key)) or t.site_key
    if site == "" or site == require("lib.forms.json").null then site = nil end
    if site ~= nil and (type(site) ~= "string" or #site > 100 or not site:match(KEY)) then
        return nil, "site_key must be the key from the Cloudflare dashboard"
    end
    local secret = current and val(current.turnstile_secret_encrypted)
    if t.secret ~= nil then
        if t.secret == "" then
            secret = nil
        elseif type(t.secret) ~= "string" or #t.secret > 200 or not t.secret:match(KEY) then
            return nil, "secret must be the secret key from the Cloudflare dashboard"
        else
            secret = Global.encryptSecret(t.secret)
        end
    end
    -- Without keys (and no platform keys to fall back on), every form with the
    -- check on would refuse all responses: the check fails closed.
    if (site == nil or secret == nil) and not platform() then
        local n = tonumber(db.query([[SELECT COUNT(*) AS n FROM forms WHERE namespace_id = ? AND deleted_at IS NULL
            AND settings->>'captcha' = 'true']], namespace_id)[1].n) or 0
        if n > 0 then
            return nil, n .. " form(s) use the \"I'm human\" check. Turn it off in their Settings first, "
                .. "or they can't take responses."
        end
    end
    db.query([[
        INSERT INTO form_workspace_settings (namespace_id, turnstile_site_key, turnstile_secret_encrypted,
            updated_by_uuid, updated_at)
        VALUES (?, ?, ?, ?, NOW())
        ON CONFLICT (namespace_id) DO UPDATE SET turnstile_site_key = EXCLUDED.turnstile_site_key,
            turnstile_secret_encrypted = EXCLUDED.turnstile_secret_encrypted,
            updated_by_uuid = EXCLUDED.updated_by_uuid, updated_at = NOW()
    ]], namespace_id, site or db.NULL, secret or db.NULL, actor_uuid or db.NULL)
    return Workspace.get(namespace_id)
end

--- The workspace's keys when it has both, else the platform's.
-- @return site_key, secret | nil
function Workspace.turnstile(namespace_id)
    local ok, r = pcall(row, namespace_id)
    if not ok or not r or not val(r.turnstile_site_key) or not val(r.turnstile_secret_encrypted) then
        return platform()
    end
    local dok, secret = pcall(Global.decryptSecret, r.turnstile_secret_encrypted)
    if not dok or not secret then return nil end
    return r.turnstile_site_key, secret
end

--- Ask Cloudflare whether a widget token is good. Fails closed: a check the
-- owner turned on that can't be completed refuses the response.
-- @return true | nil, reason
function Workspace.verify(secret, token, ip)
    if type(token) ~= "string" or token == "" or #token > 4096 then return nil, "missing" end
    local http = require("resty.http").new()
    http:set_timeout(5000)
    local url = os.getenv("TURNSTILE_VERIFY_URL")
    if not url or url == "" then url = VERIFY_URL end
    local res, err = http:request_uri(url, {
        method = "POST",
        body = ngx.encode_args({ secret = secret, response = token, remoteip = ip }),
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        ssl_verify = url:find("^https://") ~= nil,
    })
    if not res then
        ngx.log(ngx.WARN, "[forms] turnstile verify failed: ", tostring(err))
        return nil, "unreachable"
    end
    local ok, body = pcall(require("cjson").decode, res.body or "")
    if ok and type(body) == "table" and body.success == true then return true end
    return nil, "rejected"
end

return Workspace
