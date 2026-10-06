--[[
    AI usage — every model call the platform makes, metered by lib/agent/llm
    into ai_usage: who asked, which feature, which model, tokens in/out.
    See queries/AiUsageQueries.lua.

      GET /api/v2/namespace/ai-usage?days=30   this workspace (RBAC activity.read)
      GET /api/v2/admin/ai-usage?days=30       every workspace (platform admins)
]]

local Http = require("helper.field-service-http")
local AuthMiddleware = require("middleware.auth")
local AiUsageQueries = require("queries.AiUsageQueries")

return function(app)
    app:get("/api/v2/namespace/ai-usage", Http.guard("activity", "read", function(self)
        return Http.ok(AiUsageQueries.summary(self.namespace.id, AiUsageQueries.days(self.params.days)))
    end))

    app:get("/api/v2/admin/ai-usage", AuthMiddleware.requireRole("administrative", function(self)
        return Http.ok(AiUsageQueries.summary(nil, AiUsageQueries.days(self.params.days)))
    end))
end
