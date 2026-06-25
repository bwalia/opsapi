--[[
    Income Sources Routes — the income questionnaire.

    Per-user "do you have income sources?" answer + the multi-select of income
    types picked from the income_types catalogue.

      GET /api/v2/tax/my-income-sources
        -> { data = { has_income_sources, selected = [keys], available = [{key,label}] } }

      PUT /api/v2/tax/my-income-sources   body: { has_income_sources, income_type_keys }
        -> replaces the selection set (validated against the active catalogue)
           and returns the saved state.

    Storage + validation live in queries/IncomeSelectionQueries.lua.
]]

local cjson = require("cjson")
local IncomeSelectionQueries = require "queries.IncomeSelectionQueries"
local AuthMiddleware = require("middleware.auth")

-- Parse JSON or form body. Identical to routes/my-incomes.lua — kept inline to
-- avoid a dependency on internal route shapes.
local function parse_request_body()
    ngx.req.read_body()
    local content_type = ngx.var.content_type or ""
    if content_type:find("application/json", 1, true) then
        local ok, result = pcall(function()
            local body = ngx.req.get_body_data()
            if not body or body == "" then return {} end
            return cjson.decode(body)
        end)
        if ok and type(result) == "table" then return result end
        return {}
    end
    local post_args = ngx.req.get_post_args()
    if post_args and next(post_args) then return post_args end
    return {}
end

return function(app)
    -- Current answer + selection + available catalogue
    app:get("/api/v2/tax/my-income-sources", AuthMiddleware.requireAuth(function(self)
        local result, err = IncomeSelectionQueries.get(self.current_user)
        if not result then
            return { json = { error = err or "Failed to load income sources" }, status = 400 }
        end
        return { json = { data = result }, status = 200 }
    end))

    -- Save answer + selection (replace-the-whole-set)
    app:put("/api/v2/tax/my-income-sources", AuthMiddleware.requireAuth(function(self)
        local body = parse_request_body()
        local result, err = IncomeSelectionQueries.save(
            self.current_user, body.has_income_sources, body.income_type_keys)
        if not result then
            return { json = { error = err or "Failed to save income sources" }, status = 400 }
        end
        return { json = { data = result }, status = 200 }
    end))
end
