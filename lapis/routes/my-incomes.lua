--[[
    My Income Routes

    CRUD on the user's manually-entered income rows. All endpoints require
    auth. Server-authoritative validation of:
      - income_type (catalogue below)
      - amount > 0
      - tax_year matches YYYY-YY

    Frontend uses the same constraints for inline UX but the source of
    truth is here.
]]

local cjson = require("cjson")
local MyIncomeQueries = require "queries.MyIncomeQueries"
local AuthMiddleware = require("middleware.auth")

-- Fixed catalogue. Drive the frontend dropdown from this list.
local VALID_INCOME_TYPES = {
    salary          = true,
    self_employment = true,
    dividends       = true,
    rental          = true,
    interest        = true,
    pension         = true,
    capital_gains   = true,
    other           = true,
}
local function income_type_list()
    local keys = {}
    for k in pairs(VALID_INCOME_TYPES) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- YYYY-YY (e.g. 2026-27). Server-side regex; frontend mirrors.
local function valid_tax_year(s)
    if type(s) ~= "string" then return false end
    local y1, y2 = s:match("^(%d%d%d%d)%-(%d%d)$")
    if not y1 or not y2 then return false end
    local n1, n2 = tonumber(y1), tonumber(y2)
    -- y2 must be (y1+1) mod 100, e.g. 2026-27 ok, 2026-28 not ok
    return n2 == (n1 + 1) % 100
end

-- Validate input. `is_create=true` enforces required fields.
local function validate(params, is_create)
    if is_create or params.amount ~= nil then
        local n = tonumber(params.amount)
        if not n or n <= 0 then
            return false, "amount is required and must be a positive number"
        end
        params.amount = n
    end

    if is_create or params.income_type ~= nil then
        if not params.income_type or not VALID_INCOME_TYPES[params.income_type] then
            return false, "income_type must be one of: " .. table.concat(income_type_list(), ", ")
        end
    end

    if is_create or params.tax_year ~= nil then
        if not valid_tax_year(params.tax_year) then
            return false, "tax_year must be YYYY-YY (e.g. 2026-27)"
        end
    end

    if params.description and type(params.description) == "string" and #params.description > 500 then
        return false, "description must be 500 characters or fewer"
    end

    return true
end

-- Parse JSON or form body. Identical to tax-bank-accounts.lua — kept inline
-- (not extracted to a helper) to avoid a dependency on internal route shapes.
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

local function merge_params(self)
    local body_params = parse_request_body()
    for k, v in pairs(body_params) do
        if self.params[k] == nil then self.params[k] = v end
    end
end

return function(app)
    -- Catalogue (open — small and stable, useful for the frontend dropdown
    -- on first load. Behind auth anyway because the rest of the surface is.)
    app:get("/api/v2/tax/my-incomes/types", AuthMiddleware.requireAuth(function(_)
        return {
            json = {
                data = {
                    { key = "salary",          label = "Salary / Employment (PAYE)" },
                    { key = "self_employment", label = "Self-employment / Sole trader" },
                    { key = "dividends",       label = "Dividends" },
                    { key = "rental",          label = "Rental / Property income" },
                    { key = "interest",        label = "Bank interest" },
                    { key = "pension",         label = "Pension income" },
                    { key = "capital_gains",   label = "Capital gains" },
                    { key = "other",           label = "Other income" },
                },
            },
            status = 200,
        }
    end))

    -- List
    app:get("/api/v2/tax/my-incomes", AuthMiddleware.requireAuth(function(self)
        local result, err = MyIncomeQueries.all(self.params, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list incomes" }, status = 400 }
        end
        return { json = result, status = 200 }
    end))

    -- Create
    app:post("/api/v2/tax/my-incomes", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        local ok, vmsg = validate(self.params, true)
        if not ok then return { json = { error = vmsg }, status = 400 } end
        local row, err = MyIncomeQueries.create(self.params, self.current_user)
        if not row then return { json = { error = err or "Failed to create income" }, status = 400 } end
        return { json = { data = row }, status = 201 }
    end))

    -- Get one
    app:get("/api/v2/tax/my-incomes/:id", AuthMiddleware.requireAuth(function(self)
        local row = MyIncomeQueries.show(tostring(self.params.id), self.current_user)
        if not row then return { json = { error = "Income row not found" }, status = 404 } end
        return { json = { data = row }, status = 200 }
    end))

    -- Update
    app:put("/api/v2/tax/my-incomes/:id", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        local ok, vmsg = validate(self.params, false)
        if not ok then return { json = { error = vmsg }, status = 400 } end
        local row, err = MyIncomeQueries.update(tostring(self.params.id), self.params, self.current_user)
        if not row then return { json = { error = err or "Income row not found" }, status = 404 } end
        return { json = { data = row }, status = 200 }
    end))

    -- Soft delete (archive)
    app:delete("/api/v2/tax/my-incomes/:id", AuthMiddleware.requireAuth(function(self)
        local ok = MyIncomeQueries.archive(tostring(self.params.id), self.current_user)
        if not ok then return { json = { error = "Income row not found" }, status = 404 } end
        return { json = { message = "Income row archived" }, status = 200 }
    end))
end
