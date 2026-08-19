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
local WebsiteRevalidate = require "lib.website-revalidate"

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

--- Fetch category rows ({name, slug, uuid}) attached to a set of post ids via
--- the cms_post_categories join. Returns a map post_id -> array of categories.
local function categoriesForPosts(post_ids)
    local map = {}
    for _, id in ipairs(post_ids) do map[id] = {} end
    if #post_ids == 0 then return map end
    local ph = {}
    for i = 1, #post_ids do ph[i] = "?" end
    local rows = db.query([[
        SELECT pc.post_id, c.uuid, c.name, c.slug
        FROM cms_post_categories pc
        JOIN cms_categories c ON c.id = pc.category_id AND c.deleted_at IS NULL
        WHERE pc.post_id IN (]] .. table.concat(ph, ", ") .. [[)
        ORDER BY c.name ASC
    ]], table.unpack(post_ids)) or {}
    for _, r in ipairs(rows) do
        local bucket = map[r.post_id]
        if bucket then
            table.insert(bucket, { uuid = r.uuid, name = r.name, slug = r.slug })
        end
    end
    return map
end
CmsPostQueries.categoriesForPosts = categoriesForPosts

--- Attach hydrated tags[], categories[] (and the primary category) to post rows.
local function hydrate(namespace_id, posts)
    if #posts == 0 then return posts end
    local ids = {}
    for _, p in ipairs(posts) do ids[#ids + 1] = p.id end
    local tagMap = tagsForPosts(ids)
    local catMap = categoriesForPosts(ids)

    -- Category lookup (one query for the referenced categories).
    local catRows = db.query([[
        SELECT id, uuid, name, slug FROM cms_categories
        WHERE namespace_id = ? AND deleted_at IS NULL
    ]], namespace_id) or {}
    local catById = {}
    for _, c in ipairs(catRows) do catById[c.id] = c end

    for _, p in ipairs(posts) do
        p.tags = tagMap[p.id] or {}
        -- Full set of categories (many-to-many).
        p.categories = catMap[p.id] or {}
        -- Primary category kept for backward compatibility (category_id FK).
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

--- Re-sync a post's category join rows from an array of category uuids (scoped).
--- Categories must already exist in the namespace — unlike tags, we never
--- auto-create them here. Duplicates and unknown/foreign uuids are ignored.
-- Returns the resolved primary category_id (first valid uuid), or nil.
local function syncCategories(namespace_id, post_id, category_uuids)
    if type(category_uuids) ~= "table" then return nil end
    local wanted = {}       -- category_id -> true
    local ordered = {}      -- resolved ids in input order (to pick a primary)
    for _, uuid in ipairs(category_uuids) do
        local cid = resolveCategoryId(namespace_id, uuid)
        if cid and not wanted[cid] then
            wanted[cid] = true
            ordered[#ordered + 1] = cid
        end
    end

    -- Existing join rows.
    local existing = db.query("SELECT category_id FROM cms_post_categories WHERE post_id = ?", post_id) or {}
    local have = {}
    for _, r in ipairs(existing) do have[r.category_id] = true end

    -- Insert missing.
    for cid in pairs(wanted) do
        if not have[cid] then
            db.query("INSERT INTO cms_post_categories (post_id, category_id, created_at) VALUES (?, ?, NOW()) " ..
                "ON CONFLICT (post_id, category_id) DO NOTHING", post_id, cid)
        end
    end
    -- Remove stale.
    for cid in pairs(have) do
        if not wanted[cid] then
            db.query("DELETE FROM cms_post_categories WHERE post_id = ? AND category_id = ?", post_id, cid)
        end
    end

    return ordered[1]
end
CmsPostQueries.syncCategories = syncCategories

--- Normalise category inputs: `category_uuids` (array) is authoritative when
--- present; otherwise fall back to the legacy single `category_uuid`. Returns
--- an array (possibly empty) or nil when neither field was supplied (caller
--- then leaves categories untouched).
local function normaliseCategoryUuids(params)
    if type(params.category_uuids) == "table" then return params.category_uuids end
    if params.category_uuid ~= nil then
        return (params.category_uuid ~= "") and { params.category_uuid } or {}
    end
    return nil
end

function CmsPostQueries.create(namespace_id, params)
    local base = slugify((params.slug and params.slug ~= "") and params.slug or params.title)
    local status = params.status or "draft"

    -- Multi-category: category_uuids (array) is authoritative; category_uuid
    -- (single, legacy) is treated as a one-element list. The primary category_id
    -- FK is the first resolvable uuid (kept for backward compatibility); the full
    -- set is written to the join by syncCategories after the post row exists.
    local category_uuids = normaliseCategoryUuids(params)
    local primary_category_id
    if category_uuids then
        for _, uuid in ipairs(category_uuids) do
            local cid = resolveCategoryId(namespace_id, uuid)
            if cid then primary_category_id = cid; break end
        end
    end

    local insert = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        -- Nullable FK: explicit NULL when unset (column has a DEFAULT 0 from
        -- lapis types.integer, which would violate the category FK).
        category_id = primary_category_id or db.NULL,
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
    if category_uuids then syncCategories(namespace_id, post.id, category_uuids) end
    if params.tags ~= nil then syncTags(namespace_id, post.id, params.tags) end
    WebsiteRevalidate.notify("cms_post.created", namespace_id)
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
        -- Match via the many-to-many join so a post shows under any of its
        -- categories (the backfilled join includes each post's primary category).
        table.insert(where, [[p.id IN (
            SELECT pc.post_id FROM cms_post_categories pc
            JOIN cms_categories c ON c.id = pc.category_id
            WHERE c.namespace_id = ? AND c.uuid = ?
        )]])
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
    -- Categories are synced to the join after the main update (which also sets
    -- the primary category_id); nil = neither field supplied, leave untouched.
    local category_uuids = normaliseCategoryUuids(params)
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
    if category_uuids then
        local primary = syncCategories(namespace_id, row.id, category_uuids)
        row:update({ category_id = primary or db.NULL, updated_at = db.raw("NOW()") })
    end
    if params.tags ~= nil then syncTags(namespace_id, row.id, params.tags) end
    WebsiteRevalidate.notify("cms_post.updated", namespace_id)
    return CmsPostQueries.getByUuid(namespace_id, uuid)
end

function CmsPostQueries.softDelete(namespace_id, uuid)
    local row = findScoped(namespace_id, uuid)
    if not row then return nil end
    row:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    WebsiteRevalidate.notify("cms_post.deleted", namespace_id)
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
        -- Match via the many-to-many join (by category slug) so a post is served
        -- under any of its categories, not only its primary one.
        table.insert(where, [[p.id IN (
            SELECT pc.post_id FROM cms_post_categories pc
            JOIN cms_categories c ON c.id = pc.category_id
            WHERE c.namespace_id = ? AND c.slug = ?
        )]])
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
