-- luacheck: max line length 140
--[[
    Shop market prices (pinned sources + scraped observations)
    ===========================================================
    Contract: workstation-website shop/MARKET.prompt.md §A.

    - Sources are admin-pinned URLs per catalogue product (shop_market_sources).
    - Observations are written by the market-sync worker. VAT is derived
      server-side from the source's prices_include_vat + the product vat_rate.
    - Anomaly: a price change > 40 % vs the source's last ACCEPTED observation
      (same currency) is stored with accepted=false, flags.anomaly=true and the
      source gets last_status='anomaly' until an admin accepts it.
    - Summaries use accepted, fresh (<= 7 days), GBP observations, latest per
      active source. Nothing here ever changes our prices except applyPrice.
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local Global = require("helper.global")
local U = require("lib.shop-util")
local Stock = require("queries.ShopStockQueries")

local ShopMarketQueries = {}

local FRESH_DAYS = 7
local DUE_HOURS = 6
local ANOMALY_RATIO = 0.40
ShopMarketQueries.FRESH_DAYS = FRESH_DAYS
ShopMarketQueries.ANOMALY_RATIO = ANOMALY_RATIO

local FRESH_SQL = "o.fetched_at >= NOW() - interval '" .. FRESH_DAYS .. " days'"

local FETCH_MODES = { direct = true, firecrawl = true }
local STATUSES = { ok = true, no_price = true, mismatch = true, http_error = true, blocked = true, rejected = true, anomaly = true }
local AVAILABILITY = { in_stock = true, limited = true, out_of_stock = true, preorder = true, backorder = true, unknown = true }
local METHODS = { json_ld = true, meta = true, microdata = true, llm = true }
local IN_STOCK = { in_stock = true, limited = true }

ShopMarketQueries.STATUSES = STATUSES
ShopMarketQueries.AVAILABILITY = AVAILABILITY
ShopMarketQueries.METHODS = METHODS

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function round(x)
    return math.floor(x + 0.5)
end

--- (ex, inc) minor units from a scraped price (pure; exported for tests).
function ShopMarketQueries.vat_split(price_minor, prices_include_vat, vat_rate)
    price_minor = tonumber(price_minor)
    if not price_minor then return nil, nil end
    vat_rate = tonumber(vat_rate) or 0.2
    if prices_include_vat then
        return round(price_minor / (1 + vat_rate)), price_minor
    end
    return price_minor, round(price_minor * (1 + vat_rate))
end

--- Median of a list of numbers (rounded to an integer for even counts).
function ShopMarketQueries.median(list)
    local n = #list
    if n == 0 then return nil end
    local s = {}
    for i, v in ipairs(list) do s[i] = v end
    table.sort(s)
    if n % 2 == 1 then return s[(n + 1) / 2] end
    return round((s[n / 2] + s[n / 2 + 1]) / 2)
end

--- Is `new` an anomaly vs `prev` (> 40 % change)? Returns (bool, change_ratio).
function ShopMarketQueries.is_anomaly(new, prev)
    new, prev = tonumber(new), tonumber(prev)
    if not new or not prev or prev <= 0 then return false, nil end
    local change = (new - prev) / prev
    return math.abs(change) > ANOMALY_RATIO, change
end

local function nn(v)
    if v == nil then return U.null end
    return v
end

local function valid_url(u)
    if type(u) ~= "string" or #u > 2048 then return false end
    return u:match("^https?://[%w][%w%.%-]*") ~= nil and not u:find("%s")
end

local function currency_code(c, default)
    c = U.nz(c)
    if type(c) ~= "string" then return default end
    c = c:upper()
    if not c:match("^%u%u%u$") then return nil end
    return c
end

--- Normalise a `match` object: {mpn?, gtin?, title_must_include?:[..], variant_hint?}.
local function clean_match(m)
    if m == nil or m == U.null then return {} end
    if type(m) ~= "table" then return nil, "match must be an object" end
    local out = {}
    for _, k in ipairs({ "mpn", "gtin", "variant_hint" }) do
        local v = U.nz(m[k])
        if v ~= nil then
            if type(v) ~= "string" and type(v) ~= "number" then return nil, "match." .. k .. " must be a string" end
            out[k] = tostring(v)
        end
    end
    local t = m.title_must_include
    if t ~= nil and t ~= U.null then
        if type(t) == "string" then t = { t } end
        if type(t) ~= "table" then return nil, "match.title_must_include must be an array of strings" end
        local list = {}
        for _, tok in ipairs(t) do
            if type(tok) ~= "string" then return nil, "match.title_must_include must be an array of strings" end
            if tok ~= "" then list[#list + 1] = tok end
        end
        out.title_must_include = U.arr(list)
    end
    return out
end

local SOURCE_COLS = [[
    s.id, s.uuid, s.product_id, s.name, s.url, s.fetch_mode, s.prices_include_vat, s.currency,
    s.match::text AS match, s.is_active, s.last_checked_at, s.last_status, s.last_error, s.created_at, s.updated_at,
    p.uuid AS product_uuid, p.sku AS product_sku, p.name AS product_name
]]

local function present_source(r)
    local m = U.dec(r.match, {})
    if type(m.title_must_include) == "table" then U.arr(m.title_must_include) end
    return {
        uuid = r.uuid,
        product_uuid = r.product_uuid,
        product_sku = r.product_sku,
        product_name = r.product_name,
        name = r.name,
        url = r.url,
        fetch_mode = r.fetch_mode,
        prices_include_vat = r.prices_include_vat == true,
        currency = r.currency,
        match = m,
        is_active = r.is_active == true,
        last_checked_at = nn(r.last_checked_at),
        last_status = nn(r.last_status),
        last_error = nn(r.last_error),
        created_at = r.created_at,
        updated_at = r.updated_at,
    }
end

local OBS_COLS = [[
    o.id, o.uuid, o.source_id, o.product_id, o.price_minor, o.currency, o.price_ex_vat_minor, o.price_inc_vat_minor,
    o.availability, o.stock_qty, o.title, o.method, o.confidence, o.evidence, o.flags::text AS flags, o.accepted,
    o.fetched_at, o.created_at
]]

local function present_obs(r)
    return {
        uuid = r.uuid,
        source_uuid = nn(r.source_uuid),
        source_name = nn(r.source_name),
        url = nn(r.source_url),
        price_minor = nn(tonumber(r.price_minor)),
        currency = r.currency,
        price_ex_vat_minor = nn(tonumber(r.price_ex_vat_minor)),
        price_inc_vat_minor = nn(tonumber(r.price_inc_vat_minor)),
        availability = r.availability,
        stock_qty = nn(tonumber(r.stock_qty)),
        title = nn(r.title),
        method = r.method,
        confidence = nn(tonumber(r.confidence)),
        evidence = nn(r.evidence),
        flags = U.dec(r.flags, {}),
        accepted = r.accepted == true,
        fetched_at = r.fetched_at,
        created_at = r.created_at,
    }
end

local function product_by(ns_id, uuid, sku)
    if U.nz(uuid) then
        return db.query("SELECT * FROM shop_products WHERE namespace_id = ? AND uuid = ? LIMIT 1", ns_id, uuid)[1]
    end
    if U.nz(sku) then
        return db.query("SELECT * FROM shop_products WHERE namespace_id = ? AND sku = ? LIMIT 1", ns_id, sku)[1]
    end
    return nil
end

local function source_row(ns_id, uuid)
    if not U.nz(uuid) then return nil end
    return db.query("SELECT " .. SOURCE_COLS .. [[
          FROM shop_market_sources s JOIN shop_products p ON p.id = s.product_id
         WHERE s.namespace_id = ? AND s.uuid = ? LIMIT 1
    ]], ns_id, uuid)[1]
end

-- ---------------------------------------------------------------------------
-- sources
-- ---------------------------------------------------------------------------

function ShopMarketQueries.listSources(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 500), 1, 1000)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "s.namespace_id = ?" }, { ns_id }
    if U.nz(params.product_uuid) then
        where[#where + 1] = "p.uuid = ?"
        vals[#vals + 1] = params.product_uuid
    end
    local active = U.bool(U.nz(params.active), nil)
    if active ~= nil then
        where[#where + 1] = "s.is_active = ?"
        vals[#vals + 1] = active
    end
    if U.nz(params.status) then
        where[#where + 1] = "s.last_status = ?"
        vals[#vals + 1] = params.status
    end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query("SELECT " .. SOURCE_COLS .. [[, COUNT(*) OVER() AS total
          FROM shop_market_sources s JOIN shop_products p ON p.id = s.product_id
         WHERE ]] .. table.concat(where, " AND ") .. [[
         ORDER BY p.sku, s.name, s.id LIMIT ? OFFSET ?
    ]], unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    local out = {}
    for i, r in ipairs(rows) do out[i] = present_source(r) end
    return U.arr(out), { total = total, limit = limit, offset = offset }
end

function ShopMarketQueries.getSource(ns_id, uuid)
    local r = source_row(ns_id, uuid)
    return r and present_source(r) or nil
end

--- Validate a source document. `partial` = PUT (only supplied fields).
local function validate_source(doc, partial)
    local f = {}
    if not partial or doc.name ~= nil then
        local name = U.nz(doc.name)
        if type(name) ~= "string" then return nil, U.err(400, "VALIDATION_ERROR", "name is required") end
        f.name = name:sub(1, 255)
    end
    if not partial or doc.url ~= nil then
        local url = U.nz(doc.url)
        if not valid_url(url) then return nil, U.err(400, "VALIDATION_ERROR", "url must be an http(s) URL") end
        f.url = url
    end
    if doc.fetch_mode ~= nil and doc.fetch_mode ~= U.null then
        if not FETCH_MODES[doc.fetch_mode] then
            return nil, U.err(400, "VALIDATION_ERROR", "fetch_mode must be 'direct' or 'firecrawl'")
        end
        f.fetch_mode = doc.fetch_mode
    elseif not partial then
        f.fetch_mode = "direct"
    end
    if doc.prices_include_vat ~= nil and doc.prices_include_vat ~= U.null then
        f.prices_include_vat = U.bool(doc.prices_include_vat, true)
    elseif not partial then
        f.prices_include_vat = true
    end
    if doc.currency ~= nil and doc.currency ~= U.null then
        local c = currency_code(doc.currency, "GBP")
        if not c then return nil, U.err(400, "VALIDATION_ERROR", "currency must be a 3-letter ISO code") end
        f.currency = c
    elseif not partial then
        f.currency = "GBP"
    end
    if doc.match ~= nil then
        local m, merr = clean_match(doc.match)
        if not m then return nil, U.err(400, "VALIDATION_ERROR", merr) end
        f.match = m
    elseif not partial then
        f.match = {}
    end
    if doc.is_active ~= nil and doc.is_active ~= U.null then
        f.is_active = U.bool(doc.is_active, true)
    elseif not partial then
        f.is_active = true
    end
    return f
end

function ShopMarketQueries.createSource(ns_id, doc)
    local product = product_by(ns_id, doc.product_uuid, doc.product_sku)
    if not product then
        return nil, U.err(404, "PRODUCT_NOT_FOUND", "Product not found (product_uuid or product_sku required)")
    end
    local f, err = validate_source(doc, false)
    if not f then return nil, err end
    if db.query("SELECT 1 FROM shop_market_sources WHERE namespace_id = ? AND product_id = ? AND url = ?",
        ns_id, product.id, f.url)[1] then
        return nil, U.err(409, "SOURCE_EXISTS", "A source with this URL already exists for the product")
    end
    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO shop_market_sources (uuid, namespace_id, product_id, name, url, fetch_mode, prices_include_vat, currency,
                                         match, is_active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?, NOW(), NOW())
    ]], uuid, ns_id, product.id, f.name, f.url, f.fetch_mode, f.prices_include_vat, f.currency, U.enc(f.match), f.is_active)
    return ShopMarketQueries.getSource(ns_id, uuid)
end

function ShopMarketQueries.updateSource(ns_id, uuid, doc)
    local cur = source_row(ns_id, uuid)
    if not cur then return nil, U.err(404, "NOT_FOUND", "Market source not found") end
    local f, err = validate_source(doc, true)
    if not f then return nil, err end
    local product_id = cur.product_id
    if U.nz(doc.product_uuid) or U.nz(doc.product_sku) then
        local p = product_by(ns_id, doc.product_uuid, doc.product_sku)
        if not p then return nil, U.err(404, "PRODUCT_NOT_FOUND", "Product not found") end
        product_id = p.id
    end
    local url = f.url or cur.url
    if (url ~= cur.url or product_id ~= cur.product_id) and db.query([[
        SELECT 1 FROM shop_market_sources WHERE namespace_id = ? AND product_id = ? AND url = ? AND id <> ?
    ]], ns_id, product_id, url, cur.id)[1] then
        return nil, U.err(409, "SOURCE_EXISTS", "A source with this URL already exists for the product")
    end
    local sets, vals = { "updated_at = NOW()", "product_id = ?" }, { product_id }
    for _, k in ipairs({ "name", "url", "fetch_mode", "prices_include_vat", "currency", "is_active" }) do
        if f[k] ~= nil then
            sets[#sets + 1] = k .. " = ?"
            vals[#vals + 1] = f[k]
        end
    end
    if f.match ~= nil then
        sets[#sets + 1] = "match = ?::jsonb"
        vals[#vals + 1] = U.enc(f.match)
    end
    vals[#vals + 1] = cur.id
    db.query("UPDATE shop_market_sources SET " .. table.concat(sets, ", ") .. " WHERE id = ?", unpack(vals))
    return ShopMarketQueries.getSource(ns_id, uuid)
end

function ShopMarketQueries.deleteSource(ns_id, uuid)
    local cur = source_row(ns_id, uuid)
    if not cur then return nil, U.err(404, "NOT_FOUND", "Market source not found") end
    db.query("DELETE FROM shop_market_sources WHERE id = ? AND namespace_id = ?", cur.id, ns_id)
    return { deleted = true, uuid = uuid }
end

--- Idempotent bulk upsert keyed by (product, url). Returns counts + per-item errors.
function ShopMarketQueries.upsertSources(ns_id, list)
    local res = { received = #list, created = 0, updated = 0, failed = 0, errors = U.arr({}), sources = U.arr({}) }
    local product_cache = {}
    for i, doc in ipairs(list) do
        local function fail(msg)
            res.failed = res.failed + 1
            res.errors[#res.errors + 1] = { index = i - 1, product_sku = nn(type(doc) == "table" and doc.product_sku or nil),
                url = nn(type(doc) == "table" and doc.url or nil), error = msg }
        end
        if type(doc) ~= "table" then
            fail("source must be an object")
        else
            local key = tostring(doc.product_uuid or "") .. "|" .. tostring(doc.product_sku or "")
            local product = product_cache[key]
            if product == nil then
                product = product_by(ns_id, doc.product_uuid, doc.product_sku) or false
                product_cache[key] = product
            end
            local f, err = validate_source(doc, false)
            if not product then
                fail("product not found: " .. tostring(doc.product_sku or doc.product_uuid))
            elseif not f then
                fail(err.message)
            else
                local row = db.query([[
                    INSERT INTO shop_market_sources (uuid, namespace_id, product_id, name, url, fetch_mode, prices_include_vat,
                                                     currency, match, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?, NOW(), NOW())
                    ON CONFLICT (namespace_id, product_id, url) DO UPDATE SET
                        name = EXCLUDED.name, fetch_mode = EXCLUDED.fetch_mode,
                        prices_include_vat = EXCLUDED.prices_include_vat, currency = EXCLUDED.currency,
                        match = EXCLUDED.match, is_active = EXCLUDED.is_active, updated_at = NOW()
                    RETURNING uuid, (xmax = 0) AS inserted
                ]], Global.generateUUID(), ns_id, product.id, f.name, f.url, f.fetch_mode, f.prices_include_vat,
                    f.currency, U.enc(f.match), f.is_active)[1]
                if row.inserted then res.created = res.created + 1 else res.updated = res.updated + 1 end
                res.sources[#res.sources + 1] = { uuid = row.uuid, product_sku = product.sku, url = f.url,
                    created = row.inserted == true }
            end
        end
    end
    return res
end

-- ---------------------------------------------------------------------------
-- due (worker queue)
-- ---------------------------------------------------------------------------

function ShopMarketQueries.due(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 50), 1, 500)
    local where, vals = {
        "s.namespace_id = ?", "s.is_active = true", "p.status <> 'archived'",
        "(s.last_checked_at IS NULL OR s.last_checked_at < NOW() - interval '" .. DUE_HOURS .. " hours')",
    }, { ns_id }
    if U.nz(params.source_uuid) then
        -- explicit single-source run (worker --source): ignore the due window
        where = { "s.namespace_id = ?", "s.uuid = ?" }
        vals[#vals + 1] = params.source_uuid
    end
    vals[#vals + 1] = limit
    local rows = db.query("SELECT " .. SOURCE_COLS .. [[,
               p.brand AS product_brand, p.vat_rate AS product_vat_rate, p.base_price_minor AS product_base_price_minor,
               p.slug AS product_slug,
               la.price_minor AS la_price_minor, la.currency AS la_currency, la.fetched_at AS la_fetched_at
          FROM shop_market_sources s
          JOIN shop_products p ON p.id = s.product_id
          LEFT JOIN LATERAL (
                SELECT o.price_minor, o.currency, o.fetched_at FROM shop_market_observations o
                 WHERE o.source_id = s.id AND o.accepted = true AND o.price_minor IS NOT NULL
                 ORDER BY o.fetched_at DESC, o.id DESC LIMIT 1) la ON true
         WHERE ]] .. table.concat(where, " AND ") .. [[
         ORDER BY s.last_checked_at ASC NULLS FIRST, s.id LIMIT ?
    ]], unpack(vals))
    local out = {}
    for i, r in ipairs(rows) do
        local s = present_source(r)
        s.product = {
            uuid = r.product_uuid,
            sku = r.product_sku,
            slug = r.product_slug,
            name = r.product_name,
            brand = nn(r.product_brand),
            vat_rate = tonumber(r.product_vat_rate) or 0.2,
            base_price_minor = tonumber(r.product_base_price_minor) or 0,
        }
        s.last_accepted_price_minor = nn(tonumber(r.la_price_minor))
        s.last_accepted = r.la_price_minor and {
            price_minor = tonumber(r.la_price_minor), currency = r.la_currency, fetched_at = r.la_fetched_at,
        } or U.null
        out[i] = s
    end
    return U.arr(out), { total = #out, limit = limit, offset = 0 }
end

-- ---------------------------------------------------------------------------
-- observations
-- ---------------------------------------------------------------------------

local function source_for_obs(ns_id, uuid)
    if not U.nz(uuid) then return nil end
    return db.query([[
        SELECT s.id, s.uuid, s.product_id, s.prices_include_vat, s.currency, p.vat_rate
          FROM shop_market_sources s JOIN shop_products p ON p.id = s.product_id
         WHERE s.namespace_id = ? AND s.uuid = ? LIMIT 1
    ]], ns_id, uuid)[1]
end

local function set_source_status(source_id, status, err)
    db.query([[
        UPDATE shop_market_sources SET last_checked_at = NOW(), last_status = ?, last_error = ?, updated_at = NOW()
         WHERE id = ?
    ]], status, err and tostring(err):sub(1, 2000) or db.NULL, source_id)
end

local function valid_ts(v)
    return type(v) == "string" and v:match("^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d") ~= nil
end

--- Process one worker result. Returns a result row (never raises for bad input).
local function record_one(ns_id, item)
    local src = source_for_obs(ns_id, item.source_uuid)
    if not src then
        return { source_uuid = nn(item.source_uuid), status = "error", error = "source not found" }
    end
    local status = U.nz(item.status) or "ok"
    if not STATUSES[status] then
        return { source_uuid = src.uuid, status = "error", error = "invalid status: " .. tostring(status) }
    end
    if status == "anomaly" then status = "ok" end -- anomaly is decided here, not by the worker

    if status ~= "ok" then
        set_source_status(src.id, status, U.nz(item.error))
        return { source_uuid = src.uuid, status = status }
    end

    -- status ok: validate the observation
    local price = U.nz(item.price_minor)
    if price ~= nil then
        price = tonumber(price)
        if not price or price ~= math.floor(price) or price <= 0 or price > 2000000000 then
            set_source_status(src.id, "rejected", "invalid price_minor: " .. tostring(item.price_minor))
            return { source_uuid = src.uuid, status = "rejected", error = "price_minor must be a positive integer" }
        end
    end
    local availability = U.nz(item.availability) or "unknown"
    if not AVAILABILITY[availability] then availability = "unknown" end
    if price == nil and availability == "unknown" then
        set_source_status(src.id, "no_price", U.nz(item.error) or "no price or availability in observation")
        return { source_uuid = src.uuid, status = "no_price" }
    end
    local method = U.nz(item.method)
    if not METHODS[method] then
        set_source_status(src.id, "rejected", "invalid method: " .. tostring(method))
        return { source_uuid = src.uuid, status = "rejected", error = "method must be json_ld, meta, microdata or llm" }
    end
    local currency = currency_code(item.currency, src.currency or "GBP") or src.currency or "GBP"
    local confidence = tonumber(U.nz(item.confidence))
    if confidence then confidence = U.clamp(math.floor(confidence * 1000 + 0.5) / 1000, 0, 1) end
    local stock_qty = U.int(U.nz(item.stock_qty), nil)
    local flags = type(item.flags) == "table" and item.flags or {}

    local ex, inc
    if price then ex, inc = ShopMarketQueries.vat_split(price, src.prices_include_vat == true, src.vat_rate) end

    -- anomaly vs last accepted (same currency)
    local accepted = true
    local result_status = "ok"
    if price then
        local prev = db.query([[
            SELECT price_minor, currency FROM shop_market_observations
             WHERE source_id = ? AND accepted = true AND price_minor IS NOT NULL
             ORDER BY fetched_at DESC, id DESC LIMIT 1
        ]], src.id)[1]
        if prev and prev.currency == currency then
            local anomalous, change = ShopMarketQueries.is_anomaly(price, prev.price_minor)
            if anomalous then
                accepted = false
                result_status = "anomaly"
                flags.anomaly = true
                flags.previous_price_minor = tonumber(prev.price_minor)
                flags.change_pct = math.floor(change * 1000 + 0.5) / 10
            end
        end
    end

    local fetched_at = valid_ts(item.fetched_at) and item.fetched_at or nil
    local uuid = Global.generateUUID()
    local ok, err = pcall(db.query, [[
        INSERT INTO shop_market_observations (uuid, namespace_id, source_id, product_id, price_minor, currency,
            price_ex_vat_minor, price_inc_vat_minor, availability, stock_qty, title, method, confidence, evidence, flags,
            accepted, fetched_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?,
                LEAST(COALESCE(?::timestamptz, NOW()), NOW()), NOW())
    ]], uuid, ns_id, src.id, src.product_id, price or db.NULL, currency, ex or db.NULL, inc or db.NULL, availability,
        stock_qty or db.NULL, U.nz(item.title) and tostring(item.title):sub(1, 1000) or db.NULL, method,
        confidence or db.NULL, U.nz(item.evidence) and tostring(item.evidence):sub(1, 4000) or db.NULL, U.enc(flags),
        accepted, fetched_at or db.NULL)
    if not ok then
        ngx.log(ngx.ERR, "[shop-market] observation insert failed: ", tostring(err))
        set_source_status(src.id, "rejected", "observation could not be stored")
        return { source_uuid = src.uuid, status = "error", error = "observation could not be stored (check fetched_at)" }
    end
    set_source_status(src.id, result_status, result_status == "anomaly"
        and string.format("price changed %.1f%% vs last accepted; awaiting admin review", flags.change_pct) or nil)
    return {
        source_uuid = src.uuid,
        status = result_status,
        observation_uuid = uuid,
        accepted = accepted,
        anomaly = not accepted,
        price_ex_vat_minor = nn(ex),
        price_inc_vat_minor = nn(inc),
    }
end

function ShopMarketQueries.recordObservations(ns_id, list)
    local res = { received = #list, inserted = 0, anomalies = 0, sources_updated = 0, failed = 0,
        results = U.arr({}), errors = U.arr({}) }
    for i, item in ipairs(list) do
        local r
        if type(item) ~= "table" then
            r = { source_uuid = U.null, status = "error", error = "observation must be an object" }
        else
            r = record_one(ns_id, item)
        end
        r.index = i - 1
        res.results[#res.results + 1] = r
        if r.status == "error" or r.error then
            res.failed = res.failed + 1
            res.errors[#res.errors + 1] = { index = i - 1, source_uuid = r.source_uuid, error = r.error }
        end
        if r.status ~= "error" then res.sources_updated = res.sources_updated + 1 end
        if r.observation_uuid then res.inserted = res.inserted + 1 end
        if r.anomaly then res.anomalies = res.anomalies + 1 end
    end
    return res
end

function ShopMarketQueries.acceptObservation(ns_id, uuid, user_id)
    local o = db.query([[
        SELECT o.id, o.source_id, o.accepted, o.flags::text AS flags FROM shop_market_observations o
         WHERE o.namespace_id = ? AND o.uuid = ? LIMIT 1
    ]], ns_id, uuid)[1]
    if not o then return nil, U.err(404, "NOT_FOUND", "Observation not found") end
    local flags = U.dec(o.flags, {})
    if flags.anomaly then
        flags.anomaly = nil
        flags.anomaly_accepted = true
        flags.accepted_at = ngx and ngx.utctime and ngx.utctime() or os.date("!%Y-%m-%d %H:%M:%S")
        if user_id then flags.accepted_by = user_id end
    end
    db.query("UPDATE shop_market_observations SET accepted = true, flags = ?::jsonb WHERE id = ?", U.enc(flags), o.id)
    -- If this is the source's latest observation, the source is healthy again.
    local latest = db.query([[
        SELECT id FROM shop_market_observations WHERE source_id = ? ORDER BY fetched_at DESC, id DESC LIMIT 1
    ]], o.source_id)[1]
    if latest and latest.id == o.id then
        db.query([[
            UPDATE shop_market_sources SET last_status = 'ok', last_error = NULL, updated_at = NOW()
             WHERE id = ? AND last_status = 'anomaly'
        ]], o.source_id)
    end
    local r = db.query("SELECT " .. OBS_COLS .. [[, s.uuid AS source_uuid, s.name AS source_name, s.url AS source_url
          FROM shop_market_observations o JOIN shop_market_sources s ON s.id = o.source_id WHERE o.id = ?
    ]], o.id)[1]
    return present_obs(r)
end

-- ---------------------------------------------------------------------------
-- summaries
-- ---------------------------------------------------------------------------

--- Latest accepted, fresh observation per ACTIVE source for a set of products.
-- @return { [product_id] = { obs rows (with source_name, source_url, source_uuid) } }
local function latest_fresh(product_ids)
    local map = {}
    if #product_ids == 0 then return map end
    local rows = db.query([[
        SELECT DISTINCT ON (o.source_id) ]] .. OBS_COLS .. [[,
               s.uuid AS source_uuid, s.name AS source_name, s.url AS source_url
          FROM shop_market_observations o JOIN shop_market_sources s ON s.id = o.source_id
         WHERE o.product_id = ANY(?) AND o.accepted = true AND s.is_active = true AND ]] .. FRESH_SQL .. [[
         ORDER BY o.source_id, o.fetched_at DESC, o.id DESC
    ]], db.array(product_ids))
    for _, r in ipairs(rows) do
        local list = map[r.product_id]
        if not list then
            list = {}
            map[r.product_id] = list
        end
        list[#list + 1] = r
    end
    return map
end

--- Summary over latest-per-source observations (GBP only for prices).
function ShopMarketQueries.summarize(obs_rows)
    local prices, in_stock, freshest = {}, 0, nil
    for _, r in ipairs(obs_rows or {}) do
        local ex = tonumber(r.price_ex_vat_minor)
        if ex and (r.currency or "GBP") == "GBP" then prices[#prices + 1] = ex end
        if IN_STOCK[r.availability] then in_stock = in_stock + 1 end
        if r.fetched_at and (not freshest or tostring(r.fetched_at) > tostring(freshest)) then freshest = r.fetched_at end
    end
    local min, max
    for _, p in ipairs(prices) do
        if not min or p < min then min = p end
        if not max or p > max then max = p end
    end
    return {
        min_ex_vat_minor = nn(min),
        median_ex_vat_minor = nn(ShopMarketQueries.median(prices)),
        max_ex_vat_minor = nn(max),
        sources_in_stock = in_stock,
        sources_total = #(obs_rows or {}),
        priced_sources = #prices,
        freshest_at = nn(freshest),
        fresh_days = FRESH_DAYS,
    }
end

local function sort_obs(list)
    table.sort(list, function(a, b)
        local pa, pb = tonumber(a.price_ex_vat_minor), tonumber(b.price_ex_vat_minor)
        if pa and pb and pa ~= pb then return pa < pb end
        if pa and not pb then return true end
        if pb and not pa then return false end
        return tostring(a.source_name or "") < tostring(b.source_name or "")
    end)
    return list
end

function ShopMarketQueries.productSummary(product_id)
    return ShopMarketQueries.summarize(latest_fresh({ product_id })[product_id] or {})
end

-- ---------------------------------------------------------------------------
-- admin product view
-- ---------------------------------------------------------------------------

function ShopMarketQueries.productDetail(ns_id, uuid, params)
    params = params or {}
    local p = product_by(ns_id, uuid)
    if not p then return nil end
    local av = Stock.forProducts({ p.id })[p.id]
    local sources = db.query("SELECT " .. SOURCE_COLS .. [[
          FROM shop_market_sources s JOIN shop_products p ON p.id = s.product_id
         WHERE s.namespace_id = ? AND s.product_id = ? ORDER BY s.name, s.id
    ]], ns_id, p.id)
    local latest = {}
    local lrows = db.query([[
        SELECT DISTINCT ON (o.source_id) ]] .. OBS_COLS .. [[, (]] .. FRESH_SQL .. [[) AS is_fresh
          FROM shop_market_observations o WHERE o.product_id = ?
         ORDER BY o.source_id, o.fetched_at DESC, o.id DESC
    ]], p.id)
    for _, r in ipairs(lrows) do latest[r.source_id] = r end
    local pending = {}
    for _, r in ipairs(db.query([[
        SELECT source_id, COUNT(*)::int AS n FROM shop_market_observations
         WHERE product_id = ? AND accepted = false GROUP BY source_id
    ]], p.id)) do pending[r.source_id] = r.n end

    local out_sources = {}
    for i, s in ipairs(sources) do
        local doc = present_source(s)
        local l = latest[s.id]
        if l then
            l.source_uuid, l.source_name, l.source_url = s.uuid, s.name, s.url
            local po = present_obs(l)
            po.fresh = l.is_fresh == true
            doc.latest_observation = po
        else
            doc.latest_observation = U.null
        end
        doc.pending_anomalies = pending[s.id] or 0
        out_sources[i] = doc
    end
    local hist_limit = U.clamp(U.int(params.history, 50), 0, 500)
    local history = {}
    if hist_limit > 0 then
        local hrows = db.query("SELECT " .. OBS_COLS .. [[, s.uuid AS source_uuid, s.name AS source_name, s.url AS source_url
              FROM shop_market_observations o JOIN shop_market_sources s ON s.id = o.source_id
             WHERE o.product_id = ? ORDER BY o.fetched_at DESC, o.id DESC LIMIT ?
        ]], p.id, hist_limit)
        for i, r in ipairs(hrows) do history[i] = present_obs(r) end
    end

    return {
        product = {
            uuid = p.uuid,
            sku = p.sku,
            slug = p.slug,
            name = p.name,
            brand = nn(p.brand),
            base_price_minor = tonumber(p.base_price_minor) or 0,
            vat_rate = tonumber(p.vat_rate) or 0.2,
            currency = p.currency or "GBP",
            price_verified = p.price_verified == true,
            stock_qty = tonumber(p.stock_qty) or 0,
            available = av and av.available or (tonumber(p.stock_qty) or 0),
            lead_time_days = tonumber(p.lead_time_days) or 10,
            status = p.status,
        },
        sources = U.arr(out_sources),
        summary = ShopMarketQueries.productSummary(p.id),
        observations = U.arr(history),
    }
end

-- ---------------------------------------------------------------------------
-- overview
-- ---------------------------------------------------------------------------

function ShopMarketQueries.overview(ns_id, params)
    params = params or {}
    local where, vals = { "p.namespace_id = ?" }, { ns_id }
    if U.nz(params.q) then
        local like = "%" .. tostring(params.q):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(p.name ILIKE ? OR p.sku ILIKE ? OR p.brand ILIKE ?)"
        vals[#vals + 1] = like
        vals[#vals + 1] = like
        vals[#vals + 1] = like
    end
    local products = db.query([[
        SELECT p.id, p.uuid, p.sku, p.slug, p.name, p.brand, p.base_price_minor, p.vat_rate, p.price_verified, p.status,
               COUNT(s.id) FILTER (WHERE s.is_active)::int AS total_sources,
               COUNT(s.id)::int AS configured_sources,
               COUNT(s.id) FILTER (WHERE s.is_active AND s.last_status IS NOT NULL
                                    AND s.last_status NOT IN ('ok','anomaly'))::int AS failing_sources,
               (SELECT COUNT(*) FROM shop_market_observations o WHERE o.product_id = p.id AND o.accepted = false)::int
                   AS pending_anomalies,
               (SELECT MAX(o.fetched_at) FROM shop_market_observations o WHERE o.product_id = p.id AND o.accepted = true)
                   AS freshest_at,
               MAX(s.last_checked_at) AS last_checked_at
          FROM shop_products p JOIN shop_market_sources s ON s.product_id = p.id
         WHERE ]] .. table.concat(where, " AND ") .. [[
         GROUP BY p.id ORDER BY p.sku
    ]], unpack(vals))
    local ids = {}
    for i, r in ipairs(products) do ids[i] = r.id end
    local fresh = latest_fresh(ids)

    local stale_filter = U.bool(U.nz(params.stale), nil)
    local diff_gt = tonumber(U.nz(params.diff_gt))
    local anomalies_only = U.bool(U.nz(params.anomalies), false)
    local out = {}
    for _, r in ipairs(products) do
        local s = ShopMarketQueries.summarize(fresh[r.id] or {})
        local ours = tonumber(r.base_price_minor) or 0
        local median = s.median_ex_vat_minor ~= U.null and s.median_ex_vat_minor or nil
        local diff
        if median and median > 0 and ours > 0 then
            diff = math.floor((ours - median) / median * 1000 + 0.5) / 10
        end
        local stale = s.sources_total == 0
        local row = {
            product_uuid = r.uuid,
            sku = r.sku,
            slug = r.slug,
            name = r.name,
            brand = nn(r.brand),
            status = r.status,
            vat_rate = tonumber(r.vat_rate) or 0.2,
            price_verified = r.price_verified == true,
            our_price_ex_vat_minor = ours,
            market_min_ex_vat_minor = s.min_ex_vat_minor,
            market_median_ex_vat_minor = s.median_ex_vat_minor,
            market_max_ex_vat_minor = s.max_ex_vat_minor,
            diff_pct = nn(diff),
            in_stock_sources = s.sources_in_stock,
            fresh_sources = s.sources_total,
            total_sources = tonumber(r.total_sources) or 0,
            configured_sources = tonumber(r.configured_sources) or 0,
            failing_sources = tonumber(r.failing_sources) or 0,
            pending_anomalies = tonumber(r.pending_anomalies) or 0,
            freshest_at = nn(r.freshest_at),
            last_checked_at = nn(r.last_checked_at),
            stale = stale,
        }
        local keep = true
        if stale_filter ~= nil and stale ~= stale_filter then keep = false end
        if diff_gt and (not diff or math.abs(diff) <= diff_gt) then keep = false end
        if anomalies_only and row.pending_anomalies == 0 then keep = false end
        if keep then out[#out + 1] = row end
    end
    return U.arr(out), { total = #out, limit = #out, offset = 0, fresh_days = FRESH_DAYS }
end

-- ---------------------------------------------------------------------------
-- apply price
-- ---------------------------------------------------------------------------

function ShopMarketQueries.applyPrice(ns_id, uuid, body)
    local p = product_by(ns_id, uuid)
    if not p then return nil, U.err(404, "NOT_FOUND", "Product not found") end
    local strategy = U.nz(body.strategy)
    local summary = ShopMarketQueries.productSummary(p.id)
    local value
    if strategy == "median" or strategy == "min" then
        local v = summary[strategy .. "_ex_vat_minor"]
        if v == nil or v == U.null then
            return nil, U.err(409, "NO_MARKET_DATA", "No accepted, fresh GBP market observations for this product")
        end
        value = v
    elseif strategy == "value" then
        value = tonumber(U.nz(body.value_minor))
        if not value or value ~= math.floor(value) or value <= 0 then
            return nil, U.err(400, "VALIDATION_ERROR", "value_minor must be a positive integer (ex VAT, minor units)")
        end
    else
        return nil, U.err(400, "VALIDATION_ERROR", "strategy must be 'median', 'min' or 'value'")
    end
    local previous = tonumber(p.base_price_minor) or 0
    db.query([[
        UPDATE shop_products SET base_price_minor = ?, price_verified = true, updated_at = NOW()
         WHERE id = ? AND namespace_id = ?
    ]], value, p.id, ns_id)
    ngx.log(ngx.NOTICE, "[shop-market] price applied: ", p.sku, " ", previous, " -> ", value, " (", strategy, ")")
    return {
        product_uuid = p.uuid,
        sku = p.sku,
        strategy = strategy,
        previous_price_minor = previous,
        base_price_minor = value,
        price_verified = true,
        summary = summary,
    }
end

-- ---------------------------------------------------------------------------
-- public (agent tool)
-- ---------------------------------------------------------------------------

--- Public market view for product rows (shop_products rows incl. id).
function ShopMarketQueries.publicEntries(products)
    local ids = {}
    for i, p in ipairs(products) do ids[i] = p.id end
    local fresh = latest_fresh(ids)
    local av = Stock.forProducts(ids)
    local out = {}
    for _, p in ipairs(products) do
        local rows = fresh[p.id] or {}
        local ours = tonumber(p.base_price_minor) or 0
        local vat = tonumber(p.vat_rate) or 0.2
        local a = av[p.id]
        local obs = {}
        for _, r in ipairs(sort_obs(rows)) do
            obs[#obs + 1] = {
                source_name = r.source_name,
                url = r.source_url,
                price_ex_vat_minor = nn(tonumber(r.price_ex_vat_minor)),
                price_inc_vat_minor = nn(tonumber(r.price_inc_vat_minor)),
                currency = r.currency,
                availability = r.availability,
                stock_qty = nn(tonumber(r.stock_qty)),
                fetched_at = r.fetched_at,
                method = r.method,
            }
        end
        out[#out + 1] = {
            product = {
                slug = p.slug,
                name = p.name,
                sku = p.sku,
                our_price_ex_vat_minor = ours,
                our_price_inc_vat_minor = round(ours * (1 + vat)),
                currency = p.currency or "GBP",
                price_mode = p.price_mode,
                price_verified = p.price_verified == true,
                availability = Stock.availability(a and a.available or (tonumber(p.stock_qty) or 0),
                    tonumber(p.lead_time_days) or 10),
            },
            summary = ShopMarketQueries.summarize(rows),
            observations = U.arr(obs),
        }
    end
    return U.arr(out)
end

function ShopMarketQueries.publicBySlug(ns_id, slug)
    local p = db.query("SELECT * FROM shop_products WHERE namespace_id = ? AND slug = ? AND status = 'active' LIMIT 1",
        ns_id, slug)[1]
    if not p then return nil end
    return ShopMarketQueries.publicEntries({ p })
end

--- Public entries for product uuids (search hits), keeping the given order.
function ShopMarketQueries.publicByUuids(ns_id, uuids)
    if #uuids == 0 then return U.arr({}) end
    local rows = db.query("SELECT * FROM shop_products WHERE namespace_id = ? AND status = 'active' AND uuid = ANY(?)",
        ns_id, db.array(uuids))
    local by = {}
    for _, r in ipairs(rows) do by[r.uuid] = r end
    local ordered = {}
    for _, u in ipairs(uuids) do
        if by[u] then ordered[#ordered + 1] = by[u] end
    end
    return ShopMarketQueries.publicEntries(ordered)
end

return ShopMarketQueries
