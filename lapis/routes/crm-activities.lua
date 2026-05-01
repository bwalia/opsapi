--[[
    CRM Activities API Routes
    =========================

    RESTful API for CRM activity tracking (calls, emails, meetings, notes, tasks).

    Endpoints:
    - GET    /api/v2/crm/activities                  - List activities
    - POST   /api/v2/crm/activities                  - Create activity
    - GET    /api/v2/crm/activities/:uuid             - Get activity
    - PUT    /api/v2/crm/activities/:uuid             - Update activity
    - DELETE /api/v2/crm/activities/:uuid             - Soft delete activity
    - POST   /api/v2/crm/activities/:uuid/complete    - Mark activity as completed
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

    -- POST /api/v2/crm/activities/:uuid/complete - Mark activity as completed
    -- NOTE: This route must be defined before /api/v2/crm/activities/:uuid to avoid
    -- route conflicts.
    app:post("/api/v2/crm/activities/:uuid/complete", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local activity = CrmQueries.getActivity(self.params.uuid)
            if not activity then
                return api_response(404, nil, "Activity not found")
            end

            if tonumber(activity.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local completed = CrmQueries.completeActivity(self.params.uuid)
            if not completed then
                return api_response(500, nil, "Failed to complete activity")
            end

            return api_response(200, completed)
        end)
    ))

    -- GET /api/v2/crm/activities - List activities
    app:get("/api/v2/crm/activities", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = CrmQueries.getActivities(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                activity_type = self.params.activity_type,
                account_id = self.params.account_id,
                contact_id = self.params.contact_id,
                deal_id = self.params.deal_id,
                status = self.params.status
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

    -- POST /api/v2/crm/activities - Create activity
    app:post("/api/v2/crm/activities", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.subject or data.subject == "" then
                return api_response(400, nil, "subject is required")
            end

            if not data.activity_type or data.activity_type == "" then
                return api_response(400, nil, "activity_type is required")
            end

            local metadata = data.metadata
            if metadata and type(metadata) == "table" then
                metadata = cjson.encode(metadata)
            end

            local activity = CrmQueries.createActivity({
                namespace_id = self.namespace.id,
                activity_type = data.activity_type,
                subject = data.subject,
                description = data.description,
                account_id = data.account_id,
                contact_id = data.contact_id,
                deal_id = data.deal_id,
                owner_user_uuid = data.owner_user_uuid or self.current_user.uuid,
                activity_date = data.activity_date,
                duration_minutes = data.duration_minutes,
                status = data.status or "planned",
                metadata = metadata or "{}"
            })

            if not activity then
                return api_response(500, nil, "Failed to create activity")
            end

            return api_response(201, activity)
        end)
    ))

    -- GET /api/v2/crm/activities/:uuid - Get activity
    app:get("/api/v2/crm/activities/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local activity = CrmQueries.getActivity(self.params.uuid)
            if not activity then
                return api_response(404, nil, "Activity not found")
            end

            if tonumber(activity.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, activity)
        end)
    ))

    -- PUT /api/v2/crm/activities/:uuid - Update activity
    app:put("/api/v2/crm/activities/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local activity = CrmQueries.getActivity(self.params.uuid)
            if not activity then
                return api_response(404, nil, "Activity not found")
            end

            if tonumber(activity.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = {
                "activity_type", "subject", "description",
                "account_id", "contact_id", "deal_id",
                "owner_user_uuid", "activity_date", "duration_minutes", "status"
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

            local updated = CrmQueries.updateActivity(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update activity")
            end

            return api_response(200, updated)
        end)
    ))

    -- DELETE /api/v2/crm/activities/:uuid - Soft delete activity
    app:delete("/api/v2/crm/activities/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local activity = CrmQueries.getActivity(self.params.uuid)
            if not activity then
                return api_response(404, nil, "Activity not found")
            end

            if tonumber(activity.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local deleted = CrmQueries.deleteActivity(self.params.uuid)
            if not deleted then
                return api_response(500, nil, "Failed to delete activity")
            end

            return api_response(200, { message = "Activity deleted successfully" })
        end)
    ))
end
