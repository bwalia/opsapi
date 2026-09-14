--[[
    Field Service — asset (equipment) routes

    Endpoints:
    - GET    /api/v2/field-service/assets        - List (?account_uuid=&site_uuid=&status=&category=&search=&page=&per_page=)
    - POST   /api/v2/field-service/assets        - Create
    - GET    /api/v2/field-service/assets/:uuid  - Get
    - PUT    /api/v2/field-service/assets/:uuid  - Update
    - DELETE /api/v2/field-service/assets/:uuid  - Soft delete
]]

local Http = require("helper.field-service-http")
local AssetQueries = require("queries.FieldServiceAssetQueries")

return function(app)
    -- Anyone who reads assets, or builds jobs/visits, needs the list.
    local READERS = { { "fs_assets", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" } }

    app:get("/api/v2/field-service/assets", Http.guard_any(READERS, function(self)
        local result = AssetQueries.listAssets(self.namespace.id, {
            account_uuid = self.params.account_uuid,
            site_uuid = self.params.site_uuid,
            status = self.params.status,
            category = self.params.category,
            search = self.params.search,
            page = self.params.page,
            per_page = self.params.per_page,
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
end
