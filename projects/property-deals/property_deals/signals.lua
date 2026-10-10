-- "Recent news" about a lead, so a follow-up can be personal ("congratulations on
-- setting up Elm Property Holdings last week…"):
--   * Companies House, daily (official API, free key): for a lead with a company number — new filings and
--     charges (a new charge usually means a mortgaged purchase); for a lead linked to an officer id — new
--     directorships, and companies they have just formed.
--   * New property companies in the workspace's areas (SIC 68xxx / 41100, incorporated in the last week)
--     become new leads, so the team can reach them while they are buying.
--   * Posts and pages a person captured (pasted or shared from the phone). Social networks are never fetched
--     or scraped by us: their terms forbid it.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local C = require("property_deals.connectors")

local S = {}

S.KINDS = { "company_formed", "officer_appointed", "company_filing", "charge_registered", "social_post", "website",
    "news", "note" }
S.MANUAL_KINDS = { "social_post", "website", "news", "note" }

local LOOKBACK_DAYS = 60       -- first look at a lead: only news this recent counts
local WATCH_BATCH = 100        -- leads checked per run (oldest check first)
local NEW_COMPANY_CAP = 25     -- new-company leads per area per run
local DEFAULT_SIC = "68100,68209,68320,41100"

local function null(v) return v == nil or v == db.NULL end

local function humanise(code)
    return (tostring(code or ""):gsub("%-", " "):gsub("^%l", string.upper))
end

--- Store one signal (deduped on external_id). @return row (or nil when it already existed)
function S.add(ns, lead_uuid, f, user_uuid)
    local row = db.query([[
        INSERT INTO property_deals_lead_signals (namespace_id, lead_uuid, kind, source, title, summary, url, occurred_at,
            external_id, data, created_by_user_uuid)
        VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE(?::timestamptz, NOW()), ?, ?::jsonb, ?)
        ON CONFLICT (namespace_id, external_id) WHERE external_id IS NOT NULL DO NOTHING
        RETURNING *
    ]], ns, lead_uuid, f.kind, f.source or "manual", tostring(f.title):sub(1, 300), f.summary or db.NULL,
        f.url or db.NULL, f.occurred_at or db.NULL, f.external_id or db.NULL, cjson.encode(f.data or {}),
        user_uuid or db.NULL)[1]
    if row then
        db.query([[
            INSERT INTO property_deals_lead_details (namespace_id, lead_uuid, last_signal_at) VALUES (?, ?, ?)
            ON CONFLICT (lead_uuid) DO UPDATE SET last_signal_at = GREATEST(property_deals_lead_details.last_signal_at,
                EXCLUDED.last_signal_at), updated_at = NOW()
        ]], ns, lead_uuid, row.occurred_at)
    end
    return row
end

function S.list(ns, lead_uuid, limit)
    return U.array(db.query([[
        SELECT uuid, lead_uuid, kind, source, title, summary, url, occurred_at, data, used_at, created_by_user_uuid, created_at
        FROM property_deals_lead_signals WHERE namespace_id = ? AND lead_uuid = ?
        ORDER BY occurred_at DESC, id DESC LIMIT ?
    ]], ns, lead_uuid, limit or 50))
end

-- ---------------------------------------------------------------------------
-- Companies House watch
-- ---------------------------------------------------------------------------

local function since_for(lead)
    local floor = os.time() - LOOKBACK_DAYS * 86400
    if null(lead.checked_epoch) then return floor end
    return math.max(floor, tonumber(lead.checked_epoch) - 2 * 86400)
end

local function epoch(date)
    local y, m, d = tostring(date or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    return y and os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) or nil
end

local function watch_company(ns, lead, since)
    local added = 0
    local hist = C.companies_house(ns, "/company/" .. ngx.escape_uri(lead.company_number)
        .. "/filing-history?items_per_page=15")
    for _, f in ipairs(hist and type(hist.items) == "table" and hist.items or {}) do
        local t = epoch(f.date)
        if t and t >= since then
            local charge = f.category == "mortgage"
            local row = S.add(ns, lead.lead_uuid, {
                kind = charge and "charge_registered" or "company_filing", source = "companies_house",
                title = charge and ("New charge registered for " .. (lead.company_name or lead.company_number)
                    .. " (often a mortgage on a purchase)")
                    or ("Companies House filing: " .. humanise(f.description or f.type)),
                summary = f.description_values and cjson.encode(f.description_values) or nil,
                url = "https://find-and-update.company-information.service.gov.uk/company/" .. lead.company_number
                    .. "/filing-history",
                occurred_at = f.date, external_id = "ch-filing:" .. tostring(f.transaction_id or (lead.company_number .. f.date)),
                data = { company_number = lead.company_number, category = f.category, type = f.type },
            })
            if row then added = added + 1 end
        end
    end
    return added
end

local function watch_officer(ns, lead, since)
    local added = 0
    local appts = C.companies_house(ns, "/officers/" .. ngx.escape_uri(lead.ch_officer_id) .. "/appointments?items_per_page=20")
    for _, a in ipairs(appts and type(appts.items) == "table" and appts.items or {}) do
        local t = epoch(a.appointed_on)
        local to = type(a.appointed_to) == "table" and a.appointed_to or {}
        if t and t >= since and to.company_number then
            local profile = C.companies_house(ns, "/company/" .. ngx.escape_uri(to.company_number)) or {}
            local created = epoch(profile.date_of_creation)
            local formed = created and math.abs(created - t) <= 14 * 86400
            local name = profile.company_name or to.company_name or to.company_number
            local row = S.add(ns, lead.lead_uuid, {
                kind = formed and "company_formed" or "officer_appointed", source = "companies_house",
                title = formed and ("Set up " .. name .. " on " .. tostring(profile.date_of_creation))
                    or ("Became " .. humanise(a.officer_role or "officer") .. " of " .. name),
                url = "https://find-and-update.company-information.service.gov.uk/company/" .. to.company_number,
                occurred_at = formed and profile.date_of_creation or a.appointed_on,
                external_id = "ch-appt:" .. lead.ch_officer_id .. ":" .. to.company_number,
                data = { company_number = to.company_number, company_name = name, role = a.officer_role,
                         sic_codes = profile.sic_codes },
            })
            if row then added = added + 1 end
        end
    end
    return added
end

--- One pass of the watch. Leads with new news get a follow-up draft (property_deals.followups.auto).
-- @return { leads, signals, errors, followups }
function S.watch(ns, settings)
    local out = { leads = 0, signals = 0, errors = 0, followups = 0 }
    local fresh = {}
    if not C.of_kind(ns, "companies_house") then return out end
    local leads = db.query([[
        SELECT d.lead_uuid, d.company_number, d.ch_officer_id, l.company_name,
               EXTRACT(EPOCH FROM d.ch_checked_at)::bigint AS checked_epoch
        FROM property_deals_lead_details d JOIN crm_leads l ON l.uuid = d.lead_uuid AND l.deleted_at IS NULL
        WHERE d.namespace_id = ? AND (d.company_number IS NOT NULL OR d.ch_officer_id IS NOT NULL)
          AND (d.ch_checked_at IS NULL OR d.ch_checked_at < NOW() - INTERVAL '20 hours')
        ORDER BY d.ch_checked_at NULLS FIRST LIMIT ?
    ]], ns, WATCH_BATCH)
    for _, lead in ipairs(leads) do
        out.leads = out.leads + 1
        local since = since_for(lead)
        local ok, n = pcall(function()
            local added = 0
            if not null(lead.company_number) then added = added + watch_company(ns, lead, since) end
            if not null(lead.ch_officer_id) then added = added + watch_officer(ns, lead, since) end
            return added
        end)
        if ok then
            out.signals = out.signals + n
            if n > 0 then fresh[#fresh + 1] = lead.lead_uuid end
        else
            out.errors = out.errors + 1
            ngx.log(ngx.WARN, "[property_deals] companies house watch lead=", lead.lead_uuid, ": ", tostring(n))
        end
        db.update("property_deals_lead_details", { ch_checked_at = db.raw("NOW()") }, { lead_uuid = lead.lead_uuid })
    end
    if #fresh > 0 then
        local ok, n = pcall(require("property_deals.followups").auto, ns, fresh, settings)
        out.followups = ok and n or 0
        if not ok then ngx.log(ngx.WARN, "[property_deals] auto follow-ups: ", tostring(n)) end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- New property companies -> new leads
-- ---------------------------------------------------------------------------

local function split_name(officer)
    -- Companies House writes "SURNAME, First Middle".
    local last, first = tostring(officer or ""):match("^([^,]+),%s*(.+)$")
    local function tidy(s) return (s:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)) end
    if last then return tidy(first:match("^(%S+)") or first), tidy(last) end
    return tidy(tostring(officer or "Director")), ""
end

--- @return { areas, companies, leads }
function S.new_companies(ns, settings)
    local out = { areas = 0, companies = 0, leads = 0 }
    settings = settings or {}
    local areas = tostring(settings.ch_new_company_areas or "")
    if areas:match("^%s*$") or not C.of_kind(ns, "companies_house") then return out end
    local sic = tostring(settings.ch_new_company_sic or DEFAULT_SIC):gsub("%s+", "")
    local from = os.date("!%Y-%m-%d", os.time() - 7 * 86400)
    for area in areas:gmatch("[^,]+") do
        area = area:gsub("^%s+", ""):gsub("%s+$", "")
        if area ~= "" then
            out.areas = out.areas + 1
            local res = C.companies_house(ns, "/advanced-search/companies?" .. require("property_deals.http").query({
                incorporated_from = from, sic_codes = sic, location = area, size = 100 }))
            local made = 0
            for _, co in ipairs(res and type(res.items) == "table" and res.items or {}) do
                if made >= NEW_COMPANY_CAP then break end
                out.companies = out.companies + 1
                local ext = "ch-new:" .. tostring(co.company_number)
                if not U.one("SELECT 1 FROM property_deals_lead_signals WHERE namespace_id = ? AND external_id = ?", ns, ext) then
                    local officers = C.companies_house(ns, "/company/" .. ngx.escape_uri(co.company_number)
                        .. "/officers?items_per_page=10") or {}
                    local director
                    for _, o in ipairs(type(officers.items) == "table" and officers.items or {}) do
                        if not o.resigned_on and (o.officer_role == "director" or not director) then director = o end
                    end
                    local first, last = split_name(director and director.name)
                    local officer_id = director and type(director.links) == "table" and type(director.links.officer) == "table"
                        and tostring(director.links.officer.appointments or ""):match("^/officers/([^/]+)/") or nil
                    U.tx(function()
                        local lead = require("queries.CrmLeadQueries").createLead({
                            namespace_id = ns, first_name = first, last_name = last, company_name = co.company_name,
                            source = "companies_house", channel = "data", status = "new",
                            notes = "New property company formed " .. tostring(co.date_of_creation)
                                .. " (SIC " .. table.concat(type(co.sic_codes) == "table" and co.sic_codes or {}, ", ") .. "), "
                                .. area .. ". Found by the Companies House watch: check before contacting.",
                        })
                        db.insert("property_deals_lead_details", { namespace_id = ns, lead_uuid = lead.uuid,
                            lead_kind = "buyer_investor", company_number = co.company_number,
                            ch_officer_id = officer_id or db.NULL, ch_checked_at = db.raw("NOW()") })
                        S.add(ns, lead.uuid, { kind = "company_formed", source = "companies_house",
                            title = "Set up " .. tostring(co.company_name) .. " on " .. tostring(co.date_of_creation),
                            url = "https://find-and-update.company-information.service.gov.uk/company/" .. co.company_number,
                            occurred_at = co.date_of_creation, external_id = ext,
                            data = { company_number = co.company_number, sic_codes = co.sic_codes, area = area } })
                    end)
                    made, out.leads = made + 1, out.leads + 1
                end
            end
        end
    end
    return out
end

--- Officer search, to link a lead to their Companies House officer record.
function S.officer_search(ns, q)
    local data, err, status = C.companies_house(ns, "/search/officers?" .. require("property_deals.http").query({
        q = q, items_per_page = 10 }))
    if not data then return nil, err, status end
    local out = {}
    for _, it in ipairs(type(data.items) == "table" and data.items or {}) do
        local self_link = type(it.links) == "table" and tostring(it.links.self or "") or ""
        local dob = type(it.date_of_birth) == "table" and it.date_of_birth or nil
        out[#out + 1] = { officer_id = self_link:match("^/officers/([^/]+)/"), name = it.title,
            appointments = it.appointment_count, address = it.address_snippet,
            born = dob and string.format("%02d/%d", tonumber(dob.month) or 0, tonumber(dob.year) or 0) or nil }
    end
    return U.array(out)
end

return S
