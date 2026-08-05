--[[
    Employment Routes — the Salary hub's backend surface (Phase 1 of the
    profile-builder unification, see
    docs/PROFILE_BUILDER_UNIFICATION_PLAN.md).

    Endpoints (all auth-required):
      GET    /api/v2/tax/employments                     list (hub)
      POST   /api/v2/tax/employments                     { label }
      GET    /api/v2/tax/employments/:uuid
      PUT    /api/v2/tax/employments/:uuid               { label?, metadata_json?, display_order? }
      DELETE /api/v2/tax/employments/:uuid               soft archive

    Employment-scope QUESTIONS are not served here — they come from the
    Profile Builder (?context=employment&entity=<uuid>) so admins keep
    full control of what's asked per employment without shipping code.

    Wire-up: added under load_if("tax_copilot", ...) in app.lua alongside
    tax-properties / tax-businesses. Off by default outside tax_copilot.
]]

local cjson = require("cjson")
local EmploymentQueries = require "queries.EmploymentQueries"
local AuthMiddleware = require("middleware.auth")

-- Parse JSON or form body — same helper shape as tax-properties.lua:
-- cjson.null stripped at the boundary so a JSON null behaves like an
-- absent key; body-file fallback for spooled bodies.
local function parse_request_body()
    ngx.req.read_body()
    local content_type = ngx.var.content_type or ""
    if content_type:find("application/json", 1, true) then
        local ok, result = pcall(function()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                local path = ngx.req.get_body_file()
                if path then
                    local f = io.open(path, "rb")
                    if f then
                        body = f:read("*a")
                        f:close()
                    end
                end
            end
            if not body or body == "" then return {} end
            return cjson.decode(body)
        end)
        if ok and type(result) == "table" then
            for k, v in pairs(result) do
                if v == cjson.null then result[k] = nil end
            end
            return result
        end
        return {}
    end
    local post_args = ngx.req.get_post_args()
    if post_args and next(post_args) then return post_args end
    return {}
end

local function merge_params(self)
    local body_params = parse_request_body()
    for k, v in pairs(body_params) do
        if self.params[k] == nil then self.params[k] = v end
    end
end

return function(app)
    app:get("/api/v2/tax/employments", AuthMiddleware.requireAuth(function(self)
        -- tax_year is optional. When present it decorates every row
        -- with pay/benefits/expenses/income/net totals derived from
        -- user_profile_answers — see EmploymentQueries.all's docstring
        -- for the key-set and grouping.
        local result, err = EmploymentQueries.all(self.params, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list employments" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:post("/api/v2/tax/employments", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if not self.params.label or tostring(self.params.label):gsub("%s", "") == "" then
            return { json = { error = "label is required" }, status = 400 }
        end
        if #tostring(self.params.label) > 120 then
            return { json = { error = "label must be 120 characters or fewer" }, status = 400 }
        end
        local row, err = EmploymentQueries.create(self.params, self.current_user)
        if not row then return { json = { error = err or "Failed to create employment" }, status = 400 } end
        return { json = { data = row }, status = 201 }
    end))

    app:get("/api/v2/tax/employments/:uuid", AuthMiddleware.requireAuth(function(self)
        local row = EmploymentQueries.show(tostring(self.params.uuid), self.current_user)
        if not row then return { json = { error = "Employment not found" }, status = 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:put("/api/v2/tax/employments/:uuid", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if self.params.label ~= nil and #tostring(self.params.label) > 120 then
            return { json = { error = "label must be 120 characters or fewer" }, status = 400 }
        end
        local row, err = EmploymentQueries.update(tostring(self.params.uuid), self.params, self.current_user)
        if not row then return { json = { error = err or "Employment not found" }, status = err and 400 or 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:delete("/api/v2/tax/employments/:uuid", AuthMiddleware.requireAuth(function(self)
        local ok = EmploymentQueries.archive(tostring(self.params.uuid), self.current_user)
        if not ok then return { json = { error = "Employment not found" }, status = 404 } end
        return { json = { message = "Employment archived" }, status = 200 }
    end))
end
