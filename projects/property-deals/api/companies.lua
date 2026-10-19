-- Companies House in the deal finder (NebulaDB index) — an alternate "base" for
-- the map. CH search is by name/number (keyword, not radius), so results are
-- pinned by their registered-office postcode (postcodes.io, via connectors.geocode).
--   GET  /finder/companies?q=...   search companies, geocoded to map pins
--   POST /finder/companies/lead    turn a company into a property-deals lead
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local cjson = require("cjson")
local Nebula = require("property_deals.nebula")
local Connectors = require("property_deals.connectors")
local CrmLeadQueries = require("queries.CrmLeadQueries")

local MAX = 50

-- Same normalisation connectors.geocode keys its results by (upper + single spaces).
local function norm_pc(s)
    return s and tostring(s):upper():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or nil
end

local function postcode_of(item)
    local a = type(item.address) == "table" and item.address or {}
    local p = a.postal_code
    return type(p) == "string" and p ~= "" and p or nil
end

local function str(v)
    return type(v) == "string" and v ~= "" and v or nil
end

local function company_number_clean(s)
    s = type(s) == "string" and s:upper():gsub("[^%w]", "") or ""
    return s ~= "" and s or nil
end

return function(app)
    app:get("/finder/companies", sdk.handler({ permission = "property_deals_leads.read" }, function(self)
        local q = self.params.q
        if type(q) ~= "string" or q:gsub("%s+", "") == "" then
            return sdk.error(422, "Validation failed", { q = "a company name or number to search" })
        end
        local ns = sdk.namespace_id(self)
        local items, err, status = Nebula.companies_search(q)
        if not items then return sdk.error(status or 502, err) end

        -- Geocode the registered-office postcodes in one batch.
        local postcodes = {}
        for _, it in ipairs(items) do
            local p = postcode_of(it)
            if p then postcodes[#postcodes + 1] = p end
        end
        local geo = (#postcodes > 0) and Connectors.geocode(ns, postcodes) or {}

        local companies, mapped = {}, 0
        for i = 1, math.min(#items, MAX) do
            local it = items[i]
            local p = postcode_of(it)
            local ll = p and geo[norm_pc(p)] or nil
            if ll then mapped = mapped + 1 end
            companies[#companies + 1] = {
                company_number = str(it.company_number) or cjson.null,
                title = str(it.title) or "Company",
                company_status = str(it.company_status) or cjson.null,
                address_snippet = str(it.address_snippet) or cjson.null,
                postcode = p or cjson.null,
                lat = ll and ll.lat or cjson.null,
                lng = ll and ll.lng or cjson.null,
            }
        end
        return sdk.ok({ companies = sdk.array(companies), total = #items, mapped = mapped })
    end))

    app:post("/finder/companies/lead", sdk.handler({ permission = "property_deals_leads.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local title = str(body.title)
        if not title then
            return sdk.error(422, "Validation failed", { title = "the company name is required" })
        end
        local number = company_number_clean(body.company_number)
        -- crm_leads.first_name is NOT NULL; a company lead carries the company name.
        local lead = CrmLeadQueries.createLead({
            namespace_id = ns,
            first_name = title:sub(1, 255),
            company_name = title:sub(1, 255),
            source = "companies_house",
            status = "new",
            notes = str(body.address_snippet),
        })
        if not lead then return sdk.error(500, "Could not create the lead") end
        -- Link the Companies House number so the news watch can follow it (best-effort).
        if number then
            pcall(function()
                db.insert("property_deals_lead_details",
                    { namespace_id = ns, lead_uuid = lead.uuid, company_number = number })
            end)
        end
        return sdk.created({ uuid = lead.uuid })
    end))
end
