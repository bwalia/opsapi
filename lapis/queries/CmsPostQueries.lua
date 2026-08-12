--[[
    CMS Post (Blog Article) Queries
    ===============================
    Namespace-scoped CRUD + public catalogue reads for cms_posts.

    - Soft-deleted; slug unique per namespace among live rows.
    - Tags are a many-to-many via cms_post_tags; the route hands us tag *names*
      and we resolve/create them (CmsTagQueries.getOrCreateByName) then re-sync
      the join rows.
    - Publishing: moving to `published` stamps published_at once (first time).
]]

local CmsPostModel = require "models.CmsPostModel"
local CmsTagQueries = require "queries.CmsTagQueries"
local Global = require "helper.global"
local db = require("lapis.db")

local CmsPostQueries = {}

local function slugify(text)
    if not text or text == "" then return "" end
    return (text:lower():gsub("%s+", "-"):gsub("[^%w%-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end
CmsPostQueries.slugify = slugify

local function uniqueSlug(namespace_id, base, ignore_id)
    base = (base and base ~= "") and base or "post"
    local slug = base
    local n = 1
    while true do
        local rows = db.query(
            "SELECT id FROM cms_posts WHERE namespace_id = ? AND slug = ? AND deleted_at IS NULL LIMIT 1",
            namespace_id, slug)
        local clash = rows and rows[1]
        if not clash or (ignore_id and tonumber(clash.id) == tonumber(ignore_id)) then
            return slug
        end
        n = n + 1
        slug = base .. "-" .. n
    end
end

--- Rough reading time from rendered HTML: strip tags, count words, /200 wpm.
local function readingMinutes(html)
    if not html or html == "" then return 0 end
    local text = html:gsub("<[^>]->", " ")
    local words = 0
    for _ in text:gmatch("%S+") do words = words + 1 end
    local mins = math.floor(words / 200)
    return mins < 1 and 1 or mins
end

local function findScoped(namespace_id, uuid)
    local row = CmsPostModel:find({ uuid = uuid, namespace_id = namespace_id })
    if not row or row.deleted_at then return nil end
    return row
end
CmsPostQueries.findScoped = findScoped

--- Resolve a category uuid to internal id (scoped); nil clears the category.
local function resolveCategoryId(namespace_id, category_uuid)
    if category_uuid == nil or category_uuid == "" then return nil end
    local rows = db.query(
        "SELECT id FROM cms_categories WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL LIMIT 1",
        namespace_id, category_uuid)
    return rows and rows[1] and rows[1].id or nil
end

--- Fetch tag rows ({name, slug, uuid}) attached to a set of post ids.
--- Returns a map post_id -> array of tags.
local function tagsForPosts(post_ids)
    local map = {}
    for _, id in ipairs(post_ids) do map[id] = {} end
    if #post_ids == 0 then return map end
    local ph = {}
    for i = 1, #post_ids do ph[i] = "?" end
    local rows = db.query([[
        SELECT pt.post_id, t.uuid, t.name, t.slug
        FROM cms_post_tags pt
        JOIN cms_tags t ON t.id = pt.tag_id AND t.deleted_at IS NULL
        WHERE pt.post_id IN (]] .. table.concat(ph, ", ") .. [[)
        ORDER BY t.name ASC
    ]], table.unpack(post_ids)) or {}
    for _, r in ipairs(rows) do
        local bucket = map[r.post_id]
        if bucket then
            table.insert(bucket, { uuid = r.uuid, name = r.name, slug = r.slug })
        end
    end
    return map
end
CmsPostQueries.tagsForPosts = tagsForPosts

--- Attach hydrated tags[] (and category slug/name) to a list of post rows.
local function hydrate(namespace_id, posts)
    if #posts == 0 then return posts end
    local ids = {}
    for _, p in ipairs(posts) do ids[#ids + 1] = p.id end
    local tagMap = tagsForPosts(ids)

    -- Category lookup (one query for the referenced categories).
    local catRows = db.query([[
        SELECT id, uuid, name, slug FROM cms_categories
        WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id) or {}
    local catById = {}
    for _, c in ipairs(catRows) do catById[c.id] = c end

    for _, p in ipairs(posts) do
        p.tags = tagMap[p.id] or {}
        if p.category_id and catById[p.category_id] then
            local c = catById[p.category_id]
            p.category = { uuid = c.uuid, name = c.name, slug = c.slug }
        else
            p.category = nil
        end
    end
    return posts
end

--- Re-sync a post's tag join rows from an array of tag names.
local function syncTags(namespace_id, post_id, tag_names)
    if type(tag_names) ~= "table" then return end
    local wanted = {}       -- tag_id -> true
    for _, name in ipairs(tag_names) do
        local tag = CmsTagQueries.getOrCreateByName(namespace_id, name)
        if tag then wanted[tag.id] = true end
    end

    -- Existing join rows.
    local existing = db.query("SELECT tag_id FROM cms_post_tags WHERE post_id = ?", post_id) or {}
    local have = {}
    for _, r in ipairs(existing) do have[r.tag_id] = true end

    -- Insert missing.
    for tag_id in pairs(wanted) do
        if not have[tag_id] then
            db.query("INSERT INTO cms_post_tags (post_id, tag_id, created_at) VALUES (?, ?, NOW()) " ..
                "ON CONFLICT (post_id, tag_id) DO NOTHING", post_id, tag_id)
        end
    end
    -- Remove stale.
    for tag_id in pairs(have) do
        if not wanted[tag_id] then
            db.query("DELETE FROM cms_post_tags WHERE post_id = ? AND tag_id = ?", post_id, tag_id)
        end
    end
end
CmsPostQueries.syncTags = syncTags

function CmsPostQueries.create(namespace_id, params)
    local base = slugify((params.slug and params.slug ~= "") and params.slug or params.title)
    local status = params.status or "draft"
    local insert = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        -- Nullable FK: explicit NULL when unset (column has a DEFAULT 0 from
        -- lapis types.integer, which would violate the category FK).
        category_id = resolveCategoryId(namespace_id, params.category_uuid) or db.NULL,
        title = params.title,
        slug = uniqueSlug(namespace_id, base),
        excerpt = params.excerpt,
        content_html = params.content_html,
        content_json = params.content_json,
        featured_image_url = params.featured_image_url,
        status = status,
        visibility = params.visibility or "public",
        is_featured = params.is_featured and true or false,
        author_uuid = params.author_uuid,
        author_name = params.author_name,
        seo_title = params.seo_title,
        seo_description = params.seo_description,
        seo_keywords = params.seo_keywords,
        reading_minutes = readingMinutes(params.content_html),
        view_count = 0,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }
    if status == "published" then
        insert.published_at = db.raw("NOW()")
    elseif status == "scheduled" and params.scheduled_at then
        insert.scheduled_at = params.scheduled_at
    end

    local post = CmsPostModel:create(insert, { returning = "*" })
    if params.tags ~= nil then syncTags(namespace_id, post.id, params.tags) end
    return hydrate(namespace_id, { post })[1]
end

--- List posts in a namespace with filters + pagination. Admin view (all
--- statuses unless filtered).
function CmsPostQueries.list(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 20
    local offset = (page - 1) * perPage

    local where = { "p.namespace_id = ?", "p.deleted_at IS NULL" }
    local values = { namespace_id }

    if params.status and params.status ~= "" then
        table.insert(where, "p.status = ?"); table.insert(values, params.status)
    end
    if params.category_uuid and params.category_uuid ~= "" then
        table.insert(where, "p.category_id = (SELECT id FROM cms_categories WHERE namespace_id = ? AND uuid = ? LIMIT 1)")
        table.insert(values, namespace_id); table.insert(values, params.category_uuid)
    end
    if params.is_featured ~= nil then
        table.insert(where, "p.is_featured = ?"); table.insert(values, params.is_featured and true or false)
    end
    if params.tag and params.tag ~= "" then
        table.insert(where, [[p.id IN (
            SELECT pt.post_id FROM cms_post_tags pt
            JOIN cms_tags t ON t.id = pt.tag_id
            WHERE t.namespace_id = ? AND t.slug = ?
        )]])
        table.insert(values, namespace_id); table.insert(values, params.tag)
    end
    if params.search and params.search ~= "" then
        table.insert(where, "(p.title ILIKE ? OR p.excerpt ILIKE ?)")
        local pat = "%" .. params.search .. "%"
        table.insert(values, pat); table.insert(values, pat)
    end

    local whereSql = table.concat(where, " AND ")

    local countRows = db.query("SELECT COUNT(*) AS n FROM cms_posts p WHERE " .. whereSql, table.unpack(values))
    local total = countRows and countRows[1] and tonumber(countRows[1].n) or 0

    local listValues = {}
    for _, v in ipairs(values) do listValues[#listValues + 1] = v end
    listValues[#listValues + 1] = perPage
    listValues[#listValues + 1] = offset

    -- NULLS LAST so drafts (no published_at) sort by created_at fallback.
    local rows = db.query([[
        SELECT * FROM cms_posts p
        WHERE ]] .. whereSql .. [[
        ORDER BY COALESCE(p.published_at, p.created_at) DESC
        LIMIT ? OFFSET ?
    ]], table.unpack(listValues)) or {}

    hydrate(namespace_id, rows)
    return {
        data = rows,
        meta = { total = total, page = page, perPage = perPage,
                 totalPages = math.ceil(total / perPage) }
    }
end

function CmsPostQueries.getByUuid(namespace_id, uuid)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    return hydrate(namespace_id, { row })[1]
end

function CmsPostQueries.update(namespace_id, uuid, params)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end

    local fields = { updated_at = db.raw("NOW()") }
    for _, k in ipairs({ "title", "excerpt", "content_html", "content_json",
        "featured_image_url", "author_name", "seo_title", "seo_description", "seo_keywords" }) do
        if params[k] ~= nil then fields[k] = params[k] end
    end
    if params.slug ~= nil and params.slug ~= "" then
        fields.slug = uniqueSlug(namespace_id, slugify(params.slug), row.id)
    end
    if params.visibility ~= nil then fields.visibility = params.visibility end
    if params.is_featured ~= nil then fields.is_featured = params.is_featured and true or false end
    if params.category_uuid ~= nil then
        fields.category_id = resolveCategoryId(namespace_id, params.category_uuid) or db.NULL
    end
    if params.content_html ~= nil then
        fields.reading_minutes = readingMinutes(params.content_html)
    end
    if params.status ~= nil then
        fields.status = params.status
        -- Stamp published_at the first time it goes live; keep it thereafter.
        if params.status == "published" and (row.published_at == nil or row.published_at == db.NULL) then
            fields.published_at = db.raw("NOW()")
        end
        if params.status == "scheduled" and params.scheduled_at then
            fields.scheduled_at = params.scheduled_at
        end
    end

    row:update(fields)
    if params.tags ~= nil then syncTags(namespace_id, row.id, params.tags) end
    return CmsPostQueries.getByUuid(namespace_id, uuid)
end

function CmsPostQueries.softDelete(namespace_id, uuid)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    row:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return row
end

-- ---------------------------------------------------------------------------
-- PUBLIC catalogue reads (published only)
-- ---------------------------------------------------------------------------

--- Published posts for the public site (namespace-scoped, paginated).
function CmsPostQueries.listPublished(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 12
    local offset = (page - 1) * perPage

    local where = { "p.namespace_id = ?", "p.deleted_at IS NULL",
        "p.status = 'published'", "p.visibility = 'public'" }
    local values = { namespace_id }

    if params.category and params.category ~= "" then
        table.insert(where, "p.category_id = (SELECT id FROM cms_categories WHERE namespace_id = ? AND slug = ? LIMIT 1)")
        table.insert(values, namespace_id); table.insert(values, params.category)
    end
    if params.tag and params.tag ~= "" then
        table.insert(where, [[p.id IN (
            SELECT pt.post_id FROM cms_post_tags pt
            JOIN cms_tags t ON t.id = pt.tag_id
            WHERE t.namespace_id = ? AND t.slug = ?
        )]])
        table.insert(values, namespace_id); table.insert(values, params.tag)
    end
    if params.search and params.search ~= "" then
        table.insert(where, "(p.title ILIKE ? OR p.excerpt ILIKE ?)")
        local pat = "%" .. params.search .. "%"
        table.insert(values, pat); table.insert(values, pat)
    end

    local whereSql = table.concat(where, " AND ")
    local countRows = db.query("SELECT COUNT(*) AS n FROM cms_posts p WHERE " .. whereSql, table.unpack(values))
    local total = countRows and countRows[1] and tonumber(countRows[1].n) or 0

    local listValues = {}
    for _, v in ipairs(values) do listValues[#listValues + 1] = v end
    listValues[#listValues + 1] = perPage
    listValues[#listValues + 1] = offset

    local rows = db.query([[
        SELECT * FROM cms_posts p
        WHERE ]] .. whereSql .. [[
        ORDER BY p.published_at DESC NULLS LAST
        LIMIT ? OFFSET ?
    ]], table.unpack(listValues)) or {}

    hydrate(namespace_id, rows)
    return {
        data = rows,
        meta = { total = total, page = page, perPage = perPage,
                 totalPages = math.ceil(total / perPage) }
    }
end

--- A single published post by slug for the public site; increments view_count.
function CmsPostQueries.getPublishedBySlug(namespace_id, slug)
    local rows = db.query([[
        SELECT * FROM cms_posts
        WHERE namespace_id = ? AND slug = ? AND deleted_at IS NULL
          AND status = 'published' AND visibility = 'public'
        LIMIT 1
    ]], namespace_id, slug)
    local post = rows and rows[1]
    if not post then return nil end
    db.query("UPDATE cms_posts SET view_count = view_count + 1 WHERE id = ?", post.id)
    post.view_count = (tonumber(post.view_count) or 0) + 1
    return hydrate(namespace_id, { post })[1]
end

return CmsPostQueries
