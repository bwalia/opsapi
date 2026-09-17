--[[
    Field Service — maintenance contract routes

    Endpoints:
    - GET    /api/v2/field-service/contracts        - List (?customer_uuid=&status=&expiring_within_days=&search=)
    - POST   /api/v2/field-service/contracts        - Create
    - GET    /api/v2/field-service/contracts/:uuid  - Get (+ coverage by asset type, + sites)
    - PUT    /api/v2/field-service/contracts/:uuid  - Update
    - DELETE /api/v2/field-service/contracts/:uuid  - Soft delete
]]

local Http = require("helper.field-service-http")
local ContractQueries = require("queries.FieldServiceContractQueries")

return function(app)
    -- Engineers and the desk read contracts to know the SLA they are working to.
    local READERS = {
        { "fs_contracts", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" },
    }

    app:get("/api/v2/field-service/contracts", Http.guard_any(READERS, function(self)
        local p = self.params
        local result = ContractQueries.listContracts(self.namespace.id, {
            customer_uuid = p.customer_uuid, status = p.status,
            expiring_within_days = p.expiring_within_days, search = p.search,
            page = p.page, per_page = p.per_page,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/contracts", Http.guard("fs_contracts", "create", function(self)
        local c, err = ContractQueries.createContract(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(c, err, 201)
    end))

    app:get("/api/v2/field-service/contracts/:uuid", Http.guard_any(READERS, function(self)
        local c = ContractQueries.getContract(self.namespace.id, self.params.uuid)
        if not c then return Http.fail(404, "Contract not found") end
        return Http.ok(c)
    end))

    app:put("/api/v2/field-service/contracts/:uuid", Http.guard("fs_contracts", "update", function(self)
        return Http.result(ContractQueries.updateContract(
            self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:delete("/api/v2/field-service/contracts/:uuid", Http.guard("fs_contracts", "delete", function(self)
        local ok, err = ContractQueries.deleteContract(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Contract deleted" })
    end))
end
