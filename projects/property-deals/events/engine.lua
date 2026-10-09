-- The workflow engine reacting to Property Deals' own events (delivered in the
-- background, at least once; every handler is safe to repeat):
--   property updated (e.g. a valid EPC was found)  -> re-check skip conditions on its deals
--   compliance check / enquiry / chase changed      -> recompute the deal's health and urgency
local root = debug.getinfo(1, "S").source:match("^@(.+)/events/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")

local function recompute(event)
    local deal = event.data and event.data.deal_uuid
    if event.namespace_id and type(deal) == "string" then
        require("property_deals.health").recompute_deal(event.namespace_id, deal, event.settings)
    end
end

return {
    ["property_deals.property.updated"] = function(event)
        local ns, property = event.namespace_id, event.data and event.data.uuid
        if not ns or not property then return end
        local Engine = require("property_deals.engine")
        local U = require("property_deals.util")
        for _, d in ipairs(sdk.db.query([[
            SELECT uuid FROM property_deals_deals WHERE namespace_id = ? AND property_uuid = ? AND status = 'active'
        ]], ns, property)) do
            local ctx = Engine.context(ns, d.uuid, event.settings)
            if ctx then
                U.tx(function() Engine.reevaluate(ctx, nil) end)
                require("property_deals.health").recompute_deal(ns, d.uuid, event.settings)
            end
        end
    end,
    ["property_deals.compliance_check.*"] = recompute,
    ["property_deals.enquiry.*"] = recompute,
    ["property_deals.chase.*"] = recompute,
}
