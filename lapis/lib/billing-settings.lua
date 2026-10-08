--[[
    Billing & Entitlements — per-app settings (docs/BILLING_ENTITLEMENTS.md §4)
    ==========================================================================
    Every tunable of an app is data in billing_apps.settings, validated here
    against a declared schema. Only values an admin set are stored; the rest
    take the default for the app's kind. The schema is published (GET
    /api/v2/billing/settings-schema) so the dashboard renders the form from it.
]]

local cjson = require("cjson")

local Settings = {}

local LICENSED = { desktop = 0, self_hosted = 0 }
-- A default that depends on the app's kind: { web = x, desktop = y, ... }.
local function by_kind(web, licensed)
    return { web = web, mobile = web, desktop = licensed, self_hosted = licensed }
end

local RATE_FIELDS = {
    { key = "licence_per_ip_per_min", min = 1, max = 100000, default = 30 },
    { key = "licence_per_key_per_min", min = 1, max = 100000, default = 20 },
    { key = "app_per_min", min = 1, max = 10000000, default = 6000 },
    { key = "checkout_per_ip_per_hour", min = 1, max = 100000, default = 20 },
    { key = "access_link_per_email_per_hour", min = 1, max = 1000, default = 3 },
    { key = "access_link_per_ip_per_hour", min = 1, max = 100000, default = 10 },
    { key = "public_per_ip_per_min", min = 1, max = 100000, default = 120 },
}
local LOCKOUT_FIELDS = {
    { key = "failures", min = 1, max = 1000, default = 10 },
    { key = "window_minutes", min = 1, max = 1440, default = 15 },
    { key = "lock_minutes", min = 1, max = 10080, default = 30 },
}

-- Ordered: the dashboard shows the groups in this order.
Settings.SCHEMA = {
    { key = "offline_policy", group = "offline", type = "enum", values = { "fail_closed", "fail_open" },
      default = "fail_closed", label = "When OpsAPI can't be reached",
      help = "fail_closed blocks access once the grace period is over; fail_open keeps the last known access." },
    { key = "token_ttl_seconds", group = "offline", type = "integer", min = 60, max = 86400, default = 900,
      label = "Entitlement token lifetime (seconds)", help = "Web apps re-check access this often." },
    { key = "refresh_interval_days", group = "offline", type = "integer", min = 1, max = 365, default = 7,
      label = "Licence refresh interval (days)", help = "Desktop apps refresh their licence file this often." },
    { key = "grace_days", group = "offline", type = "integer", min = 0, max = 365, default = by_kind(3, 30),
      label = "Grace period (days)", help = "How long a token or licence file keeps working without a refresh." },
    { key = "past_due_grace_days", group = "offline", type = "integer", min = 0, max = 90, default = 7,
      label = "Past-due grace (days)", help = "A failed renewal keeps access this long while payment is retried." },

    { key = "max_activations", group = "licences", type = "integer", min = 1, max = 10000, nullable = true,
      default = by_kind(cjson.null, 3), label = "Devices per licence",
      help = "Default for new licences (each licence can override it). Empty = unlimited." },
    { key = "released_seat_hold_days", group = "licences", type = "integer", min = 0, max = 3650, nullable = true,
      label = "Released devices keep their seat for (days)",
      help = "A device given back still counts for this long, so a licence can't be shared by activating and "
          .. "releasing machines in turn. Empty = refresh interval + grace period (as long as the released "
          .. "machine's licence file keeps working). 0 = free at once. Seats you free here never count." },
    { key = "activation_auto_release_days", group = "licences", type = "integer", min = 0, max = 3650,
      default = by_kind(0, 90), label = "Free devices not seen for (days)", help = "0 = never." },
    { key = "fingerprint_salt", group = "licences", type = "string", readonly = true,
      label = "Fingerprint salt", help = "Apps hash machine ids with this (LICENCE_FORMAT.md §6)." },

    { key = "allowed_origins", group = "public", type = "origins", default = {},
      label = "Allowed browser origins", help = "Web pages that may call the public endpoints (CORS)." },
    { key = "allowed_redirect_urls", group = "public", type = "urls", default = {},
      label = "Allowed redirect URLs", help = "Checkout success/cancel and account-link return URLs must start with one of these." },
    { key = "rate_limits", group = "public", type = "object", fields = RATE_FIELDS, label = "Rate limits" },
    { key = "lockout", group = "public", type = "object", fields = LOCKOUT_FIELDS, label = "Bad-key lockout" },

    { key = "email_collection", group = "customers", type = "enum", values = { "required", "optional", "none" },
      default = by_kind("required", "optional"), label = "Customer email" },
    { key = "activation_retention_days", group = "customers", type = "integer", min = 0, max = 3650, default = 90,
      label = "Keep freed devices for (days)" },

    { key = "display_name", group = "branding", type = "string", max = 120, label = "Display name" },
    { key = "logo_url", group = "branding", type = "url", label = "Logo URL" },
    { key = "accent_color", group = "branding", type = "color", label = "Accent colour" },
    { key = "support_email", group = "branding", type = "email", label = "Support email" },
    { key = "terms_url", group = "branding", type = "url", label = "Terms URL" },
    { key = "privacy_url", group = "branding", type = "url", label = "Privacy policy URL" },

    { key = "email_licence_keys", group = "delivery", type = "boolean", default = by_kind(false, true),
      label = "Email licence keys to customers" },
    { key = "webhook_include_licence_key", group = "delivery", type = "boolean", default = false,
      label = "Include the raw key in license.issued webhooks", help = "Off unless your server needs it." },

    { key = "refund_policy", group = "payments", type = "enum", values = { "revoke", "keep" }, default = "revoke",
      label = "On a full refund", help = "Partial refunds always keep access." },
    { key = "automatic_tax", group = "payments", type = "boolean", default = false, label = "Stripe Tax" },
}

local BY_KEY = {}
for _, s in ipairs(Settings.SCHEMA) do BY_KEY[s.key] = s end

local function default_for(spec, kind)
    local d = spec.default
    if type(d) == "table" and (d.web ~= nil or d.desktop ~= nil) then d = d[kind] end
    if spec.type == "object" then
        local o = {}
        for _, f in ipairs(spec.fields) do o[f.key] = f.default end
        return o
    end
    return d
end

--- The effective settings of an app: stored values over the kind's defaults.
function Settings.resolve(app)
    local stored = type(app.settings) == "table" and app.settings or {}
    local out = {}
    for _, spec in ipairs(Settings.SCHEMA) do
        local v = default_for(spec, app.kind)
        local s = stored[spec.key]
        if s ~= nil then
            if spec.type == "object" and type(s) == "table" and type(v) == "table" then
                for k, x in pairs(s) do v[k] = x end
            else
                v = s
            end
        end
        out[spec.key] = v
    end
    if out.display_name == nil then out.display_name = app.name end
    return out
end

local function origin_ok(o)
    return type(o) == "string" and #o <= 200
        and (o:match("^https://[%w%-%.]+%.[%w%-]+:?%d*$") or o:match("^http://localhost:?%d*$")
            or o:match("^http://127%.0%.0%.1:?%d*$")) ~= nil
end

-- https://<host with a dot>[:port][/...], or http on localhost / 127.0.0.1. The
-- host must end where it should (http://localhost.evil.com is not localhost).
local function url_ok(u)
    if type(u) ~= "string" or #u > 500 or u:find("[%s\\]") then return false end
    local scheme, host, rest = u:match("^(https?)://([%w%-%.]+)(.*)$")
    if not scheme then return false end
    rest = rest:gsub("^:%d+", "")
    if rest ~= "" and not rest:match("^[/?#]") then return false end
    if scheme == "https" then return host:match("^[%w%-]+%.[%w%-%.]*[%w%-]$") ~= nil end
    return host == "localhost" or host == "127.0.0.1"
end
Settings._url_ok = url_ok

local function is_array(v)
    if type(v) ~= "table" then return false end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return n == #v
end

local function check_value(spec, v)
    local t = spec.type
    if v == cjson.null then
        if spec.nullable then return true end
        return nil, spec.key .. " can't be empty"
    end
    if t == "integer" then
        if type(v) ~= "number" or v ~= math.floor(v) or v < spec.min or v > spec.max then
            return nil, string.format("%s must be a whole number from %d to %d", spec.key, spec.min, spec.max)
        end
    elseif t == "boolean" then
        if type(v) ~= "boolean" then return nil, spec.key .. " must be true or false" end
    elseif t == "enum" then
        for _, x in ipairs(spec.values) do if v == x then return true end end
        return nil, spec.key .. " must be one of " .. table.concat(spec.values, ", ")
    elseif t == "string" then
        if type(v) ~= "string" or #v > (spec.max or 500) then return nil, spec.key .. " must be text" end
    elseif t == "url" then
        if v ~= "" and not url_ok(v) then return nil, spec.key .. " must be an https URL" end
    elseif t == "email" then
        if v ~= "" and (type(v) ~= "string" or not v:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") or #v > 254) then
            return nil, spec.key .. " must be an email address"
        end
    elseif t == "color" then
        if v ~= "" and (type(v) ~= "string" or not v:match("^#%x%x%x%x%x%x$")) then
            return nil, spec.key .. " must be a colour like #2563eb"
        end
    elseif t == "origins" or t == "urls" then
        if not is_array(v) or #v > 50 then return nil, spec.key .. " must be a list (max 50)" end
        local ok = t == "origins" and origin_ok or url_ok
        for _, x in ipairs(v) do
            if not ok(x) then
                return nil, spec.key .. ": " .. tostring(x) .. (t == "origins"
                    and " is not an origin like https://app.example.com" or " is not an https URL")
            end
        end
    elseif t == "object" then
        if type(v) ~= "table" then return nil, spec.key .. " must be an object" end
        local fields = {}
        for _, f in ipairs(spec.fields) do fields[f.key] = f end
        for k, x in pairs(v) do
            local f = fields[k]
            if not f then return nil, spec.key .. "." .. tostring(k) .. " is not a setting" end
            if type(x) ~= "number" or x ~= math.floor(x) or x < f.min or x > f.max then
                return nil, string.format("%s.%s must be a whole number from %d to %d", spec.key, k, f.min, f.max)
            end
        end
    end
    return true
end

--- Validate a settings update and merge it into the stored settings.
-- @return the new stored settings table | nil, err
function Settings.merge(stored, input)
    if type(input) ~= "table" then return nil, "settings must be an object" end
    local out = {}
    for k, v in pairs(type(stored) == "table" and stored or {}) do out[k] = v end
    for k, v in pairs(input) do
        local spec = BY_KEY[k]
        if not spec then return nil, tostring(k) .. " is not a setting" end
        if spec.readonly then return nil, k .. " can't be changed" end
        local ok, err = check_value(spec, v)
        if not ok then return nil, err end
        if spec.type == "object" and type(out[k]) == "table" then
            local merged = {}
            for a, b in pairs(out[k]) do merged[a] = b end
            for a, b in pairs(v) do merged[a] = b end
            v = merged
        end
        -- An empty list is stored as [] (not {}).
        if (spec.type == "origins" or spec.type == "urls") and #v == 0 then v = setmetatable({}, cjson.array_mt) end
        out[k] = v
    end
    return out
end

--- What apps without a back end may read (GET /api/v2/public/billing/apps/:app).
local PUBLIC = { "display_name", "logo_url", "accent_color", "support_email", "terms_url", "privacy_url",
    "email_collection", "fingerprint_salt", "offline_policy", "refresh_interval_days", "grace_days" }
function Settings.public(app)
    local s = Settings.resolve(app)
    local out = {}
    for _, k in ipairs(PUBLIC) do out[k] = s[k] end
    return out
end

--- The schema for UIs, with the defaults for one kind of app.
function Settings.describe(kind)
    local out = {}
    for _, spec in ipairs(Settings.SCHEMA) do
        local d = {}
        for k, v in pairs(spec) do d[k] = v end
        d.default = default_for(spec, kind or "web")
        out[#out + 1] = d
    end
    return out
end

function Settings.isLicensed(app) return LICENSED[app.kind] ~= nil end

--- A fresh fingerprint salt (32 hex).
function Settings.newSalt()
    local random = require("resty.random")
    return require("resty.string").to_hex(random.bytes(16, true) or random.bytes(16))
end

return Settings
