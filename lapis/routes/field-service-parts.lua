--[[
    Field Service — parts catalog routes

    Endpoints:
    - GET    /api/v2/field-service/parts        - List (?category=&is_active=&include_inactive=&search=&page=&per_page=)
    - POST   /api/v2/field-service/parts        - Create
    - GET    /api/v2/field-service/parts/:uuid  - Get
    - PUT    /api/v2/field-service/parts/:uuid  - Update
    - DELETE /api/v2/field-service/parts/:uuid  - Soft delete
]]

local Http = require("helper.field-service-http")
local PartQueries = require("queries.FieldServicePartQueries")

return function(app)
    -- Anyone who reads parts, or works jobs, needs the catalog for the part picker.
    local READERS = { { "fs_parts", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" } }

    app:get("/api/v2/field-service/parts", Http.guard_any(READERS, function(self)
        local result = PartQueries.listParts(self.namespace.id, {
            category = self.params.category,
            is_active = self.params.is_active,
            include_inactive = self.params.include_inactive,
            search = self.params.search,
            page = self.params.page,
            per_page = self.params.per_page,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/parts", Http.guard("fs_parts", "create", function(self)
        local part, err = PartQueries.createPart(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(part, err, 201)
    end))

    app:get("/api/v2/field-service/parts/:uuid", Http.guard_any(READERS, function(self)
        local part = PartQueries.getPart(self.namespace.id, self.params.uuid)
        if not part then return Http.fail(404, "Part not found") end
        return Http.ok(part)
    end))

    app:put("/api/v2/field-service/parts/:uuid", Http.guard("fs_parts", "update", function(self)
        return Http.result(PartQueries.updatePart(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:delete("/api/v2/field-service/parts/:uuid", Http.guard("fs_parts", "delete", function(self)
        local ok, err = PartQueries.deletePart(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Part deleted" })
    end))
end
