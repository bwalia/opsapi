--[[
    CMS Tag Queries
    ===============
    Namespace-scoped CRUD for cms_tags (flat blog tags). Soft-deleted; slug is
    unique per namespace among live rows. Includes getOrCreate for attaching
    tags to posts by name.
]]

local CmsTagModel = require "models.CmsTagModel"
local Global = require "helper.global"
local db = require("lapis.db")

local CmsTagQueries = {}

local function slugify(text)
    if not text or text == "" then return "" end
    return (text:lower():gsub("%s+", "-"):gsub("[^%w%-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end
CmsTagQueries.slugify = slugify

local function findScoped(namespace_id, uuid)
    local row = CmsTagModel:find({ uuid = uuid, namespace_id = namespace_id })
    if not row or row.deleted_at then return nil end
    return row
end
CmsTagQueries.findScoped = findScoped

--- Find a live tag row by slug within a namespace (internal use).
local function findLiveBySlug(namespace_id, slug)
    local rows = db.query(
        "SELECT * FROM cms_tags WHERE namespace_id = ? AND slug = ? AND deleted_at IS NULL LIMIT 1",
        namespace_id, slug)
    return rows and rows[1] or nil
end

function CmsTagQueries.create(namespace_id, params)
    local slug = slugify(params.slug ~= "" and params.slug or params.name)
    local existing = findLiveBySlug(namespace_id, slug)
    if existing then return existing end
    return CmsTagModel:create({
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        name = params.name,
        slug = slug,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

--- Return an existing live tag by name/slug, or create one. Also revives a
--- previously soft-deleted tag with the same slug. Used when saving a post's
--- tag list — the client sends tag *names*, we resolve them to ids.
function CmsTagQueries.getOrCreateByName(namespace_id, name)
    if not name or name == "" then return nil end
    local slug = slugify(name)
    if slug == "" then return nil end

    local live = findLiveBySlug(namespace_id, slug)
    if live then return live end

    -- Revive a soft-deleted tag with the same slug (keeps its uuid/id stable).
    local dead = db.query(
        "SELECT * FROM cms_tags WHERE namespace_id = ? AND slug = ? AND deleted_at IS NOT NULL LIMIT 1",
        namespace_id, slug)
    dead = dead and dead[1] or nil
    if dead then
        db.query("UPDATE cms_tags SET deleted_at = NULL, name = ?, updated_at = NOW() WHERE id = ?",
            name, dead.id)
        dead.deleted_at = nil
        dead.name = name
        return dead
    end

    return CmsTagModel:create({
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        name = name,
        slug = slug,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

--- List tags in a namespace (with post counts). `search` optional.
function CmsTagQueries.list(namespace_id, params)
    params = params or {}
    local where = { "t.namespace_id = ?", "t.deleted_at IS NULL" }
    local values = { namespace_id }
    if params.search and params.search ~= "" then
        table.insert(where, "(t.name ILIKE ? OR t.slug ILIKE ?)")
        local p = "%" .. params.search .. "%"
        table.insert(values, p); table.insert(values, p)
    end
    local rows = db.query([[
        SELECT t.*, (
            SELECT COUNT(*) FROM cms_post_tags pt
            JOIN cms_posts p ON p.id = pt.post_id AND p.deleted_at IS NULL
            WHERE pt.tag_id = t.id
        ) AS post_count
        FROM cms_tags t
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY t.name ASC
    ]], table.unpack(values))
    return rows or {}
end

function CmsTagQueries.getByUuid(namespace_id, uuid)
    return findScoped(namespace_id, uuid)
end

function CmsTagQueries.update(namespace_id, uuid, params)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    local fields = { updated_at = db.raw("NOW()") }
    if params.name ~= nil then fields.name = params.name end
    if params.slug ~= nil and params.slug ~= "" then
        local slug = slugify(params.slug)
        local clash = findLiveBySlug(namespace_id, slug)
        if clash and tonumber(clash.id) ~= tonumber(row.id) then
            return nil, "slug_taken"
        end
        fields.slug = slug
    end
    row:update(fields)
    return findScoped(namespace_id, uuid)
end

function CmsTagQueries.softDelete(namespace_id, uuid)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    row:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return row
end

return CmsTagQueries
