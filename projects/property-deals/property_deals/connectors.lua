-- Data connectors (SPEC §3.6): one adapter interface, so a workspace can plug in
-- its own sources. Free/open adapters are real; paid feeds are config-only
-- stubs (use their CSV export until an adapter is written). We only call
-- official APIs — no scraping.
--
--   kind             what                                   config                      secret
--   epc              EPC register (domestic certificates)    base_url?, email            API key
--   price_paid       HM Land Registry Price Paid             base_url?                   —
--   companies_house  Companies House (Ltd/SPV buyers, lead   base_url?                   API key
--                    news watch, new property companies)
--   postcodes        postcode → lat/lng (postcodes.io)       base_url?                   —
--   csv              auction catalogues, agent feeds         record_type?                —
--   ntfy             staff alerts (open-source push)         base_url?, topic_prefix     access token?
--   telegram         staff alerts (Telegram bot)             base_url?                   bot token
--   sms_gateway      staff texts from your own Android phone base_url, username         password
--                    (Android SMS Gateway, open source)
--   propertydata, searchland, streetdata, homedata          base_url?                   API key   (stubs)
--
-- Adapters return records for property_deals_market_records:
--   { record_type, external_id, address, postcode, lat?, lng?, property_type?, tenure?, bedrooms?, price?,
--     event_date?, epc_rating?, status?, cash_only?, url?, data }
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local H = require("property_deals.http")
local Box = require("helper.secret-box")

local C = {}

local PURPOSE = "property_deals_connector"

local function null(v) return v == nil or v == db.NULL end
local function base(conn, default)
    local cfg = U.json(conn and conn.config) or {}
    return ((type(cfg.base_url) == "string" and cfg.base_url ~= "" and cfg.base_url) or default):gsub("/+$", "")
end
local function pc(s) return s and tostring(s):upper():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or nil end

-- ---------------------------------------------------------------------------
-- Adapters
-- ---------------------------------------------------------------------------

C.KINDS = {}

C.KINDS.epc = {
    label = "EPC register", secret = true, query = { "postcode" },
    fetch = function(conn, secret, q)
        if not q.postcode then return nil, "postcode is required" end
        local cfg = U.json(conn.config) or {}
        local data, err = H.json(base(conn, "https://epc.opendatacommunities.org") .. "/api/v1/domestic/search?"
            .. H.query({ postcode = pc(q.postcode), size = 100 }), { headers = { Authorization = H.basic(cfg.email, secret) } })
        if not data then return nil, "EPC register: " .. err end
        local out = {}
        for _, r in ipairs(type(data.rows) == "table" and data.rows or {}) do
            local lodged = r["lodgement-date"]
            local expires = lodged and lodged:match("^(%d%d%d%d)") and (tonumber(lodged:sub(1, 4)) + 10) .. lodged:sub(5) or nil
            out[#out + 1] = { record_type = "epc", external_id = tostring(r["lmk-key"] or r["certificate-number"]),
                address = r.address or table.concat({ r.address1, r.address2, r.address3 }, ", "),
                postcode = pc(r.postcode), property_type = r["property-type"], epc_rating = r["current-energy-rating"],
                event_date = lodged, data = { certificate_number = r["certificate-number"] or r["lmk-key"],
                    expires_on = expires, floor_area_sqm = tonumber(r["total-floor-area"]),
                    potential_rating = r["potential-energy-rating"], built_form = r["built-form"], uprn = r.uprn } }
        end
        return out
    end,
}

local function label(v)
    if type(v) ~= "table" then return v end
    local pl = v.prefLabel
    if type(pl) == "table" then
        local first = pl[1]
        return type(first) == "table" and first._value or first
    end
    return v.label or v._about
end

C.KINDS.price_paid = {
    label = "Land Registry Price Paid", query = { "postcode" },
    fetch = function(conn, _, q)
        if not q.postcode then return nil, "postcode is required" end
        local data, err = H.json(base(conn, "https://landregistry.data.gov.uk") .. "/data/ppi/transaction-record.json?"
            .. H.query({ ["propertyAddress.postcode"] = pc(q.postcode), _pageSize = 100, _sort = "-transactionDate" }))
        if not data then return nil, "Price Paid: " .. err end
        local items = type(data.result) == "table" and data.result.items or {}
        local out = {}
        for _, it in ipairs(items) do
            local a = type(it.propertyAddress) == "table" and it.propertyAddress or {}
            local addr = {}
            for _, k in ipairs({ "saon", "paon", "street", "town" }) do if a[k] then addr[#addr + 1] = a[k] end end
            out[#out + 1] = { record_type = "sold_price", external_id = tostring(it.transactionId or it._about),
                address = table.concat(addr, " "), postcode = pc(a.postcode), price = tonumber(it.pricePaid),
                event_date = it.transactionDate, property_type = label(it.propertyType), tenure = label(it.estateType),
                data = { new_build = it.newBuild, category = label(it.transactionCategory) } }
        end
        return out
    end,
}

C.KINDS.companies_house = { label = "Companies House", secret = true, lookup = true }
C.KINDS.postcodes = { label = "Postcode lookup (postcodes.io)", lookup = true }
C.KINDS.csv = { label = "CSV import" }
-- Staff alert channels (property_deals.messaging): free / open-source, not run.
C.KINDS.ntfy = { label = "ntfy (open-source push alerts)", secret = true, lookup = true }
C.KINDS.telegram = { label = "Telegram bot (alerts)", secret = true, lookup = true }
C.KINDS.sms_gateway = { label = "Android SMS Gateway (texts from your phone)", secret = true, lookup = true }
for _, k in ipairs({ "propertydata", "searchland", "streetdata", "homedata" }) do
    C.KINDS[k] = { label = k .. " (stub)", secret = true, stub = true }
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

function C.present(row)
    if not row then return nil end
    local out = {}
    for k, v in pairs(row) do
        if k ~= "secret_sealed" and k ~= "id" and k ~= "namespace_id" and not null(v) then out[k] = v end
    end
    out.config, out.has_secret = U.json(row.config), not null(row.secret_sealed)
    local spec = C.KINDS[row.kind] or {}
    out.stub, out.label = spec.stub == true, spec.label
    return out
end

function C.get(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one("SELECT * FROM property_deals_connectors WHERE namespace_id = ? AND uuid = ?", ns, id)
end

--- The workspace's enabled connector of a kind (first by name), or nil.
function C.of_kind(ns, kind)
    return U.one("SELECT * FROM property_deals_connectors WHERE namespace_id = ? AND kind = ? AND enabled ORDER BY name LIMIT 1",
        ns, kind)
end

function C.secret(conn)
    if not conn or null(conn.secret_sealed) then return nil end
    return Box.open(conn.secret_sealed, PURPOSE)
end

function C.save(ns, b, existing)
    local errors, row = {}, {}
    local kind = b.kind or (existing and existing.kind)
    if not C.KINDS[kind or ""] then
        local kinds = {}
        for k in pairs(C.KINDS) do kinds[#kinds + 1] = k end
        table.sort(kinds)
        errors.kind = "one of " .. table.concat(kinds, ", ")
    end
    if b.kind ~= nil then row.kind = b.kind end
    if not existing or b.name ~= nil then
        if type(b.name) ~= "string" or b.name == "" then errors.name = "required" else row.name = b.name:sub(1, 120) end
    end
    if b.config ~= nil then
        if type(b.config) ~= "table" then errors.config = "object"
        else
            if b.config.base_url ~= nil then
                local ok, err = require("lib.ai-providers").url_ok(b.config.base_url)
                if not ok then errors["config.base_url"] = err end
            end
            row.config = cjson.encode(b.config)
        end
    end
    if b.secret ~= nil then
        if b.secret == "" then row.secret_sealed = db.NULL
        elseif type(b.secret) ~= "string" then errors.secret = "string"
        else row.secret_sealed = Box.seal(b.secret, PURPOSE) end
    end
    if b.enabled ~= nil then row.enabled = b.enabled ~= false end
    if b.sync_enabled ~= nil then row.sync_enabled = b.sync_enabled == true end
    if next(errors) then return nil, errors end
    row.updated_at = db.raw("NOW()")
    if existing then
        db.update("property_deals_connectors", row, { id = existing.id })
        return C.get(ns, existing.uuid)
    end
    row.namespace_id = ns
    local ok, res = pcall(db.insert, "property_deals_connectors", row, { returning = "*" })
    if not ok then
        if tostring(res):find("duplicate key", 1, true) then return nil, { name = "already used" } end
        error(res)
    end
    return res[1]
end

-- ---------------------------------------------------------------------------
-- Postcode lookup (postcodes.io, or the workspace's own postcodes connector)
-- ---------------------------------------------------------------------------

--- { ["YO1 7AA"] = { lat, lng, district } } for a list of postcodes (unknown ones are left out).
function C.geocode(ns, postcodes)
    local list, seen = {}, {}
    for _, p in ipairs(postcodes or {}) do
        p = pc(p)
        if p and p ~= "" and not seen[p] then seen[p] = true; list[#list + 1] = p end
    end
    if #list == 0 then return {} end
    local conn = C.of_kind(ns, "postcodes")
    local out = {}
    for i = 1, #list, 100 do
        local chunk = {}
        for j = i, math.min(i + 99, #list) do chunk[#chunk + 1] = list[j] end
        local data = H.json(base(conn, "https://api.postcodes.io") .. "/postcodes", { method = "POST",
            headers = { ["Content-Type"] = "application/json" }, body = cjson.encode({ postcodes = chunk }) })
        for _, r in ipairs(data and type(data.result) == "table" and data.result or {}) do
            local res = type(r.result) == "table" and r.result or nil
            if res and res.latitude then
                out[pc(r.query)] = { lat = tonumber(res.latitude), lng = tonumber(res.longitude), district = res.admin_district }
            end
        end
    end
    return out
end

--- Nearest postcode to a point (to fetch data around a saved search's pin).
function C.reverse_geocode(ns, lat, lng)
    local conn = C.of_kind(ns, "postcodes")
    local data = H.json(base(conn, "https://api.postcodes.io") .. "/postcodes?" .. H.query({ lat = lat, lon = lng, limit = 1 }))
    local r = data and type(data.result) == "table" and data.result[1]
    return r and pc(r.postcode) or nil
end

-- ---------------------------------------------------------------------------
-- Companies House
-- ---------------------------------------------------------------------------

local function ch(ns, path)
    local conn = C.of_kind(ns, "companies_house")
    if not conn then return nil, "Add a Companies House connector first (Settings → Data connectors)", 422 end
    local key = C.secret(conn)
    if not key then return nil, "The Companies House connector has no API key", 422 end
    local data, err, status = H.json(base(conn, "https://api.company-information.service.gov.uk") .. path,
        { headers = { Authorization = H.basic(key, "") } })
    if not data then return nil, "Companies House: " .. err, status == 404 and 404 or 502 end
    return data
end

--- Raw Companies House GET (path from the API root), for the lead news watch.
function C.companies_house(ns, path)
    return ch(ns, path)
end

function C.company_search(ns, q)
    local data, err, status = ch(ns, "/search/companies?" .. H.query({ q = q, items_per_page = 10 }))
    if not data then return nil, err, status end
    local out = {}
    for _, it in ipairs(type(data.items) == "table" and data.items or {}) do
        out[#out + 1] = { company_number = it.company_number, title = it.title, company_status = it.company_status,
            date_of_creation = it.date_of_creation, address = it.address_snippet }
    end
    return U.array(out)
end

--- Profile + officers, summarised with the flags a buyer check cares about.
function C.company_check(ns, number)
    number = tostring(number or ""):upper():gsub("[^%w]", "")
    if number == "" or #number > 10 then return nil, "company_number is required", 422 end
    local profile, err, status = ch(ns, "/company/" .. number)
    if not profile then return nil, err, status end
    local officers = ch(ns, "/company/" .. number .. "/officers?items_per_page=50") or {}
    local active = {}
    for _, o in ipairs(type(officers.items) == "table" and officers.items or {}) do
        if not o.resigned_on then active[#active + 1] = { name = o.name, role = o.officer_role, appointed_on = o.appointed_on } end
    end
    local flags = {}
    if profile.company_status ~= "active" then flags[#flags + 1] = "status: " .. tostring(profile.company_status) end
    if profile.has_insolvency_history then flags[#flags + 1] = "insolvency history" end
    if type(profile.accounts) == "table" and profile.accounts.overdue then flags[#flags + 1] = "accounts overdue" end
    if type(profile.confirmation_statement) == "table" and profile.confirmation_statement.overdue then
        flags[#flags + 1] = "confirmation statement overdue"
    end
    return { company_number = number, name = profile.company_name, status = profile.company_status, type = profile.type,
        created_on = profile.date_of_creation, sic_codes = U.array(profile.sic_codes or {}),
        registered_office = profile.registered_office_address, officers = U.array(active), flags = U.array(flags),
        checked_at = require("property_deals.workdays").now() }
end

-- ---------------------------------------------------------------------------
-- Running a connector
-- ---------------------------------------------------------------------------

--- Fetch from one connector and store what came back. @return { fetched, stored } | nil, err
function C.run(ns, conn, query)
    local spec = C.KINDS[conn.kind]
    if spec.stub then
        return nil, spec.label .. " has no adapter yet: import their CSV export with POST /market-records/import."
    end
    if not spec.fetch then return nil, spec.label .. " is used on demand (lookups), not run" end
    local ok, records, err = pcall(spec.fetch, conn, C.secret(conn), query or {})
    if not ok then records, err = nil, records end
    if not records then
        db.update("property_deals_connectors", { last_error = tostring(err):sub(1, 500), updated_at = db.raw("NOW()") },
            { id = conn.id })
        return nil, tostring(err)
    end
    local stored = require("property_deals.market").upsert(ns, conn, records)
    db.update("property_deals_connectors", { last_run_at = db.raw("NOW()"), last_error = db.NULL,
        records_count = db.raw("records_count + " .. stored), updated_at = db.raw("NOW()") }, { id = conn.id })
    return { fetched = #records, stored = stored }
end

return C
