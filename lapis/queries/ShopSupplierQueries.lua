-- luacheck: max line length 140
--[[
    Shop supplier catalogue sync
    ============================
    Rules (parsing, filter, margin, apply-or-review) live in lib/shop-supplier.lua.
    This module does the database work and fetches feeds.

      suppliers      CRUD; the feed login is encrypted and never returned
      import         a whole price file → items (upsert), daily cost history,
                     items missing from the file marked inactive, obvious
                     product matches linked (pricing left manual), linked
                     products repriced
      reprice        products with pricing_source = 'supplier': cost × (1 + margin);
                     ≤ change_threshold_pct applies now, bigger (or a first price)
                     waits in shop_price_changes for an admin
      fetch / sync   feeds fetched by OpsAPI itself (SSRF-guarded, size-capped),
                     due suppliers synced from the market-sync CronJob
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local Global = require("helper.global")
local U = require("lib.shop-util")
local S = require("lib.shop-supplier")

local Q = {}

local MAX_FEED_BYTES = 25 * 1024 * 1024
local FETCH_SECONDS = 120
local UK_TODAY = "(NOW() AT TIME ZONE 'Europe/London')::date"

local function nz(v) return U.nz(v) end

-- ---------------------------------------------------------------------------
-- suppliers
-- ---------------------------------------------------------------------------

local SUPPLIER_COLS = [[
    id, uuid, namespace_id, name, feed_format, feed_url, feed_options::text AS feed_options, auth_type, auth_username,
    auth_header_name, (auth_secret_encrypted IS NOT NULL) AS has_auth_secret, mapping::text AS mapping,
    filter::text AS filter, prices_include_vat, currency, default_margin_pct::float8 AS default_margin_pct,
    change_threshold_pct::float8 AS change_threshold_pct, update_lead_times, sync_hours, is_active, last_synced_at,
    last_status, last_error, last_summary::text AS last_summary, portal_enabled, contact_email, created_at, updated_at
]]

local function supplier_view(r)
    if not r then return nil end
    local out = {}
    for k, v in pairs(r) do out[k] = v end
    out.id, out.namespace_id = nil, nil
    out.feed_options = U.dec(r.feed_options, {})
    out.mapping = U.dec(r.mapping, {})
    out.filter = U.dec(r.filter, {})
    out.last_summary = U.dec(r.last_summary, U.null)
    out.has_auth_secret = r.has_auth_secret == true
    for _, k in ipairs({ "feed_url", "auth_username", "auth_header_name", "last_synced_at", "last_status", "last_error",
                         "contact_email" }) do
        if out[k] == nil then out[k] = U.null end
    end
    out.item_counts = db.query([[
        SELECT COUNT(*) FILTER (WHERE is_active)::int AS active, COUNT(*)::int AS total,
               (SELECT COUNT(*)::int FROM shop_products p WHERE p.supplier_item_id IN
                   (SELECT id FROM shop_supplier_items WHERE supplier_id = ?)) AS linked
          FROM shop_supplier_items WHERE supplier_id = ?
    ]], r.id, r.id)[1]
    return out
end

local function supplier_row(ns_id, uuid)
    return db.query("SELECT " .. SUPPLIER_COLS .. " FROM shop_suppliers WHERE namespace_id = ? AND uuid = ?", ns_id, uuid)[1]
end
Q.supplierRow = supplier_row

function Q.list(ns_id)
    local rows = db.query("SELECT " .. SUPPLIER_COLS .. " FROM shop_suppliers WHERE namespace_id = ? ORDER BY name", ns_id)
    local out = {}
    for i, r in ipairs(rows) do out[i] = supplier_view(r) end
    return U.arr(out)
end

function Q.get(ns_id, uuid)
    return supplier_view(supplier_row(ns_id, uuid))
end

local function num_in(v, lo, hi)
    local n = tonumber(v)
    if not n or n < lo or n > hi then return nil end
    return n
end

--- Validate a create/update body into column values. partial = update (only given fields).
local function supplier_fields(body, partial)
    if type(body) ~= "table" then return nil, "body must be an object" end
    local f = {}
    if body.name ~= nil or not partial then
        local name = S.trim(body.name)
        if not name or #name > 255 then return nil, "name is required" end
        f.name = name
    end
    if body.feed_format ~= nil or not partial then
        local fmt = body.feed_format or "csv"
        if not S.FORMATS[fmt] then return nil, "feed_format must be csv, json or xml" end
        f.feed_format = fmt
    end
    if body.feed_url ~= nil then
        local url = S.trim(body.feed_url)
        if url and not url:match("^https?://[^%s]+$") then return nil, "feed_url must be an http(s) URL" end
        f.feed_url = url or db.NULL
    end
    if body.feed_options ~= nil then
        if type(body.feed_options) ~= "table" then return nil, "feed_options must be an object" end
        local o = {}
        if body.feed_options.delimiter ~= nil then
            local d = tostring(body.feed_options.delimiter)
            if d == "\\t" or d == "tab" then d = "\t" end
            if #d ~= 1 then return nil, "feed_options.delimiter must be one character" end
            o.delimiter = d
        end
        if body.feed_options.records_path ~= nil then o.records_path = tostring(body.feed_options.records_path):sub(1, 200) end
        if body.feed_options.record_tag ~= nil then o.record_tag = tostring(body.feed_options.record_tag):sub(1, 100) end
        f.feed_options = U.enc(o)
    end
    if body.mapping ~= nil or not partial then
        local m, err = S.validate_mapping(body.mapping)
        if not m then return nil, err end
        f.mapping = U.enc(m)
    end
    if body.filter ~= nil then
        if type(body.filter) ~= "table" then return nil, "filter must be an object" end
        local kws = body.filter.keywords
        if kws ~= nil and type(kws) ~= "table" then return nil, "filter.keywords must be a list" end
        local clean = {}
        for _, k in ipairs(kws or {}) do
            local t = S.trim(k)
            if t then clean[#clean + 1] = t:lower():sub(1, 60) end
        end
        f.filter = U.enc({ keywords = kws and U.arr(clean) or nil, fields = body.filter.fields })
    end
    if body.auth_type ~= nil then
        if not ({ none = true, basic = true, bearer = true, header = true })[body.auth_type] then
            return nil, "auth_type must be none, basic, bearer or header"
        end
        f.auth_type = body.auth_type
    end
    if body.auth_username ~= nil then f.auth_username = S.trim(body.auth_username) or db.NULL end
    if body.auth_header_name ~= nil then
        local h = S.trim(body.auth_header_name)
        if h and not h:match("^[%w%-]+$") then return nil, "auth_header_name must be a header name" end
        f.auth_header_name = h or db.NULL
    end
    -- write-only: omitted = keep, "" = remove
    if body.auth_secret ~= nil then
        f.auth_secret_encrypted = body.auth_secret ~= "" and Global.encryptSecret(tostring(body.auth_secret)) or db.NULL
    end
    for k, range in pairs({ default_margin_pct = { -50, 500 }, change_threshold_pct = { 0, 100 }, sync_hours = { 1, 168 } }) do
        if body[k] ~= nil then
            local n = num_in(body[k], range[1], range[2])
            if not n then return nil, k .. " must be between " .. range[1] .. " and " .. range[2] end
            f[k] = n
        end
    end
    for _, k in ipairs({ "prices_include_vat", "update_lead_times", "is_active" }) do
        if body[k] ~= nil then f[k] = body[k] == true end
    end
    if body.contact_email ~= nil then f.contact_email = S.trim(body.contact_email) or db.NULL end
    return f
end

function Q.create(ns_id, body)
    local f, err = supplier_fields(body, false)
    if not f then return nil, U.err(400, "VALIDATION_ERROR", err) end
    f.uuid = Global.generateUUID()
    f.namespace_id = ns_id
    if not f.filter then f.filter = U.enc(S.DEFAULT_FILTER) end
    db.insert("shop_suppliers", f)
    return Q.get(ns_id, f.uuid)
end

function Q.update(ns_id, uuid, body)
    local r = supplier_row(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Supplier not found") end
    local f, err = supplier_fields(body, true)
    if not f then return nil, U.err(400, "VALIDATION_ERROR", err) end
    if next(f) then
        f.updated_at = db.raw("NOW()")
        db.update("shop_suppliers", f, { id = r.id })
    end
    return Q.get(ns_id, uuid)
end

function Q.delete(ns_id, uuid)
    local r = supplier_row(ns_id, uuid)
    if not r then return nil, U.err(404, "NOT_FOUND", "Supplier not found") end
    -- Linked products keep their current price and go back to manual pricing.
    db.query([[
        UPDATE shop_products SET pricing_source = 'manual', supplier_item_id = NULL, updated_at = NOW()
         WHERE supplier_item_id IN (SELECT id FROM shop_supplier_items WHERE supplier_id = ?)
    ]], r.id)
    db.query("DELETE FROM shop_suppliers WHERE id = ?", r.id)
    return { deleted = true }
end

-- ---------------------------------------------------------------------------
-- pricing
-- ---------------------------------------------------------------------------

local function supersede_pending(product_id)
    db.query("UPDATE shop_price_changes SET status = 'superseded' WHERE product_id = ? AND status = 'pending'", product_id)
end

local function apply_price(ns_id, p, new_price, cost, margin, status, actor, change_uuid)
    db.query([[UPDATE shop_products SET base_price_minor = ?, price_verified = true, updated_at = NOW() WHERE id = ?]],
        new_price, p.id)
    if change_uuid then
        db.query([[UPDATE shop_price_changes SET status = ?, decided_by = ?, decided_at = NOW() WHERE uuid = ?]],
            status, actor or db.NULL, change_uuid)
    else
        supersede_pending(p.id)
        db.query([[
            INSERT INTO shop_price_changes (uuid, namespace_id, product_id, supplier_item_id, old_price_minor, new_price_minor,
                                            cost_minor, margin_pct, change_pct, status, decided_by, decided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ]], Global.generateUUID(), ns_id, p.id, p.supplier_item_id or db.NULL, p.base_price_minor, new_price, cost, margin,
            S.change_pct(p.base_price_minor, new_price) or db.NULL, status, actor or "auto")
    end
    require("queries.ShopInsightsQueries").snapshotPrices(ns_id, { p.id })
end

--- Reprice products linked to supplier items. where_sql filters products (alias p).
-- Returns { applied, pending, unchanged }.
local function reprice(ns_id, where_sql, ...)
    local rows = db.query([[
        SELECT p.id, p.uuid, p.sku, p.name, p.base_price_minor, p.margin_pct::float8 AS margin_pct, p.supplier_item_id,
               p.price_mode, p.pricing_source, c.margin_pct::float8 AS category_margin_pct,
               i.cost_minor, i.lead_time_days AS item_lead_time_days, i.is_active AS item_active,
               s.default_margin_pct::float8 AS supplier_margin_pct, s.change_threshold_pct::float8 AS threshold_pct,
               s.update_lead_times
          FROM shop_products p
          JOIN shop_supplier_items i ON i.id = p.supplier_item_id
          JOIN shop_suppliers s ON s.id = i.supplier_id
          LEFT JOIN shop_categories c ON c.id = p.category_id
         WHERE p.namespace_id = ? AND ]] .. where_sql, ns_id, ...)
    local out = { applied = 0, pending = 0, unchanged = 0, lead_times_updated = 0 }
    for _, p in ipairs(rows) do
        if p.update_lead_times and p.item_active and tonumber(p.item_lead_time_days) then
            local upd = db.query([[UPDATE shop_products SET lead_time_days = ?, updated_at = NOW()
                                   WHERE id = ? AND lead_time_days IS DISTINCT FROM ? RETURNING id]],
                p.item_lead_time_days, p.id, p.item_lead_time_days)
            out.lead_times_updated = out.lead_times_updated + #upd
        end
        if p.pricing_source == "supplier" and p.price_mode ~= "quote_only" and p.item_active then
            local margin = S.margin(p.margin_pct, p.category_margin_pct, p.supplier_margin_pct)
            local new_price = S.sell_price(p.cost_minor, margin)
            local decision = S.decide(p.base_price_minor, new_price, p.threshold_pct)
            if decision == "apply" then
                apply_price(ns_id, p, new_price, p.cost_minor, margin, "applied")
                out.applied = out.applied + 1
            elseif decision == "review" then
                local existing = db.query("SELECT id FROM shop_price_changes WHERE product_id = ? AND status = 'pending'", p.id)[1]
                local pct = S.change_pct(p.base_price_minor, new_price)
                if existing then
                    db.query([[UPDATE shop_price_changes SET old_price_minor = ?, new_price_minor = ?, cost_minor = ?,
                               margin_pct = ?, change_pct = ?, supplier_item_id = ?, created_at = NOW() WHERE id = ?]],
                        p.base_price_minor, new_price, p.cost_minor, margin, pct or db.NULL, p.supplier_item_id, existing.id)
                else
                    db.query([[
                        INSERT INTO shop_price_changes (uuid, namespace_id, product_id, supplier_item_id, old_price_minor,
                                                        new_price_minor, cost_minor, margin_pct, change_pct, status)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending')
                    ]], Global.generateUUID(), ns_id, p.id, p.supplier_item_id, p.base_price_minor, new_price, p.cost_minor,
                        margin, pct or db.NULL)
                end
                out.pending = out.pending + 1
            else
                supersede_pending(p.id)
                out.unchanged = out.unchanged + 1
            end
        end
    end
    return out
end

function Q.repriceProduct(ns_id, product_id)
    return reprice(ns_id, "p.id = ?", product_id)
end

-- ---------------------------------------------------------------------------
-- import
-- ---------------------------------------------------------------------------

local function auto_link(ns_id, item_id, item)
    -- Only an unambiguous match on our SKU or MPN, only for products not already linked; pricing stays manual.
    local rows = db.query([[
        SELECT id FROM shop_products
         WHERE namespace_id = ? AND supplier_item_id IS NULL
           AND (lower(sku) = lower(?) OR (? <> '' AND lower(COALESCE(attributes->>'mpn', specs->>'MPN', '')) = lower(?)))
         LIMIT 2
    ]], ns_id, item.supplier_sku, item.mpn or "", item.mpn or "")
    if #rows ~= 1 then return false end
    db.query("UPDATE shop_products SET supplier_item_id = ?, updated_at = NOW() WHERE id = ?", item_id, rows[1].id)
    return true
end

--- Import a whole price file for a supplier row (from supplier_row). Returns a summary.
function Q.importText(ns_id, sup, text)
    local opts = U.dec(sup.feed_options, {})
    local mapping = U.dec(sup.mapping, {})
    local filter = U.dec(sup.filter, {})
    if not next(filter) then filter = S.DEFAULT_FILTER end
    local recs, perr = S.records(text, sup.feed_format, opts)
    if not recs then return nil, U.err(422, "FEED_UNREADABLE", perr) end
    local summary = { records = #recs, kept = 0, filtered_out = 0, invalid = 0, created = 0, updated = 0, cost_changed = 0,
                      big_cost_changes = 0, deactivated = 0, auto_linked = 0, invalid_examples = {} }
    local seen = {}
    local threshold = tonumber(sup.change_threshold_pct) or 10
    U.tx(function()
        for i, rec in ipairs(recs) do
            local item, why = S.normalise(rec, mapping, { prices_include_vat = sup.prices_include_vat, vat_rate = 0.2 })
            if not item then
                summary.invalid = summary.invalid + 1
                if #summary.invalid_examples < 10 then
                    summary.invalid_examples[#summary.invalid_examples + 1] = "row " .. (i + 1) .. ": " .. why
                end
            elseif not S.matches(item, filter) then
                summary.filtered_out = summary.filtered_out + 1
            elseif not seen[item.supplier_sku] then
                seen[item.supplier_sku] = true
                summary.kept = summary.kept + 1
                local ex = db.query("SELECT id, cost_minor FROM shop_supplier_items WHERE supplier_id = ? AND supplier_sku = ?",
                    sup.id, item.supplier_sku)[1]
                local id
                local vals = {
                    mpn = item.mpn or db.NULL, ean = item.ean or db.NULL, name = item.name, brand = item.brand or db.NULL,
                    category = item.category or db.NULL, cost_minor = item.cost_minor, rrp_minor = item.rrp_minor or db.NULL,
                    currency = sup.currency or "GBP", stock_qty = item.stock_qty or db.NULL,
                    in_stock = item.in_stock == nil and db.NULL or item.in_stock,
                    lead_time_days = item.lead_time_days or db.NULL, url = item.url or db.NULL, is_active = true,
                    last_seen_at = db.raw("NOW()"), updated_at = db.raw("NOW()"),
                }
                if ex then
                    id = ex.id
                    local old = tonumber(ex.cost_minor)
                    if old ~= item.cost_minor then
                        vals.previous_cost_minor = old
                        vals.cost_changed_at = db.raw("NOW()")
                        summary.cost_changed = summary.cost_changed + 1
                        local pct = S.change_pct(old, item.cost_minor)
                        if pct and math.abs(pct) > threshold then summary.big_cost_changes = summary.big_cost_changes + 1 end
                    end
                    db.update("shop_supplier_items", vals, { id = id })
                    summary.updated = summary.updated + 1
                else
                    vals.uuid = Global.generateUUID()
                    vals.namespace_id = ns_id
                    vals.supplier_id = sup.id
                    vals.supplier_sku = item.supplier_sku
                    id = db.insert("shop_supplier_items", vals, "id")[1].id
                    summary.created = summary.created + 1
                    if auto_link(ns_id, id, item) then summary.auto_linked = summary.auto_linked + 1 end
                end
                db.query([[
                    INSERT INTO shop_supplier_price_history (supplier_item_id, day, cost_minor, stock_qty)
                    VALUES (?, ]] .. UK_TODAY .. [[, ?, ?)
                    ON CONFLICT (supplier_item_id, day) DO UPDATE SET cost_minor = EXCLUDED.cost_minor,
                        stock_qty = EXCLUDED.stock_qty, recorded_at = NOW()
                ]], id, item.cost_minor, item.stock_qty or db.NULL)
            end
        end
        -- A full file: anything not in it is no longer offered.
        local skus = {}
        for sku in pairs(seen) do skus[#skus + 1] = sku end
        local gone = db.query([[
            UPDATE shop_supplier_items SET is_active = false, updated_at = NOW()
             WHERE supplier_id = ? AND is_active AND NOT (supplier_sku = ANY(?)) RETURNING id
        ]], sup.id, db.array(#skus > 0 and skus or { "" }))
        summary.deactivated = #gone
        return true
    end)
    summary.pricing = reprice(ns_id, "i.supplier_id = ?", sup.id)
    summary.invalid_examples = U.arr(summary.invalid_examples)
    return summary
end

local function finish(sup, ok, summary_or_err)
    if ok then
        db.query([[UPDATE shop_suppliers SET last_synced_at = NOW(), last_status = 'ok', last_error = NULL,
                   last_summary = ?::jsonb, updated_at = NOW() WHERE id = ?]], U.enc(summary_or_err), sup.id)
    else
        db.query([[UPDATE shop_suppliers SET last_synced_at = NOW(), last_status = 'error', last_error = ?, updated_at = NOW()
                   WHERE id = ?]], tostring(summary_or_err):sub(1, 1000), sup.id)
    end
end

--- Admin upload (the raw file is the request body).
function Q.importUpload(ns_id, uuid, text)
    local sup = supplier_row(ns_id, uuid)
    if not sup then return nil, U.err(404, "NOT_FOUND", "Supplier not found") end
    if not text or #text == 0 then return nil, U.err(400, "EMPTY_FILE", "The file is empty") end
    if #text > MAX_FEED_BYTES then return nil, U.err(413, "FILE_TOO_LARGE", "Files are limited to 25 MB") end
    local summary, err = Q.importText(ns_id, sup, text)
    finish(sup, summary ~= nil, summary or err.message)
    if not summary then return nil, err end
    return summary
end

--- Fetch the supplier's feed URL (SSRF-guarded) and import it.
function Q.syncOne(ns_id, sup)
    if not nz(sup.feed_url) then return nil, U.err(409, "NO_FEED_URL", "This supplier has no feed URL — upload a file instead") end
    -- one run at a time per supplier (a stuck run is retried after 30 minutes)
    local claimed = db.query([[UPDATE shop_suppliers SET last_status = 'running', updated_at = NOW()
                                WHERE id = ? AND (last_status IS DISTINCT FROM 'running' OR updated_at < NOW() - interval '30 minutes')
                                RETURNING id]], sup.id)
    if #claimed == 0 then return nil, U.err(409, "SYNC_RUNNING", "A sync for this supplier is already running") end
    local headers = { ["Accept"] = "*/*", ["User-Agent"] = "WorkstationShop-SupplierSync/1" }
    local secret
    if sup.auth_type ~= "none" then
        local row = db.query("SELECT auth_secret_encrypted FROM shop_suppliers WHERE id = ?", sup.id)[1]
        if row and row.auth_secret_encrypted then
            local ok, pw = pcall(Global.decryptSecret, row.auth_secret_encrypted)
            if ok then secret = pw end
        end
        if not secret then
            finish(sup, false, "The feed needs a login but no password/token is saved")
            return nil, U.err(409, "AUTH_MISSING", "The feed needs a login but no password/token is saved")
        end
        if sup.auth_type == "basic" then
            headers["Authorization"] = "Basic " .. ngx.encode_base64((sup.auth_username or "") .. ":" .. secret)
        elseif sup.auth_type == "bearer" then
            headers["Authorization"] = "Bearer " .. secret
        else
            headers[sup.auth_header_name or "X-API-Key"] = secret
        end
    end
    local Webhooks = require("lib.outbound-webhooks")
    local res, ferr = Webhooks.request(sup.feed_url, { headers = headers }, {
        allow_http = true, allow_private = U.env("SHOP_SUPPLIER_ALLOW_PRIVATE") == "true",
        timeout_ms = 60000, deadline = ngx.now() + FETCH_SECONDS,
    })
    if not res then
        finish(sup, false, "Could not fetch the feed: " .. tostring(ferr))
        return nil, U.err(502, "FEED_FETCH_FAILED", "Could not fetch the feed: " .. tostring(ferr))
    end
    if res.status ~= 200 then
        local msg = "The feed answered HTTP " .. res.status .. (res.status == 401 and " (check the login)" or "")
        finish(sup, false, msg)
        return nil, U.err(502, "FEED_FETCH_FAILED", msg)
    end
    if #(res.body or "") > MAX_FEED_BYTES then
        finish(sup, false, "The feed is larger than 25 MB")
        return nil, U.err(413, "FEED_TOO_LARGE", "The feed is larger than 25 MB")
    end
    local summary, err = Q.importText(ns_id, sup, res.body)
    finish(sup, summary ~= nil, summary or err.message)
    if not summary then return nil, err end
    return summary
end

function Q.syncNow(ns_id, uuid)
    local sup = supplier_row(ns_id, uuid)
    if not sup then return nil, U.err(404, "NOT_FOUND", "Supplier not found") end
    return Q.syncOne(ns_id, sup)
end

--- Sync every active supplier with a feed URL whose last sync is older than its sync_hours (CronJob).
function Q.syncDue(ns_id)
    local rows = db.query("SELECT " .. SUPPLIER_COLS .. [[ FROM shop_suppliers
         WHERE namespace_id = ? AND is_active AND feed_url IS NOT NULL
           AND (last_synced_at IS NULL OR last_synced_at < NOW() - make_interval(hours => sync_hours))
         ORDER BY last_synced_at NULLS FIRST]], ns_id)
    local out = {}
    for _, sup in ipairs(rows) do
        local summary, err = Q.syncOne(ns_id, sup)
        out[#out + 1] = { supplier = sup.name, ok = summary ~= nil, summary = summary or U.null,
                          error = err and err.message or U.null }
    end
    return U.arr(out)
end

-- ---------------------------------------------------------------------------
-- items + links
-- ---------------------------------------------------------------------------

function Q.items(ns_id, uuid, params)
    params = params or {}
    local sup = supplier_row(ns_id, uuid)
    if not sup then return nil, U.err(404, "NOT_FOUND", "Supplier not found") end
    local limit = U.clamp(U.int(params.limit, 50), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "i.supplier_id = ?" }, { sup.id }
    if nz(params.q) then
        where[#where + 1] = "(i.supplier_sku ILIKE ? OR i.name ILIKE ? OR i.mpn ILIKE ?)"
        local like = "%" .. tostring(params.q):sub(1, 200):gsub("[%%_\\]", "\\%0") .. "%"
        vals[#vals + 1], vals[#vals + 2], vals[#vals + 3] = like, like, like
    end
    if params.linked == "true" then where[#where + 1] = "p.id IS NOT NULL" end
    if params.linked == "false" then where[#where + 1] = "p.id IS NULL" end
    if params.active ~= "all" then where[#where + 1] = "i.is_active" end
    if params.changed == "true" then
        where[#where + 1] = "i.cost_changed_at > NOW() - interval '7 days'"
    end
    vals[#vals + 1], vals[#vals + 2] = limit, offset
    local rows = db.query([[
        SELECT i.uuid, i.supplier_sku, i.mpn, i.name, i.brand, i.category, i.cost_minor, i.previous_cost_minor, i.rrp_minor,
               i.stock_qty, i.in_stock, i.lead_time_days, i.url, i.is_active, i.last_seen_at, i.cost_changed_at,
               CASE WHEN i.previous_cost_minor > 0 THEN round((i.cost_minor - i.previous_cost_minor) * 100.0
                    / i.previous_cost_minor, 2)::float8 END AS cost_change_pct,
               p.uuid AS product_uuid, p.sku AS product_sku, p.name AS product_name, p.pricing_source,
               p.base_price_minor AS product_price_minor, p.margin_pct::float8 AS product_margin_pct,
               COUNT(*) OVER() AS total
          FROM shop_supplier_items i LEFT JOIN shop_products p ON p.supplier_item_id = i.id
         WHERE ]] .. table.concat(where, " AND ") .. [[
         ORDER BY (i.cost_changed_at > NOW() - interval '7 days') DESC NULLS LAST, i.name
         LIMIT ? OFFSET ?
    ]], unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    for _, r in ipairs(rows) do
        r.total = nil
        for _, k in ipairs({ "mpn", "brand", "category", "previous_cost_minor", "rrp_minor", "stock_qty", "in_stock",
                             "lead_time_days", "url", "cost_changed_at", "cost_change_pct", "product_uuid", "product_sku",
                             "product_name", "pricing_source", "product_price_minor", "product_margin_pct" }) do
            if r[k] == nil then r[k] = U.null end
        end
    end
    return U.arr(rows), { total = total, limit = limit, offset = offset }
end

function Q.itemHistory(ns_id, item_uuid)
    local item = db.query("SELECT id FROM shop_supplier_items WHERE namespace_id = ? AND uuid = ?", ns_id, item_uuid)[1]
    if not item then return nil end
    return U.arr(db.query([[SELECT day::text AS day, cost_minor, stock_qty FROM shop_supplier_price_history
                             WHERE supplier_item_id = ? AND day > ]] .. UK_TODAY .. [[ - 365 ORDER BY day]], item.id))
end

--- Link a supplier item to one of our products (or unlink with product_uuid = null).
-- body: { product_uuid, pricing_source?: "supplier"|"manual", margin_pct? (null clears) }
function Q.link(ns_id, item_uuid, body)
    body = type(body) == "table" and body or {}
    local item = db.query("SELECT id FROM shop_supplier_items WHERE namespace_id = ? AND uuid = ?", ns_id, item_uuid)[1]
    if not item then return nil, U.err(404, "NOT_FOUND", "Supplier item not found") end
    if body.product_uuid == nil or body.product_uuid == U.null or body.product_uuid == "" then
        db.query([[UPDATE shop_products SET supplier_item_id = NULL, pricing_source = 'manual', updated_at = NOW()
                   WHERE supplier_item_id = ?]], item.id)
        return { linked = false }
    end
    local p = db.query("SELECT id, supplier_item_id FROM shop_products WHERE namespace_id = ? AND uuid = ?", ns_id,
        body.product_uuid)[1]
    if not p then return nil, U.err(404, "PRODUCT_NOT_FOUND", "Product not found") end
    local pricing = body.pricing_source or "manual"
    if pricing ~= "supplier" and pricing ~= "manual" then
        return nil, U.err(400, "VALIDATION_ERROR", "pricing_source must be supplier or manual")
    end
    local margin = db.NULL
    if body.margin_pct ~= nil and body.margin_pct ~= U.null then
        margin = num_in(body.margin_pct, -50, 500)
        if not margin then return nil, U.err(400, "VALIDATION_ERROR", "margin_pct must be between -50 and 500") end
    end
    -- one product per supplier item
    db.query("UPDATE shop_products SET supplier_item_id = NULL, pricing_source = 'manual' WHERE supplier_item_id = ? AND id <> ?",
        item.id, p.id)
    db.query([[UPDATE shop_products SET supplier_item_id = ?, pricing_source = ?, margin_pct = ?, updated_at = NOW() WHERE id = ?]],
        item.id, pricing, margin, p.id)
    if pricing == "manual" then supersede_pending(p.id) end
    return { linked = true, pricing_source = pricing, pricing = Q.repriceProduct(ns_id, p.id) }
end

-- ---------------------------------------------------------------------------
-- price changes (approvals)
-- ---------------------------------------------------------------------------

function Q.priceChanges(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 50), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "c.namespace_id = ?" }, { ns_id }
    if nz(params.status) then
        where[#where + 1] = "c.status = ?"
        vals[#vals + 1] = params.status
    end
    vals[#vals + 1], vals[#vals + 2] = limit, offset
    local rows = db.query([[
        SELECT c.uuid, c.old_price_minor, c.new_price_minor, c.cost_minor, c.margin_pct::float8 AS margin_pct,
               c.change_pct::float8 AS change_pct, c.status, c.decided_by, c.decided_at, c.created_at,
               p.uuid AS product_uuid, p.sku AS product_sku, p.name AS product_name, p.base_price_minor AS current_price_minor,
               i.supplier_sku, s.name AS supplier_name, COUNT(*) OVER() AS total
          FROM shop_price_changes c
          JOIN shop_products p ON p.id = c.product_id
          LEFT JOIN shop_supplier_items i ON i.id = c.supplier_item_id
          LEFT JOIN shop_suppliers s ON s.id = i.supplier_id
         WHERE ]] .. table.concat(where, " AND ") .. [[
         ORDER BY (c.status = 'pending') DESC, c.created_at DESC
         LIMIT ? OFFSET ?
    ]], unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    for _, r in ipairs(rows) do
        r.total = nil
        for _, k in ipairs({ "change_pct", "decided_by", "decided_at", "supplier_sku", "supplier_name" }) do
            if r[k] == nil then r[k] = U.null end
        end
    end
    return U.arr(rows), { total = total, limit = limit, offset = offset }
end

function Q.decide(ns_id, uuid, approve, actor)
    local c = db.query([[SELECT c.*, p.base_price_minor, p.supplier_item_id AS product_supplier_item_id
                          FROM shop_price_changes c JOIN shop_products p ON p.id = c.product_id
                         WHERE c.namespace_id = ? AND c.uuid = ? FOR UPDATE OF c]], ns_id, uuid)[1]
    if not c then return nil, U.err(404, "NOT_FOUND", "Price change not found") end
    if c.status ~= "pending" then
        return nil, U.err(409, "NOT_PENDING", "This price change was already " .. c.status)
    end
    if approve then
        apply_price(ns_id, { id = c.product_id, base_price_minor = c.base_price_minor, supplier_item_id = c.supplier_item_id },
            tonumber(c.new_price_minor), tonumber(c.cost_minor), tonumber(c.margin_pct), "approved", actor, c.uuid)
    else
        db.query("UPDATE shop_price_changes SET status = 'rejected', decided_by = ?, decided_at = NOW() WHERE id = ?",
            actor or db.NULL, c.id)
    end
    local out = Q.priceChanges(ns_id, { status = approve and "approved" or "rejected", limit = 200 })
    for _, r in ipairs(out) do if r.uuid == uuid then return r end end
    return { uuid = uuid, status = approve and "approved" or "rejected" }
end

return Q
