--[[
    Render Template Queries
    =======================
    Namespace-scoped CRUD for the render_templates library. Soft-deleted; slug is
    unique per (namespace, template_type) among live rows. Exactly one row per
    (namespace, type) may be is_default.
]]

local RenderTemplateModel = require "models.RenderTemplateModel"
local TemplateRender = require "helper.template-render"
local Global = require "helper.global"
local db = require("lapis.db")

local RenderTemplateQueries = {}

local VALID_TYPES = { cms_page = true, domain_wslproxy = true }
RenderTemplateQueries.VALID_TYPES = VALID_TYPES

local function slugify(text)
    if not text or text == "" then return "" end
    return (text:lower():gsub("%s+", "-"):gsub("[^%w%-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end
RenderTemplateQueries.slugify = slugify

--- Unique slug within (namespace, type) among live rows; appends -2, -3, …
local function uniqueSlug(namespace_id, ttype, base, ignore_id)
    base = (base and base ~= "") and base or "template"
    local slug, n = base, 1
    while true do
        local rows = db.query([[
            SELECT id FROM render_templates
            WHERE namespace_id = ? AND template_type = ? AND slug = ? AND deleted_at IS NULL LIMIT 1
        ]], namespace_id, ttype, slug)
        local clash = rows and rows[1]
        if not clash or (ignore_id and tonumber(clash.id) == tonumber(ignore_id)) then return slug end
        n = n + 1
        slug = base .. "-" .. n
    end
end

local function findScoped(namespace_id, uuid)
    local row = RenderTemplateModel:find({ uuid = uuid, namespace_id = namespace_id })
    if not row or row.deleted_at then return nil end
    return row
end
RenderTemplateQueries.findScoped = findScoped

--- Clear is_default on every other live template of the same (namespace, type).
local function clearOtherDefaults(namespace_id, ttype, keep_id)
    db.query([[
        UPDATE render_templates SET is_default = FALSE, updated_at = NOW()
        WHERE namespace_id = ? AND template_type = ? AND is_default = TRUE
          AND deleted_at IS NULL AND id <> ?
    ]], namespace_id, ttype, keep_id or -1)
end

--- Attach the parsed placeholder list to a row (for the editor).
local function withMeta(row)
    if not row then return row end
    row.placeholders = TemplateRender.placeholders(row.content or "")
    return row
end
RenderTemplateQueries.withMeta = withMeta

function RenderTemplateQueries.create(namespace_id, params)
    local ttype = VALID_TYPES[params.template_type] and params.template_type or "cms_page"
    local base = slugify((params.slug and params.slug ~= "") and params.slug or params.name)
    local row = RenderTemplateModel:create({
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        name = params.name,
        slug = uniqueSlug(namespace_id, ttype, base),
        template_type = ttype,
        content = params.content,
        sample_data = params.sample_data,
        description = params.description,
        is_default = params.is_default and true or false,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
    if row.is_default then clearOtherDefaults(namespace_id, ttype, row.id) end
    return withMeta(row)
end

--- List templates in a namespace, optionally filtered by type. `search` optional.
function RenderTemplateQueries.list(namespace_id, params)
    params = params or {}
    local where = { "namespace_id = ?", "deleted_at IS NULL" }
    local values = { namespace_id }
    if params.template_type and params.template_type ~= "" then
        table.insert(where, "template_type = ?"); table.insert(values, params.template_type)
    end
    if params.search and params.search ~= "" then
        table.insert(where, "(name ILIKE ? OR slug ILIKE ?)")
        local p = "%" .. params.search .. "%"
        table.insert(values, p); table.insert(values, p)
    end
    local rows = db.query([[
        SELECT * FROM render_templates
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY template_type ASC, is_default DESC, name ASC
    ]], table.unpack(values)) or {}
    for _, r in ipairs(rows) do withMeta(r) end
    return rows
end

function RenderTemplateQueries.getByUuid(namespace_id, uuid)
    return withMeta(findScoped(namespace_id, uuid))
end

--- Default template for a (namespace, type), or nil.
function RenderTemplateQueries.getDefault(namespace_id, ttype)
    local rows = db.query([[
        SELECT * FROM render_templates
        WHERE namespace_id = ? AND template_type = ? AND is_default = TRUE AND deleted_at IS NULL
        LIMIT 1
    ]], namespace_id, ttype)
    return rows and rows[1] and withMeta(rows[1]) or nil
end

function RenderTemplateQueries.update(namespace_id, uuid, params)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    local fields = { updated_at = db.raw("NOW()") }
    for _, k in ipairs({ "name", "content", "sample_data", "description" }) do
        if params[k] ~= nil then fields[k] = params[k] end
    end
    if params.slug ~= nil and params.slug ~= "" then
        fields.slug = uniqueSlug(namespace_id, row.template_type, slugify(params.slug), row.id)
    end
    if params.is_default ~= nil then fields.is_default = params.is_default and true or false end
    row:update(fields)
    if fields.is_default == true then clearOtherDefaults(namespace_id, row.template_type, row.id) end
    return withMeta(findScoped(namespace_id, uuid))
end

function RenderTemplateQueries.softDelete(namespace_id, uuid)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    row:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return row
end

--- Render the (namespace, type) template identified by `slug` with `data`.
--- Returns the rendered string, or nil when there's no template to apply
--- (slug empty/"default"/unknown) so the caller can fall back to raw content.
function RenderTemplateQueries.renderBySlug(namespace_id, ttype, slug, data)
    if not slug or slug == "" or slug == "default" then return nil end
    local rows = db.query([[
        SELECT content FROM render_templates
        WHERE namespace_id = ? AND template_type = ? AND slug = ? AND deleted_at IS NULL
        LIMIT 1
    ]], namespace_id, ttype, slug)
    local row = rows and rows[1]
    if not row then return nil end
    return TemplateRender.render(row.content or "", data or {})
end

--- Render a template's content with the given data (for the preview endpoint).
--- Falls back to the stored sample_data when no data is supplied.
function RenderTemplateQueries.preview(namespace_id, uuid, data)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    if data == nil and row.sample_data and row.sample_data ~= "" then
        local ok, decoded = pcall(require("cjson").decode, row.sample_data)
        if ok and type(decoded) == "table" then data = decoded end
    end
    return {
        rendered = TemplateRender.render(row.content or "", data or {}),
        placeholders = TemplateRender.placeholders(row.content or ""),
    }
end

return RenderTemplateQueries
