-- POST /api/v2/helpdesk/tickets/:id/escalate — raise the priority and publish
-- the custom event helpdesk.ticket.escalated (see events/escalations.lua).
local sdk = require("helper.plugin-sdk")

local tickets = sdk.resource("helpdesk_tickets")

return function(app)
    app:post("/tickets/:id/escalate", sdk.handler({ permission = "helpdesk_tickets.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local row = tickets.update(ns, self.params.id, { priority = 5 })
        if not row then return sdk.not_found("Ticket") end
        sdk.emit(ns, "helpdesk.ticket.escalated", { uuid = row.uuid, title = row.title, by = sdk.user(self).uuid })
        return sdk.ok(row)
    end))
end
