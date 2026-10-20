-- Analytics overview, campaign breakdown, contact timeline.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local Analytics = require("opsapi_marketing.analytics")
local Camp = require("opsapi_marketing.campaigns")

return function(app)
    app:get("/analytics/overview", sdk.handler({ permission = "opsapi_marketing_analytics.read" }, function(self)
        return sdk.ok(Analytics.overview(sdk.namespace_id(self)))
    end))

    app:get("/analytics/campaigns/:id", sdk.handler({ permission = "opsapi_marketing_analytics.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local campaign = Camp.find(ns, self.params.id)
        if not campaign then return sdk.not_found("campaign") end
        return sdk.ok(Analytics.campaign(ns, campaign.id))
    end))

    app:get("/analytics/contacts/:contact_uuid", sdk.handler({ permission = "opsapi_marketing_analytics.read" }, function(self)
        local ns = sdk.namespace_id(self)
        return sdk.ok(Analytics.contact_timeline(ns, self.params.contact_uuid, self.params.limit))
    end))
end
