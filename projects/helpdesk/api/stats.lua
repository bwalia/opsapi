-- GET /api/v2/helpdesk/stats — ticket count per status in the caller's
-- namespace. A hand-written route: sdk.handler checks the namespace and
-- permission before the handler runs; the query filters by namespace_id.
local sdk = require("helper.plugin-sdk")

return function(app)
    app:get("/stats", sdk.handler({ permission = "helpdesk_tickets.read" }, function(self)
        local rows = sdk.db.query([[
            SELECT status, COUNT(*)::int AS count
            FROM helpdesk_tickets
            WHERE namespace_id = ?
            GROUP BY status
            ORDER BY status
        ]], sdk.namespace_id(self))
        return sdk.ok(sdk.array(rows))
    end))
end
