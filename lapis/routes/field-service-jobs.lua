--[[
    Field Service — job, phase, item and invoicing routes

    Endpoints:
    - GET    /api/v2/field-service/jobs                        - List (?status=open|<status>&priority=&account_uuid=
                                                                 &site_uuid=&job_type_uuid=&manager_uuid=&engineer_uuid=
                                                                 &overdue=&uninvoiced=&search=&page=&per_page=
                                                                 &order_by=&order_dir=)
    - POST   /api/v2/field-service/jobs                        - Create (phases copied from job_type_uuid's templates,
                                                                 or an explicit `phases` array)
    - GET    /api/v2/field-service/jobs/:uuid                  - Job + phases + visits + items + activity + totals
    - PUT    /api/v2/field-service/jobs/:uuid                  - Update details
    - DELETE /api/v2/field-service/jobs/:uuid                  - Soft delete (not once invoiced)
    - POST   /api/v2/field-service/jobs/:uuid/status           - { status, reason?, force? }

    - POST   /api/v2/field-service/jobs/:uuid/phases           - Add a phase
    - PUT    /api/v2/field-service/jobs/:uuid/phases/reorder   - { order = [phase uuid, ...] }
    - PUT    /api/v2/field-service/job-phases/:uuid            - Update a phase
    - DELETE /api/v2/field-service/job-phases/:uuid            - Remove a phase
    - POST   /api/v2/field-service/job-phases/:uuid/status     - { status, signoff_name?, force?, notes? }
    - POST   /api/v2/field-service/job-phases/:uuid/checklist/:index - { done } (0-based index)

    - POST   /api/v2/field-service/jobs/:uuid/items            - Log a part / material / expense
    - PUT    /api/v2/field-service/job-items/:uuid             - Update (not once invoiced)
    - DELETE /api/v2/field-service/job-items/:uuid             - Remove (not once invoiced)

    - GET    /api/v2/field-service/jobs/:uuid/invoice-preview  - Uninvoiced billable lines (?hourly_rate=&labour_tax_rate=)
    - POST   /api/v2/field-service/jobs/:uuid/invoice          - Bill them as one draft invoice
                                                                 { hourly_rate?, labour_tax_rate?, due_date?, notes? }

    Engineers assigned to a visit on a job may view it, tick checklists,
    start/complete/block its phases and log items against it without holding
    fs_jobs grants.
]]

local Http = require("helper.field-service-http")
local Common = require("queries.FieldServiceCommon")
local JobQueries = require("queries.FieldServiceJobQueries")

return function(app)
    -- fs_jobs.<action>, or the caller is an engineer booked on the job.
    local function can_work_job(self, job_id, action)
        return Http.has_perm(self, "fs_jobs", action) or Common.is_engineer_on_job(job_id, Http.actor(self))
    end

    -- ============================================================
    -- JOBS
    -- ============================================================

    app:get("/api/v2/field-service/jobs", Http.guard("fs_jobs", "read", function(self)
        local p = self.params
        local result = JobQueries.listJobs(self.namespace.id, {
            status = p.status, priority = p.priority, account_uuid = p.account_uuid, site_uuid = p.site_uuid,
            job_type_uuid = p.job_type_uuid, manager_uuid = p.manager_uuid, engineer_uuid = p.engineer_uuid,
            overdue = p.overdue, uninvoiced = p.uninvoiced, search = p.search,
            page = p.page, per_page = p.per_page, order_by = p.order_by, order_dir = p.order_dir,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/jobs", Http.guard("fs_jobs", "create", function(self)
        local job, err = JobQueries.createJob(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(job, err, 201)
    end))

    app:get("/api/v2/field-service/jobs/:uuid", Http.route(function(self)
        local row = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, "Job not found") end
        if not can_work_job(self, row.id, "read") then return Http.forbidden("fs_jobs", "read") end
        return Http.ok(JobQueries.getJob(self.namespace.id, self.params.uuid))
    end))

    app:put("/api/v2/field-service/jobs/:uuid", Http.guard("fs_jobs", "update", function(self)
        return Http.result(JobQueries.updateJob(self.namespace.id, self.params.uuid, Http.body(self), Http.actor(self)))
    end))

    app:delete("/api/v2/field-service/jobs/:uuid", Http.guard("fs_jobs", "delete", function(self)
        local ok, err = JobQueries.deleteJob(self.namespace.id, self.params.uuid, Http.actor(self))
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Job deleted" })
    end))

    app:post("/api/v2/field-service/jobs/:uuid/status", Http.guard("fs_jobs", "update", function(self)
        local body = Http.body(self)
        if not body.status or body.status == "" then return Http.fail(400, "status is required") end
        return Http.result(JobQueries.setJobStatus(self.namespace.id, self.params.uuid, body.status, {
            reason = body.reason, force = body.force,
        }, Http.actor(self)))
    end))

    -- ============================================================
    -- PHASES
    -- ============================================================

    app:post("/api/v2/field-service/jobs/:uuid/phases", Http.guard("fs_jobs", "update", function(self)
        local phase, err = JobQueries.addPhase(self.namespace.id, self.params.uuid, Http.body(self), Http.actor(self))
        return Http.result(phase, err, 201)
    end))

    app:put("/api/v2/field-service/jobs/:uuid/phases/reorder", Http.guard("fs_jobs", "update", function(self)
        local body = Http.body(self)
        return Http.result(JobQueries.reorderPhases(self.namespace.id, self.params.uuid, body.order, Http.actor(self)))
    end))

    app:put("/api/v2/field-service/job-phases/:uuid", Http.guard("fs_jobs", "update", function(self)
        return Http.result(JobQueries.updatePhase(self.namespace.id, self.params.uuid, Http.body(self),
            Http.actor(self)))
    end))

    app:delete("/api/v2/field-service/job-phases/:uuid", Http.guard("fs_jobs", "update", function(self)
        local ok, err = JobQueries.deletePhase(self.namespace.id, self.params.uuid, Http.actor(self))
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Phase removed" })
    end))

    -- Engineers on site may move a phase through the working states; skipping
    -- or reopening to pending is a service-manager decision.
    local ENGINEER_PHASE_STATUSES = { in_progress = true, blocked = true, completed = true }

    app:post("/api/v2/field-service/job-phases/:uuid/status", Http.route(function(self)
        local phase = JobQueries.findPhaseRow(self.namespace.id, self.params.uuid)
        if not phase then return Http.fail(404, "Phase not found") end
        local body = Http.body(self)
        if not body.status or body.status == "" then return Http.fail(400, "status is required") end

        local allowed = Http.has_perm(self, "fs_jobs", "update")
            or (ENGINEER_PHASE_STATUSES[body.status] and Common.is_engineer_on_job(phase.job_id, Http.actor(self)))
        if not allowed then return Http.forbidden("fs_jobs", "update") end

        return Http.result(JobQueries.setPhaseStatus(self.namespace.id, self.params.uuid, body.status, {
            signoff_name = body.signoff_name, force = body.force, notes = body.notes,
        }, Http.actor(self)))
    end))

    app:post("/api/v2/field-service/job-phases/:uuid/checklist/:index", Http.route(function(self)
        local phase = JobQueries.findPhaseRow(self.namespace.id, self.params.uuid)
        if not phase then return Http.fail(404, "Phase not found") end
        if not can_work_job(self, phase.job_id, "update") then return Http.forbidden("fs_jobs", "update") end
        local body = Http.body(self)
        return Http.result(JobQueries.setChecklistItem(self.namespace.id, self.params.uuid, self.params.index,
            body.done, Http.actor(self)))
    end))

    -- ============================================================
    -- ITEMS (parts / materials / expenses)
    -- ============================================================

    app:post("/api/v2/field-service/jobs/:uuid/items", Http.route(function(self)
        local job = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if not job then return Http.fail(404, "Job not found") end
        if not can_work_job(self, job.id, "update") then return Http.forbidden("fs_jobs", "update") end
        local item, err = JobQueries.addItem(self.namespace.id, self.params.uuid, Http.body(self), Http.actor(self))
        return Http.result(item, err, 201)
    end))

    -- Managers edit any item; an engineer only the items they logged.
    local function can_edit_item(self, item)
        if Http.has_perm(self, "fs_jobs", "update") then return true end
        return item.created_by_uuid == Http.actor(self) and Common.is_engineer_on_job(item.job_id, Http.actor(self))
    end

    app:put("/api/v2/field-service/job-items/:uuid", Http.route(function(self)
        local item = JobQueries.findItemRow(self.namespace.id, self.params.uuid)
        if not item then return Http.fail(404, "Item not found") end
        if not can_edit_item(self, item) then return Http.forbidden("fs_jobs", "update") end
        return Http.result(JobQueries.updateItem(self.namespace.id, self.params.uuid, Http.body(self),
            Http.actor(self)))
    end))

    app:delete("/api/v2/field-service/job-items/:uuid", Http.route(function(self)
        local item = JobQueries.findItemRow(self.namespace.id, self.params.uuid)
        if not item then return Http.fail(404, "Item not found") end
        if not can_edit_item(self, item) then return Http.forbidden("fs_jobs", "update") end
        local ok, err = JobQueries.deleteItem(self.namespace.id, self.params.uuid, Http.actor(self))
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Item removed" })
    end))

    -- ============================================================
    -- INVOICING
    -- ============================================================

    app:get("/api/v2/field-service/jobs/:uuid/invoice-preview", Http.guard("fs_jobs", "read", function(self)
        return Http.result(JobQueries.invoicePreview(self.namespace.id, self.params.uuid, {
            hourly_rate = self.params.hourly_rate,
            labour_tax_rate = self.params.labour_tax_rate,
        }))
    end))

    app:post("/api/v2/field-service/jobs/:uuid/invoice", Http.guard("fs_jobs", "update", function(self)
        if not Http.has_perm(self, "invoices", "create") then return Http.forbidden("invoices", "create") end
        local body = Http.body(self)
        local invoice, err = JobQueries.createInvoice(self.namespace.id, self.params.uuid, Http.actor(self), {
            hourly_rate = body.hourly_rate,
            labour_tax_rate = body.labour_tax_rate,
            due_date = body.due_date,
            notes = body.notes,
        })
        return Http.result(invoice, err, 201)
    end))
end
