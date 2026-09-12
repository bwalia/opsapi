--[[
    Field Service — shared HTTP helpers for routes/field-service-*.lua

    RBAC modules: fs_jobs, fs_visits, fs_sites, fs_job_types (see
    helper/project-config.lua). Namespace owners and platform admins pass
    every check, mirroring NamespaceMiddleware.requirePermission.

    Engineers are regular members: besides their module grants, the user
    assigned to a visit may always work that visit (en route / check in /
    check out / report) and log parts or tick checklists on its job.
]]

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RequestParser = require("helper.request_parser")

local Http = {}

function Http.ok(data, status, meta)
    return { status = status or 200, json = { success = true, data = data, meta = meta } }
end

function Http.fail(status, message)
    return { status = status, json = { success = false, error = message } }
end

--- Map a query-layer error string to an HTTP status.
function Http.from_error(err)
    err = tostring(err or "Request failed")
    if err:lower():match("not found") then return Http.fail(404, err) end
    if err == "Operation failed" then return Http.fail(500, err) end
    return Http.fail(422, err)
end

--- Render a query result: `result` or (nil, err).
function Http.result(result, err, status)
    if result == nil then return Http.from_error(err) end
    return Http.ok(result, status)
end

function Http.body(self)
    return RequestParser.parse_request(self)
end

function Http.actor(self)
    return self.current_user and self.current_user.uuid
end

function Http.has_perm(self, module, action)
    return NamespaceMiddleware.hasPermission(self, module, action)
end

--- True when the caller holds ANY of the { module, action } pairs.
function Http.any_perm(self, pairs_list)
    for _, p in ipairs(pairs_list) do
        if Http.has_perm(self, p[1], p[2]) then return true end
    end
    return false
end

function Http.forbidden(module, action)
    return {
        status = 403,
        json = { success = false, error = "Permission denied", required = { module = module, action = action } },
    }
end

--- Auth + namespace wrapper; the handler does its own permission checks.
function Http.route(handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(handler))
end

--- Auth + namespace + a single required permission.
function Http.guard(module, action, handler)
    return Http.route(function(self)
        if not Http.has_perm(self, module, action) then return Http.forbidden(module, action) end
        return handler(self)
    end)
end

--- Auth + namespace + any one of several permissions.
function Http.guard_any(pairs_list, handler)
    return Http.route(function(self)
        if not Http.any_perm(self, pairs_list) then
            return Http.forbidden(pairs_list[1][1], pairs_list[1][2])
        end
        return handler(self)
    end)
end

return Http
