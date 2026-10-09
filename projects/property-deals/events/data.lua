-- Map data and matching reacting to Property Deals' own events (background, at
-- least once; every handler is safe to repeat):
--   property created / its postcode changed  -> EPC register + sold prices lookup (when the
--                                               workspace has those connectors), so a valid EPC
--                                               closes the booking task by itself (SPEC §5 #2)
--   property or buyer profile changed        -> re-score its matches (SPEC §3.7)
local root = debug.getinfo(1, "S").source:match("^@(.+)/events/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local function rescore(event, key)
    local id = event.data and event.data.uuid
    if not event.namespace_id or type(id) ~= "string" then return end
    require("property_deals.matching").recompute(event.namespace_id, { [key] = id }, event.settings)
end

local function enrich(event)
    local ns, id = event.namespace_id, event.data and event.data.uuid
    if not ns or type(id) ~= "string" then return end
    local C = require("property_deals.connectors")
    if C.of_kind(ns, "epc") or C.of_kind(ns, "price_paid") then
        local ok, err = pcall(require("property_deals.market").enrich_property, ns, id)
        if not ok then ngx.log(ngx.WARN, "[property_deals] enrich ", id, ": ", tostring(err)) end
    end
end

return {
    ["property_deals.property.created"] = function(event)
        enrich(event)
        rescore(event, "property_uuid")
    end,
    ["property_deals.property.updated"] = function(event)
        local ch = event.changes or {}
        if ch.postcode then enrich(event) end
        -- Only facts the score uses; enrichment's own EPC update doesn't loop back here.
        for _, k in ipairs({ "lat", "lng", "est_market_value", "est_rent_pcm", "condition", "known_issues", "tenure",
                             "lease_years_left", "bedrooms", "property_type", "tenancy", "flood_risk", "epc_rating" }) do
            if ch[k] then return rescore(event, "property_uuid") end
        end
    end,
    ["property_deals.buyer_profile.created"] = function(event) rescore(event, "buyer_profile_uuid") end,
    ["property_deals.buyer_profile.updated"] = function(event) rescore(event, "buyer_profile_uuid") end,
}
