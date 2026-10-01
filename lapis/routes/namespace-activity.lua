--[[
    Workspace activity — who signed in and what they did, for workspace
    owners/admins (RBAC module `activity`, action `read`). Always scoped to the
    caller's current namespace. See queries/ActivityQueries.lua and
    USER_ACTIVITY.md.

      GET /api/v2/namespace/activity/summary?days=30
      GET /api/v2/namespace/activity/members?search=&sort=last_login|name&page=&per_page=
      GET /api/v2/namespace/activity?days=7&user_uuid=&area=&kind=changes|errors&cursor=&limit=
      GET /api/v2/namespace/activity/changes?days=30&user_uuid=&entity=&entity_id=&action=created|updated|deleted&cursor=&limit=
          record changes (audit trail): who changed which record, fields before -> after
]]

local Http = require("helper.field-service-http")
local ActivityQueries = require("queries.ActivityQueries")

return function(app)
    app:get("/api/v2/namespace/activity/summary", Http.guard("activity", "read", function(self)
        return Http.ok(ActivityQueries.summary(self.namespace.id, ActivityQueries.days(self.params.days, 30)))
    end))

    app:get("/api/v2/namespace/activity/members", Http.guard("activity", "read", function(self)
        local items, meta = ActivityQueries.members(self.namespace.id, self.params)
        return Http.ok(items, 200, meta)
    end))

    app:get("/api/v2/namespace/activity/changes", Http.guard("activity", "read", function(self)
        local items, meta = ActivityQueries.changes(self.namespace.id, self.params)
        return Http.ok(items, 200, meta)
    end))

    app:get("/api/v2/namespace/activity", Http.guard("activity", "read", function(self)
        local items, meta = ActivityQueries.log(self.namespace.id, self.params)
        return Http.ok(items, 200, meta)
    end))
end
