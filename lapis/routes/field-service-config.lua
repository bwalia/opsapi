--[[
    Field Service — configuration & lookup routes

    Endpoints:
    - GET    /api/v2/field-service/stats                          - Dashboard counters
    - GET    /api/v2/field-service/engineers                      - Workspace members (engineer / manager pickers)
    - GET    /api/v2/field-service/lookups/accounts               - CRM accounts (?search=)
    - GET    /api/v2/field-service/lookups/contacts               - CRM contacts (?account_uuid=&search=)

    - GET    /api/v2/field-service/job-types                      - List (?include_inactive=&with_phases=)
    - POST   /api/v2/field-service/job-types                      - Create (optional ordered `phases` array)
    - GET    /api/v2/field-service/job-types/:uuid                - Get with phase templates
    - PUT    /api/v2/field-service/job-types/:uuid                - Update
    - DELETE /api/v2/field-service/job-types/:uuid                - Soft delete
    - POST   /api/v2/field-service/job-types/:uuid/phases         - Add a phase template
    - PUT    /api/v2/field-service/job-types/:uuid/phases/reorder - Reorder ({ order = [uuid, ...] })
    - PUT    /api/v2/field-service/phase-templates/:uuid          - Update a phase template
    - DELETE /api/v2/field-service/phase-templates/:uuid          - Remove a phase template

    - GET    /api/v2/field-service/sites                          - List (?account_uuid=&search=&page=&per_page=)
    - POST   /api/v2/field-service/sites                          - Create
    - GET    /api/v2/field-service/sites/:uuid                    - Get
    - PUT    /api/v2/field-service/sites/:uuid                    - Update
    - DELETE /api/v2/field-service/sites/:uuid                    - Soft delete (blocked while open jobs use it)
]]

local Http = require("helper.field-service-http")
local ConfigQueries = require("queries.FieldServiceConfigQueries")
local JobQueries = require("queries.FieldServiceJobQueries")

return function(app)
    -- Anyone who works jobs or visits needs the pickers.
    local READERS = { { "fs_jobs", "read" }, { "fs_visits", "read" }, { "fs_sites", "read" } }
    local TYPE_READERS = { { "fs_job_types", "read" }, { "fs_jobs", "read" } }
    local SITE_READERS = { { "fs_sites", "read" }, { "fs_jobs", "read" } }

    -- ============================================================
    -- STATS & LOOKUPS
    -- ============================================================

    app:get("/api/v2/field-service/stats", Http.guard("fs_jobs", "read", function(self)
        return Http.ok(JobQueries.getStats(self.namespace.id))
    end))

    app:get("/api/v2/field-service/engineers", Http.guard_any(READERS, function(self)
        return Http.ok(ConfigQueries.listEngineers(self.namespace.id, { search = self.params.search }))
    end))

    app:get("/api/v2/field-service/lookups/accounts", Http.guard_any(READERS, function(self)
        return Http.ok(ConfigQueries.lookupAccounts(self.namespace.id, self.params.search))
    end))

    app:get("/api/v2/field-service/lookups/contacts", Http.guard_any(READERS, function(self)
        return Http.ok(ConfigQueries.lookupContacts(self.namespace.id, self.params.account_uuid, self.params.search))
    end))

    -- ============================================================
    -- JOB TYPES & PHASE TEMPLATES
    -- ============================================================

    app:get("/api/v2/field-service/job-types", Http.guard_any(TYPE_READERS, function(self)
        return Http.ok(ConfigQueries.listJobTypes(self.namespace.id, {
            include_inactive = self.params.include_inactive,
            with_phases = self.params.with_phases,
        }))
    end))

    app:post("/api/v2/field-service/job-types", Http.guard("fs_job_types", "create", function(self)
        local jt, err = ConfigQueries.createJobType(self.namespace.id, Http.body(self))
        return Http.result(jt, err, 201)
    end))

    app:get("/api/v2/field-service/job-types/:uuid", Http.guard_any(TYPE_READERS, function(self)
        local jt = ConfigQueries.getJobType(self.namespace.id, self.params.uuid)
        if not jt then return Http.fail(404, "Job type not found") end
        return Http.ok(jt)
    end))

    app:put("/api/v2/field-service/job-types/:uuid", Http.guard("fs_job_types", "update", function(self)
        return Http.result(ConfigQueries.updateJobType(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:delete("/api/v2/field-service/job-types/:uuid", Http.guard("fs_job_types", "delete", function(self)
        local ok, err = ConfigQueries.deleteJobType(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Job type deleted" })
    end))

    app:post("/api/v2/field-service/job-types/:uuid/phases", Http.guard("fs_job_types", "update", function(self)
        local tpl, err = ConfigQueries.addPhaseTemplate(self.namespace.id, self.params.uuid, Http.body(self))
        return Http.result(tpl, err, 201)
    end))

    app:put("/api/v2/field-service/job-types/:uuid/phases/reorder",
        Http.guard("fs_job_types", "update", function(self)
            local body = Http.body(self)
            return Http.result(ConfigQueries.reorderPhaseTemplates(self.namespace.id, self.params.uuid, body.order))
        end))

    app:put("/api/v2/field-service/phase-templates/:uuid", Http.guard("fs_job_types", "update", function(self)
        return Http.result(ConfigQueries.updatePhaseTemplate(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:delete("/api/v2/field-service/phase-templates/:uuid", Http.guard("fs_job_types", "update", function(self)
        local ok, err = ConfigQueries.deletePhaseTemplate(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Phase template removed" })
    end))

    -- ============================================================
    -- SITES
    -- ============================================================

    app:get("/api/v2/field-service/sites", Http.guard_any(SITE_READERS, function(self)
        local result = ConfigQueries.listSites(self.namespace.id, {
            account_uuid = self.params.account_uuid,
            search = self.params.search,
            page = self.params.page,
            per_page = self.params.per_page,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/sites", Http.guard("fs_sites", "create", function(self)
        local site, err = ConfigQueries.createSite(self.namespace.id, Http.body(self))
        return Http.result(site, err, 201)
    end))

    app:get("/api/v2/field-service/sites/:uuid", Http.guard_any(SITE_READERS, function(self)
        local site = ConfigQueries.getSite(self.namespace.id, self.params.uuid)
        if not site then return Http.fail(404, "Site not found") end
        return Http.ok(site)
    end))

    app:put("/api/v2/field-service/sites/:uuid", Http.guard("fs_sites", "update", function(self)
        return Http.result(ConfigQueries.updateSite(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:delete("/api/v2/field-service/sites/:uuid", Http.guard("fs_sites", "delete", function(self)
        local ok, err = ConfigQueries.deleteSite(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Site deleted" })
    end))
end
