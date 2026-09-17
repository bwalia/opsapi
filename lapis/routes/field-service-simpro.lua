--[[
    Field Service — Simpro connection and sync routes

    Endpoints:
    - GET  /api/v2/field-service/simpro/status      - Connection + per-table sync counts
    - PUT  /api/v2/field-service/simpro/connection  - Create or update the connection
    - POST /api/v2/field-service/simpro/test        - Check the build answers
    - POST /api/v2/field-service/simpro/pull        - Pull (?entities=customers,sites,assets,jobs)
    - POST /api/v2/field-service/simpro/push        - Push pending records (?entities=&limit=)
    - GET  /api/v2/field-service/simpro/log         - Sync audit trail (?status=&entity_type=&batch_uuid=)

    Reading the console needs simpro_sync read. Running a sync or changing the
    connection needs manage, which only the Owner role gets by default: a push
    writes to the customer's system of record, so it is not a service-manager
    button.
]]

local Http = require("helper.field-service-http")
local SyncQueries = require("queries.SimproSyncQueries")

return function(app)
    app:get("/api/v2/field-service/simpro/status", Http.guard("simpro_sync", "read", function(self)
        return Http.ok(SyncQueries.status(self.namespace.id))
    end))

    app:put("/api/v2/field-service/simpro/connection", Http.guard("simpro_sync", "manage", function(self)
        return Http.result(SyncQueries.saveConnection(self.namespace.id, Http.actor(self), Http.body(self)))
    end))

    app:post("/api/v2/field-service/simpro/test", Http.guard("simpro_sync", "manage", function(self)
        local client, err = SyncQueries.clientFor(self.namespace.id)
        if not client then return Http.from_error(err) end
        local info, ping_err = client:ping()
        if not info then return Http.fail(502, ping_err) end
        return Http.ok(info)
    end))

    app:post("/api/v2/field-service/simpro/pull", Http.guard("simpro_sync", "manage", function(self)
        local body = Http.body(self)
        return Http.result(SyncQueries.pull(self.namespace.id, Http.actor(self), {
            entities = self.params.entities or body.entities,
        }))
    end))

    app:post("/api/v2/field-service/simpro/push", Http.guard("simpro_sync", "manage", function(self)
        local body = Http.body(self)
        return Http.result(SyncQueries.push(self.namespace.id, Http.actor(self), {
            entities = self.params.entities or body.entities,
            limit = self.params.limit or body.limit,
        }))
    end))

    app:get("/api/v2/field-service/simpro/log", Http.guard("simpro_sync", "read", function(self)
        local result = SyncQueries.listLog(self.namespace.id, self.params)
        return Http.ok(result.items, 200, result.meta)
    end))
end
