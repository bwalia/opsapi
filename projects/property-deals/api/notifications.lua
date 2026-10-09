-- My Property Deals notification preferences in this workspace (ios-notification-preferences).
--   GET /notification-preferences
--   PUT /notification-preferences   only fields sent change
--   { "<category>": { "push": bool, "email": bool }, "quiet_hours": { "from": "21:00", "to": "07:00" } | null }
--   categories: sla_warning, overdue, escalated, approval_requested, digest, compliance_expiring, agent_update
-- In-app notifications always arrive. Quiet hours (workspace time zone) hold back push, not the digest.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local Notify = require("property_deals.notify")

return function(app)
    app:get("/notification-preferences", sdk.handler(function(self)
        return sdk.ok(Notify.prefs(sdk.namespace_id(self), sdk.user(self).uuid))
    end))

    app:put("/notification-preferences", sdk.handler(U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local prefs, errors = Notify.save_prefs(sdk.namespace_id(self), sdk.user(self).uuid, body)
        if not prefs then return sdk.error(422, "Validation failed", errors) end
        return sdk.ok(prefs)
    end)))
end
