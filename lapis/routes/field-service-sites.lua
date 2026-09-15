--[[
    Field Service — customer site routes

    - GET    /api/v2/field-service/sites            - List (?customer_uuid=&search=&page=&per_page=)
    - POST   /api/v2/field-service/sites            - Create (needs customer_uuid + name)
    - GET    /api/v2/field-service/sites/:uuid       - Get
    - PUT    /api/v2/field-service/sites/:uuid       - Update
    - DELETE /api/v2/field-service/sites/:uuid       - Soft delete

    Reads are open to anyone who works jobs/visits/requests (engineers need the
    site address); writes need fs_service_requests.update (telecaller + manager).
]]

local Http = require("helper.field-service-http")
local SiteQueries = require("queries.SiteQueries")

return function(app)
    local READERS = { { "fs_service_requests", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" } }

    app:get("/api/v2/field-service/sites", Http.guard_any(READERS, function(self)
        local result = SiteQueries.listSites(self.namespace.id, {
            customer_uuid = self.params.customer_uuid,
            search = self.params.search,
            page = self.params.page,
            per_page = self.params.per_page,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/sites", Http.guard("fs_service_requests", "update", function(self)
        local site, err = SiteQueries.createSite(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(site, err, 201)
    end))

    app:get("/api/v2/field-service/sites/:uuid", Http.guard_any(READERS, function(self)
        local site = SiteQueries.getSite(self.namespace.id, self.params.uuid)
        if not site then return Http.fail(404, "Site not found") end
        return Http.ok(site)
    end))

    app:put("/api/v2/field-service/sites/:uuid", Http.guard("fs_service_requests", "update", function(self)
        return Http.result(SiteQueries.updateSite(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:delete("/api/v2/field-service/sites/:uuid", Http.guard("fs_service_requests", "update", function(self)
        local ok, err = SiteQueries.deleteSite(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Site deleted" })
    end))
end
