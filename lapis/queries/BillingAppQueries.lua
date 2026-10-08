--[[
    Billing & Entitlements — apps, their feature catalogue, reports
    ===============================================================
    docs/BILLING_ENTITLEMENTS.md §4.2 / §7.1. Every lookup takes the caller's
    namespace_id: another workspace's app is simply "not found".

    An app is referenced by uuid or slug. Its publishable key (pk_test_… /
    pk_live_…) only identifies it on public endpoints; it grants nothing.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Common = require("queries.FieldServiceCommon")
local Settings = require("lib.billing-settings")

local Apps = {}

local KINDS = { web = true, desktop = true, self_hosted = true, mobile = true }
local MODES = { test = true, live = true }
local FEATURE_TYPES = { boolean = true, limit = true }

local function random_hex(n)
    local random = require("resty.random")
    return require("resty.string").to_hex(random.bytes(n, true) or random.bytes(n))
end
Apps.random_hex = random_hex

local function new_publishable_key(mode)
    return "pk_" .. mode .. "_" .. random_hex(16)
end

--- Unique-index violations become a readable 409-style message.
local function insert_or_conflict(fn, conflict_message)
    local ok, res = pcall(fn)
    if ok then return res end
    if tostring(res):find("duplicate key", 1, true) then return nil, conflict_message end
    error(res)
end
Apps.insert_or_conflict = insert_or_conflict

local function int_in(v, lo, hi, name)
    local n = Common.to_number(v)
    if not n or n ~= math.floor(n) or n < lo or n > hi then
        return nil, string.format("%s must be a whole number between %d and %d", name, lo, hi)
    end
    return n
end

local function slugify(s)
    return (tostring(s):lower():gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", ""):sub(1, 64))
end

-- Validate the writable fields present in `b`. partial = update (only what's sent).
local function clean(b, partial)
    local f = {}
    if b.name ~= nil or not partial then
        local name = Common.nilify(b.name)
        if type(name) ~= "string" or #name > 120 then return nil, "name is required (max 120 characters)" end
        f.name = name
    end
    if b.slug ~= nil or not partial then
        local slug = Common.nilify(b.slug) or slugify(f.name or "")
        if type(slug) ~= "string" or not slug:match("^[a-z0-9][a-z0-9-]*$") or #slug > 64 then
            return nil, "slug must be lowercase letters, digits and dashes (max 64)"
        end
        f.slug = slug
    end
    for field, allowed in pairs({ kind = KINDS, mode = MODES }) do
        if b[field] ~= nil then
            if not allowed[b[field]] then
                local names = {}
                for k in pairs(allowed) do names[#names + 1] = k end
                table.sort(names)
                return nil, field .. " must be one of " .. table.concat(names, ", ")
            end
            f[field] = b[field]
        end
    end
    if b.active ~= nil then f.active = Common.to_bool(b.active, true) end
    return f
end

local function jsonb(v)
    return db.raw(db.escape_literal(require("lib.billing-signing").encode(v)) .. "::jsonb")
end

function Apps.list(namespace_id)
    local rows = db.query("SELECT * FROM billing_apps WHERE namespace_id = ? AND deleted_at IS NULL ORDER BY name",
        namespace_id)
    for i, r in ipairs(rows) do rows[i] = Apps.present(r) end
    return Common.arr(rows)
end

--- Full row (with id) of a workspace's app, by uuid or slug.
function Apps.find(namespace_id, ref)
    if type(ref) ~= "string" or ref == "" then return nil end
    return db.query([[SELECT * FROM billing_apps WHERE namespace_id = ? AND deleted_at IS NULL
        AND (uuid = ? OR slug = ?) LIMIT 1]], namespace_id, ref, ref)[1]
end

--- The live app behind a publishable key (public endpoints).
function Apps.byPublishableKey(pk)
    if type(pk) ~= "string" or not pk:match("^pk_%a+_%x+$") then return nil end
    return db.query([[SELECT * FROM billing_apps
        WHERE publishable_key = ? AND active AND deleted_at IS NULL LIMIT 1]], pk)[1]
end

--- An app for the management API: settings are the effective values
-- (defaults for its kind + what was set).
function Apps.present(row)
    if not row then return nil end
    local out = {}
    for k, v in pairs(row) do
        if k ~= "id" and k ~= "namespace_id" and k ~= "deleted_at" and k ~= "cache_generation" then out[k] = v end
    end
    out.settings = Settings.resolve(row)
    return out
end

--- Bump the app's cache generation: every cached entitlement of the app is
-- stale from now on (plans, features, settings, upgrade paths changed).
function Apps.bump(app_id)
    db.query("UPDATE billing_apps SET cache_generation = cache_generation + 1 WHERE id = ?", app_id)
end

--- A live app by uuid or publishable key, for the public endpoints.
function Apps.findPublic(ref)
    if type(ref) ~= "string" or ref == "" then return nil end
    if ref:match("^pk_") then return Apps.byPublishableKey(ref) end
    return db.query("SELECT * FROM billing_apps WHERE uuid = ? AND active AND deleted_at IS NULL LIMIT 1", ref)[1]
end

function Apps.create(namespace_id, actor, b)
    local f, err = clean(b, false)
    if not f then return nil, err end
    f.mode = f.mode or "test"
    f.kind = f.kind or "web"
    local settings, serr = Settings.merge({}, b.settings or {})
    if not settings then return nil, serr end
    settings.fingerprint_salt = Settings.newSalt()
    f.settings = jsonb(settings)
    f.uuid = Common.uuid()
    f.namespace_id = namespace_id
    f.publishable_key = new_publishable_key(f.mode)
    f.created_by = actor
    local row, cerr = insert_or_conflict(function()
        return db.insert("billing_apps", f, { returning = "*" })[1]
    end, "an app with this slug already exists")
    if not row then return nil, cerr end
    return Apps.present(row)
end

function Apps.update(namespace_id, ref, b)
    local app = Apps.find(namespace_id, ref)
    if not app then return nil, "App not found" end
    local f, err = clean(b, true)
    if not f then return nil, err end
    if b.settings ~= nil then
        local settings, serr = Settings.merge(app.settings, b.settings)
        if not settings then return nil, serr end
        f.settings = jsonb(settings)
    end
    -- The key's prefix names the mode, so switching mode issues a new key.
    if f.mode and f.mode ~= app.mode then f.publishable_key = new_publishable_key(f.mode) end
    if next(f) == nil then return Apps.present(app) end
    f.updated_at = db.raw("NOW()")
    f.cache_generation = db.raw("cache_generation + 1")
    local _, cerr = insert_or_conflict(function()
        return db.update("billing_apps", f, { id = app.id })
    end, "an app with this slug already exists")
    if cerr then return nil, cerr end
    return Apps.present(Apps.find(namespace_id, app.uuid))
end

function Apps.rotateKey(namespace_id, ref)
    local app = Apps.find(namespace_id, ref)
    if not app then return nil, "App not found" end
    db.update("billing_apps", { publishable_key = new_publishable_key(app.mode), updated_at = db.raw("NOW()") },
        { id = app.id })
    return Apps.present(Apps.find(namespace_id, app.uuid))
end

--- Soft delete: plans, subscriptions and licences stay for the record, and
-- the publishable key stops working at once.
function Apps.delete(namespace_id, ref)
    local app = Apps.find(namespace_id, ref)
    if not app then return nil, "App not found" end
    db.update("billing_apps", { deleted_at = db.raw("NOW()"), active = false, updated_at = db.raw("NOW()") },
        { id = app.id })
    return true
end

-- ---------------------------------------------------------------------------
-- Feature catalogue
-- ---------------------------------------------------------------------------

local FEATURE_COLUMNS = "uuid, key, name, description, type, unit, sort_order, released_at, created_at, updated_at"

function Apps.features(app_id)
    return Common.arr(db.query("SELECT " .. FEATURE_COLUMNS ..
        " FROM billing_features WHERE app_id = ? ORDER BY sort_order, key", app_id))
end

--- { [key] = "boolean" | "limit" } for an app.
function Apps.catalog(app_id)
    local out = {}
    for _, r in ipairs(db.query("SELECT key, type FROM billing_features WHERE app_id = ?", app_id)) do
        out[r.key] = r.type
    end
    return out
end

--- { [key] = { type, released (unix seconds or nil) } } for resolution.
function Apps.catalogWithReleases(app_id)
    local out = {}
    for _, r in ipairs(db.query([[SELECT key, type, extract(epoch FROM released_at)::bigint AS released
        FROM billing_features WHERE app_id = ?]], app_id)) do
        out[r.key] = { type = r.type, released = tonumber(r.released) }
    end
    return out
end

local function clean_feature(b, partial)
    local f = {}
    if not partial then
        if type(b.key) ~= "string" or not b.key:match("^[a-z0-9_]+$") or #b.key > 64 then
            return nil, "key must be lowercase letters, digits and _ (max 64)"
        end
        f.key = b.key
        local ftype = b.type or "boolean"
        if not FEATURE_TYPES[ftype] then return nil, "type must be boolean or limit" end
        f.type = ftype
    elseif b.type ~= nil or b.key ~= nil then
        return nil, "a feature's key and type can't change: delete it and add a new one"
    end
    if b.name ~= nil or not partial then
        local name = Common.nilify(b.name)
        if type(name) ~= "string" or #name > 120 then return nil, "name is required (max 120 characters)" end
        f.name = name
    end
    for _, field in ipairs({ "description", "unit" }) do
        if b[field] ~= nil then
            local v = Common.nilify(b[field])
            if v ~= nil and (type(v) ~= "string" or #v > 500) then return nil, field .. " must be text" end
            f[field] = v or db.NULL
        end
    end
    if b.sort_order ~= nil then
        local n, err = int_in(b.sort_order, -100000, 100000, "sort_order")
        if not n then return nil, err end
        f.sort_order = n
    end
    if b.released_at ~= nil then
        local v = Common.nilify(b.released_at)
        if v ~= nil and (type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d")
            or not pcall(db.query, "SELECT ?::timestamptz", v)) then
            return nil, "released_at must be an ISO-8601 date, or null"
        end
        f.released_at = v and db.raw(db.escape_literal(v) .. "::timestamptz") or db.NULL
    end
    return f
end

function Apps.addFeature(app, b)
    local f, err = clean_feature(b, false)
    if not f then return nil, err end
    f.uuid = Common.uuid()
    f.app_id = app.id
    local row, cerr = insert_or_conflict(function()
        return db.insert("billing_features", f, { returning = "*" })[1]
    end, "this app already has a feature with that key")
    if not row then return nil, cerr end
    Apps.bump(app.id)
    row.id, row.app_id = nil, nil
    return row
end

function Apps.updateFeature(app, key, b)
    local f, err = clean_feature(b, true)
    if not f then return nil, err end
    if next(f) ~= nil then
        f.updated_at = db.raw("NOW()")
        db.update("billing_features", f, { app_id = app.id, key = key })
        Apps.bump(app.id)
    end
    local row = db.query("SELECT " .. FEATURE_COLUMNS .. " FROM billing_features WHERE app_id = ? AND key = ?",
        app.id, key)[1]
    if not row then return nil, "Feature not found" end
    return row
end

--- Remove a feature and its value from every plan and grant of the app.
function Apps.deleteFeature(app, key)
    return Common.transaction(function()
        local res = db.query("DELETE FROM billing_features WHERE app_id = ? AND key = ?", app.id, key)
        if (res.affected_rows or 0) == 0 then return nil, "Feature not found" end
        db.query("UPDATE billing_plans SET features = features - ?, updated_at = NOW() WHERE app_id = ?", key, app.id)
        Apps.bump(app.id)
        -- A grant left with no features and no plan would grant nothing: revoke it.
        db.query([[UPDATE billing_grants SET features = features - ?, updated_at = NOW(),
            revoked_at = CASE WHEN plan_id IS NULL AND (features - ?) = '{}'::jsonb THEN NOW() ELSE revoked_at END
            WHERE app_id = ? AND (features -> ?) IS NOT NULL]], key, key, app.id, key)
        return true
    end)
end

--- Validate a { feature_key = value } map against the app's catalogue:
-- booleans true/false; limits a whole number >= 0, or null = unlimited.
-- @return the cleaned map | nil, err
function Apps.checkFeatureValues(app_id, values)
    if values == nil or values == cjson.null then return {} end
    if type(values) ~= "table" then return nil, "features must be an object of feature key -> value" end
    local catalog = Apps.catalog(app_id)
    local out = {}
    for key, v in pairs(values) do
        local ftype = catalog[key]
        if not ftype then return nil, "unknown feature '" .. tostring(key) .. "' (add it to the app first)" end
        if ftype == "boolean" then
            if type(v) ~= "boolean" then return nil, "feature '" .. key .. "' is on/off: use true or false" end
        elseif v ~= cjson.null and (type(v) ~= "number" or v < 0 or v ~= math.floor(v)) then
            return nil, "feature '" .. key .. "' is a limit: use a whole number, or null for unlimited"
        end
        out[key] = v
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

-- Monthly value of one subscription in minor units.
local MONTHLY_SQL = [[p.amount * (CASE p.billing_interval WHEN 'year' THEN 1.0 / 12 WHEN 'week' THEN 52.0 / 12
    WHEN 'day' THEN 365.0 / 12 ELSE 1 END) / GREATEST(COALESCE(p.interval_count, 1), 1)]]

function Apps.report(app)
    local counts = db.query([[
        SELECT count(*) FILTER (WHERE status = 'active') AS active,
               count(*) FILTER (WHERE status = 'trialing') AS trialing,
               count(*) FILTER (WHERE status = 'past_due') AS past_due,
               count(*) FILTER (WHERE status IN ('canceled', 'incomplete_expired')
                                  AND canceled_at > NOW() - interval '30 days') AS churned_30d,
               count(*) FILTER (WHERE created_at > NOW() - interval '30 days') AS new_30d
        FROM billing_subscriptions WHERE app_id = ?]], app.id)[1]
    local mrr = db.query([[
        SELECT p.currency, round(sum(]] .. MONTHLY_SQL .. [[))::bigint AS amount
        FROM billing_subscriptions s JOIN billing_plans p ON p.id = s.plan_id
        WHERE s.app_id = ? AND s.status IN ('active', 'past_due') AND p.plan_type = 'subscription'
        GROUP BY p.currency ORDER BY p.currency]], app.id)
    local other = db.query([[
        SELECT (SELECT count(*) FROM billing_grants WHERE app_id = ? AND revoked_at IS NULL
                  AND (expires_at IS NULL OR expires_at > NOW())) AS active_grants,
               (SELECT count(*) FROM billing_licenses WHERE app_id = ? AND status = 'active') AS active_licenses,
               (SELECT count(*) FROM billing_license_activations a JOIN billing_licenses l ON l.id = a.license_id
                  WHERE l.app_id = ? AND a.deactivated_at IS NULL) AS active_activations]],
        app.id, app.id, app.id)[1]
    local out = { mrr = Common.arr(mrr) }
    for _, src in ipairs({ counts, other }) do
        for k, v in pairs(src) do out[k] = tonumber(v) or 0 end
    end
    return out
end

return Apps
