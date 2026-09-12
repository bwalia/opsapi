--[[
    Field Service — engineer site visit routes

    Endpoints:
    - GET    /api/v2/field-service/visits                    - List (?mine=true&engineer_uuid=<uuid>|unassigned
                                                               &job_uuid=&status=open|<status>&from=&to=
                                                               &follow_up=&search=&page=&per_page=&order_dir=)
    - POST   /api/v2/field-service/jobs/:uuid/visits         - Book a visit { scheduled_start, scheduled_end?,
                                                               engineer_user_uuid?, phase_uuid?, instructions?,
                                                               is_billable?, hourly_rate? } -> { visit, conflicts }
    - GET    /api/v2/field-service/visits/:uuid              - Visit + job/site context + phase checklist + items
    - PUT    /api/v2/field-service/visits/:uuid              - Reschedule / reassign / correct the report
                                                               -> { visit, conflicts, warnings }
    - DELETE /api/v2/field-service/visits/:uuid              - Soft delete (not once logged or invoiced)

    Engineer workflow (the assigned engineer, or anyone with fs_visits.update):
    - POST   /api/v2/field-service/visits/:uuid/en-route
    - POST   /api/v2/field-service/visits/:uuid/check-in     - { latitude?, longitude? }
    - POST   /api/v2/field-service/visits/:uuid/check-out    - { work_summary, labour_hours?, customer_signoff_name?,
                                                               follow_up_required?, follow_up_notes?, complete_phase?,
                                                               force_phase?, log_timesheet? = true,
                                                               latitude?, longitude? } -> { visit, warnings }
    - POST   /api/v2/field-service/visits/:uuid/no-access    - { reason }
    - POST   /api/v2/field-service/visits/:uuid/log-timesheet - Retry logging a completed visit to the timesheet
    Service manager only:
    - POST   /api/v2/field-service/visits/:uuid/cancel       - { reason? }
]]

local Http = require("helper.field-service-http")
local VisitQueries = require("queries.FieldServiceVisitQueries")

return function(app)
    local function is_assigned(self, visit)
        return visit.engineer_user_uuid ~= nil and visit.engineer_user_uuid == Http.actor(self)
    end

    -- Load the visit and check the caller may work it.
    local function with_visit(action, handler)
        return Http.route(function(self)
            local visit = VisitQueries.findVisitRow(self.namespace.id, self.params.uuid)
            if not visit then return Http.fail(404, "Visit not found") end
            if not (is_assigned(self, visit) or Http.has_perm(self, "fs_visits", action)) then
                return Http.forbidden("fs_visits", action)
            end
            return handler(self, visit)
        end)
    end

    -- Report fields an assigned engineer may correct without fs_visits.update.
    local ENGINEER_FIELDS = {
        work_summary = true, labour_hours = true, follow_up_required = true,
        follow_up_notes = true, customer_signoff_name = true,
    }

    app:get("/api/v2/field-service/visits", Http.route(function(self)
        local p = self.params
        local engineer = p.engineer_uuid
        -- Without fs_visits.read a member only ever sees their own visits.
        if p.mine == "true" or not Http.has_perm(self, "fs_visits", "read") then
            engineer = Http.actor(self)
        end
        local result = VisitQueries.listVisits(self.namespace.id, {
            job_uuid = p.job_uuid, engineer_uuid = engineer, status = p.status, from = p.from, to = p.to,
            follow_up = p.follow_up, search = p.search, page = p.page, per_page = p.per_page,
            order_dir = p.order_dir,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/jobs/:uuid/visits", Http.guard("fs_visits", "create", function(self)
        local result, err = VisitQueries.createVisit(self.namespace.id, self.params.uuid, Http.body(self),
            Http.actor(self))
        return Http.result(result, err, 201)
    end))

    app:get("/api/v2/field-service/visits/:uuid", with_visit("read", function(self)
        return Http.ok(VisitQueries.getVisit(self.namespace.id, self.params.uuid))
    end))

    app:put("/api/v2/field-service/visits/:uuid", with_visit("update", function(self, visit)
        local body = Http.body(self)
        local data = body
        if not Http.has_perm(self, "fs_visits", "update") then
            data = {}
            for k in pairs(ENGINEER_FIELDS) do data[k] = body[k] end
            if visit.status ~= "completed" and data.labour_hours ~= nil then
                return Http.fail(422, "Labour hours are recorded at check-out")
            end
        end
        return Http.result(VisitQueries.updateVisit(self.namespace.id, self.params.uuid, data, Http.actor(self)))
    end))

    app:delete("/api/v2/field-service/visits/:uuid", Http.guard("fs_visits", "delete", function(self)
        local ok, err = VisitQueries.deleteVisit(self.namespace.id, self.params.uuid, Http.actor(self))
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Visit deleted" })
    end))

    -- ============================================================
    -- ENGINEER WORKFLOW
    -- ============================================================

    app:post("/api/v2/field-service/visits/:uuid/en-route", with_visit("update", function(self)
        return Http.result(VisitQueries.markEnRoute(self.namespace.id, self.params.uuid, Http.actor(self)))
    end))

    app:post("/api/v2/field-service/visits/:uuid/check-in", with_visit("update", function(self)
        return Http.result(VisitQueries.checkIn(self.namespace.id, self.params.uuid, Http.body(self), Http.actor(self)))
    end))

    app:post("/api/v2/field-service/visits/:uuid/check-out", with_visit("update", function(self)
        return Http.result(VisitQueries.checkOut(self.namespace.id, self.params.uuid, Http.body(self),
            Http.actor(self)))
    end))

    app:post("/api/v2/field-service/visits/:uuid/no-access", with_visit("update", function(self)
        return Http.result(VisitQueries.markNoAccess(self.namespace.id, self.params.uuid, Http.body(self),
            Http.actor(self)))
    end))

    app:post("/api/v2/field-service/visits/:uuid/log-timesheet", with_visit("update", function(self)
        local result, err = VisitQueries.logTimesheet(self.namespace.id, self.params.uuid, Http.actor(self))
        return Http.result(result, err, 201)
    end))

    app:post("/api/v2/field-service/visits/:uuid/cancel", Http.guard("fs_visits", "update", function(self)
        return Http.result(VisitQueries.cancelVisit(self.namespace.id, self.params.uuid, Http.body(self),
            Http.actor(self)))
    end))
end
