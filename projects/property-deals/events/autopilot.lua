-- Deal autopilot (property_deals/research.lua): a new deal, or a deal that gets its property, is researched
-- by itself unless the workspace switched that off (autopilot_on_new_deal, or ai_auto_runs for all agents).
local root = debug.getinfo(1, "S").source:match("^@(.+)/events/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

-- trigger "auto" (a new deal) is skipped when the deal was researched already: events arrive at least once.
local function research(event, trigger)
    local ns, id, s = event.namespace_id, event.data and event.data.uuid, event.settings or {}
    if not ns or type(id) ~= "string" or s.autopilot_on_new_deal == false or s.ai_auto_runs == false then return end
    local run, err, status = require("property_deals.research").start(ns, id, nil, trigger)
    if not run and status ~= 409 then ngx.log(ngx.WARN, "[property_deals] autopilot ", id, ": ", tostring(err)) end
end

return {
    ["property_deals.deal.created"] = function(event) research(event, "auto") end,
    ["property_deals.deal.updated"] = function(event)
        if (event.changes or {}).property_uuid then research(event, "property_changed") end
    end,
}
