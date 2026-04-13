--[[
    Module Routes

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.
]]

local respond_to = require("lapis.application").respond_to
local ModuleQueries = require "queries.ModuleQueries"
local AuthMiddleware = require("middleware.auth")
local AdminCheck = require("helper.admin-check")
local db = require("lapis.db")

--- Extract safe error message from pcall error, log full details server-side
local function safe_error(err, fallback)
    local msg = tostring(err)
    ngx.log(ngx.ERR, "Module operation failed: ", msg)
    -- Only expose business logic errors, not DB/system internals
    if msg:match("already exists") or msg:match("is required")
        or msg:match("Cannot delete") or msg:match("is assigned to") then
        return msg
    end
    return fallback or "Operation failed"
end

return function(app)
    -- GET /api/v2/modules/available — list active modules for permission UIs
    app:get("/api/v2/modules/available", AuthMiddleware.requireAuth(function(self)
        local ok, modules = pcall(db.query,
            "SELECT machine_name, name, description, category, default_actions "
            .. "FROM modules WHERE is_active = true ORDER BY category, name"
        )
        if not ok then
            return { json = { error = "Failed to fetch modules" }, status = 500 }
        end
        -- Parse default_actions string into array
        for _, m in ipairs(modules or {}) do
            local actions = {}
            for action in (m.default_actions or ""):gmatch("[^,]+") do
                table.insert(actions, action:match("^%s*(.-)%s*$"))
            end
            m.actions = actions
            m.default_actions = nil
        end
        return { json = { modules = modules } }
    end))

    app:match("modules", "/api/v2/modules", respond_to({
        before = function(self)
            AuthMiddleware.requireAuthBefore(self)
            if self.res and self.res.status then return end

            -- Write operations require platform admin
            if self.req.method ~= "GET" then
                if not AdminCheck.isPlatformAdmin(self.current_user) then
                    self:write({
                        json = { error = "Platform admin access required" },
                        status = 403
                    })
                    return
                end
            end
        end,

        GET = function(self)
            self.params.timestamp = true
            local modules = ModuleQueries.all(self.params)
            return {
                json = modules
            }
        end,
        POST = function(self)
            local ok, module = pcall(ModuleQueries.create, self.params)
            if not ok then
                return { json = { error = safe_error(module, "Failed to create module") }, status = 400 }
            end
            if not module then
                return { json = { error = "Failed to create module" }, status = 500 }
            end
            return {
                json = module,
                status = 201
            }
        end
    }))

    app:match("edit_module", "/api/v2/modules/:id", respond_to({
        before = function(self)
            -- First authenticate
            AuthMiddleware.requireAuthBefore(self)
            if self.res and self.res.status then return end

            -- Write operations require platform admin
            if self.req.method ~= "GET" then
                if not AdminCheck.isPlatformAdmin(self.current_user) then
                    self:write({
                        json = { error = "Platform admin access required" },
                        status = 403
                    })
                    return
                end
            end

            self.module = ModuleQueries.show(tostring(self.params.id))
            if not self.module then
                self:write({
                    json = { error = "Module not found" },
                    status = 404
                })
            end
        end,
        GET = function(self)
            return {
                json = self.module,
                status = 200
            }
        end,
        PUT = function(self)
            local ok, module = pcall(ModuleQueries.update, tostring(self.params.id), self.params)
            if not ok then
                return { json = { error = safe_error(module, "Failed to update module") }, status = 400 }
            end
            if not module then
                return { json = { error = "Module not found" }, status = 404 }
            end
            return {
                json = module,
                status = 200
            }
        end,
        DELETE = function(self)
            local ok, err = pcall(ModuleQueries.destroy, tostring(self.params.id))
            if not ok then
                return { json = { error = safe_error(err, "Failed to delete module") }, status = 400 }
            end
            return {
                json = { message = "Module deleted successfully" },
                status = 200
            }
        end
    }))
end
