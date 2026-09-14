--[[
    Field Service — asset (equipment) queries
    =========================================

    The units installed at a customer site (the AC / fridge a complaint is raised
    against). Namespace-scoped; account + site are resolved from their uuids and
    re-checked against the tenant. Service history (jobs against an asset) is
    added once fs_jobs links to assets (Phase 2/3).
]]

local db = require("lapis.db")
local cjson = require("cjson")
local FsAssetModel = require("models.FsAssetModel")
local Common = require("queries.FieldServiceCommon")

local nilify, nullable, to_number, arr = Common.nilify, Common.nullable, Common.to_number, Common.arr

local AssetQueries = {}

local STATUSES = { active = true, inactive = true, decommissioned = true }

local ASSET_SELECT = [[
    SELECT a.*, acc.uuid AS account_uuid, acc.name AS account_name,
        s.uuid AS site_uuid, s.name AS site_name
    FROM fs_assets a
    LEFT JOIN crm_accounts acc ON acc.id = a.account_id
    LEFT JOIN fs_sites s ON s.id = a.site_id
]]

local function shape_asset(a)
    return {
        uuid = a.uuid,
        name = a.name,
        asset_tag = a.asset_tag,
        serial_number = a.serial_number,
        category = a.category,
        manufacturer = a.manufacturer,
        model = a.model,
        location_detail = a.location_detail,
        installed_at = a.installed_at,
        warranty_expires_at = a.warranty_expires_at,
        status = a.status,
        notes = a.notes,
        account_uuid = a.account_uuid,
        account_name = a.account_name,
        site_uuid = a.site_uuid,
        site_name = a.site_name,
        metadata = Common.decode(a.metadata, {}),
        created_at = a.created_at,
        updated_at = a.updated_at,
    }
end

function AssetQueries.listAssets(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where = { "a.namespace_id = ?", "a.deleted_at IS NULL" }
    local values = { namespace_id }

    if nilify(params.account_uuid) then
        table.insert(where, "acc.uuid = ?")
        table.insert(values, tostring(params.account_uuid))
    end
    if nilify(params.site_uuid) then
        table.insert(where, "s.uuid = ?")
        table.insert(values, tostring(params.site_uuid))
    end
    if nilify(params.status) and STATUSES[tostring(params.status)] then
        table.insert(where, "a.status = ?")
        table.insert(values, tostring(params.status))
    end
    if nilify(params.category) then
        table.insert(where, "a.category = ?")
        table.insert(values, tostring(params.category))
    end
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        table.insert(where,
            "(a.name ILIKE ? OR a.asset_tag ILIKE ? OR a.serial_number ILIKE ? OR a.model ILIKE ?)")
        for _ = 1, 4 do table.insert(values, term) end
    end
    local where_sql = table.concat(where, " AND ")

    local count = db.query([[
        SELECT COUNT(*) AS total FROM fs_assets a
        LEFT JOIN crm_accounts acc ON acc.id = a.account_id
        LEFT JOIN fs_sites s ON s.id = a.site_id
        WHERE ]] .. where_sql, unpack(values))

    local page_values = { unpack(values) }
    table.insert(page_values, per_page)
    table.insert(page_values, offset)
    local rows = db.query(ASSET_SELECT .. " WHERE " .. where_sql .. " ORDER BY a.name ASC LIMIT ? OFFSET ?",
        unpack(page_values))

    local items = {}
    for _, a in ipairs(rows or {}) do table.insert(items, shape_asset(a)) end
    return { items = arr(items), meta = Common.meta(count[1].total, page, per_page) }
end

function AssetQueries.getAsset(namespace_id, uuid)
    local rows = db.query(
        ASSET_SELECT .. " WHERE a.uuid = ? AND a.namespace_id = ? AND a.deleted_at IS NULL LIMIT 1",
        tostring(uuid), namespace_id)
    return rows and rows[1] and shape_asset(rows[1]) or nil
end

local TEXT_FIELDS = {
    "name", "asset_tag", "serial_number", "category", "manufacturer", "model",
    "location_detail", "notes",
}
local DATE_FIELDS = { "installed_at", "warranty_expires_at" }

-- Resolve the optional account + site uuids to ids, tenant-scoped.
-- Returns a partial fields table, or (nil, err) when a supplied uuid is invalid.
local function resolve_links(namespace_id, data, out, clearing)
    if data.account_uuid ~= nil then
        if nilify(data.account_uuid) then
            out.account_id = Common.resolve_id("crm_accounts", namespace_id, data.account_uuid)
            if not out.account_id then return nil, "Account not found" end
        elseif clearing then
            out.account_id = db.NULL
        end
    end
    if data.site_uuid ~= nil then
        if nilify(data.site_uuid) then
            out.site_id = Common.resolve_id("fs_sites", namespace_id, data.site_uuid)
            if not out.site_id then return nil, "Site not found" end
        elseif clearing then
            out.site_id = db.NULL
        end
    end
    return out
end

function AssetQueries.createAsset(namespace_id, actor_uuid, data)
    if not nilify(data.name) then return nil, "name is required" end
    if nilify(data.status) and not STATUSES[tostring(data.status)] then
        return nil, "Invalid status"
    end

    local fields = {
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        status = nilify(data.status) or "active",
        created_by_uuid = nilify(actor_uuid),
    }
    for _, f in ipairs(TEXT_FIELDS) do fields[f] = nilify(data[f]) end
    for _, f in ipairs(DATE_FIELDS) do fields[f] = nilify(data[f]) end
    if type(data.metadata) == "table" then fields.metadata = cjson.encode(data.metadata) end

    local ok, err = resolve_links(namespace_id, data, fields, false)
    if not ok then return nil, err end

    local asset = FsAssetModel:create(fields)
    return AssetQueries.getAsset(namespace_id, asset.uuid)
end

function AssetQueries.updateAsset(namespace_id, uuid, data)
    local id = Common.resolve_id("fs_assets", namespace_id, uuid)
    if not id then return nil, "Asset not found" end

    local update = {}
    for _, f in ipairs(TEXT_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if update.name == db.NULL then return nil, "name cannot be empty" end
    for _, f in ipairs(DATE_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if data.status ~= nil then
        if not STATUSES[tostring(data.status)] then return nil, "Invalid status" end
        update.status = tostring(data.status)
    end
    if type(data.metadata) == "table" then update.metadata = cjson.encode(data.metadata) end

    local ok, err = resolve_links(namespace_id, data, update, true)
    if not ok then return nil, err end
    if next(update) == nil then return nil, "No valid fields to update" end

    FsAssetModel:find(id):update(update)
    return AssetQueries.getAsset(namespace_id, uuid)
end

function AssetQueries.deleteAsset(namespace_id, uuid)
    local id = Common.resolve_id("fs_assets", namespace_id, uuid)
    if not id then return nil, "Asset not found" end
    db.query("UPDATE fs_assets SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", id)
    return true
end

return AssetQueries
