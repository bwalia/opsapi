--[[
    CMS Page (Static Site Page) Queries
    ===================================
    Namespace-scoped CRUD + public reads for cms_pages.
    - Soft-deleted; slug unique per namespace among live rows.
    - Optional parent (nesting) resolved by uuid.
    - Publishing stamps published_at once (first time it goes live).
]]

local CmsPageModel = require "models.CmsPageModel"
local Global = require "helper.global"
local db = require("lapis.db")

local CmsPageQueries = {}

local function slugify(text)
    if not text or text == "" then return "" end
    return (text:lower():gsub("%s+", "-"):gsub("[^%w%-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end
CmsPageQueries.slugify = slugify

local function uniqueSlug(namespace_id, base, ignore_id)
    base = (base and base ~= "") and base or "page"
    local slug = base
    local n = 1
    while true do
        local rows = db.query(
            "SELECT id FROM cms_pages WHERE namespace_id = ? AND slug = ? AND deleted_at IS NULL LIMIT 1",
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
    local row = CmsPageModel:find({ uuid = uuid, namespace_id = namespace_id })
    if not row or row.deleted_at then return nil end
    return row
end
CmsPageQueries.findScoped = findScoped

local function resolveParentId(namespace_id, parent_uuid)
    if not parent_uuid or parent_uuid == "" then return nil end
    local p = findScoped(namespace_id, parent_uuid)
    return p and p.id or nil
end

function CmsPageQueries.create(namespace_id, params)
    local base = slugify((params.slug and params.slug ~= "") and params.slug or params.title)
    local status = params.status or "draft"
    local insert = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        -- Nullable FK: explicit NULL when unset (column has a DEFAULT 0 from
        -- lapis types.integer, which would violate the self-parent FK).
        parent_id = resolveParentId(namespace_id, params.parent_uuid) or db.NULL,
        title = params.title,
        slug = uniqueSlug(namespace_id, base),
        excerpt = params.excerpt,
        content_html = params.content_html,
        content_json = params.content_json,
        featured_image_url = params.featured_image_url,
        status = status,
        template = params.template or "default",
        menu_order = tonumber(params.menu_order) or 0,
        show_in_nav = params.show_in_nav and true or false,
        author_uuid = params.author_uuid,
        seo_title = params.seo_title,
        seo_description = params.seo_description,
        seo_keywords = params.seo_keywords,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }
    if status == "published" then
        insert.published_at = db.raw("NOW()")
    end
    return CmsPageModel:create(insert, { returning = "*" })
end

function CmsPageQueries.list(namespace_id, params)
    params = params or {}
    local where = { "namespace_id = ?", "deleted_at IS NULL" }
    local values = { namespace_id }
    if params.status and params.status ~= "" then
        table.insert(where, "status = ?"); table.insert(values, params.status)
    end
    if params.search and params.search ~= "" then
        table.insert(where, "(title ILIKE ? OR slug ILIKE ?)")
        local pat = "%" .. params.search .. "%"
        table.insert(values, pat); table.insert(values, pat)
    end
    local rows = db.query([[
        SELECT * FROM cms_pages
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY menu_order ASC, title ASC
    ]], table.unpack(values))
    return rows or {}
end

function CmsPageQueries.getByUuid(namespace_id, uuid)
    return findScoped(namespace_id, uuid)
end

function CmsPageQueries.update(namespace_id, uuid, params)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end

    local fields = { updated_at = db.raw("NOW()") }
    for _, k in ipairs({ "title", "excerpt", "content_html", "content_json",
        "featured_image_url", "template", "seo_title", "seo_description", "seo_keywords" }) do
        if params[k] ~= nil then fields[k] = params[k] end
    end
    if params.slug ~= nil and params.slug ~= "" then
        fields.slug = uniqueSlug(namespace_id, slugify(params.slug), row.id)
    end
    if params.menu_order ~= nil then fields.menu_order = tonumber(params.menu_order) or 0 end
    if params.show_in_nav ~= nil then fields.show_in_nav = params.show_in_nav and true or false end
    if params.parent_uuid ~= nil then
        local pid = resolveParentId(namespace_id, params.parent_uuid)
        if pid == row.id then pid = nil end
        fields.parent_id = pid or db.NULL
    end
    if params.status ~= nil then
        fields.status = params.status
        if params.status == "published" and (row.published_at == nil or row.published_at == db.NULL) then
            fields.published_at = db.raw("NOW()")
        end
    end

    row:update(fields)
    return findScoped(namespace_id, uuid)
end

function CmsPageQueries.softDelete(namespace_id, uuid)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    row:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return row
end

-- ---------------------------------------------------------------------------
-- PUBLIC reads (published only)
-- ---------------------------------------------------------------------------

--- Published pages flagged for nav, ordered — for the public site menu.
function CmsPageQueries.listPublishedNav(namespace_id)
    local rows = db.query([[
        SELECT uuid, title, slug, menu_order, parent_id FROM cms_pages
        WHERE namespace_id = ? AND deleted_at IS NULL
          AND status = 'published' AND show_in_nav = TRUE
        ORDER BY menu_order ASC, title ASC
    ]], namespace_id)
    return rows or {}
end

--- All published pages (for a public sitemap/listing).
function CmsPageQueries.listPublished(namespace_id)
    local rows = db.query([[
        SELECT uuid, title, slug, excerpt, featured_image_url, published_at, updated_at
        FROM cms_pages
        WHERE namespace_id = ? AND deleted_at IS NULL AND status = 'published'
        ORDER BY menu_order ASC, title ASC
    ]], namespace_id)
    return rows or {}
end

--- A single published page by slug for the public site.
function CmsPageQueries.getPublishedBySlug(namespace_id, slug)
    local rows = db.query([[
        SELECT * FROM cms_pages
        WHERE namespace_id = ? AND slug = ? AND deleted_at IS NULL AND status = 'published'
        LIMIT 1
    ]], namespace_id, slug)
    return rows and rows[1] or nil
end

return CmsPageQueries
