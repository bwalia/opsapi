-- luacheck: max line length 140
--[[
    Shop catalogue: categories, products, option groups/options/rules
    ===================================================================

    - Loads a product "bundle" (product + groups + options + rules + live
      availability) in the shape lib/shop-pricing.lua expects, and prices it.
    - Shapes public Product(list) / Product(full) (BUILD.prompt.md §3).
    - Admin CRUD: full product document with transactional replace of option
      groups/options/rules (upsert by code, deactivate missing), categories,
      and the bulk /import used by the seed script.
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local cjson = require("cjson")
local Global = require("helper.global")
local U = require("lib.shop-util")
local Pricing = require("lib.shop-pricing")
local Stock = require("queries.ShopStockQueries")

local ShopCatalogQueries = {}

local PRODUCT_TYPES = {
    workstation = true, server = true, gpu = true, cpu = true, memory = true, storage = true,
    networking = true, peripheral = true, software = true, service = true,
}
local PRICE_MODES = { fixed = true, configurable = true, quote_only = true }
local PRODUCT_STATUS = { draft = true, active = true, archived = true }
local RULE_KINDS = { requires = true, excludes = true, power = true, max_total = true, attr_match = true }
ShopCatalogQueries.RULE_KINDS = RULE_KINDS

local PRODUCT_COLS = [[
    p.id, p.uuid, p.namespace_id, p.category_id, p.sku, p.slug, p.name, p.brand, p.product_type, p.price_mode,
    p.short_description, p.description, p.specs::text AS specs, p.attributes::text AS attributes,
    p.images::text AS images, COALESCE(array_to_json(p.tags)::text, '[]') AS tags,
    p.base_price_minor, p.currency, p.vat_rate::float8 AS vat_rate, p.stock_qty, p.low_stock_threshold,
    p.lead_time_days, p.allow_backorder, p.price_verified, p.status, p.is_featured, p.sort_order,
    p.created_at, p.updated_at
]]
ShopCatalogQueries.PRODUCT_COLS = PRODUCT_COLS

-- ---------------------------------------------------------------------------
-- namespace
-- ---------------------------------------------------------------------------

function ShopCatalogQueries.namespaceBySlug(slug)
    if not U.nz(slug) then return nil end
    local rows = db.query("SELECT id, uuid, slug, name, domain FROM namespaces WHERE slug = ? AND status = 'active' LIMIT 1",
        slug)
    return rows[1]
end

-- ---------------------------------------------------------------------------
-- embeddings capability (per-worker cache)
-- ---------------------------------------------------------------------------

local _emb_cache = { at = 0, value = false }
function ShopCatalogQueries.hasEmbeddings()
    local now = ngx and ngx.now() or os.time()
    if now - _emb_cache.at < 300 then return _emb_cache.value end
    local ok, rows = pcall(db.query, [[
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'shop_products' AND column_name = 'embedding' LIMIT 1
    ]])
    _emb_cache.value = ok and rows and #rows > 0 or false
    _emb_cache.at = now
    return _emb_cache.value
end

-- ---------------------------------------------------------------------------
-- row normalisation
-- ---------------------------------------------------------------------------

local function norm_product(r)
    r.specs = U.dec(r.specs, {})
    r.attributes = U.dec(r.attributes, {})
    r.images = U.arr(U.dec(r.images, {}))
    r.tags = U.arr(U.dec(r.tags, {}))
    r.vat_rate = tonumber(r.vat_rate) or 0.2
    r.base_price_minor = tonumber(r.base_price_minor) or 0
    r.stock_qty = tonumber(r.stock_qty) or 0
    return r
end
ShopCatalogQueries.normProduct = norm_product

local function category_ref(r)
    if U.nz(r.category_slug) then
        return { slug = r.category_slug, name = r.category_name }
    end
    return U.null
end

--- Product(list) shape.
function ShopCatalogQueries.card(r, available)
    if available == nil then available = r.available end
    available = tonumber(available)
    if available == nil then available = (tonumber(r.stock_qty) or 0) end
    local from = tonumber(r.from_price_minor) or r.base_price_minor
    return {
        uuid = r.uuid,
        sku = r.sku,
        slug = r.slug,
        name = r.name,
        brand = r.brand or U.null,
        product_type = r.product_type,
        price_mode = r.price_mode,
        short_description = r.short_description or U.null,
        images = r.images,
        tags = r.tags,
        from_price_minor = from,
        currency = r.currency or "GBP",
        vat_rate = r.vat_rate,
        category = category_ref(r),
        availability = Stock.availability(available, tonumber(r.lead_time_days) or 10),
        price_verified = r.price_verified == true,
        is_featured = r.is_featured == true,
        specs = r.specs,
    }
end

-- ---------------------------------------------------------------------------
-- bundle loading (product + groups + options + rules + availability)
-- ---------------------------------------------------------------------------

--- by = { slug = } | { uuid = } | { id = }
-- opts.public  → only status=active, active groups/options/rules
function ShopCatalogQueries.loadBundle(ns_id, by, opts)
    opts = opts or {}
    local where, val
    if by.slug then where, val = "p.slug = ?", by.slug
    elseif by.uuid then where, val = "p.uuid = ?", by.uuid
    elseif by.id then where, val = "p.id = ?", by.id
    else return nil end
    local sql = "SELECT " .. PRODUCT_COLS .. [[, c.uuid AS category_uuid, c.slug AS category_slug, c.name AS category_name
          FROM shop_products p LEFT JOIN shop_categories c ON c.id = p.category_id
         WHERE p.namespace_id = ? AND ]] .. where
    if opts.public then sql = sql .. " AND p.status = 'active'" end
    local rows = db.query(sql .. " LIMIT 1", ns_id, val)
    local p = rows[1]
    if not p then return nil end
    norm_product(p)

    local groups = db.query([[
        SELECT id, uuid, code, name, description, selection, required, min_qty, max_qty, sort_order, is_active
          FROM shop_option_groups WHERE product_id = ? ORDER BY sort_order, id
    ]], p.id)
    local options = db.query([[
        SELECT o.id, o.uuid, o.group_id, o.code, o.name, o.description, o.price_delta_minor, o.component_product_id,
               o.stock_qty, o.max_qty, o.is_default, o.is_active, o.sort_order, o.attributes::text AS attributes,
               cp.uuid AS component_uuid, cp.sku AS component_sku, cp.name AS component_name,
               cp.allow_backorder AS component_allow_backorder, cp.lead_time_days AS component_lead_time_days,
               cp.status AS component_status
          FROM shop_options o
          JOIN shop_option_groups g ON g.id = o.group_id
          LEFT JOIN shop_products cp ON cp.id = o.component_product_id
         WHERE g.product_id = ?
         ORDER BY o.sort_order, o.id
    ]], p.id)
    local rules = db.query([[
        SELECT id, uuid, kind, params::text AS params, message, is_active, sort_order
          FROM shop_rules WHERE product_id = ? ORDER BY sort_order, id
    ]], p.id)

    -- availability
    local product_ids, option_ids = { p.id }, {}
    for _, o in ipairs(options) do
        if U.nz(o.component_product_id) then
            product_ids[#product_ids + 1] = o.component_product_id
        elseif U.nz(o.stock_qty) then
            option_ids[#option_ids + 1] = o.id
        end
    end
    local pav = Stock.forProducts(product_ids)
    local oav = Stock.forOptions(option_ids)

    p.held = pav[p.id] and pav[p.id].held or 0
    p.available = pav[p.id] and pav[p.id].available or p.stock_qty

    local by_group = {}
    for _, g in ipairs(groups) do
        g.options = {}
        by_group[g.id] = g
    end
    for _, o in ipairs(options) do
        o.attributes = U.dec(o.attributes, {})
        o.price_delta_minor = tonumber(o.price_delta_minor) or 0
        if U.nz(o.component_product_id) then
            local a = pav[o.component_product_id]
            o.available = a and a.available or 0
            o.stock_key = "p:" .. tostring(o.component_product_id)
            o.allow_backorder = o.component_allow_backorder ~= false
            o.lead_time_days = tonumber(o.component_lead_time_days) or p.lead_time_days
        elseif U.nz(o.stock_qty) then
            local a = oav[o.id]
            o.available = a and a.available or tonumber(o.stock_qty)
            o.stock_key = "o:" .. tostring(o.id)
            o.allow_backorder = p.allow_backorder ~= false
            o.lead_time_days = p.lead_time_days
        else
            o.available = nil
            o.stock_key = nil
            o.lead_time_days = p.lead_time_days
        end
        local g = by_group[o.group_id]
        if g then g.options[#g.options + 1] = o end
    end
    for _, r in ipairs(rules) do r.params = U.dec(r.params, {}) end

    p.stock_key = "p:" .. tostring(p.id)

    local bundle = { product = p, groups = groups, rules = rules }
    if opts.public then
        local ag = {}
        for _, g in ipairs(groups) do
            if g.is_active ~= false then
                local ao = {}
                for _, o in ipairs(g.options) do if o.is_active ~= false then ao[#ao + 1] = o end end
                g.options = ao
                ag[#ag + 1] = g
            end
        end
        bundle.groups = ag
        local ar = {}
        for _, r in ipairs(rules) do if r.is_active ~= false then ar[#ar + 1] = r end end
        bundle.rules = ar
    end
    return bundle
end

--- Price a loaded bundle. Returns (priced, demand).
function ShopCatalogQueries.priceBundle(bundle, selections, qty)
    local p = bundle.product
    local product = {
        slug = p.slug, name = p.name, base_price_minor = p.base_price_minor, vat_rate = p.vat_rate,
        price_mode = p.price_mode, attributes = p.attributes, currency = p.currency,
        price_verified = p.price_verified == true,
        available = p.available, stock_key = p.stock_key,
        allow_backorder = p.allow_backorder ~= false, lead_time_days = tonumber(p.lead_time_days) or 10,
    }
    local priced, demand = Pricing.price(product, bundle.groups, bundle.rules, selections, qty)
    -- JSON shaping
    priced.breakdown = U.arr(priced.breakdown)
    for _, v in ipairs(priced.violations) do v.groups = U.arr(v.groups) end
    priced.violations = U.arr(priced.violations)
    priced.availability.shortages = U.arr(priced.availability.shortages)
    for g, list in pairs(priced.selections) do priced.selections[g] = U.arr(list) end
    return priced, demand
end

--- Line snapshot = Priced + {uuid, product_uuid, product_name, sku, image}.
function ShopCatalogQueries.lineSnapshot(bundle, priced, line_uuid)
    local p = bundle.product
    local line = {}
    for k, v in pairs(priced) do line[k] = v end
    line.uuid = line_uuid or Global.generateUUID()
    line.product_uuid = p.uuid
    line.product_name = p.name
    line.sku = p.sku
    line.image = p.images[1] or U.null
    return line
end

--- Price a {product_slug, qty, selections} request for a namespace.
-- Returns (priced, bundle, demand) or (nil, err).
function ShopCatalogQueries.priceRequest(ns_id, req, opts)
    opts = opts or {}
    if type(req) ~= "table" or not U.nz(req.product_slug) then
        return nil, U.err(400, "VALIDATION_ERROR", "product_slug is required")
    end
    local qty = U.int(req.qty, 1)
    local bundle = ShopCatalogQueries.loadBundle(ns_id, { slug = req.product_slug }, { public = not opts.admin })
    if not bundle then
        return nil, U.err(404, "PRODUCT_NOT_FOUND", "Product not found: " .. tostring(req.product_slug))
    end
    local selections = req.selections
    if selections == cjson.null then selections = nil end
    if selections ~= nil and type(selections) ~= "table" then
        return nil, U.err(400, "VALIDATION_ERROR", "selections must be an object")
    end
    local priced, demand = ShopCatalogQueries.priceBundle(bundle, selections, qty)
    return priced, bundle, demand
end

--- Product(full) shape.
function ShopCatalogQueries.fullProduct(bundle)
    local p = bundle.product
    local from = Pricing.from_price(p, bundle.groups)
    p.from_price_minor = from
    local out = ShopCatalogQueries.card(p, p.available)
    out.description = p.description or U.null
    out.attributes = p.attributes
    local groups = {}
    for _, g in ipairs(bundle.groups) do
        local opts = {}
        for _, o in ipairs(g.options) do
            opts[#opts + 1] = {
                code = o.code, name = o.name, description = o.description or U.null,
                price_delta_minor = o.price_delta_minor, max_qty = tonumber(o.max_qty) or 1,
                is_default = o.is_default == true, attributes = o.attributes,
                availability = Stock.availability(o.available, tonumber(o.lead_time_days) or 10),
            }
        end
        groups[#groups + 1] = {
            code = g.code, name = g.name, description = g.description or U.null, selection = g.selection,
            required = g.required == true, min_qty = tonumber(g.min_qty) or 0, max_qty = tonumber(g.max_qty) or 1,
            options = U.arr(opts),
        }
    end
    out.option_groups = U.arr(groups)
    local rules = {}
    for _, r in ipairs(bundle.rules) do
        rules[#rules + 1] = { kind = r.kind, message = r.message or U.null }
    end
    out.rules = U.arr(rules)
    local defs = Pricing.default_selections(bundle.groups)
    for g, list in pairs(defs) do defs[g] = U.arr(list) end
    out.default_selections = defs
    return out
end

-- ---------------------------------------------------------------------------
-- public listing
-- ---------------------------------------------------------------------------

local FROM_PRICE_SQL = [[
    p.base_price_minor + COALESCE((
        SELECT SUM(CASE WHEN need > 0 THEN m.min_delta * need ELSE LEAST(m.min_delta, 0) END)
          FROM (SELECT g.id, GREATEST(g.min_qty, CASE WHEN g.required THEN 1 ELSE 0 END) AS need
                  FROM shop_option_groups g WHERE g.product_id = p.id AND g.is_active) g2
          JOIN LATERAL (SELECT MIN(o.price_delta_minor) AS min_delta FROM shop_options o
                         WHERE o.group_id = g2.id AND o.is_active) m ON m.min_delta IS NOT NULL
    ), 0)
]]

local HELD_SQL = [[
    COALESCE((SELECT SUM(r.qty) FROM shop_stock_reservations r
               WHERE r.product_id = p.id AND r.status = 'held' AND r.expires_at > NOW()), 0)
]]

--- Shared product query for public + admin listings.
-- Returns (rows (normalised), total).
function ShopCatalogQueries.queryProducts(ns_id, params, opts)
    params = params or {}
    opts = opts or {}
    local limit = U.clamp(U.int(params.limit, 24), 1, opts.max_limit or 100)
    local offset = math.max(0, U.int(params.offset, 0))

    local where, vals = { "p.namespace_id = ?" }, { ns_id }
    if opts.public then
        where[#where + 1] = "p.status = 'active'"
    elseif U.nz(params.status) then
        where[#where + 1] = "p.status = ?"
        vals[#vals + 1] = params.status
    end
    local q = U.nz(params.q)
    local rank_sql = "0"
    if q then
        q = tostring(q):sub(1, 200)
        where[#where + 1] = "(p.search_tsv @@ websearch_to_tsquery('english', ?) OR p.sku ILIKE ? OR p.name ILIKE ?)"
        local like = "%" .. q:gsub("[%%_\\]", "\\%0") .. "%"
        vals[#vals + 1] = q
        vals[#vals + 1] = like
        vals[#vals + 1] = like
        rank_sql = "ts_rank_cd(p.search_tsv, websearch_to_tsquery('english', " .. db.escape_literal(q) .. "))"
    end
    if U.nz(params.category) then
        where[#where + 1] = [[(c.slug = ? OR c.parent_id IN
            (SELECT id FROM shop_categories WHERE namespace_id = p.namespace_id AND slug = ?))]]
        vals[#vals + 1] = params.category
        vals[#vals + 1] = params.category
    end
    if U.nz(params.type) then
        where[#where + 1] = "p.product_type = ?"
        vals[#vals + 1] = params.type
    end
    if U.nz(params.brand) then
        where[#where + 1] = "LOWER(p.brand) = LOWER(?)"
        vals[#vals + 1] = params.brand
    end
    if U.bool(params.featured, false) then
        where[#where + 1] = "p.is_featured"
    end

    local outer, ovals = {}, {}
    if U.int(params.min_price, nil) then
        outer[#outer + 1] = "from_price_minor >= ?"
        ovals[#ovals + 1] = U.int(params.min_price, 0)
    end
    if U.int(params.max_price, nil) then
        outer[#outer + 1] = "from_price_minor <= ?"
        ovals[#ovals + 1] = U.int(params.max_price, 0)
    end
    if U.bool(params.in_stock, false) then
        outer[#outer + 1] = "available > 0"
    end
    if U.bool(params.low_stock, false) then
        outer[#outer + 1] = "available <= low_stock_threshold"
    end

    local sorts = {
        price_asc = "from_price_minor ASC, name ASC",
        price_desc = "from_price_minor DESC, name ASC",
        name = "name ASC",
        featured = "is_featured DESC, sort_order ASC, name ASC",
        newest = "created_at DESC",
        relevance = "rank DESC, is_featured DESC, name ASC",
    }
    local sort = sorts[params.sort or ""] or (q and sorts.relevance) or sorts.featured

    local sql = "WITH base AS (SELECT " .. PRODUCT_COLS .. [[,
               c.uuid AS category_uuid, c.slug AS category_slug, c.name AS category_name,
               ]] .. FROM_PRICE_SQL .. [[ AS from_price_minor,
               ]] .. HELD_SQL .. [[ AS held,
               p.stock_qty - ]] .. HELD_SQL .. [[ AS available,
               ]] .. rank_sql .. [[ AS rank
          FROM shop_products p LEFT JOIN shop_categories c ON c.id = p.category_id
         WHERE ]] .. table.concat(where, " AND ") .. [[)
        SELECT *, COUNT(*) OVER() AS total FROM base]]
        .. (#outer > 0 and (" WHERE " .. table.concat(outer, " AND ")) or "")
        .. " ORDER BY " .. sort .. " LIMIT ? OFFSET ?"
    for _, v in ipairs(ovals) do vals[#vals + 1] = v end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query(sql, unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    for _, r in ipairs(rows) do
        norm_product(r)
        r.total = nil
    end
    return rows, total, limit, offset
end

function ShopCatalogQueries.listPublic(ns_id, params)
    local rows, total, limit, offset = ShopCatalogQueries.queryProducts(ns_id, params, { public = true })
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = ShopCatalogQueries.card(r) end
    return U.arr(out), { total = total, limit = limit, offset = offset }
end

--- Cards for a set of product ids (search results), keyed by id.
function ShopCatalogQueries.cardsByIds(ns_id, ids)
    local map = {}
    if #ids == 0 then return map end
    local rows = db.query("SELECT " .. PRODUCT_COLS .. [[,
               c.slug AS category_slug, c.name AS category_name,
               ]] .. FROM_PRICE_SQL .. [[ AS from_price_minor,
               p.stock_qty - ]] .. HELD_SQL .. [[ AS available
          FROM shop_products p LEFT JOIN shop_categories c ON c.id = p.category_id
         WHERE p.namespace_id = ? AND p.status = 'active' AND p.id = ANY(?)
    ]], ns_id, db.array(ids))
    for _, r in ipairs(rows) do
        norm_product(r)
        map[r.id] = ShopCatalogQueries.card(r)
    end
    return map
end

function ShopCatalogQueries.listCategories(ns_id, opts)
    opts = opts or {}
    local rows = db.query([[
        SELECT c.uuid, c.slug, c.name, c.description, c.image_url, c.sort_order, c.is_active,
               pc.slug AS parent_slug, pc.uuid AS parent_uuid,
               (SELECT COUNT(*) FROM shop_products p WHERE p.category_id = c.id
                  AND (p.status = 'active' OR ?))::int AS product_count,
               c.created_at, c.updated_at
          FROM shop_categories c LEFT JOIN shop_categories pc ON pc.id = c.parent_id
         WHERE c.namespace_id = ? ]] .. (opts.admin and "" or "AND c.is_active") .. [[
         ORDER BY c.sort_order, c.name
    ]], opts.admin and true or false, ns_id)
    for _, r in ipairs(rows) do
        for _, k in ipairs({ "description", "image_url", "parent_slug", "parent_uuid" }) do
            if r[k] == nil then r[k] = U.null end
        end
        if not opts.admin then
            r.is_active = nil
            r.created_at = nil
            r.updated_at = nil
            r.parent_uuid = nil
        end
    end
    return U.arr(rows)
end

-- ---------------------------------------------------------------------------
-- admin: categories
-- ---------------------------------------------------------------------------

local function category_id_by(ns_id, uuid, slug)
    if U.nz(uuid) then
        local r = db.query("SELECT id FROM shop_categories WHERE namespace_id = ? AND uuid = ?", ns_id, uuid)[1]
        return r and r.id
    end
    if U.nz(slug) then
        local r = db.query("SELECT id FROM shop_categories WHERE namespace_id = ? AND slug = ?", ns_id, slug)[1]
        return r and r.id
    end
    return nil
end

--- Upsert a category by slug (or update by uuid). Returns (row, created) or (nil, err).
function ShopCatalogQueries.saveCategory(ns_id, doc, uuid)
    doc = doc or {}
    local existing
    if uuid then
        existing = db.query("SELECT * FROM shop_categories WHERE namespace_id = ? AND uuid = ?", ns_id, uuid)[1]
        if not existing then return nil, U.err(404, "NOT_FOUND", "Category not found") end
    end
    local slug = U.nz(doc.slug) or (existing and existing.slug) or (U.nz(doc.name) and U.slugify(doc.name))
    if not slug or slug == "" then return nil, U.err(400, "VALIDATION_ERROR", "name or slug is required") end
    if not existing then
        existing = db.query("SELECT * FROM shop_categories WHERE namespace_id = ? AND slug = ?", ns_id, slug)[1]
    elseif slug ~= existing.slug then
        local clash = db.query("SELECT 1 FROM shop_categories WHERE namespace_id = ? AND slug = ? AND id <> ?",
            ns_id, slug, existing.id)[1]
        if clash then return nil, U.err(409, "SLUG_TAKEN", "Category slug already in use") end
    end
    local name = U.nz(doc.name) or (existing and existing.name)
    if not name then return nil, U.err(400, "VALIDATION_ERROR", "name is required") end

    local parent_id = db.NULL
    if doc.parent_uuid ~= nil or doc.parent_slug ~= nil then
        local pid = category_id_by(ns_id, doc.parent_uuid, doc.parent_slug)
        if pid and (not existing or pid ~= existing.id) then parent_id = pid end
    elseif existing and U.nz(existing.parent_id) then
        parent_id = existing.parent_id
    end

    local function pick(k, default)
        if doc[k] ~= nil and doc[k] ~= cjson.null then return doc[k] end
        if existing and existing[k] ~= nil then return existing[k] end
        return default
    end
    local fields = {
        slug = slug, name = name,
        description = U.nz(pick("description")) or db.NULL,
        image_url = U.nz(pick("image_url")) or db.NULL,
        parent_id = parent_id,
        sort_order = U.int(pick("sort_order", 0), 0),
        is_active = U.bool(pick("is_active", true), true),
    }
    if existing then
        fields.updated_at = db.raw("NOW()")
        db.update("shop_categories", fields, { id = existing.id })
        return db.query("SELECT * FROM shop_categories WHERE id = ?", existing.id)[1], false
    end
    fields.uuid = Global.generateUUID()
    fields.namespace_id = ns_id
    fields.created_at = db.raw("NOW()")
    fields.updated_at = db.raw("NOW()")
    local row = db.insert("shop_categories", fields, "id", "uuid", "slug", "name")
    return row and row[1] or row, true
end

function ShopCatalogQueries.deleteCategory(ns_id, uuid)
    local c = db.query("SELECT id FROM shop_categories WHERE namespace_id = ? AND uuid = ?", ns_id, uuid)[1]
    if not c then return nil, U.err(404, "NOT_FOUND", "Category not found") end
    local used = db.query("SELECT COUNT(*)::int AS n FROM shop_products WHERE category_id = ?", c.id)[1].n
    if used > 0 then
        return nil, U.err(409, "CATEGORY_IN_USE", "Category has " .. used .. " product(s); move them first")
    end
    db.query("UPDATE shop_categories SET parent_id = NULL WHERE parent_id = ?", c.id)
    db.query("DELETE FROM shop_categories WHERE id = ?", c.id)
    return true
end

-- ---------------------------------------------------------------------------
-- admin: products
-- ---------------------------------------------------------------------------

--- Full admin document for a product.
function ShopCatalogQueries.adminDocument(ns_id, uuid)
    local b = ShopCatalogQueries.loadBundle(ns_id, { uuid = uuid })
    if not b then return nil end
    local p = b.product
    local doc = {
        uuid = p.uuid, sku = p.sku, slug = p.slug, name = p.name, brand = p.brand or U.null,
        product_type = p.product_type, price_mode = p.price_mode,
        short_description = p.short_description or U.null, description = p.description or U.null,
        specs = p.specs, attributes = p.attributes, images = p.images, tags = p.tags,
        base_price_minor = p.base_price_minor, currency = p.currency, vat_rate = p.vat_rate,
        stock_qty = p.stock_qty, held = p.held, available = p.available,
        low_stock_threshold = p.low_stock_threshold, lead_time_days = p.lead_time_days,
        allow_backorder = p.allow_backorder == true, price_verified = p.price_verified == true,
        status = p.status, is_featured = p.is_featured == true, sort_order = p.sort_order,
        category = U.nz(p.category_uuid) and { uuid = p.category_uuid, slug = p.category_slug,
            name = p.category_name } or U.null,
        from_price_minor = Pricing.from_price(p, (function()
            local active = {}
            for _, g in ipairs(b.groups) do
                if g.is_active ~= false then
                    local ao = {}
                    for _, o in ipairs(g.options) do if o.is_active ~= false then ao[#ao + 1] = o end end
                    active[#active + 1] = { required = g.required, min_qty = g.min_qty, options = ao }
                end
            end
            return active
        end)()),
        created_at = p.created_at, updated_at = p.updated_at,
    }
    local groups = {}
    for _, g in ipairs(b.groups) do
        local opts = {}
        for _, o in ipairs(g.options) do
            opts[#opts + 1] = {
                uuid = o.uuid, code = o.code, name = o.name, description = o.description or U.null,
                price_delta_minor = o.price_delta_minor,
                stock_qty = U.nz(o.stock_qty) and tonumber(o.stock_qty) or U.null,
                component_product = U.nz(o.component_product_id) and {
                    uuid = o.component_uuid, sku = o.component_sku, name = o.component_name } or U.null,
                component_product_sku = o.component_sku or U.null,
                available = o.available == nil and U.null or o.available,
                max_qty = tonumber(o.max_qty) or 1, is_default = o.is_default == true,
                is_active = o.is_active ~= false, sort_order = o.sort_order, attributes = o.attributes,
            }
        end
        groups[#groups + 1] = {
            uuid = g.uuid, code = g.code, name = g.name, description = g.description or U.null,
            selection = g.selection, required = g.required == true, min_qty = g.min_qty, max_qty = g.max_qty,
            sort_order = g.sort_order, is_active = g.is_active ~= false, options = U.arr(opts),
        }
    end
    doc.option_groups = U.arr(groups)
    local rules = {}
    for _, r in ipairs(b.rules) do
        rules[#rules + 1] = { uuid = r.uuid, kind = r.kind, params = r.params, message = r.message or U.null,
            is_active = r.is_active ~= false, sort_order = r.sort_order }
    end
    doc.rules = U.arr(rules)
    return doc
end

function ShopCatalogQueries.adminList(ns_id, params)
    local rows, total, limit, offset = ShopCatalogQueries.queryProducts(ns_id, params, { max_limit = 500 })
    local out = {}
    for _, r in ipairs(rows) do
        local c = ShopCatalogQueries.card(r)
        c.status = r.status
        c.stock_qty = r.stock_qty
        c.held = tonumber(r.held) or 0
        c.available = tonumber(r.available) or 0
        c.low_stock_threshold = r.low_stock_threshold
        c.base_price_minor = r.base_price_minor
        c.allow_backorder = r.allow_backorder == true
        c.updated_at = r.updated_at
        c.low_stock = c.available <= (tonumber(r.low_stock_threshold) or 0)
        out[#out + 1] = c
    end
    return U.arr(out), { total = total, limit = limit, offset = offset }
end

local function jsonb(v, default)
    if v == nil or v == cjson.null then v = default end
    return db.raw(db.escape_literal(U.enc(v)) .. "::jsonb")
end

local function text_array(list)
    local clean = {}
    if type(list) == "table" then
        for _, t in ipairs(list) do
            if type(t) == "string" or type(t) == "number" then clean[#clean + 1] = tostring(t) end
        end
    elseif type(list) == "string" then
        for part in list:gmatch("[^,]+") do
            local s = part:match("^%s*(.-)%s*$")
            if s ~= "" then clean[#clean + 1] = s end
        end
    end
    if #clean == 0 then return db.raw("'{}'::text[]") end
    return db.array(clean)
end

--- Resolve a component product reference on an option doc.
-- Returns (id|nil, unresolved_sku|nil)
local function resolve_component(ns_id, o)
    if U.nz(o.component_product_uuid) then
        local r = db.query("SELECT id FROM shop_products WHERE namespace_id = ? AND uuid = ?", ns_id,
            o.component_product_uuid)[1]
        return r and r.id, nil
    end
    if U.nz(o.component_product_sku) then
        local r = db.query("SELECT id FROM shop_products WHERE namespace_id = ? AND sku = ?", ns_id,
            o.component_product_sku)[1]
        if r then return r.id, nil end
        return nil, o.component_product_sku
    end
    if type(o.component_product) == "table" and U.nz(o.component_product.uuid) then
        local r = db.query("SELECT id FROM shop_products WHERE namespace_id = ? AND uuid = ?", ns_id,
            o.component_product.uuid)[1]
        return r and r.id, nil
    end
    if U.nz(o.component_product_id) and tonumber(o.component_product_id) then
        local r = db.query("SELECT id FROM shop_products WHERE namespace_id = ? AND id = ?", ns_id,
            tonumber(o.component_product_id))[1]
        return r and r.id, nil
    end
    return nil, nil
end

local function validate_product_doc(doc, existing)
    if not existing then
        if not U.nz(doc.sku) then return "sku is required" end
        if not U.nz(doc.name) then return "name is required" end
    end
    if doc.product_type ~= nil and not PRODUCT_TYPES[doc.product_type] then
        return "product_type must be one of workstation|server|gpu|cpu|memory|storage|networking|peripheral|software|service"
    end
    if doc.price_mode ~= nil and not PRICE_MODES[doc.price_mode] then
        return "price_mode must be fixed|configurable|quote_only"
    end
    if doc.status ~= nil and not PRODUCT_STATUS[doc.status] then return "status must be draft|active|archived" end
    if doc.base_price_minor ~= nil and not U.int(doc.base_price_minor, nil) then return "base_price_minor must be an integer" end
    if doc.option_groups ~= nil and type(doc.option_groups) ~= "table" then return "option_groups must be an array" end
    if doc.rules ~= nil and type(doc.rules) ~= "table" then return "rules must be an array" end
    for _, g in ipairs(type(doc.option_groups) == "table" and doc.option_groups or {}) do
        if type(g) ~= "table" or not U.nz(g.code) then return "every option group needs a code" end
        if g.selection ~= nil and g.selection ~= "single" and g.selection ~= "multi" then
            return "option group " .. g.code .. ": selection must be single|multi"
        end
        for _, o in ipairs(type(g.options) == "table" and g.options or {}) do
            if type(o) ~= "table" or not U.nz(o.code) then return "every option in group " .. g.code .. " needs a code" end
        end
    end
    for _, r in ipairs(type(doc.rules) == "table" and doc.rules or {}) do
        if type(r) ~= "table" or not RULE_KINDS[r.kind] then
            return "rule kind must be requires|excludes|power|max_total|attr_match"
        end
        if r.params ~= nil and type(r.params) ~= "table" then return "rule params must be an object" end
    end
    return nil
end

--- Replace option groups/options for a product (upsert by code, deactivate missing).
-- Returns list of unresolved component skus { {option_id, sku} }.
local function save_groups(ns_id, product_id, groups_doc, keep_option_stock)
    local unresolved = {}
    local seen_groups = {}
    for gi, g in ipairs(groups_doc) do
        local gfields = {
            name = U.nz(g.name) or g.code,
            description = U.nz(g.description) or db.NULL,
            selection = (g.selection == "multi") and "multi" or "single",
            required = U.bool(g.required, false),
            min_qty = U.int(g.min_qty, 0),
            max_qty = U.int(g.max_qty, (g.selection == "multi") and 10 or 1),
            sort_order = U.int(g.sort_order, gi * 10),
            is_active = U.bool(g.is_active, true),
            updated_at = db.raw("NOW()"),
        }
        local ex = db.query("SELECT id FROM shop_option_groups WHERE product_id = ? AND code = ?", product_id, g.code)[1]
        local gid
        if ex then
            db.update("shop_option_groups", gfields, { id = ex.id })
            gid = ex.id
        else
            gfields.uuid = Global.generateUUID()
            gfields.product_id = product_id
            gfields.code = g.code
            gfields.created_at = db.raw("NOW()")
            gid = db.insert("shop_option_groups", gfields, "id")[1].id
        end
        seen_groups[#seen_groups + 1] = gid

        local seen_opts = {}
        for oi, o in ipairs(type(g.options) == "table" and g.options or {}) do
            local comp_id, unresolved_sku = resolve_component(ns_id, o)
            local ofields = {
                name = U.nz(o.name) or o.code,
                description = U.nz(o.description) or db.NULL,
                price_delta_minor = U.int(o.price_delta_minor, 0),
                component_product_id = comp_id or db.NULL,
                stock_qty = U.int(U.nz(o.stock_qty), nil) or db.NULL,
                max_qty = U.int(o.max_qty, 1),
                is_default = U.bool(o.is_default, false),
                is_active = U.bool(o.is_active, true),
                sort_order = U.int(o.sort_order, oi * 10),
                attributes = jsonb(type(o.attributes) == "table" and o.attributes or nil, {}),
                updated_at = db.raw("NOW()"),
            }
            local oex = db.query("SELECT id FROM shop_options WHERE group_id = ? AND code = ?", gid, o.code)[1]
            local oid
            if oex then
                -- existing option: keep its stock when editing (only set on creation)
                if keep_option_stock then ofields.stock_qty = nil end
                db.update("shop_options", ofields, { id = oex.id })
                oid = oex.id
            else
                ofields.uuid = Global.generateUUID()
                ofields.group_id = gid
                ofields.code = o.code
                ofields.created_at = db.raw("NOW()")
                oid = db.insert("shop_options", ofields, "id")[1].id
            end
            seen_opts[#seen_opts + 1] = oid
            if unresolved_sku then unresolved[#unresolved + 1] = { option_id = oid, sku = unresolved_sku } end
        end
        if #seen_opts > 0 then
            db.query("UPDATE shop_options SET is_active = false, updated_at = NOW() WHERE group_id = ? AND NOT (id = ANY(?))",
                gid, db.array(seen_opts))
        else
            db.query("UPDATE shop_options SET is_active = false, updated_at = NOW() WHERE group_id = ?", gid)
        end
    end
    if #seen_groups > 0 then
        db.query("UPDATE shop_option_groups SET is_active = false, updated_at = NOW() WHERE product_id = ? AND NOT (id = ANY(?))",
            product_id, db.array(seen_groups))
    else
        db.query("UPDATE shop_option_groups SET is_active = false, updated_at = NOW() WHERE product_id = ?", product_id)
    end
    return unresolved
end

--- Replace rules (match by uuid, else by kind + params; deactivate missing).
local function save_rules(product_id, rules_doc)
    local seen = {}
    for ri, r in ipairs(rules_doc) do
        local params = type(r.params) == "table" and r.params or {}
        local fields = {
            kind = r.kind,
            params = jsonb(params, {}),
            message = U.nz(r.message) or db.NULL,
            is_active = U.bool(r.is_active, true),
            sort_order = U.int(r.sort_order, ri * 10),
            updated_at = db.raw("NOW()"),
        }
        local ex
        if U.nz(r.uuid) then
            ex = db.query("SELECT id FROM shop_rules WHERE product_id = ? AND uuid = ?", product_id, r.uuid)[1]
        end
        if not ex then
            local seen_arr = #seen > 0 and seen or { 0 }
            ex = db.query([[SELECT id FROM shop_rules WHERE product_id = ? AND kind = ? AND params = ?::jsonb
                             AND NOT (id = ANY(?)) ORDER BY id LIMIT 1]],
                product_id, r.kind, U.enc(params), db.array(seen_arr))[1]
        end
        if ex then
            db.update("shop_rules", fields, { id = ex.id })
            seen[#seen + 1] = ex.id
        else
            fields.uuid = Global.generateUUID()
            fields.product_id = product_id
            fields.created_at = db.raw("NOW()")
            seen[#seen + 1] = db.insert("shop_rules", fields, "id")[1].id
        end
    end
    if #seen > 0 then
        db.query("UPDATE shop_rules SET is_active = false, updated_at = NOW() WHERE product_id = ? AND NOT (id = ANY(?))",
            product_id, db.array(seen))
    else
        db.query("UPDATE shop_rules SET is_active = false, updated_at = NOW() WHERE product_id = ?", product_id)
    end
end

--- Create or update a product document (transactional).
-- opts.uuid      update this product (PUT); otherwise upsert by sku
-- opts.user_id   for stock movement attribution
-- opts.reason    stock movement reason when stock_qty changes ("adjustment"|"import")
-- Returns (result, err) where result = { uuid, created, unresolved = {{option_id, sku}} }
function ShopCatalogQueries.saveProduct(ns_id, doc, opts)
    opts = opts or {}
    if type(doc) ~= "table" then return nil, U.err(400, "VALIDATION_ERROR", "product document must be an object") end
    return U.tx(function()
        local existing
        if opts.uuid then
            existing = db.query("SELECT id, uuid, sku, slug, name, stock_qty FROM shop_products WHERE namespace_id = ? AND uuid = ?",
                ns_id, opts.uuid)[1]
            if not existing then return nil, U.err(404, "NOT_FOUND", "Product not found") end
        elseif U.nz(doc.sku) then
            existing = db.query("SELECT id, uuid, sku, slug, name, stock_qty FROM shop_products WHERE namespace_id = ? AND sku = ?",
                ns_id, doc.sku)[1]
        end
        local verr = validate_product_doc(doc, existing)
        if verr then return nil, U.err(400, "VALIDATION_ERROR", verr) end

        local sku = U.nz(doc.sku) or existing.sku
        local slug = U.nz(doc.slug) or (existing and existing.slug) or U.slugify(doc.name)
        if sku ~= (existing and existing.sku) then
            local clash = db.query("SELECT 1 FROM shop_products WHERE namespace_id = ? AND sku = ? AND id <> ?",
                ns_id, sku, existing and existing.id or 0)[1]
            if clash then return nil, U.err(409, "SKU_TAKEN", "SKU already in use: " .. sku) end
        end
        local slug_clash = db.query("SELECT sku FROM shop_products WHERE namespace_id = ? AND slug = ? AND id <> ?",
            ns_id, slug, existing and existing.id or 0)[1]
        if slug_clash then
            return nil, U.err(409, "SLUG_TAKEN", "Slug '" .. slug .. "' already used by " .. tostring(slug_clash.sku))
        end

        local fields = { sku = sku, slug = slug, updated_at = db.raw("NOW()") }
        local function set(k, v) if v ~= nil then fields[k] = v end end
        set("name", U.nz(doc.name))
        if doc.brand ~= nil then fields.brand = U.nz(doc.brand) or db.NULL end
        set("product_type", doc.product_type)
        set("price_mode", doc.price_mode)
        if doc.short_description ~= nil then fields.short_description = U.nz(doc.short_description) or db.NULL end
        if doc.description ~= nil then fields.description = U.nz(doc.description) or db.NULL end
        if doc.specs ~= nil then fields.specs = jsonb(type(doc.specs) == "table" and doc.specs or nil, {}) end
        if doc.attributes ~= nil then
            fields.attributes = jsonb(type(doc.attributes) == "table" and doc.attributes or nil, {})
        end
        if doc.images ~= nil then
            fields.images = jsonb(U.arr(type(doc.images) == "table" and doc.images or {}), {})
        end
        if doc.tags ~= nil then fields.tags = text_array(doc.tags) end
        if doc.base_price_minor ~= nil then fields.base_price_minor = U.int(doc.base_price_minor, 0) end
        set("currency", U.nz(doc.currency) and tostring(doc.currency):upper() or nil)
        if doc.vat_rate ~= nil and tonumber(doc.vat_rate) then fields.vat_rate = tonumber(doc.vat_rate) end
        if doc.low_stock_threshold ~= nil then fields.low_stock_threshold = U.int(doc.low_stock_threshold, 2) end
        if doc.lead_time_days ~= nil then fields.lead_time_days = U.int(doc.lead_time_days, 10) end
        if doc.allow_backorder ~= nil then fields.allow_backorder = U.bool(doc.allow_backorder, true) end
        if doc.price_verified ~= nil then fields.price_verified = U.bool(doc.price_verified, false) end
        set("status", doc.status)
        if doc.is_featured ~= nil then fields.is_featured = U.bool(doc.is_featured, false) end
        if doc.sort_order ~= nil then fields.sort_order = U.int(doc.sort_order, 0) end
        if doc.category_uuid ~= nil or doc.category_slug ~= nil or doc.category_id ~= nil
            or type(doc.category) == "table" then
            local cat = type(doc.category) == "table" and doc.category or {}
            local cid = category_id_by(ns_id, doc.category_uuid or cat.uuid, doc.category_slug or cat.slug)
            if not cid and tonumber(doc.category_id) then
                local r = db.query("SELECT id FROM shop_categories WHERE namespace_id = ? AND id = ?", ns_id,
                    tonumber(doc.category_id))[1]
                cid = r and r.id
            end
            if not cid and (U.nz(doc.category_uuid) or U.nz(doc.category_slug) or tonumber(doc.category_id)) then
                return nil, U.err(400, "CATEGORY_NOT_FOUND", "Category not found: "
                    .. tostring(doc.category_slug or doc.category_uuid))
            end
            fields.category_id = cid or db.NULL
        end

        -- PUT (opts.ignore_stock) never touches stock: that goes through the /stock
        -- endpoints so a stale editor cannot overwrite sales.
        local new_stock = (doc.stock_qty ~= nil and not (opts.ignore_stock and existing))
            and U.int(doc.stock_qty, nil) or nil
        local product_id, created
        if existing then
            if new_stock ~= nil then fields.stock_qty = new_stock end
            db.update("shop_products", fields, { id = existing.id })
            product_id, created = existing.id, false
            if new_stock ~= nil and new_stock ~= tonumber(existing.stock_qty) then
                Stock.recordMovement(ns_id, { product_id = existing.id, delta = new_stock - tonumber(existing.stock_qty),
                    reason = opts.reason or "adjustment", ref = opts.ref or "product update", user_id = opts.user_id })
            end
        else
            fields.uuid = Global.generateUUID()
            fields.namespace_id = ns_id
            fields.name = fields.name or sku
            fields.stock_qty = new_stock or 0
            fields.created_at = db.raw("NOW()")
            product_id = db.insert("shop_products", fields, "id")[1].id
            created = true
            if (new_stock or 0) ~= 0 then
                Stock.recordMovement(ns_id, { product_id = product_id, delta = new_stock,
                    reason = opts.reason or "adjustment", ref = opts.ref or "initial stock", user_id = opts.user_id })
            end
        end

        local unresolved = {}
        if type(doc.option_groups) == "table" then
            unresolved = save_groups(ns_id, product_id, doc.option_groups, opts.ignore_stock)
        end
        if type(doc.rules) == "table" then
            save_rules(product_id, doc.rules)
        end
        local uuid = db.query("SELECT uuid FROM shop_products WHERE id = ?", product_id)[1].uuid
        return { uuid = uuid, id = product_id, created = created, unresolved = unresolved }
    end)
end

--- Delete a product; archive instead when referenced by carts/quotes/orders/options.
function ShopCatalogQueries.deleteProduct(ns_id, uuid)
    local p = db.query("SELECT id, uuid FROM shop_products WHERE namespace_id = ? AND uuid = ?", ns_id, uuid)[1]
    if not p then return nil, U.err(404, "NOT_FOUND", "Product not found") end
    local ref = db.query([[
        SELECT (EXISTS (SELECT 1 FROM shop_cart_lines WHERE product_id = ?)
             OR EXISTS (SELECT 1 FROM shop_options WHERE component_product_id = ?)
             OR EXISTS (SELECT 1 FROM shop_stock_reservations WHERE product_id = ?)
             OR EXISTS (SELECT 1 FROM shop_quotes WHERE namespace_id = ? AND lines @> ?::jsonb)
             OR EXISTS (SELECT 1 FROM shop_orders WHERE namespace_id = ? AND lines @> ?::jsonb)) AS used
    ]], p.id, p.id, p.id, ns_id, U.enc({ { product_uuid = uuid } }), ns_id,
        U.enc({ { product_uuid = uuid } }))[1].used
    if ref then
        db.query("UPDATE shop_products SET status = 'archived', updated_at = NOW() WHERE id = ?", p.id)
        return { archived = true, deleted = false }
    end
    db.query("DELETE FROM shop_stock_movements WHERE product_id = ?", p.id)
    db.query("DELETE FROM shop_knowledge_chunks WHERE namespace_id = ? AND source_type = 'product' AND source_ref = ?",
        ns_id, uuid)
    db.query("DELETE FROM shop_products WHERE id = ?", p.id)
    return { archived = false, deleted = true }
end

-- ---------------------------------------------------------------------------
-- admin: bulk import (seed script)
-- ---------------------------------------------------------------------------

function ShopCatalogQueries.import(ns_id, payload, user_id)
    payload = payload or {}
    local result = {
        categories = { created = 0, updated = 0 },
        products = { created = 0, updated = 0 },
        errors = {},
    }
    local function add_error(kind, ref, message)
        result.errors[#result.errors + 1] = { type = kind, ref = ref, error = message }
    end

    -- categories (pass 1 without parents, pass 2 parents)
    local cats = type(payload.categories) == "table" and payload.categories or {}
    for _, c in ipairs(cats) do
        local doc = {}
        for k, v in pairs(type(c) == "table" and c or {}) do doc[k] = v end
        doc.parent_slug, doc.parent_uuid = nil, nil
        local ok, row, created = pcall(ShopCatalogQueries.saveCategory, ns_id, doc)
        if not ok then
            add_error("category", c and c.slug, tostring(row))
        elseif not row then
            add_error("category", c and c.slug, type(created) == "table" and created.message or "invalid")
        elseif created == true then
            result.categories.created = result.categories.created + 1
        else
            result.categories.updated = result.categories.updated + 1
        end
    end
    for _, c in ipairs(cats) do
        if type(c) == "table" and U.nz(c.slug) and U.nz(c.parent_slug) then
            local pid = category_id_by(ns_id, nil, c.parent_slug)
            if pid then
                db.query("UPDATE shop_categories SET parent_id = ? WHERE namespace_id = ? AND slug = ? AND id <> ?",
                    pid, ns_id, c.slug, pid)
            else
                add_error("category", c.slug, "parent category not found: " .. c.parent_slug)
            end
        end
    end

    -- products (pass 1), component skus resolved in pass 2
    local pending = {}
    for _, p in ipairs(type(payload.products) == "table" and payload.products or {}) do
        -- Re-importing must not clobber live stock (sales, admin adjustments):
        -- existing products/options keep their stock unless overwrite_stock.
        local ok, res, err = pcall(ShopCatalogQueries.saveProduct, ns_id, p,
            { reason = "import", ref = "import", user_id = user_id,
              ignore_stock = payload.overwrite_stock ~= true })
        local ref = type(p) == "table" and (p.sku or p.slug or p.name) or nil
        if not ok then
            add_error("product", ref, tostring(res))
        elseif not res then
            add_error("product", ref, err and err.message or "invalid")
        else
            if res.created then
                result.products.created = result.products.created + 1
            else
                result.products.updated = result.products.updated + 1
            end
            for _, u in ipairs(res.unresolved or {}) do
                u.product_sku = ref
                pending[#pending + 1] = u
            end
        end
    end
    for _, u in ipairs(pending) do
        local r = db.query("SELECT id FROM shop_products WHERE namespace_id = ? AND sku = ?", ns_id, u.sku)[1]
        if r then
            db.query("UPDATE shop_options SET component_product_id = ?, updated_at = NOW() WHERE id = ?", r.id, u.option_id)
        else
            add_error("option", tostring(u.product_sku), "component_product_sku not found: " .. tostring(u.sku))
        end
    end
    result.errors = U.arr(result.errors)
    return result
end

return ShopCatalogQueries
