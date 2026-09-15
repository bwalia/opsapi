--[[
    Field Service — customer site queries. Everything namespace-scoped.
    A site belongs to a customer; jobs/requests point at it.
]]

local db = require("lapis.db")
local FsSiteModel = require("models.FsSiteModel")
local Common = require("queries.FieldServiceCommon")

local nilify, nullable, arr = Common.nilify, Common.nullable, Common.arr

local SiteQueries = {}

local SITE_SELECT = [[
    SELECT s.*, c.uuid AS customer_uuid,
        COALESCE(NULLIF(TRIM(COALESCE(c.first_name,'') || ' ' || COALESCE(c.last_name,'')), ''), c.email) AS customer_name,
        (SELECT COUNT(*) FROM fs_jobs j WHERE j.site_id = s.id AND j.deleted_at IS NULL) AS job_count
    FROM fs_sites s
    LEFT JOIN customers c ON c.id = s.customer_id
]]

local ADDRESS_FIELDS = {
    "name", "address_line1", "address_line2", "city", "county", "postal_code", "country",
    "contact_name", "contact_phone", "access_notes",
}

local function shape_site(s)
    local out = {
        uuid = s.uuid,
        customer_uuid = s.customer_uuid,
        customer_name = s.customer_name,
        job_count = tonumber(s.job_count) or 0,
        created_at = s.created_at,
        updated_at = s.updated_at,
    }
    for _, f in ipairs(ADDRESS_FIELDS) do out[f] = s[f] end
    -- One-line address for pickers / display.
    local parts = {}
    for _, f in ipairs({ "address_line1", "city", "postal_code" }) do
        if s[f] and s[f] ~= "" then table.insert(parts, s[f]) end
    end
    out.address = table.concat(parts, ", ")
    return out
end

function SiteQueries.listSites(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where = { "s.namespace_id = ?", "s.deleted_at IS NULL" }
    local values = { namespace_id }

    if nilify(params.customer_uuid) then
        table.insert(where, "c.uuid = ?")
        table.insert(values, tostring(params.customer_uuid))
    end
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        table.insert(where, "(s.name ILIKE ? OR s.address_line1 ILIKE ? OR s.city ILIKE ? OR s.postal_code ILIKE ?)")
        for _ = 1, 4 do table.insert(values, term) end
    end
    local where_sql = table.concat(where, " AND ")

    local count = db.query([[
        SELECT COUNT(*) AS total FROM fs_sites s LEFT JOIN customers c ON c.id = s.customer_id
        WHERE ]] .. where_sql, unpack(values))

    local page_values = { unpack(values) }
    table.insert(page_values, per_page)
    table.insert(page_values, offset)
    local rows = db.query(SITE_SELECT .. " WHERE " .. where_sql .. " ORDER BY s.name ASC LIMIT ? OFFSET ?",
        unpack(page_values))

    local items = {}
    for _, s in ipairs(rows or {}) do table.insert(items, shape_site(s)) end
    return { items = arr(items), meta = Common.meta(count[1].total, page, per_page) }
end

function SiteQueries.getSite(namespace_id, uuid)
    local rows = db.query(SITE_SELECT .. " WHERE s.uuid = ? AND s.namespace_id = ? AND s.deleted_at IS NULL LIMIT 1",
        tostring(uuid), namespace_id)
    return rows and rows[1] and shape_site(rows[1]) or nil
end

function SiteQueries.createSite(namespace_id, actor_uuid, data)
    if not nilify(data.name) then return nil, "Site name is required" end

    local fields = {
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        created_by_uuid = nilify(actor_uuid),
    }
    for _, f in ipairs(ADDRESS_FIELDS) do fields[f] = nilify(data[f]) end

    if nilify(data.customer_uuid) then
        fields.customer_id = Common.resolve_id("customers", namespace_id, data.customer_uuid)
        if not fields.customer_id then return nil, "Customer not found" end
    else
        return nil, "A site must belong to a customer"
    end

    local site = FsSiteModel:create(fields)
    return SiteQueries.getSite(namespace_id, site.uuid)
end

function SiteQueries.updateSite(namespace_id, uuid, data)
    local id = Common.resolve_id("fs_sites", namespace_id, uuid)
    if not id then return nil, "Site not found" end

    local update = {}
    for _, f in ipairs(ADDRESS_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if update.name == db.NULL then return nil, "Site name cannot be empty" end
    if data.customer_uuid ~= nil and nilify(data.customer_uuid) then
        update.customer_id = Common.resolve_id("customers", namespace_id, data.customer_uuid)
        if not update.customer_id then return nil, "Customer not found" end
    end
    if next(update) == nil then return nil, "No valid fields to update" end

    FsSiteModel:find(id):update(update)
    return SiteQueries.getSite(namespace_id, uuid)
end

function SiteQueries.deleteSite(namespace_id, uuid)
    local id = Common.resolve_id("fs_sites", namespace_id, uuid)
    if not id then return nil, "Site not found" end
    db.query("UPDATE fs_sites SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", id)
    return true
end

return SiteQueries
