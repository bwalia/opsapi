local Model = require("lapis.db.model").Model

local AuditEvents = Model:extend("audit_events", {
    timestamp = false
})

return AuditEvents
