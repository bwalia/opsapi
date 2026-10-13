-- luacheck: max line length 140
--[[
    Supplier catalogue — pure rules (no nginx, no DB)
    =================================================
    Turns a supplier's price file (CSV, JSON or XML) into normalised items,
    keeps only the NVIDIA-based ones, and decides what each supplier cost
    means for our selling price. Unit tested by spec/shop-supplier-test.lua.

      records(text, format, opts)   → { {field = value, …}, … }   (raw rows)
      normalise(row, mapping, opts) → item | nil, reason
      matches(item, filter)         → bool   (NVIDIA keyword filter)
      margin(product, category, supplier) → %
      sell_price(cost, margin)      → pence (ex VAT)
      decide(old, new, threshold)   → "none" | "apply" | "review"

    Money is integer pence. Supplier costs are stored ex VAT.
]]

local M = {}

M.FORMATS = { csv = true, json = true, xml = true }
M.FIELDS = { "supplier_sku", "mpn", "name", "brand", "category", "cost", "rrp", "stock", "lead_time_days", "url", "ean" }

--- Default filter: keep items whose brand, name or category mention an NVIDIA GPU or NVIDIA system.
M.DEFAULT_FILTER = {
    keywords = { "nvidia", "rtx", "quadro", "geforce", "dgx", "tesla", "a100", "h100", "h200", "b200", "b300", "gb200",
                 "gb300", "l40", "l4 ", "a6000", "a5000", "a4000", "grace", "blackwell", "hopper", "ada lovelace" },
    fields = { "brand", "name", "category" },
}

local function trim(s)
    if s == nil then return nil end
    s = tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end
M.trim = trim

-- ---------------------------------------------------------------------------
-- parsing
-- ---------------------------------------------------------------------------

--- RFC 4180 CSV: quoted fields, "" escapes, commas/newlines inside quotes, CRLF or LF.
function M.csv_rows(text, delim)
    delim = delim or ","
    local rows, row, field = {}, {}, {}
    local i, n, in_quotes = 1, #text, false
    if text:sub(1, 3) == "\239\187\191" then i = 4 end -- UTF-8 BOM
    while i <= n do
        local c = text:sub(i, i)
        if in_quotes then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then
                    field[#field + 1] = '"'
                    i = i + 1
                else
                    in_quotes = false
                end
            else
                field[#field + 1] = c
            end
        elseif c == '"' then
            in_quotes = true
        elseif c == delim then
            row[#row + 1] = table.concat(field)
            field = {}
        elseif c == "\n" or c == "\r" then
            if c == "\r" and text:sub(i + 1, i + 1) == "\n" then i = i + 1 end
            row[#row + 1] = table.concat(field)
            field = {}
            rows[#rows + 1] = row
            row = {}
        else
            field[#field + 1] = c
        end
        i = i + 1
    end
    if #field > 0 or #row > 0 then
        row[#row + 1] = table.concat(field)
        rows[#rows + 1] = row
    end
    -- drop blank lines
    local out = {}
    for _, r in ipairs(rows) do
        if not (#r == 1 and r[1]:match("^%s*$")) then out[#out + 1] = r end
    end
    return out
end

local function csv_records(text, opts)
    local rows = M.csv_rows(text, opts.delimiter)
    if #rows < 1 then return {} end
    local header = rows[1]
    local out = {}
    for r = 2, #rows do
        local rec = {}
        for c, h in ipairs(header) do rec[trim(h) or ("col" .. c)] = rows[r][c] end
        out[#out + 1] = rec
    end
    return out
end

local function json_records(text, opts)
    local cjson = require("cjson.safe")
    local doc = cjson.decode(text)
    if doc == nil then return nil, "the file is not valid JSON" end
    local node = doc
    if opts.records_path and opts.records_path ~= "" then
        for part in tostring(opts.records_path):gmatch("[^%.]+") do
            if type(node) ~= "table" then return nil, "records_path not found: " .. opts.records_path end
            node = node[part]
        end
    end
    if type(node) ~= "table" or (#node == 0 and next(node) ~= nil) then
        return nil, "expected a list of records" .. (opts.records_path and (" at " .. opts.records_path) or "")
    end
    local out = {}
    for _, rec in ipairs(node) do
        if type(rec) == "table" then
            local flat = {}
            for k, v in pairs(rec) do
                if type(v) ~= "table" and v ~= cjson.null then flat[k] = tostring(v) end
            end
            out[#out + 1] = flat
        end
    end
    return out
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local function xml_text(s)
    s = s:gsub("^%s*<!%[CDATA%[(.-)%]%]>%s*$", "%1")
    s = s:gsub("&(#?x?%w+);", function(e)
        if ENTITIES[e] then return ENTITIES[e] end
        local hex = e:match("^#x(%x+)$")
        local dec = e:match("^#(%d+)$")
        local code = hex and tonumber(hex, 16) or (dec and tonumber(dec))
        if code and code < 128 then return string.char(code) end
        return "&" .. e .. ";"
    end)
    return s
end

--- Flat XML: each <record_tag> holds simple child elements (<Name>…</Name>); attributes are ignored.
local function xml_records(text, opts)
    local tag = opts.record_tag
    if not tag or not tag:match("^[%w_:%-]+$") then return nil, "record_tag (the XML element of one product) is required" end
    local out = {}
    local esc = tag:gsub("%-", "%%-")
    for body in text:gmatch("<" .. esc .. "[%s>].-</" .. esc .. ">") do
        local inner = body:match("^<[^>]*>(.*)</[^>]*>$") or ""
        local rec = {}
        for name, value in inner:gmatch("<([%w_:%-]+)[^>/]*>(.-)</%1>") do
            rec[name] = xml_text(value)
        end
        for name in inner:gmatch("<([%w_:%-]+)[^>]*/>") do rec[name] = rec[name] or "" end
        out[#out + 1] = rec
    end
    return out
end

--- Parse a whole file into raw records. opts: { delimiter, records_path, record_tag }.
function M.records(text, format, opts)
    opts = opts or {}
    if type(text) ~= "string" or text == "" then return nil, "the file is empty" end
    if format == "csv" then return csv_records(text, opts) end
    if format == "json" then return json_records(text, opts) end
    if format == "xml" then return xml_records(text, opts) end
    return nil, "format must be csv, json or xml"
end

-- ---------------------------------------------------------------------------
-- values
-- ---------------------------------------------------------------------------

--- "£1,234.56", "1234.5", "1.234,56 €", "GBP 99" → pence. Nil when there's no positive price.
function M.money(v)
    v = trim(v)
    if not v then return nil end
    local s = v:gsub("[£$€]", ""):gsub("%a", ""):gsub("%s", "")
    if s == "" then return nil end
    -- European "1.234,56": comma is the decimal mark when it is the last separator with 1–2 digits after it
    if s:match(",%d%d?$") and not s:match("%.%d%d?$") then
        s = s:gsub("%.", ""):gsub(",", ".")
    else
        s = s:gsub(",", "")
    end
    local n = tonumber(s)
    if not n or n <= 0 then return nil end
    return math.floor(n * 100 + 0.5)
end

--- Stock: a number, or words. Returns qty (number) or nil when unknown; "in stock" without a number → nil qty, in_stock true.
function M.stock(v)
    v = trim(v)
    if not v then return nil, nil end
    local n = tonumber((v:gsub("[,%s]", "")))
    if n then return math.max(0, math.floor(n)), n > 0 end
    local l = v:lower()
    local lead = l:match("(%d+)%+") or l:match(">%s*(%d+)") or l:match("^(%d+)")
    if lead then return tonumber(lead), true end
    if l:find("out of stock", 1, true) or l:find("no stock", 1, true) or l == "0" or l:find("discontinued", 1, true) then
        return 0, false
    end
    if l:find("in stock", 1, true) or l:find("available", 1, true) then return nil, true end
    return nil, nil
end

--- Lead time in days from "5", "3-5 days", "2 weeks", "10 working days". Takes the upper end of a range.
function M.lead_days(v)
    v = trim(v)
    if not v then return nil end
    local l = v:lower()
    local nums = {}
    for d in l:gmatch("%d+") do nums[#nums + 1] = tonumber(d) end
    if #nums == 0 then return nil end
    local n = nums[#nums]
    if l:find("week", 1, true) then n = n * 7 end
    if n < 0 or n > 365 then return nil end
    return math.floor(n)
end

-- ---------------------------------------------------------------------------
-- normalise + filter
-- ---------------------------------------------------------------------------

--- One raw record → item. mapping: { supplier_sku = "Part No", cost = "Trade Price", … } (file column names).
-- opts: { prices_include_vat, vat_rate }. Returns item or nil, reason.
function M.normalise(rec, mapping, opts)
    opts = opts or {}
    local function get(field)
        local col = mapping[field]
        if not col then return nil end
        return trim(rec[col])
    end
    local sku = get("supplier_sku")
    if not sku then return nil, "no supplier SKU" end
    local name = get("name")
    if not name then return nil, "no name" end
    local cost = M.money(get("cost"))
    if not cost then return nil, "no cost price" end
    local rrp = M.money(get("rrp"))
    if opts.prices_include_vat then
        local rate = tonumber(opts.vat_rate) or 0.2
        cost = math.floor(cost / (1 + rate) + 0.5)
        if rrp then rrp = math.floor(rrp / (1 + rate) + 0.5) end
    end
    local qty, in_stock = M.stock(get("stock"))
    local item = {
        supplier_sku = sku:sub(1, 120),
        mpn = (get("mpn") or ""):sub(1, 120),
        ean = (get("ean") or ""):sub(1, 32),
        name = name:sub(1, 500),
        brand = (get("brand") or ""):sub(1, 120),
        category = (get("category") or ""):sub(1, 255),
        cost_minor = cost,
        rrp_minor = rrp,
        stock_qty = qty,
        in_stock = in_stock,
        lead_time_days = M.lead_days(get("lead_time_days")),
        url = (get("url") or ""):sub(1, 1000),
    }
    for _, k in ipairs({ "mpn", "ean", "brand", "category", "url" }) do
        if item[k] == "" then item[k] = nil end
    end
    return item
end

--- Keep only items that mention one of the filter keywords (case-insensitive) in the chosen fields.
function M.matches(item, filter)
    filter = filter or M.DEFAULT_FILTER
    local kws = filter.keywords or M.DEFAULT_FILTER.keywords
    if #kws == 0 then return true end
    local fields = filter.fields or M.DEFAULT_FILTER.fields
    local hay = {}
    for _, f in ipairs(fields) do hay[#hay + 1] = tostring(item[f] or "") end
    local text = " " .. table.concat(hay, " "):lower() .. " "
    for _, kw in ipairs(kws) do
        if text:find(tostring(kw):lower(), 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- pricing
-- ---------------------------------------------------------------------------

--- First set margin wins: product, then category, then the supplier's default.
function M.margin(product_pct, category_pct, supplier_pct)
    -- not ipairs: it stops at the first nil, and an unset product margin is nil
    local candidates = { product_pct, category_pct, supplier_pct }
    for i = 1, 3 do
        local n = tonumber(candidates[i])
        if n then return n end
    end
    return 15
end

--- Our price ex VAT = cost × (1 + margin %), to the penny.
function M.sell_price(cost_minor, margin_pct)
    cost_minor = tonumber(cost_minor) or 0
    if cost_minor <= 0 then return nil end
    return math.floor(cost_minor * (1 + (tonumber(margin_pct) or 0) / 100) + 0.5)
end

function M.change_pct(old, new)
    old, new = tonumber(old) or 0, tonumber(new) or 0
    if old <= 0 then return nil end
    return (new - old) / old * 100
end

--- "none" (same price), "apply" (small change, apply now) or "review" (first price or a change over the threshold).
function M.decide(old_price, new_price, threshold_pct)
    old_price, new_price = tonumber(old_price) or 0, tonumber(new_price)
    if not new_price or new_price <= 0 then return "none" end
    if old_price == new_price then return "none" end
    if old_price <= 0 then return "review" end
    local pct = math.abs(M.change_pct(old_price, new_price))
    if pct > (tonumber(threshold_pct) or 10) then return "review" end
    return "apply"
end

--- Validate a supplier's column mapping. Returns clean mapping or nil, message.
function M.validate_mapping(mapping)
    if type(mapping) ~= "table" then return nil, "mapping must be an object of field → column name" end
    local allowed, out = {}, {}
    for _, f in ipairs(M.FIELDS) do allowed[f] = true end
    for k, v in pairs(mapping) do
        if not allowed[k] then return nil, "unknown mapping field: " .. tostring(k) end
        if type(v) ~= "string" or trim(v) == nil or #v > 120 then return nil, "mapping." .. k .. " must be a column name" end
        out[k] = trim(v)
    end
    for _, req in ipairs({ "supplier_sku", "name", "cost" }) do
        if not out[req] then return nil, "mapping." .. req .. " is required" end
    end
    return out
end

return M
