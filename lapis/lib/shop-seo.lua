-- luacheck: max line length 140
--[[
    Shop SEO content and product photos (pure: no DB, no nginx)
    ===========================================================

    shop_products.seo / shop_categories.seo (jsonb), one block per language:
        { en = { target_keyword, title, description, intro, audience = { "..." }, faqs = { { q, a } } },
          fr = { ... }, nl = { ... } }
      target_keyword  ADMIN ONLY. The phrase staff want the page to rank for. It feeds the default
                      title (below) and the dashboard's checks; it is never sent by a public endpoint
                      as a field of its own (public() drops it).
      title           <title> override. Empty = "<target keyword> | <brand>" when a keyword is set,
                      else the shop builds one from the product name.
      description     meta description override. "{price}" is replaced by the shop with the live
                      "from" price. Empty = the shop's default.
      intro           2-4 short sentences, results first, shown above the configurator.
      audience        "Who it's for": short list.
      faqs            product-specific questions (the shop adds shared ones).
      Categories use target_keyword, title, description and intro only.

    shop_products.photos (jsonb array), first = main photo:
        { url, fallback_url?, width?, height?, alt = { en?, fr?, nl? } }
      url             the photo (WebP from the dashboard upload), http(s) or a /path
      fallback_url    a JPEG copy for browsers without WebP
      alt             per language; empty = the shop's default "{name} – {key spec}, {view}"
]]

local cjson = require("cjson")

local SEO = {}

SEO.LOCALES = { "en", "fr", "nl" }
SEO.MAX_PHOTOS = 12
SEO.MAX_FAQS = 8
SEO.MAX_AUDIENCE = 8

local LIMITS = { target_keyword = 120, title = 120, description = 320, intro = 1500 }

local function str(v, max)
    if type(v) ~= "string" and type(v) ~= "number" then return nil end
    local s = tostring(v):gsub("[%z\1-\8\11\12\14-\31]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if max and #s > max then
        -- cut on a UTF-8 boundary
        local cut = max
        while cut > 0 do
            local b = s:byte(cut + 1)
            if not b or b < 0x80 or b >= 0xC0 then break end
            cut = cut - 1
        end
        s = s:sub(1, cut)
    end
    return s
end

local function arr(t)
    t = t or {}
    if cjson.array_mt then setmetatable(t, cjson.array_mt) end
    return t
end

local function list_of(v, max_items, max_len)
    local out = {}
    if type(v) ~= "table" then return out end
    for _, item in ipairs(v) do
        local s = str(item, max_len)
        if s then out[#out + 1] = s end
        if #out >= max_items then break end
    end
    return out
end

local function faqs_of(v)
    local out = {}
    if type(v) ~= "table" then return out end
    for _, f in ipairs(v) do
        if type(f) == "table" then
            local q, a = str(f.q, 200), str(f.a, 1200)
            if q and a then out[#out + 1] = { q = q, a = a } end
        end
        if #out >= SEO.MAX_FAQS then break end
    end
    return out
end

--- One language block, cleaned. kind = "product" | "category".
local function clean_block(b, kind)
    if type(b) ~= "table" then return nil end
    local out = {}
    for k, max in pairs(LIMITS) do
        local s = str(b[k], max)
        if s then out[k] = s end
    end
    if kind == "product" then
        local aud = list_of(b.audience, SEO.MAX_AUDIENCE, 80)
        if #aud > 0 then out.audience = aud end
        local faqs = faqs_of(b.faqs)
        if #faqs > 0 then out.faqs = faqs end
    end
    return next(out) and out or nil
end

--- Clean an admin seo document (unknown languages and keys dropped). Returns the table to store.
function SEO.clean(doc, kind)
    kind = kind or "product"
    local out = {}
    if type(doc) ~= "table" then return out end
    for _, loc in ipairs(SEO.LOCALES) do
        local b = clean_block(doc[loc], kind)
        if b then out[loc] = b end
    end
    return out
end

--- The public shape of a stored seo document: target_keyword never leaves OpsAPI.
-- brand: the shop's name, for the default title "<keyword> | <brand>".
function SEO.public(doc, kind, brand)
    kind = kind or "product"
    local out = {}
    if type(doc) ~= "table" then return out end
    for _, loc in ipairs(SEO.LOCALES) do
        local b = clean_block(doc[loc], kind)
        if b then
            local p = { title = b.title, description = b.description, intro = b.intro }
            if not p.title and b.target_keyword and brand then
                p.title = SEO.defaultTitle(b.target_keyword, brand)
            end
            if kind == "product" then
                p.audience = arr(b.audience or {})
                p.faqs = arr(b.faqs or {})
            end
            if next(p) then out[loc] = p end
        end
    end
    return out
end

--- "<Keyword> | <brand>" with the keyword's first letter upper-cased (the main words come first).
function SEO.defaultTitle(keyword, brand)
    local k = str(keyword, LIMITS.target_keyword)
    if not k then return nil end
    k = k:sub(1, 1):upper() .. k:sub(2)
    local b = str(brand, 60)
    -- already ends "| <brand>": keep as typed (a brand word inside the phrase still gets the suffix)
    if not b or k:lower():sub(-#b - 2) == "| " .. b:lower() then return k end
    return k .. " | " .. b
end

local function url_ok(u)
    return type(u) == "string" and (u:match("^https?://[%w%.%-]+") or u:match("^/[^/]")) ~= nil
end

--- Clean an admin photo list. Returns (list) or (nil, message).
function SEO.cleanPhotos(list)
    local out = {}
    if list == nil or list == cjson.null then return arr(out) end
    if type(list) ~= "table" then return nil, "photos must be a list" end
    for i, ph in ipairs(list) do
        if type(ph) == "string" then ph = { url = ph } end
        if type(ph) ~= "table" then return nil, "photo " .. i .. " is invalid" end
        local url = str(ph.url, 1000)
        if not url then return nil, "photo " .. i .. ": url is required" end
        if not url_ok(url) then return nil, "photo " .. i .. ": url must be an http(s) URL or a /path" end
        local p = { url = url }
        local fb = str(ph.fallback_url, 1000)
        if fb then
            if not url_ok(fb) then return nil, "photo " .. i .. ": fallback_url must be an http(s) URL or a /path" end
            p.fallback_url = fb
        end
        local w, h = tonumber(ph.width), tonumber(ph.height)
        if w and h and w >= 1 and h >= 1 and w <= 20000 and h <= 20000 then
            p.width, p.height = math.floor(w), math.floor(h)
        end
        local alt = {}
        if type(ph.alt) == "table" then
            for _, loc in ipairs(SEO.LOCALES) do alt[loc] = str(ph.alt[loc], 250) end
        elseif type(ph.alt) == "string" then
            alt.en = str(ph.alt, 250)
        end
        p.alt = alt
        out[#out + 1] = p
        if #out > SEO.MAX_PHOTOS then return nil, "at most " .. SEO.MAX_PHOTOS .. " photos" end
    end
    return arr(out)
end

--- Stored photos → public list (invalid entries dropped, alt always an object).
function SEO.publicPhotos(list)
    local out = {}
    if type(list) ~= "table" then return arr(out) end
    for _, ph in ipairs(list) do
        if type(ph) == "table" and url_ok(ph.url) then
            local alt = {}
            if type(ph.alt) == "table" then
                for _, loc in ipairs(SEO.LOCALES) do alt[loc] = str(ph.alt[loc], 250) end
            end
            out[#out + 1] = {
                url = ph.url,
                fallback_url = url_ok(ph.fallback_url) and ph.fallback_url or cjson.null,
                width = tonumber(ph.width) or cjson.null,
                height = tonumber(ph.height) or cjson.null,
                alt = alt, -- {} encodes as an object (U.json)
            }
        end
    end
    return arr(out)
end

return SEO
