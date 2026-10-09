-- Workspace setup: the kanban project deal tasks live in, the Property Deals
-- roles, the seed workflow templates and the bank-holiday calendar.
--   GET  /setup   state (null when the workspace was never set up)
--   POST /setup   set up, or add whatever is missing (idempotent)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local Workspace = require("property_deals.workspace")

return function(app)
    app:get("/setup", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        return sdk.ok(Workspace.get(sdk.namespace_id(self)) or require("cjson").null)
    end))

    app:post("/setup", sdk.handler({ permission = "property_deals_settings.manage" }, U.guard(function(self)
        local result = Workspace.setup(sdk.namespace_id(self), sdk.user(self).uuid, sdk.settings(self))
        return sdk.ok(result)
    end)))
end
