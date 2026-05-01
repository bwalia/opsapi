--[[
    CRM Deals API Routes
    ====================

    RESTful API for CRM deal/opportunity management.

    Endpoints:
    - GET    /api/v2/crm/deals                              - List deals
    - POST   /api/v2/crm/deals                              - Create deal
    - GET    /api/v2/crm/deals/:uuid                         - Get deal with joins
    - PUT    /api/v2/crm/deals/:uuid                         - Update deal
    - DELETE /api/v2/crm/deals/:uuid                         - Soft delete deal
    - GET    /api/v2/crm/deals/pipeline/:pipeline_uuid       - Deals grouped by stage
    - GET    /api/v2/crm/dashboard/stats                     - Dashboard statistics
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local CrmQueries = require("queries.CrmQueries")

return function(app)
    -- Helper to parse JSON body
    local function parse_json_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, data = pcall(cjson.decode, body)
        return ok and data or {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    -- GET /api/v2/crm/dashboard/stats - Dashboard statistics
    -- NOTE: This route must be defined before /api/v2/crm/deals/:uuid to avoid
    -- "dashboard" being captured as a :uuid parameter.
    app:get("/api/v2/crm/dashboard/stats", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local stats = CrmQueries.getDashboardStats(self.namespace.id)
            return api_response(200, stats)
        end)
    ))

    -- GET /api/v2/crm/deals/pipeline/:pipeline_uuid - Deals grouped by stage (kanban)
    -- NOTE: This route must be defined before /api/v2/crm/deals/:uuid to avoid
    -- "pipeline" being captured as a :uuid parameter.
    app:get("/api/v2/crm/deals/pipeline/:pipeline_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local pipeline = CrmQueries.getPipeline(self.params.pipeline_uuid)
            if not pipeline then
                return api_response(404, nil, "Pipeline not found")
            end

            if tonumber(pipeline.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local stages = CrmQueries.getDealsByPipeline(self.namespace.id, pipeline.id)
            return api_response(200, stages)
        end)
    ))

    -- GET /api/v2/crm/deals - List deals
    app:get("/api/v2/crm/deals", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = CrmQueries.getDeals(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                pipeline_id = self.params.pipeline_id,
                stage = self.params.stage,
                status = self.params.status,
                owner_user_uuid = self.params.owner,
                account_id = self.params.account_id
            })

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.items,
                    meta = result.meta
                }
            }
        end)
    ))

    -- POST /api/v2/crm/deals - Create deal
    app:post("/api/v2/crm/deals", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.name or data.name == "" then
                return api_response(400, nil, "name is required")
            end

            local metadata = data.metadata
            if metadata and type(metadata) == "table" then
                metadata = cjson.encode(metadata)
            end

            local deal = CrmQueries.createDeal({
                namespace_id = self.namespace.id,
                pipeline_id = data.pipeline_id,
                account_id = data.account_id,
                contact_id = data.contact_id,
                name = data.name,
                value = data.value or 0,
                currency = data.currency or "USD",
                stage = data.stage or "new",
                probability = data.probability or 0,
                expected_close_date = data.expected_close_date,
                owner_user_uuid = data.owner_user_uuid or self.current_user.uuid,
                status = data.status or "open",
                metadata = metadata or "{}"
            })

            if not deal then
                return api_response(500, nil, "Failed to create deal")
            end

            return api_response(201, deal)
        end)
    ))

    -- GET /api/v2/crm/deals/:uuid - Get deal with joins
    app:get("/api/v2/crm/deals/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local deal = CrmQueries.getDeal(self.params.uuid)
            if not deal then
                return api_response(404, nil, "Deal not found")
            end

            if tonumber(deal.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, deal)
        end)
    ))

    -- PUT /api/v2/crm/deals/:uuid - Update deal
    app:put("/api/v2/crm/deals/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local deal = CrmQueries.getDeal(self.params.uuid)
            if not deal then
                return api_response(404, nil, "Deal not found")
            end

            if tonumber(deal.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = {
                "name", "value", "currency", "stage", "probability",
                "expected_close_date", "actual_close_date", "lost_reason",
                "pipeline_id", "account_id", "contact_id",
                "owner_user_uuid", "status"
            }

            for _, field in ipairs(allowed_fields) do
                if data[field] ~= nil then
                    update_params[field] = data[field]
                end
            end

            if data.metadata ~= nil then
                update_params.metadata = type(data.metadata) == "table" and cjson.encode(data.metadata) or data.metadata
            end

            if next(update_params) == nil then
                return api_response(400, nil, "No valid fields to update")
            end

            local updated = CrmQueries.updateDeal(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update deal")
            end

            return api_response(200, updated)
        end)
    ))

    -- DELETE /api/v2/crm/deals/:uuid - Soft delete deal
    app:delete("/api/v2/crm/deals/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local deal = CrmQueries.getDeal(self.params.uuid)
            if not deal then
                return api_response(404, nil, "Deal not found")
            end

            if tonumber(deal.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local deleted = CrmQueries.deleteDeal(self.params.uuid)
            if not deleted then
                return api_response(500, nil, "Failed to delete deal")
            end

            return api_response(200, { message = "Deal deleted successfully" })
        end)
    ))
end
