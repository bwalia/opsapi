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
local IncomeTypeQueries = require "queries.IncomeTypeQueries"
local AuthMiddleware = require("middleware.auth")

-- Income types are now an admin-managed catalogue (income_types table) rather
-- than a hard-coded Lua list. Both helpers read the active set on demand —
-- low-frequency paths (validation + the /types dropdown), so no cache needed.
-- See queries/IncomeTypeQueries.lua and routes/tax-admin-income-types.lua.
-- Writes validate against manual_entry_keys(), not active_keys(): catalogue
-- rows with allows_manual_entry = false (e.g. 'pension_payments', a RELIEF)
-- are selectable in the questionnaire but must never become my_incomes rows —
-- the calculation sums my_incomes as INCOME, which would move the estimate
-- the wrong way for a relief. Unchanged types on update are grandfathered
-- below, so existing rows stay editable if an admin flips the flag later.
local function valid_income_type(key)
    if not key or key == "" then return false end
    return IncomeTypeQueries.manual_entry_keys()[key] == true
end
local function income_type_list()
    local keys = {}
    for k in pairs(IncomeTypeQueries.manual_entry_keys()) do keys[#keys + 1] = k end
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
        if not valid_income_type(params.income_type) then
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
        -- Catalogue-backed: returns the active income_types rows (admin-managed)
        -- as { key, label } so the frontend dropdown stays in lockstep with
        -- server-side validation. Previously a hard-coded list inline here.
        local rows = IncomeTypeQueries.list_active()
        local data = {}
        for _, r in ipairs(rows) do
            -- required_documents may decode to an empty table for types with no
            -- docs; coerce to [] so JSON consumers can .map it safely.
            local docs = r.required_documents
            if type(docs) ~= "table" or #docs == 0 then docs = cjson.empty_array end
            data[#data + 1] = {
                key = r.income_type_key,
                label = r.display_name,
                -- Admin-configured plain-English description shown under the
                -- H1 on the income type's page. Optional in the schema (text
                -- null=true) — pass through as-is, incl. the empty string,
                -- so the frontend can distinguish "admin left it blank" from
                -- "backend forgot to send it".
                description = r.description,
                required_documents = docs,
                allows_manual_entry = r.allows_manual_entry,
            }
        end
        -- Force [] (not {}) when empty so JSON consumers that do
        -- `(res.data.data ?? []).map(...)` don't blow up on an all-disabled
        -- or empty catalogue (?? doesn't catch an object).
        return { json = { data = #data > 0 and data or cjson.empty_array }, status = 200 }
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
        -- Grandfather an unchanged income_type: an admin may have disabled the
        -- type after this row was created, but the user must still be able to
        -- edit/correct the row. Only re-validate income_type when it's actually
        -- being changed to a different value.
        if self.params.income_type ~= nil then
            local existing = MyIncomeQueries.show(tostring(self.params.id), self.current_user)
            if existing and existing.income_type == self.params.income_type then
                self.params.income_type = nil
            end
        end
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
