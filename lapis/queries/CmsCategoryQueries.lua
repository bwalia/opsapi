--[[
    CMS Category Queries
    ====================
    Namespace-scoped CRUD for cms_categories (hierarchical blog categories).
    Soft-deleted; slug is unique per namespace among live rows.
]]

local CmsCategoryModel = require "models.CmsCategoryModel"
local Global = require "helper.global"
local db = require("lapis.db")

local CmsCategoryQueries = {}

local function slugify(text)
    if not text or text == "" then return "" end
    return (text:lower():gsub("%s+", "-"):gsub("[^%w%-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end
CmsCategoryQueries.slugify = slugify

--- Produce a slug unique among live rows in the namespace. Appends -2, -3, ...
--- `ignore_id` lets an update keep its own slug.
local function uniqueSlug(namespace_id, base, ignore_id)
    base = (base and base ~= "") and base or "category"
    local slug = base
    local n = 1
    while true do
        local rows = db.query(
            "SELECT id FROM cms_categories WHERE namespace_id = ? AND slug = ? AND deleted_at IS NULL LIMIT 1",
            namespace_id, slug)
        local clash = rows and rows[1]
        if not clash or (ignore_id and tonumber(clash.id) == tonumber(ignore_id)) then
            return slug
        end
        n = n + 1
        slug = base .. "-" .. n
    end
end

local function findScoped(namespace_id, uuid)
    local row = CmsCategoryModel:find({ uuid = uuid, namespace_id = namespace_id })
    if not row or row.deleted_at then return nil end
    return row
end
CmsCategoryQueries.findScoped = findScoped

--- Resolve a parent uuid to its internal id (scoped); nil if absent/invalid.
local function resolveParentId(namespace_id, parent_uuid)
    if not parent_uuid or parent_uuid == "" then return nil end
    local parent = findScoped(namespace_id, parent_uuid)
    return parent and parent.id or nil
end

function CmsCategoryQueries.create(namespace_id, params)
    local base = slugify(params.slug ~= "" and params.slug or params.name)
    local insert = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        name = params.name,
        slug = uniqueSlug(namespace_id, base),
        description = params.description,
        -- Nullable FK: pass an explicit NULL when unset (the column carries a
        -- DEFAULT 0 from lapis types.integer, which would break the FK).
        parent_id = resolveParentId(namespace_id, params.parent_uuid) or db.NULL,
        position = tonumber(params.position) or 0,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }
    return CmsCategoryModel:create(insert, { returning = "*" })
end

--- List categories in a namespace (with post counts). `search` optional.
function CmsCategoryQueries.list(namespace_id, params)
    params = params or {}
    local where = { "c.namespace_id = ?", "c.deleted_at IS NULL" }
    local values = { namespace_id }
    if params.search and params.search ~= "" then
        table.insert(where, "(c.name ILIKE ? OR c.slug ILIKE ?)")
        local p = "%" .. params.search .. "%"
        table.insert(values, p); table.insert(values, p)
    end
    local rows = db.query([[
        SELECT c.*, (
            SELECT COUNT(*) FROM cms_posts p
            WHERE p.category_id = c.id AND p.deleted_at IS NULL
        ) AS post_count
        FROM cms_categories c
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY c.position ASC, c.name ASC
    ]], table.unpack(values))
    return rows or {}
end

function CmsCategoryQueries.getByUuid(namespace_id, uuid)
    return findScoped(namespace_id, uuid)
end

function CmsCategoryQueries.update(namespace_id, uuid, params)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    local fields = { updated_at = db.raw("NOW()") }
    if params.name ~= nil then fields.name = params.name end
    if params.description ~= nil then fields.description = params.description end
    if params.position ~= nil then fields.position = tonumber(params.position) or 0 end
    if params.slug ~= nil and params.slug ~= "" then
        fields.slug = uniqueSlug(namespace_id, slugify(params.slug), row.id)
    end
    if params.parent_uuid ~= nil then
        local pid = resolveParentId(namespace_id, params.parent_uuid)
        -- guard against self-parenting
        if pid == row.id then pid = nil end
        fields.parent_id = pid or db.NULL
    end
    row:update(fields)
    return findScoped(namespace_id, uuid)
end

function CmsCategoryQueries.softDelete(namespace_id, uuid)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    row:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return row
end

return CmsCategoryQueries
