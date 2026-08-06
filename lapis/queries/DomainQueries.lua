--[[
    Domain Queries
    ==============

    Business logic for the namespace-scoped domain registry: CRUD, pagination,
    filters, and expiry-field updates. Every query filters by namespace_id.

    Platform admins get a cross-namespace "super-view": pass opts.platform_admin
    = true to getDomains to list domains across all namespaces (the route layer
    decides who is a platform admin via helper/admin-check.lua).
]]

local DomainModel = require("models.DomainModel")
local Global = require("helper.global")
local db = require("lapis.db")

local DomainQueries = {}

-- Whitelisted, user-writable columns (never trust arbitrary keys into SQL).
local WRITABLE_FIELDS = {
    "domain_name", "registrar", "dns_provider", "cloudflare_zone_id",
    "status", "alert_threshold_days", "auto_renew", "owner_user_uuid", "notes",
    -- WSL Proxy vhost rendering fields (see helper/wslproxy-server.lua)
    "environment", "wslproxy_rule_id", "ssl_email", "ssl_enabled",
    "ssl_auto_renew", "ssl_force_https", "ssl_staging", "wslproxy_root",
    "listen_ports", "proxy_target",
}

--------------------------------------------------------------------------------
-- Create
--------------------------------------------------------------------------------
function DomainQueries.createDomain(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")
    return DomainModel:create(params, { returning = "*" })
end

--------------------------------------------------------------------------------
-- List (namespace-scoped, or cross-namespace for platform admins)
--------------------------------------------------------------------------------
function DomainQueries.getDomains(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    if per_page > 200 then per_page = 200 end
    local offset = (page - 1) * per_page

    local where_parts = { "d.deleted_at IS NULL" }
    local where_values = {}

    -- Platform-admin super-view skips the namespace filter; everyone else is scoped.
    if not params.platform_admin then
        table.insert(where_parts, "d.namespace_id = ?")
        table.insert(where_values, namespace_id)
    end

    if params.status and params.status ~= "" then
        table.insert(where_parts, "d.status = ?")
        table.insert(where_values, params.status)
    end

    if params.dns_provider and params.dns_provider ~= "" then
        table.insert(where_parts, "d.dns_provider = ?")
        table.insert(where_values, params.dns_provider)
    end

    if params.search and params.search ~= "" then
        table.insert(where_parts, "(d.domain_name ILIKE ? OR d.registrar ILIKE ? OR d.notes ILIKE ?)")
        local term = "%" .. params.search .. "%"
        table.insert(where_values, term)
        table.insert(where_values, term)
        table.insert(where_values, term)
    end

    -- "expiring" convenience filter: registration OR SSL within N days.
    if params.expiring_within_days and tonumber(params.expiring_within_days) then
        local days = tonumber(params.expiring_within_days)
        table.insert(where_parts, [[(
            (d.registration_expires_at IS NOT NULL AND d.registration_expires_at <= NOW() + (? || ' days')::interval)
            OR (d.ssl_expires_at IS NOT NULL AND d.ssl_expires_at <= NOW() + (? || ' days')::interval)
        )]])
        table.insert(where_values, days)
        table.insert(where_values, days)
    end

    local where_clause = table.concat(where_parts, " AND ")

    local count_sql = string.format("SELECT COUNT(*) as total FROM domains d WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(where_values))
    local total = tonumber(count_result[1].total) or 0

    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT d.*
        FROM domains d
        WHERE %s
        ORDER BY
            CASE WHEN d.registration_expires_at IS NULL THEN 1 ELSE 0 END,
            d.registration_expires_at ASC,
            d.created_at DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local domains = db.query(data_sql, unpack(data_values))

    return {
        items = domains,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page),
        },
    }
end

--------------------------------------------------------------------------------
-- Get single (by uuid). Ownership is re-checked in the route handler.
--------------------------------------------------------------------------------
function DomainQueries.getDomain(uuid)
    local result = db.query([[
        SELECT d.* FROM domains d WHERE d.uuid = ? AND d.deleted_at IS NULL
    ]], uuid)
    return result and result[1] or nil
end

--------------------------------------------------------------------------------
-- Update (whitelisted fields only)
--------------------------------------------------------------------------------
function DomainQueries.updateDomain(uuid, params)
    local domain = DomainModel:find({ uuid = uuid })
    if not domain then return nil end

    local update_params = {}
    for _, field in ipairs(WRITABLE_FIELDS) do
        if params[field] ~= nil then
            update_params[field] = params[field]
        end
    end
    if params.metadata ~= nil then
        update_params.metadata = params.metadata
    end
    if next(update_params) == nil then
        return domain
    end
    update_params.updated_at = db.raw("NOW()")
    return domain:update(update_params, { returning = "*" })
end

--------------------------------------------------------------------------------
-- Persist expiry-check results (called by the expiry engine)
--------------------------------------------------------------------------------
function DomainQueries.applyExpiryResult(uuid, result)
    local domain = DomainModel:find({ uuid = uuid })
    if not domain then return nil end

    local update = {
        last_checked_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
        last_check_error = result.error,
    }
    if result.registration_expires_at ~= nil then update.registration_expires_at = result.registration_expires_at end
    if result.registrar ~= nil then update.registrar = result.registrar end
    if result.registrar_status ~= nil then update.registrar_status = result.registrar_status end
    if result.ssl_expires_at ~= nil then update.ssl_expires_at = result.ssl_expires_at end
    if result.ssl_issuer ~= nil then update.ssl_issuer = result.ssl_issuer end
    if result.status ~= nil then update.status = result.status end

    return domain:update(update, { returning = "*" })
end

--------------------------------------------------------------------------------
-- Soft delete
--------------------------------------------------------------------------------
function DomainQueries.deleteDomain(uuid)
    local domain = DomainModel:find({ uuid = uuid })
    if not domain then return nil end
    return domain:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

--------------------------------------------------------------------------------
-- All active domains for a namespace (used by the sync export + bulk refresh)
--------------------------------------------------------------------------------
function DomainQueries.getAllForNamespace(namespace_id)
    return db.query([[
        SELECT * FROM domains
        WHERE namespace_id = ? AND deleted_at IS NULL
        ORDER BY domain_name ASC
    ]], namespace_id)
end

--------------------------------------------------------------------------------
-- Aggregate stats for the dashboard header
--------------------------------------------------------------------------------
function DomainQueries.getStats(namespace_id)
    local result = db.query([[
        SELECT
            COUNT(*) AS total_domains,
            COUNT(*) FILTER (WHERE status = 'expired') AS expired,
            COUNT(*) FILTER (WHERE status = 'expiring_soon') AS expiring_soon,
            COUNT(*) FILTER (WHERE status = 'error') AS errored,
            COUNT(*) FILTER (
                WHERE registration_expires_at IS NOT NULL
                  AND registration_expires_at <= NOW() + INTERVAL '30 days'
            ) AS reg_expiring_30d,
            COUNT(*) FILTER (
                WHERE ssl_expires_at IS NOT NULL
                  AND ssl_expires_at <= NOW() + INTERVAL '30 days'
            ) AS ssl_expiring_30d
        FROM domains
        WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id)
    return result and result[1] or {}
end

return DomainQueries
