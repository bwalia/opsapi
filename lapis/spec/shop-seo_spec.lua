-- luacheck: max line length 140
-- luacheck: globals ngx
--[[
    Plain-Lua test for product SEO content, photos, delivery settings and the public product shape:
    lib/shop-seo.lua, queries/ShopCatalogQueries.lua (fullProduct, card, listCategories, saveProduct) and
    queries/ShopSettingsQueries.lua (public settings, delivery validation) — DB stubbed, nothing is sent.

    Key rule under test: the admin-only target keyword never appears in a public shape.

    Run from lapis/:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine sh -c \
          'LUA_PATH="/usr/local/openresty/lualib/?.lua;;" LUA_CPATH="/usr/local/openresty/lualib/?.so;;" \
           luajit spec/shop-seo_spec.lua'
]]

package.path = "./?.lua;./lapis/?.lua;/usr/local/openresty/lualib/?.lua;" .. package.path
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath -- cjson

local cjson = require("cjson")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail ~= nil and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

ngx = { -- luacheck: ignore 111
    log = function() end, ERR = 1, WARN = 2, NOTICE = 3, ctx = {}, now = os.time,
    encode_base64 = function(s) return s end,
    timer = { at = function() return true end },
}

local KEYWORD = "Threadripper PRO AI workstation UK"
local SECRET_FR = "station IA Threadripper Belgique"

local S
local function reset()
    S = {
        updates = {}, sql = {},
        product = {
            id = 1, uuid = "p-1", namespace_id = 3, sku = "WS-1", slug = "ws-1", name = "Workstation TR PRO",
            product_type = "workstation", price_mode = "fixed", base_price_minor = 1755500, stock_qty = 3,
            specs = "{}", attributes = "{}", images = '["/img/products/tower.svg"]', tags = "[]", vat_rate = 0.2,
            status = "active", lead_time_days = 10, allow_backorder = true, updated_at = "2026-11-01 10:00:00",
            last_modified = "2026-11-02T09:30:00Z",
            seo = cjson.encode({
                en = { target_keyword = KEYWORD, description = "Build it. From {price} ex VAT.",
                       intro = "Fine-tune 70B models at your desk.", audience = { "University labs", "AI start-ups" },
                       faqs = { { q = "Can I add GPUs later?", a = "Yes, up to four." } } },
                fr = { target_keyword = SECRET_FR, title = "Station IA Threadripper PRO | Workstation" },
            }),
            photos = cjson.encode({
                { url = "/media/tr-front.webp", fallback_url = "/media/tr-front.jpg", width = 1600, height = 1200,
                  alt = { en = "TR PRO tower, front" } },
            }),
        },
        service = false,
        category_seo = cjson.encode({ en = { target_keyword = "AI workstations UK", intro = "Machines for AI." } }),
        settings = nil, -- shop_settings row
    }
end
reset()

local function has(sql, s) return sql:find(s, 1, true) ~= nil end
local NULL = setmetatable({}, { __tostring = function() return "NULL" end })

package.loaded["lapis.db"] = {
    NULL = NULL,
    raw = function(s) return s end,
    escape_literal = function(s) return "'" .. tostring(s) .. "'" end,
    array = function(t) return t end,
    list = function(t) return t end,
    update = function(tbl, fields) S.updates[#S.updates + 1] = { tbl = tbl, fields = fields } end,
    insert = function() return { { id = 1 } } end,
    query = function(sql, ...)
        local a = { ... }
        S.sql[#S.sql + 1] = sql
        if sql == "BEGIN" or sql == "COMMIT" or sql == "ROLLBACK" or has(sql, "SAVEPOINT") then return {} end
        if has(sql, "information_schema.columns") and has(sql, "'photos'") then return { { ["?column?"] = 1 } } end
        if has(sql, "information_schema.columns") then return {} end
        if has(sql, "FROM shop_products p LEFT JOIN shop_categories c") then
            local r = {}
            for k, v in pairs(S.product) do r[k] = v end
            if S.service then r.product_type = "service"; r.stock_qty = 999 end
            return { r }
        end
        if has(sql, "AS manual_cost_minor, si.cost_minor AS supplier_cost_minor") then return { {} } end
        if has(sql, "FROM shop_option_groups WHERE product_id") then return {} end
        if has(sql, "FROM shop_options o") then return {} end
        if has(sql, "FROM shop_rules WHERE product_id") then return {} end
        if has(sql, "FROM shop_stock_reservations") or has(sql, "SELECT p.id, p.stock_qty") then
            return { { id = 1, stock_qty = S.service and 999 or 3, held = 0 } }
        end
        if has(sql, "FROM namespaces WHERE id") then return { { id = 3, name = "Workstation" } } end
        if has(sql, "FROM shop_categories c LEFT JOIN shop_categories pc") then
            return { { uuid = "c-1", slug = "ai-workstations", name = "AI Workstations", seo = S.category_seo,
                       product_count = 4 } }
        end
        -- settings
        if has(sql, "FROM shop_settings WHERE namespace_id") then
            if not S.settings then return {} end
            if has(sql, "delivery_cost_minor") or has(sql, "checkout_enabled") then return { S.settings } end
            return {}
        end
        if has(sql, "INSERT INTO shop_settings") then S.settings = S.settings or { checkout_enabled = false } return {} end
        if has(sql, "UPDATE shop_settings SET delivery") then
            local i = 1
            for col in sql:gmatch("(delivery_[%w_]+) = %?") do S.settings[col] = a[i]; i = i + 1 end
            for col in sql:gmatch("(quote_valid_days) = %?") do S.settings[col] = a[i]; i = i + 1 end
            return {}
        end
        return {}
    end,
}

package.loaded["helper.global"] = { generateUUID = function() return "uuid-" .. tostring(#S.sql) end }
package.loaded["queries.ShopInsightsQueries"] = { snapshotPrices = function() end, recordCartAdd = function() end }

local SEO = require("lib.shop-seo")
local Catalog = require("queries.ShopCatalogQueries")
local Settings = require("queries.ShopSettingsQueries")
local U = require("lib.shop-util")

-- ---------------------------------------------------------------------------
-- lib/shop-seo.lua
-- ---------------------------------------------------------------------------
do
    local doc = SEO.clean({
        en = { target_keyword = "  " .. KEYWORD .. "  ", title = "", description = ("x"):rep(500), junk = 1,
               audience = { "Labs", "", 5, {} }, faqs = { { q = "Q?", a = "A." }, { q = "no answer" } } },
        de = { title = "nein" },
    }, "product")
    check("clean: keeps the keyword trimmed", doc.en.target_keyword == KEYWORD, doc.en.target_keyword)
    check("clean: drops an empty title", doc.en.title == nil)
    check("clean: caps the description", #doc.en.description == 320, #doc.en.description)
    check("clean: drops unknown keys and languages", doc.en.junk == nil and doc.de == nil)
    check("clean: audience keeps strings and numbers only", #doc.en.audience == 2, #doc.en.audience)
    check("clean: a question without an answer is dropped", #doc.en.faqs == 1)
    local cat = SEO.clean({ en = { intro = "Hi", faqs = { { q = "a", a = "b" } } } }, "category")
    check("clean: categories have no FAQs", cat.en.intro == "Hi" and cat.en.faqs == nil)

    local pub = SEO.public(doc, "product", "Workstation")
    check("public: target keyword dropped", pub.en.target_keyword == nil)
    check("public: default title from the keyword", pub.en.title == "Threadripper PRO AI workstation UK | Workstation",
        pub.en.title)
    check("defaultTitle: no doubled brand", SEO.defaultTitle("ai workstation | Workstation", "Workstation")
        == "Ai workstation | Workstation")
    check("public: no keyword, no title → none", SEO.public({ en = { intro = "x" } }, "product", "W").en.title == nil)

    local photos, err = SEO.cleanPhotos({ "/a.webp", { url = "https://cdn.example.com/b.webp", width = "800",
        height = 600, alt = { en = " Front ", de = "x" } } })
    check("photos: strings and objects", photos and #photos == 2 and photos[2].width == 800 and photos[2].alt.en == "Front",
        err)
    check("photos: unknown alt language dropped", photos and photos[2].alt.de == nil)
    local _, bad = SEO.cleanPhotos({ { url = "javascript:alert(1)" } })
    check("photos: a non-http url is refused", bad ~= nil, bad)
    local _, bad2 = SEO.cleanPhotos({ { url = "/a.webp", fallback_url = "data:x" } })
    check("photos: a bad fallback url is refused", bad2 ~= nil, bad2)
    local many = {}
    for i = 1, 13 do many[i] = "/p" .. i .. ".webp" end
    check("photos: at most 12", select(2, SEO.cleanPhotos(many)) ~= nil)
end

-- ---------------------------------------------------------------------------
-- public product shape
-- ---------------------------------------------------------------------------
do
    reset()
    local bundle = Catalog.loadBundle(3, { slug = "ws-1" }, { public = true })
    local full = Catalog.fullProduct(bundle)
    local json = U.enc(full)
    check("product: no target_keyword field", not json:find("target_keyword", 1, true))
    check("product: the English keyword only appears inside the default title",
        select(2, json:gsub(KEYWORD, "")) == 1 and full.seo.en.title == KEYWORD .. " | Workstation", full.seo.en.title)
    check("product: the French keyword never appears (it has its own title)", not json:find(SECRET_FR, 1, true))
    check("product: French title kept", full.seo.fr.title == "Station IA Threadripper PRO | Workstation")
    check("product: intro, audience and FAQs public", full.seo.en.intro and #full.seo.en.audience == 2
        and full.seo.en.faqs[1].q == "Can I add GPUs later?")
    check("product: photos with alt, size and fallback", full.photos[1].url == "/media/tr-front.webp"
        and full.photos[1].fallback_url == "/media/tr-front.jpg" and full.photos[1].width == 1600
        and full.photos[1].alt.en == "TR PRO tower, front")
    check("product: updated_at is the last change (options, price, stock)", full.updated_at == "2026-11-02T09:30:00Z",
        full.updated_at)
    check("product: real stock count", full.availability.qty_available == 3 and full.availability.in_stock == true)

    local doc = Catalog.adminDocument(3, "p-1")
    check("admin document: keeps the keyword", doc.seo.en.target_keyword == KEYWORD)

    S.service = true
    local svc = Catalog.fullProduct(Catalog.loadBundle(3, { slug = "ws-1" }, { public = true }))
    check("service: no stock count (never '999 in stock')", svc.availability.qty_available == cjson.null
        and svc.availability.in_stock == true, U.enc(svc.availability))
    S.service = false

    S.product.stock_qty = 0
    S.product.allow_backorder = false
    local card = Catalog.card(Catalog.normProduct((function()
        local r = {}
        for k, v in pairs(S.product) do r[k] = v end
        return r
    end)()), 0)
    check("card: out of stock and not orderable says so", card.availability.in_stock == false
        and card.availability.backorder == false)
    check("card: photos and updated_at", #card.photos == 1 and card.updated_at == "2026-11-02T09:30:00Z")
    check("card: no keyword", not U.enc(card):find(KEYWORD, 1, true))
end

-- ---------------------------------------------------------------------------
-- categories
-- ---------------------------------------------------------------------------
do
    reset()
    local pub = Catalog.listCategories(3)
    local json = U.enc(pub)
    check("category: public has no target_keyword", not json:find("target_keyword", 1, true))
    check("category: public default title from keyword", pub[1].seo.en.title == "AI workstations UK | Workstation",
        pub[1].seo.en and pub[1].seo.en.title)
    check("category: intro public", pub[1].seo.en.intro == "Machines for AI.")
    local admin = Catalog.listCategories(3, { admin = true })
    check("category: admin keeps the keyword", admin[1].seo.en.target_keyword == "AI workstations UK")
end

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------
do
    reset()
    local s = Settings.get(1)
    local pub = Settings.public(s)
    check("settings: defaults before any row (delivery included, 1-2 + 1-3 days, quotes 30 days)",
        pub.delivery.cost_minor == 0 and pub.delivery.handling_min_days == 1 and pub.delivery.handling_max_days == 2
        and pub.delivery.transit_min_days == 1 and pub.delivery.transit_max_days == 3 and pub.quote_valid_days == 30)
    check("settings: public shape has no addresses or emails", pub.po_bill_to == nil and pub.order_alert_email == nil
        and pub.deal_code_prefix == nil)
    local res, err = Settings.update(1, { delivery_transit_min_days = 5, delivery_transit_max_days = 2 })
    check("settings: min above max refused", res == nil and err and err.code == "VALIDATION_ERROR")
    res, err = Settings.update(1, { delivery_cost_minor = -1 })
    check("settings: negative delivery cost refused", res == nil and err and err.code == "VALIDATION_ERROR")
    res, err = Settings.update(1, { quote_valid_days = 1.5 })
    check("settings: fractional days refused", res == nil and err and err.code == "VALIDATION_ERROR")
    res, err = Settings.update(1, { delivery_cost_minor = 2500, quote_valid_days = 14 })
    check("settings: saved", res and res.delivery_cost_minor == 2500 and res.quote_valid_days == 14,
        err and err.message)
    check("settings: quoteValidDays reads it", Settings.quoteValidDays(1) == 14)
end

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
