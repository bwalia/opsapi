--[[
    Field Service — customer assets, asset types, service levels, test history

    Endpoints:
    - GET    /api/v2/field-service/asset-types            - List (?discipline=&search=&include_inactive=)
    - POST   /api/v2/field-service/asset-types            - Create
    - PUT    /api/v2/field-service/asset-types/:uuid      - Update
    - GET    /api/v2/field-service/assets                 - List (see the filters below)
    - POST   /api/v2/field-service/assets                 - Create
    - GET    /api/v2/field-service/assets/:uuid           - Get (+ service levels + recent tests)
    - PUT    /api/v2/field-service/assets/:uuid           - Update
    - DELETE /api/v2/field-service/assets/:uuid           - Soft delete
    - GET    /api/v2/field-service/assets/:uuid/tests     - Test history (paged)
    - POST   /api/v2/field-service/assets/:uuid/tests     - Record a survey
    - POST   /api/v2/field-service/assets/:uuid/service-levels       - Add a schedule
    - PUT    /api/v2/field-service/service-levels/:uuid              - Update a schedule
    - DELETE /api/v2/field-service/service-levels/:uuid              - Remove a schedule

    Engineers survey on site, so recording a test needs only fs_assets update —
    the grant the engineer role gets. Restructuring the register (create, delete,
    re-parent) stays with the managers who hold fs_assets create/delete.
]]

local Http = require("helper.field-service-http")
local AssetQueries = require("queries.FieldServiceAssetQueries")

return function(app)
    -- Anyone working a job needs to see what they are working on.
    local READERS = {
        { "fs_assets", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" },
    }

    -- ---- Asset types -------------------------------------------------------

    app:get("/api/v2/field-service/asset-types", Http.guard_any(READERS, function(self)
        local result = AssetQueries.listAssetTypes(self.namespace.id, {
            discipline = self.params.discipline,
            search = self.params.search,
            include_inactive = self.params.include_inactive,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/asset-types", Http.guard("fs_assets", "create", function(self)
        local t, err = AssetQueries.createAssetType(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(t, err, 201)
    end))

    app:put("/api/v2/field-service/asset-types/:uuid", Http.guard("fs_assets", "update", function(self)
        return Http.result(AssetQueries.updateAssetType(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    -- ---- Assets ------------------------------------------------------------

    app:get("/api/v2/field-service/assets", Http.guard_any(READERS, function(self)
        local p = self.params
        local result = AssetQueries.listAssets(self.namespace.id, {
            site_uuid = p.site_uuid, customer_uuid = p.customer_uuid,
            asset_type_uuid = p.asset_type_uuid, contract_uuid = p.contract_uuid,
            status = p.status, discipline = p.discipline,
            condition_min = p.condition_min, fgas_only = p.fgas_only,
            service_overdue = p.service_overdue, include_archived = p.include_archived,
            search = p.search, page = p.page, per_page = p.per_page,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/assets", Http.guard("fs_assets", "create", function(self)
        local asset, err = AssetQueries.createAsset(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(asset, err, 201)
    end))

    app:get("/api/v2/field-service/assets/:uuid", Http.guard_any(READERS, function(self)
        local asset = AssetQueries.getAsset(self.namespace.id, self.params.uuid)
        if not asset then return Http.fail(404, "Asset not found") end
        return Http.ok(asset)
    end))

    app:put("/api/v2/field-service/assets/:uuid", Http.guard("fs_assets", "update", function(self)
        return Http.result(AssetQueries.updateAsset(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:delete("/api/v2/field-service/assets/:uuid", Http.guard("fs_assets", "delete", function(self)
        local ok, err = AssetQueries.deleteAsset(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Asset deleted" })
    end))

    -- ---- Test history ------------------------------------------------------

    app:get("/api/v2/field-service/assets/:uuid/tests", Http.guard_any(READERS, function(self)
        local result, err = AssetQueries.listTests(self.namespace.id, self.params.uuid, self.params)
        if not result then return Http.from_error(err) end
        return Http.ok(result.items, 200, result.meta)
    end))

    -- Recording a survey is what an engineer does on site, so it sits on the
    -- update grant rather than create.
    app:post("/api/v2/field-service/assets/:uuid/tests", Http.guard("fs_assets", "update", function(self)
        local test, err = AssetQueries.recordTest(
            self.namespace.id, Http.actor(self), self.params.uuid, Http.body(self))
        return Http.result(test, err, 201)
    end))

    -- ---- Service levels ----------------------------------------------------

    app:post("/api/v2/field-service/assets/:uuid/service-levels",
        Http.guard("fs_assets", "update", function(self)
            local level, err = AssetQueries.createServiceLevel(
                self.namespace.id, Http.actor(self), self.params.uuid, Http.body(self))
            return Http.result(level, err, 201)
        end))

    app:put("/api/v2/field-service/service-levels/:uuid",
        Http.guard("fs_assets", "update", function(self)
            return Http.result(AssetQueries.updateServiceLevel(
                self.namespace.id, self.params.uuid, Http.body(self)))
        end))

    app:delete("/api/v2/field-service/service-levels/:uuid",
        Http.guard("fs_assets", "delete", function(self)
            local ok, err = AssetQueries.deleteServiceLevel(self.namespace.id, self.params.uuid)
            if not ok then return Http.from_error(err) end
            return Http.ok({ message = "Service level removed" })
        end))
end
