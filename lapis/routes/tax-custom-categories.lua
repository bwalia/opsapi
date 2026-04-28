--[[
    Tax User Custom Categories Routes — issue #308 (user side)

    Lets a user manage their OWN custom category names. The admin
    moderation surface (approve/reject/promote, list across users) is
    in tax-admin-custom-categories.lua and is not reachable here.

    Endpoint summary:
      GET    /api/v2/tax/custom-categories          — list my customs
      GET    /api/v2/tax/custom-categories/:uuid    — detail (mine only)
      POST   /api/v2/tax/custom-categories          — create
      PUT    /api/v2/tax/custom-categories/:uuid    — rename (pending only)
      DELETE /api/v2/tax/custom-categories/:uuid    — soft-delete (pending only)

    The frontend's userCustomCategoryApi.rename uses lapisApi.put to match.
    PUT semantics fit better than PATCH here because the body is a full
    replacement of the editable field set (just `name` for now).

    Auth: every route is gated by AuthMiddleware.requireAuth. Admin/
    accountant gates are NOT applied — these are user-self-service
    endpoints. The query layer enforces user_uuid scoping so a logged-in
    user can never see or modify another user's customs through this
    surface, even via parameter manipulation.

    The feature flag (allow_user_custom_categories) is checked on POST.
    GET / PATCH / DELETE keep working when the flag flips off so users
    can clean up after themselves — locking them out of their own data
    is bad UX.
]]

local UserCustomCategoryQueries = require("queries.UserCustomCategoryQueries")
local RequestParser = require("helper.request_parser")
local AuthMiddleware = require("middleware.auth")

local function error_response(status, message, details)
    ngx.log(ngx.ERR, "[Custom Categories] ", message,
            details and (" | " .. tostring(details)) or "")
    return {
        status = status,
        json = {
            error = message,
            details = type(details) == "string" and details or nil,
        },
    }
end

local function user_uuid(self)
    if not self.current_user then return nil end
    return self.current_user.uuid or self.current_user.id
end

local function namespace_id(self)
    if self.current_user and self.current_user.namespace_id then
        return tonumber(self.current_user.namespace_id) or 0
    end
    -- Lapis sometimes nests namespace info under userinfo
    if self.current_user and self.current_user.userinfo
       and self.current_user.userinfo.namespace then
        local ns = self.current_user.userinfo.namespace
        return tonumber(ns.id or ns.namespace_id) or 0
    end
    return 0
end

return function(app)

    -- LIST my custom categories (optionally filtered by status)
    --   ?status=pending|approved|rejected|promoted|all  (default: all)
    app:get("/api/v2/tax/custom-categories",
        AuthMiddleware.requireAuth(function(self)
            local uid = user_uuid(self)
            if not uid or uid == "" then
                return error_response(401, "Authentication required")
            end

            local rows = UserCustomCategoryQueries.list_for_user(uid, {
                status = self.params.status,
            })

            return {
                status = 200,
                json = { data = rows or {}, total = #(rows or {}) }
            }
        end)
    )

    -- DETAIL — same shape as the list rows but a single row
    app:get("/api/v2/tax/custom-categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            local uid = user_uuid(self)
            if not uid or uid == "" then
                return error_response(401, "Authentication required")
            end

            local row = UserCustomCategoryQueries.get_for_user(uid, self.params.uuid)
            if not row then
                return error_response(404, "Custom category not found")
            end
            return { status = 200, json = { data = row } }
        end)
    )

    -- CREATE a new custom for me
    -- Body: { "name": "Bee Supplies" }
    app:post("/api/v2/tax/custom-categories",
        AuthMiddleware.requireAuth(function(self)
            local uid = user_uuid(self)
            if not uid or uid == "" then
                return error_response(401, "Authentication required")
            end

            local params = RequestParser.parse_request(self)
            -- Reject non-string values explicitly so a `{ name: true }` or
            -- `{ name: 42 }` body doesn't slip through and create a category
            -- with an unexpected name. RequestParser doesn't enforce types.
            if type(params.name) ~= "string" or #params.name == 0 then
                return error_response(400, "Field 'name' is required and must be a string")
            end

            local row, err, status = UserCustomCategoryQueries.create_for_user(
                uid, namespace_id(self), { name = params.name }
            )
            if not row then
                return error_response(status or 500, err)
            end

            return {
                status = 201,
                json = {
                    data = row,
                    message = "Custom category created. An admin will review it shortly.",
                },
            }
        end)
    )

    -- RENAME (pending only)
    -- Body: { "name": "New Name" }
    app:put("/api/v2/tax/custom-categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            local uid = user_uuid(self)
            if not uid or uid == "" then
                return error_response(401, "Authentication required")
            end

            local params = RequestParser.parse_request(self)
            if type(params.name) ~= "string" or #params.name == 0 then
                return error_response(400, "Field 'name' is required and must be a string")
            end

            local row, err, status = UserCustomCategoryQueries.rename_for_user(
                uid, self.params.uuid, params.name
            )
            if not row then
                return error_response(status or 500, err)
            end
            return {
                status = 200,
                json = { data = row, message = "Custom category renamed" },
            }
        end)
    )

    -- DELETE (pending + zero usage only). Soft-delete.
    app:delete("/api/v2/tax/custom-categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            local uid = user_uuid(self)
            if not uid or uid == "" then
                return error_response(401, "Authentication required")
            end

            local row, err, status = UserCustomCategoryQueries.delete_for_user(
                uid, self.params.uuid
            )
            if not row then
                return error_response(status or 500, err)
            end
            return {
                status = 200,
                json = { message = "Custom category deleted" },
            }
        end)
    )

    ngx.log(ngx.NOTICE, "[Custom Categories] user-side routes initialized")
end
