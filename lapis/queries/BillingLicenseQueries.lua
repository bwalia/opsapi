--[[
    Billing & Entitlements — licence keys for desktop / self-hosted apps
    ====================================================================
    docs/BILLING_ENTITLEMENTS.md §5 / §8 / §10, docs/LICENCE_FORMAT.md.

    A key looks like ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2 (25 characters from a
    32-letter alphabet without 0/O/1/I: 125 random bits). Only its SHA-256 and
    first group are stored; the key itself is shown once (at issue or reissue).

    A licence has its own access_until / updates_until windows (set by the
    purchase that fulfilled it, or by hand). Each machine that uses it is an
    activation, identified by the app-salted fingerprint hash the app sends.
    activate / validate return a signed licence file (format v1) the app
    verifies offline.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Common = require("queries.FieldServiceCommon")
local Apps = require("queries.BillingAppQueries")
local Subs = require("queries.BillingSubscriptionQueries")
local ApiKey = require("helper.api-key")
local EntitlementService = require("helper.entitlement-service")
local Signing = require("lib.billing-signing")
local Settings = require("lib.billing-settings")

local Licenses = {}

local ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

function Licenses.generateKey()
    local random = require("resty.random")
    local bytes = random.bytes(25, true) or random.bytes(25)
    local chars = {}
    for i = 1, 25 do
        local n = bytes:byte(i) % 32 + 1 -- 256 = 8 x 32: no modulo bias
        chars[#chars + 1] = ALPHABET:sub(n, n)
        if i % 5 == 0 and i < 25 then chars[#chars + 1] = "-" end
    end
    return table.concat(chars)
end

--- Case, dashes and spaces don't matter when a customer types the key.
function Licenses.normalize(key)
    if type(key) ~= "string" then return nil end
    local k = key:upper():gsub("[^A-Z0-9]", "")
    if #k ~= 25 then return nil end
    return k
end

local function key_hash(raw) return ApiKey.hash(Licenses.normalize(raw)) end

local LIST_SELECT = [[
    SELECT l.uuid, l.key_prefix, l.status, l.max_activations, l.access_until, l.updates_until, l.source,
           l.metadata, l.created_by, l.revoked_at, l.key_rotated_at, l.created_at, l.updated_at,
           a.uuid AS app_uuid, a.name AS app_name, p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name,
           s.uuid AS subscription_uuid, c.uuid AS customer_uuid, c.external_id AS customer_external_id,
           c.email AS customer_email,
           (SELECT count(*) FROM billing_license_activations x
             WHERE x.license_id = l.id AND x.deactivated_at IS NULL)::int AS active_activations
    FROM billing_licenses l
    JOIN billing_apps a ON a.id = l.app_id
    JOIN customers c ON c.id = l.customer_id
    LEFT JOIN billing_plans p ON p.id = l.plan_id
    LEFT JOIN billing_subscriptions s ON s.id = l.subscription_id
]]

function Licenses.list(namespace_id, params)
    local where, vals = { "l.namespace_id = ?" }, { namespace_id }
    if Common.nilify(params.app) then
        where[#where + 1] = "(a.uuid = ? OR a.slug = ?)"
        vals[#vals + 1], vals[#vals + 2] = params.app, params.app
    end
    if Common.nilify(params.customer) then
        where[#where + 1] = "c.uuid = ?"
        vals[#vals + 1] = params.customer
    end
    if Common.nilify(params.status) then
        where[#where + 1] = "l.status = ?"
        vals[#vals + 1] = params.status
    end
    local page, per_page, offset = Common.paging(params)
    local sql = LIST_SELECT .. " WHERE " .. table.concat(where, " AND ")
    local total = db.query("SELECT count(*) AS n FROM (" .. sql .. ") x", unpack(vals))[1].n
    vals[#vals + 1], vals[#vals + 2] = per_page, offset
    local rows = db.query(sql .. " ORDER BY l.created_at DESC LIMIT ? OFFSET ?", unpack(vals))
    return Common.arr(rows), Common.meta(total, page, per_page)
end

local function activations(license_uuid)
    return Common.arr(db.query([[
        SELECT x.uuid, x.name, x.platform, x.app_version, x.first_seen_at, x.last_seen_at, x.deactivated_at
        FROM billing_license_activations x JOIN billing_licenses l ON l.id = x.license_id
        WHERE l.uuid = ? ORDER BY x.deactivated_at IS NOT NULL, x.last_seen_at DESC]], license_uuid))
end

function Licenses.get(namespace_id, uuid)
    local row = db.query(LIST_SELECT .. " WHERE l.namespace_id = ? AND l.uuid = ?", namespace_id, uuid)[1]
    if not row then return nil end
    row.activations = activations(uuid)
    return row
end

-- An ISO date/time (or null) for a timestamptz column.
local function ts_field(v, name)
    v = Common.nilify(v)
    if v == nil then return db.NULL end
    if type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d") then
        return nil, name .. " must be an ISO-8601 date/time, or null"
    end
    return db.raw(db.escape_literal(v) .. "::timestamptz")
end

local function clean(b, partial)
    local f = {}
    if b.max_activations ~= nil then
        local n = Common.to_number(b.max_activations)
        if b.max_activations == cjson.null or b.max_activations == "" then
            f.max_activations = db.NULL
        elseif not n or n < 1 or n > 100000 or n ~= math.floor(n) then
            return nil, "max_activations must be a whole number from 1, or null for unlimited"
        else
            f.max_activations = n
        end
    end
    for _, k in ipairs({ "access_until", "updates_until" }) do
        if b[k] ~= nil then
            local v, err = ts_field(b[k], k)
            if not v then return nil, err end
            f[k] = v
        end
    end
    if b.metadata ~= nil then
        if type(b.metadata) ~= "table" then return nil, "metadata must be an object" end
        f.metadata = db.raw(db.escape_literal(Signing.encode(b.metadata)) .. "::jsonb")
    end
    if partial and b.status ~= nil then
        -- revoke is its own action (irreversible); expiry comes from access_until.
        if b.status ~= "active" and b.status ~= "suspended" then
            return nil, "status can be set to active or suspended (use revoke to revoke)"
        end
        f.status = b.status
    end
    return f
end

-- Bad timestamps are input errors, not 500s.
local function write(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    local msg = tostring(res)
    if msg:find("invalid input syntax", 1, true) or msg:find("out of range", 1, true) then
        return nil, "access_until / updates_until must be valid ISO-8601 dates"
    end
    error(res)
end

local function emit(namespace_id, name, lic, app, key)
    local data = { uuid = lic.uuid, key_prefix = lic.key_prefix, app = app.uuid, plan_id = lic.plan_id,
        customer_id = lic.customer_id }
    -- The raw key never goes into the event (it is stored, and audited). When the
    -- app opted in (docs §10), it waits encrypted and the webhook sender adds it.
    if key and Settings.resolve(app).webhook_include_licence_key then
        local Delivery = require("lib.billing-delivery")
        if Delivery.configured() and Delivery.store(lic.id, key, { webhook = true }) then
            data.key_in_delivery = true
        else
            ngx.log(ngx.WARN, "[billing] licence key not added to ", name, ": LICENCE_DELIVERY_KEY is not set")
        end
    end
    pcall(require("helper.plugin-events").emitCore, namespace_id, name, data)
end

--- Issue a licence (the shared path for manual issue and purchase fulfilment).
-- f: { plan_id?, subscription_id?, purchase_id?, max_activations?, access_until?, updates_until?,
--      metadata?, source?, created_by? } (db values). @return row, raw key
function Licenses.issue(app, customer, f)
    local key = Licenses.generateKey()
    f.uuid = Common.uuid()
    f.namespace_id, f.app_id, f.customer_id = app.namespace_id, app.id, customer.id
    f.key_hash = key_hash(key)
    f.key_prefix = key:sub(1, 5)
    f.source = f.source or "manual"
    if f.max_activations == nil then
        local d = Settings.resolve(app).max_activations
        f.max_activations = d == cjson.null and db.NULL or d
    end
    local row = db.insert("billing_licenses", f, { returning = "*" })[1]
    emit(app.namespace_id, "license.issued", row, app, key)
    return row, key
end

--- Issue a licence by hand. @return { license, key } (key shown once) | nil, err
function Licenses.create(namespace_id, actor, b)
    local app = Apps.find(namespace_id, b.app)
    if not app then return nil, "App not found" end
    local customer = Subs.customer(namespace_id, b.customer)
    if not customer then return nil, "Customer not found" end
    local f, err = clean(b, false)
    if not f then return nil, err end
    -- v1 name for access_until.
    if b.expires_at ~= nil and b.access_until == nil then
        local v, terr = ts_field(b.expires_at, "expires_at")
        if not v then return nil, terr end
        f.access_until = v
    end
    if Common.nilify(b.plan) then
        local plan = Subs.appPlan(app.id, b.plan)
        if not plan then return nil, "Plan not found in this app" end
        f.plan_id = plan.id
    end
    if Common.nilify(b.subscription) then
        local sub = db.query([[SELECT id FROM billing_subscriptions
            WHERE namespace_id = ? AND uuid = ? AND app_id = ? AND customer_id = ?]],
            namespace_id, b.subscription, app.id, customer.id)[1]
        if not sub then return nil, "Subscription not found for this customer and app" end
        f.subscription_id = sub.id
    end
    f.created_by = actor
    local row, key = write(function() return Licenses.issue(app, customer, f) end)
    if not row then return nil, key end
    return { license = Licenses.get(namespace_id, row.uuid), key = key }
end

function Licenses.update(namespace_id, uuid, b)
    local f, err = clean(b, true)
    if not f then return nil, err end
    local lic = db.query("SELECT id, status FROM billing_licenses WHERE namespace_id = ? AND uuid = ?",
        namespace_id, uuid)[1]
    if not lic then return nil, "Licence not found" end
    if lic.status == "revoked" then return nil, "a revoked licence can't be changed" end
    if next(f) ~= nil then
        f.updated_at = db.raw("NOW()")
        local ok, werr = write(function() return db.update("billing_licenses", f, { id = lic.id }) end)
        if not ok then return nil, werr end
    end
    return Licenses.get(namespace_id, uuid)
end

--- Revoke for good: every activation ends and validation fails from now on.
function Licenses.revoke(namespace_id, uuid)
    return Common.transaction(function()
        local lic = db.query([[UPDATE billing_licenses SET status = 'revoked', revoked_at = NOW(), updated_at = NOW()
            WHERE namespace_id = ? AND uuid = ? AND status <> 'revoked' RETURNING id]], namespace_id, uuid)[1]
        if not lic then return nil, "Licence not found" end
        db.query([[UPDATE billing_license_activations SET deactivated_at = NOW()
            WHERE license_id = ? AND deactivated_at IS NULL]], lic.id)
        return Licenses.get(namespace_id, uuid)
    end)
end

--- A lost key: a new key for the same licence. The old key stops working at
-- once; activations are kept. @return { license, key } | nil, err
--- customer_id / app_id: limit to one customer's licences in one app (the account page).
function Licenses.reissue(namespace_id, uuid, customer_id, app_id)
    local lic = db.query([[SELECT l.*, a.uuid AS app_uuid FROM billing_licenses l JOIN billing_apps a ON a.id = l.app_id
        WHERE l.namespace_id = ? AND l.uuid = ? AND (?::int IS NULL OR l.customer_id = ?::int)
          AND (?::bigint IS NULL OR l.app_id = ?::bigint)]],
        namespace_id, uuid, customer_id or db.NULL, customer_id or db.NULL, app_id or db.NULL, app_id or db.NULL)[1]
    if not lic then return nil, "Licence not found" end
    if lic.status == "revoked" then return nil, "a revoked licence can't be reissued" end
    local key = Licenses.generateKey()
    db.update("billing_licenses", { key_hash = key_hash(key), key_prefix = key:sub(1, 5),
        key_rotated_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = lic.id })
    lic.key_prefix = key:sub(1, 5)
    local app = db.query("SELECT * FROM billing_apps WHERE id = ?", lic.app_id)[1]
    emit(namespace_id, "license.reissued", lic, app, key)
    return { license = Licenses.get(namespace_id, uuid), key = key }
end

--- Free a seat (e.g. a lost laptop).
--- Free a device. With customer_id (+ app_id): the customer, from the account page
-- (the seat keeps counting for the hold period); without: an admin (free at once).
function Licenses.removeActivation(namespace_id, uuid, activation_uuid, customer_id, app_id)
    local res = db.query([[UPDATE billing_license_activations x SET deactivated_at = NOW(), released_by = ?
        FROM billing_licenses l WHERE l.id = x.license_id AND l.namespace_id = ? AND l.uuid = ?
          AND x.uuid = ? AND x.deactivated_at IS NULL AND (?::int IS NULL OR l.customer_id = ?::int)
          AND (?::bigint IS NULL OR l.app_id = ?::bigint)]],
        customer_id and "customer" or "admin", namespace_id, uuid, activation_uuid, customer_id or db.NULL,
        customer_id or db.NULL, app_id or db.NULL, app_id or db.NULL)
    if (res.affected_rows or 0) == 0 then return nil, "Activation not found" end
    return true
end

--- A customer's licences in one app with their devices (the "my licences" page).
--- The customer holding a licence key in this app (proof of ownership for an upgrade).
function Licenses.customerForKey(app, raw_key)
    local key = Licenses.normalize(raw_key)
    if not key then return nil end
    return db.query([[SELECT c.id, c.uuid, c.email FROM billing_licenses l JOIN customers c ON c.id = l.customer_id
        WHERE l.key_hash = ? AND l.app_id = ? AND l.status <> 'revoked']], ApiKey.hash(key), app.id)[1]
end

function Licenses.forCustomer(app, customer_id)
    local rows = db.query(LIST_SELECT .. " WHERE l.app_id = ? AND l.customer_id = ? ORDER BY l.created_at DESC",
        app.id, customer_id)
    for _, r in ipairs(rows) do
        r.activations = activations(r.uuid)
        r.customer_email, r.customer_external_id = nil, nil
    end
    return Common.arr(rows)
end

-- ---------------------------------------------------------------------------
-- Public: activate / validate / deactivate (publishable key + licence key)
-- Errors are { status, code, message } so apps can branch on `code`.
-- ---------------------------------------------------------------------------

local function failure(status, code, message)
    return nil, { status = status, code = code, message = message }
end

local INVALID = { 404, "invalid_license", "This licence key is not valid for this app" }

local function check_input(b, need_version)
    if type(b.fingerprint_hash) ~= "string" or not b.fingerprint_hash:match("^%x+$") or #b.fingerprint_hash ~= 64 then
        return failure(400, "invalid_fingerprint",
            "fingerprint_hash must be the 64-character SHA-256 hex of salt + \":\" + machine id (LICENCE_FORMAT.md §6)")
    end
    if need_version and (type(b.app_version) ~= "string" or b.app_version == "" or #b.app_version > 40) then
        return failure(400, "invalid_app_version", "app_version is required (max 40 characters)")
    end
    return true
end

-- The licence behind a key, if it may be used right now. Locks the row so
-- concurrent activations can't exceed max_activations.
local function usable(app, raw_key)
    local key = Licenses.normalize(raw_key)
    if not key then return failure(unpack(INVALID)) end
    local lic = db.query([[SELECT l.*, extract(epoch FROM l.access_until)::bigint AS access_until_epoch,
            extract(epoch FROM l.updates_until)::bigint AS updates_until_epoch
        FROM billing_licenses l WHERE l.key_hash = ? AND l.app_id = ? FOR UPDATE]], ApiKey.hash(key), app.id)[1]
    if not lic then return failure(unpack(INVALID)) end
    if lic.status == "active" and lic.access_until_epoch and tonumber(lic.access_until_epoch) <= ngx.time() then
        db.query("UPDATE billing_licenses SET status = 'expired', updated_at = NOW() WHERE id = ?", lic.id)
        lic.status = "expired"
    end
    if lic.status == "expired" then
        return failure(403, "access_ended", "This licence's access period is over")
    end
    if lic.status ~= "active" then
        return failure(403, "license_" .. lic.status, "This licence is " .. lic.status)
    end
    if lic.subscription_id then
        local live = db.query("SELECT 1 FROM billing_subscriptions s WHERE s.id = ? AND "
            .. require("helper.entitlement-service").liveSubscriptionSql("s"),
            lic.subscription_id, Settings.resolve(app).past_due_grace_days)[1]
        if not live then
            return failure(403, "subscription_inactive", "The subscription behind this licence is not active")
        end
    end
    return lic
end

local function file_for(app, lic, fingerprint_hash)
    if not Signing.configured() then
        return failure(503, "not_configured", "Licensing is not configured on this server")
    end
    local customer = db.query("SELECT id, uuid, external_id FROM customers WHERE id = ?", lic.customer_id)[1]
    local out, err = EntitlementService.licenseFile(app, lic, customer, fingerprint_hash)
    if not out then return failure(503, "not_configured", tostring(err)) end
    return out
end

-- Run fn(lic) in a transaction after the common checks. A bad key is
-- reported to the caller (`bad_key = true`) so it can count it for lockout.
local function public_call(app, b, need_version, fn)
    if not Signing.configured() then
        return failure(503, "not_configured", "Licensing is not configured on this server")
    end
    local ok_in, in_err = check_input(b, need_version)
    if not ok_in then return nil, in_err end
    local result, err
    local ok, tx_err = Common.transaction(function()
        local lic, ferr = usable(app, b.license_key)
        if not lic then err = ferr return true end
        result, err = fn(lic)
        return true
    end)
    if not ok then return failure(500, "error", tx_err or "Request failed") end
    if err then return nil, err end
    return result
end

-- At most `max` bytes, cut on a UTF-8 character boundary.
local function utf8_cut(s, max)
    if #s <= max then return s end
    local cut = max
    while cut > 0 do
        local nxt = s:byte(cut + 1)
        if not nxt or nxt < 0x80 or nxt >= 0xC0 then break end -- not a continuation byte
        cut = cut - 1
    end
    return s:sub(1, cut)
end
Licenses._utf8_cut = utf8_cut

local function info(b, field, max)
    local v = b[field]
    if type(v) ~= "string" or v == "" then return db.NULL end
    return utf8_cut(v, max)
end

-- How long a released seat still counts (released_seat_hold_days; empty = refresh + grace).
local function hold_days(app)
    local s = Settings.resolve(app)
    local d = s.released_seat_hold_days
    if type(d) == "number" then return d end
    return (tonumber(s.refresh_interval_days) or 0) + (tonumber(s.grace_days) or 0)
end

function Licenses.activate(app, b)
    return public_call(app, b, true, function(lic)
        local live = db.query([[SELECT id FROM billing_license_activations
            WHERE license_id = ? AND fingerprint_hash = ? AND deactivated_at IS NULL]], lic.id, b.fingerprint_hash)[1]
        if live then
            db.query([[UPDATE billing_license_activations SET last_seen_at = NOW(),
                name = COALESCE(?, name), platform = COALESCE(?, platform), app_version = ?
                WHERE id = ?]], info(b, "name", 120), info(b, "platform", 60), info(b, "app_version", 40), live.id)
        else
            -- Seats taken: live devices, plus devices released (by the device or the
            -- customer) within the hold period, whose licence files still work offline.
            local hold = hold_days(app)
            local used = db.query([[SELECT count(DISTINCT fingerprint_hash)::int AS n FROM billing_license_activations
                WHERE license_id = ? AND fingerprint_hash <> ? AND (deactivated_at IS NULL
                   OR (released_by IN ('device', 'customer') AND deactivated_at > NOW() - make_interval(days => ?)))]],
                lic.id, b.fingerprint_hash, hold)[1].n
            if lic.max_activations and lic.max_activations ~= db.NULL and used >= tonumber(lic.max_activations) then
                return failure(409, "activation_limit", "This licence is already in use on " .. used
                    .. " device(s), its limit" .. (hold > 0 and (" (devices released in the last " .. hold
                    .. " days still count)") or ""))
            end
            db.insert("billing_license_activations", {
                uuid = Common.uuid(), license_id = lic.id, fingerprint_hash = b.fingerprint_hash,
                name = info(b, "name", 120), platform = info(b, "platform", 60),
                app_version = info(b, "app_version", 40),
            })
        end
        return file_for(app, lic, b.fingerprint_hash)
    end)
end

function Licenses.validate(app, b)
    return public_call(app, b, true, function(lic)
        local res = db.query([[UPDATE billing_license_activations SET last_seen_at = NOW(), app_version = ?
            WHERE license_id = ? AND fingerprint_hash = ? AND deactivated_at IS NULL]],
            info(b, "app_version", 40), lic.id, b.fingerprint_hash)
        if (res.affected_rows or 0) == 0 then
            return failure(403, "not_activated", "This device is not activated for this licence")
        end
        return file_for(app, lic, b.fingerprint_hash)
    end)
end

--- Free this device's seat. Works for any licence that isn't revoked (an
-- expired or suspended one may still hand its seat back).
function Licenses.deactivate(app, b)
    local ok_in, in_err = check_input(b, false)
    if not ok_in then return nil, in_err end
    local key = Licenses.normalize(b.license_key)
    if not key then return failure(unpack(INVALID)) end
    local res = db.query([[UPDATE billing_license_activations x SET deactivated_at = NOW(), released_by = 'device'
        FROM billing_licenses l WHERE l.id = x.license_id AND l.key_hash = ? AND l.app_id = ?
          AND x.fingerprint_hash = ? AND x.deactivated_at IS NULL]], ApiKey.hash(key), app.id, b.fingerprint_hash)
    if (res.affected_rows or 0) == 0 then
        return failure(404, "not_activated", "This device is not activated for this licence")
    end
    return { deactivated = true }
end

-- ---------------------------------------------------------------------------
-- Maintenance (lib/billing-jobs.lua)
-- ---------------------------------------------------------------------------

--- Free devices not seen for an app's activation_auto_release_days, and delete
-- freed devices past its activation_retention_days.
function Licenses.maintain()
    for _, app in ipairs(db.query("SELECT * FROM billing_apps WHERE deleted_at IS NULL")) do
        local s = Settings.resolve(app)
        if (s.activation_auto_release_days or 0) > 0 then
            db.query([[UPDATE billing_license_activations x SET deactivated_at = NOW(), released_by = 'auto'
                FROM billing_licenses l WHERE l.id = x.license_id AND l.app_id = ? AND x.deactivated_at IS NULL
                  AND x.last_seen_at < NOW() - make_interval(days => ?)]], app.id, s.activation_auto_release_days)
        end
        db.query([[DELETE FROM billing_license_activations x USING billing_licenses l
            WHERE l.id = x.license_id AND l.app_id = ? AND x.deactivated_at IS NOT NULL
              AND x.deactivated_at < NOW() - make_interval(days => ?)]], app.id, s.activation_retention_days or 90)
    end
end

return Licenses
