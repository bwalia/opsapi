--[[
    Field Service — service request (complaint) routes

    Endpoints:
    - GET    /api/v2/field-service/service-requests               - List (?status=&priority=&account_uuid=&asset_uuid=&manager_uuid=&search=&page=&per_page=)
    - POST   /api/v2/field-service/service-requests               - Register a complaint
    - GET    /api/v2/field-service/service-requests/:uuid         - Get (+ linked jobs + rollup)
    - PUT    /api/v2/field-service/service-requests/:uuid         - Update
    - POST   /api/v2/field-service/service-requests/:uuid/status  - Triage / resolve / close / reject
    - POST   /api/v2/field-service/service-requests/:uuid/assign  - Assign a manager
    - POST   /api/v2/field-service/service-requests/:uuid/convert-to-job - Create a linked job
    - DELETE /api/v2/field-service/service-requests/:uuid         - Soft delete
]]

local Http = require("helper.field-service-http")
local RequestQueries = require("queries.FieldServiceRequestQueries")

return function(app)
    -- Managers who read jobs can see the complaint queue.
    local READERS = { { "fs_service_requests", "read" }, { "fs_jobs", "read" } }

    app:get("/api/v2/field-service/service-requests", Http.guard_any(READERS, function(self)
        local result = RequestQueries.listRequests(self.namespace.id, {
            status = self.params.status,
            priority = self.params.priority,
            customer_uuid = self.params.customer_uuid,
            product_uuid = self.params.product_uuid,
            manager_uuid = self.params.manager_uuid,
            sla = self.params.sla,
            search = self.params.search,
            page = self.params.page,
            per_page = self.params.per_page,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/service-requests", Http.guard("fs_service_requests", "create", function(self)
        local req, err = RequestQueries.createRequest(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(req, err, 201)
    end))

    app:get("/api/v2/field-service/service-requests/:uuid", Http.guard_any(READERS, function(self)
        local req = RequestQueries.getRequest(self.namespace.id, self.params.uuid)
        if not req then return Http.fail(404, "Service request not found") end
        return Http.ok(req)
    end))

    app:put("/api/v2/field-service/service-requests/:uuid", Http.guard("fs_service_requests", "update", function(self)
        return Http.result(RequestQueries.updateRequest(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:post("/api/v2/field-service/service-requests/:uuid/status",
        Http.guard("fs_service_requests", "update", function(self)
            local body = Http.body(self)
            if not body.status then return Http.fail(400, "status is required") end
            return Http.result(RequestQueries.setRequestStatus(self.namespace.id, self.params.uuid, body.status, {
                resolution_notes = body.resolution_notes,
            }))
        end))

    app:post("/api/v2/field-service/service-requests/:uuid/assign",
        Http.guard("fs_service_requests", "update", function(self)
            local body = Http.body(self)
            return Http.result(RequestQueries.assignRequest(self.namespace.id, self.params.uuid, body.manager_uuid))
        end))

    -- Converting a request creates a job, so it needs both permissions.
    app:post("/api/v2/field-service/service-requests/:uuid/convert-to-job", Http.route(function(self)
        if not Http.has_perm(self, "fs_service_requests", "update") then
            return Http.forbidden("fs_service_requests", "update")
        end
        if not Http.has_perm(self, "fs_jobs", "create") then
            return Http.forbidden("fs_jobs", "create")
        end
        local result, err = RequestQueries.convertToJob(self.namespace.id, self.params.uuid, Http.actor(self),
            Http.body(self))
        return Http.result(result, err, 201)
    end))

    app:delete("/api/v2/field-service/service-requests/:uuid",
        Http.guard("fs_service_requests", "delete", function(self)
            local ok, err = RequestQueries.deleteRequest(self.namespace.id, self.params.uuid)
            if not ok then return Http.from_error(err) end
            return Http.ok({ message = "Service request deleted" })
        end))
end
