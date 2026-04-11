--[[
    CRM Pipelines API Routes
    ========================

    RESTful API for CRM pipeline management.

    Endpoints:
    - GET    /api/v2/crm/pipelines          - List pipelines
    - POST   /api/v2/crm/pipelines          - Create pipeline
    - GET    /api/v2/crm/pipelines/:uuid     - Get pipeline
    - PUT    /api/v2/crm/pipelines/:uuid     - Update pipeline
    - DELETE /api/v2/crm/pipelines/:uuid     - Soft delete pipeline
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

    -- GET /api/v2/crm/pipelines - List pipelines
    app:get("/api/v2/crm/pipelines", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = CrmQueries.getPipelines(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page
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

    -- POST /api/v2/crm/pipelines - Create pipeline
    app:post("/api/v2/crm/pipelines", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.name or data.name == "" then
                return api_response(400, nil, "name is required")
            end

            local stages = data.stages
            if stages and type(stages) == "table" then
                stages = cjson.encode(stages)
            end

            local pipeline = CrmQueries.createPipeline({
                namespace_id = self.namespace.id,
                name = data.name,
                description = data.description,
                stages = stages or "[]",
                is_default = data.is_default or false
            })

            if not pipeline then
                return api_response(500, nil, "Failed to create pipeline")
            end

            return api_response(201, pipeline)
        end)
    ))

    -- GET /api/v2/crm/pipelines/:uuid - Get pipeline
    app:get("/api/v2/crm/pipelines/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local pipeline = CrmQueries.getPipeline(self.params.uuid)
            if not pipeline then
                return api_response(404, nil, "Pipeline not found")
            end

            if tonumber(pipeline.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, pipeline)
        end)
    ))

    -- PUT /api/v2/crm/pipelines/:uuid - Update pipeline
    app:put("/api/v2/crm/pipelines/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local pipeline = CrmQueries.getPipeline(self.params.uuid)
            if not pipeline then
                return api_response(404, nil, "Pipeline not found")
            end

            if tonumber(pipeline.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = { "name", "description", "is_default" }

            for _, field in ipairs(allowed_fields) do
                if data[field] ~= nil then
                    update_params[field] = data[field]
                end
            end

            if data.stages ~= nil then
                update_params.stages = type(data.stages) == "table" and cjson.encode(data.stages) or data.stages
            end

            if next(update_params) == nil then
                return api_response(400, nil, "No valid fields to update")
            end

            local updated = CrmQueries.updatePipeline(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update pipeline")
            end

            return api_response(200, updated)
        end)
    ))

    -- DELETE /api/v2/crm/pipelines/:uuid - Soft delete pipeline
    app:delete("/api/v2/crm/pipelines/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local pipeline = CrmQueries.getPipeline(self.params.uuid)
            if not pipeline then
                return api_response(404, nil, "Pipeline not found")
            end

            if tonumber(pipeline.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local deleted = CrmQueries.deletePipeline(self.params.uuid)
            if not deleted then
                return api_response(500, nil, "Failed to delete pipeline")
            end

            return api_response(200, { message = "Pipeline deleted successfully" })
        end)
    ))
end
