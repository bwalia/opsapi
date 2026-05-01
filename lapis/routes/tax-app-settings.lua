--[[
    Tax App Settings Routes — issue #308

    Admin CRUD on tax_app_settings (the global key/value store) plus a
    tiny non-admin endpoint that exposes only the settings flagged as
    public (is_admin_only = false). The classify page calls the public
    endpoint to learn whether allow_user_category_editing /
    allow_user_custom_categories are on.

    Auth model:
      - GET  /api/v2/admin/settings        — admin only (full list)
      - GET  /api/v2/admin/settings/:key   — admin only
      - PUT  /api/v2/admin/settings/:key   — admin only (writes)
      - GET  /api/v2/settings/public        — any authenticated user
                                              (returns is_admin_only=false rows)

    Admin check uses the centralized AdminCheck module (platform-level
    role gate), matching the pattern in permissions.lua. Validation
    (cross-setting invariants, type checking) happens in
    AppSettingsQueries — the route layer just translates HTTP↔Lua.
]]

local AppSettingsQueries = require("queries.AppSettingsQueries")
local RequestParser = require("helper.request_parser")
local AuthMiddleware = require("middleware.auth")
local AdminCheck = require("helper.admin-check")
local cjson = require("cjson")

cjson.encode_empty_table_as_object(false)

local function is_admin(user)
    return AdminCheck.isPlatformAdmin(user)
end

local function error_response(status, message, details)
    ngx.log(ngx.ERR, "[App Settings] ", message,
            details and (" | " .. tostring(details)) or "")
    return {
        status = status,
        json = {
            error = message,
            details = type(details) == "string" and details or nil,
        },
    }
end

return function(app)

    -- LIST all settings (admin only)
    -- Optional query param: ?category=classification
    app:get("/api/v2/admin/settings", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local ok, result = pcall(AppSettingsQueries.list, {
            category = self.params.category,
        })
        if not ok then
            return error_response(500, "Failed to list settings", tostring(result))
        end

        return { status = 200, json = { data = result, total = #result } }
    end))

    -- GET single setting by key (admin only)
    app:get("/api/v2/admin/settings/:key", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local ok, row = pcall(AppSettingsQueries.get, self.params.key)
        if not ok then
            return error_response(500, "Failed to fetch setting", tostring(row))
        end
        if not row then
            return error_response(404, "Setting not found")
        end
        return { status = 200, json = { data = row } }
    end))

    -- UPDATE a setting (admin only).
    -- Body: { "value": <typed value> }
    -- Cross-setting invariants (e.g. enabling custom categories requires
    -- editing) are enforced inside AppSettingsQueries.set, not here.
    app:put("/api/v2/admin/settings/:key", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local params = RequestParser.parse_request(self)
        if params.value == nil then
            return error_response(400, "Field 'value' is required in request body")
        end

        -- Most clients will send JSON; some legacy callers might send the
        -- value as a string. Try to JSON-decode strings that look like
        -- typed primitives so the type check downstream is accurate.
        local value = params.value
        if type(value) == "string" then
            local ok, decoded = pcall(cjson.decode, value)
            if ok then value = decoded end
        end

        local user_uuid = self.current_user and (
            self.current_user.uuid or self.current_user.id
        ) or nil

        local ok, row, err = pcall(
            AppSettingsQueries.set, self.params.key, value, user_uuid
        )
        if not ok then
            return error_response(500, "Failed to update setting", tostring(row))
        end
        if not row and err then
            return error_response(422, err)
        end

        return {
            status = 200,
            json = { data = row, message = "Setting updated" }
        }
    end))

    -- PUBLIC settings — returns only rows with is_admin_only = false.
    -- Authenticated but no admin gate — used by the classify page on every
    -- statement load to know whether the edit affordance should render.
    app:get("/api/v2/settings/public", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(AppSettingsQueries.list_public)
        if not ok then
            return error_response(500, "Failed to list public settings",
                                  tostring(result))
        end
        return { status = 200, json = { data = result, total = #result } }
    end))

    ngx.log(ngx.NOTICE, "[App Settings] routes initialized")
end
