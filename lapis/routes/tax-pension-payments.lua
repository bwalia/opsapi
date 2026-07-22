--[[
    Pension Payment Routes — the "Relief: Pension payments" backend surface
    (SA100 page TR4). No per-entity drill-down: rows hang straight off the
    user + tax year, grouped by the admin-managed section catalogue.

    Endpoints (all auth-required):
      GET    /api/v2/tax/pension-payment-categories    admin catalogue → section cards
      GET    /api/v2/tax/pension/summary?tax_year=     per-section totals (read-only, derived)
      GET    /api/v2/tax/pension-payments?tax_year=&category_key=
      POST   /api/v2/tax/pension-payments              { category_key, amount, tax_year, description?, relief_at_source?, one_off? }
      PUT    /api/v2/tax/pension-payments/:uuid
      DELETE /api/v2/tax/pension-payments/:uuid        soft archive

    relief_at_source = the form's "Basic rate tax relief claimed by
    provider?" checkbox (routes a registered-scheme row to TR4 box 1 vs
    box 2); one_off = "Is this a one off payment?" (box 1.1). Flags are
    forced false against the RESOLVED target section whether or not the
    payload carries them, so neither a section switch nor an edit can leave
    a true flag on a section that doesn't offer the checkbox; on rows whose
    section an admin retired, flags are frozen (updates to them ignored).
]]

local cjson = require("cjson")
local PensionPaymentQueries = require "queries.PensionPaymentQueries"
local AuthMiddleware = require("middleware.auth")

-- YYYY-YY (e.g. 2026-27) — same contract as my-incomes / tax-properties.
local function valid_tax_year(s)
    if type(s) ~= "string" then return false end
    local y1, y2 = s:match("^(%d%d%d%d)%-(%d%d)$")
    if not y1 or not y2 then return false end
    return tonumber(y2) == (tonumber(y1) + 1) % 100
end

-- Parse JSON or form body — same helper as tax-properties.lua: cjson.null
-- stripped at the boundary, body-file fallback for spooled bodies.
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

-- JSON bodies carry real booleans; form bodies carry strings — normalise
-- both ("false"/"0" are truthy in Lua, so a plain truthiness check lies).
-- "on" is what a bare HTML form posts for a checked checkbox.
local function to_bool(v)
    return v == true or v == "true" or v == "1" or v == 1 or v == "on"
end

-- Validate a payment payload against the catalogue. `category` (resolved by
-- the caller: the target section's catalogue row, or nil when the row is
-- grandfathered on a retired section) gates the two flags.
local function validate_payment(params, is_create, category)
    if is_create or params.amount ~= nil then
        local n = tonumber(params.amount)
        if not n or n ~= n or n <= 0 then
            return false, "amount is required and must be a positive number"
        end
        if n > PensionPaymentQueries.MAX_AMOUNT then
            return false, "amount is too large"
        end
        params.amount = n
    end
    if is_create or params.tax_year ~= nil then
        if not valid_tax_year(params.tax_year) then
            return false, "tax_year must be YYYY-YY (e.g. 2026-27)"
        end
    end
    if params.description ~= nil then
        -- Reject non-strings up front: a JSON number/bool/object (or a
        -- repeated form key, which arrives as a Lua table) would otherwise
        -- sail past the length check into SQL interpolation → 500.
        if type(params.description) ~= "string" then
            return false, "description must be a string"
        end
        if #params.description > 500 then
            return false, "description must be 500 characters or fewer"
        end
    end
    -- Normalise flags, then enforce them against the RESOLVED target
    -- section unconditionally — forcing only payload-present flags would
    -- let a category switch smuggle the row's stored true flags along.
    if params.relief_at_source ~= nil then
        params.relief_at_source = to_bool(params.relief_at_source)
    end
    if params.one_off ~= nil then
        params.one_off = to_bool(params.one_off)
    end
    if category then
        if not category.supports_relief_flag then params.relief_at_source = false end
        if not category.supports_one_off_flag then params.one_off = false end
    else
        -- Grandfathered retired section: its catalogue row isn't visible,
        -- so flag support can't be checked — freeze the stored flags
        -- (ignore any sent values) rather than accept or clobber them.
        params.relief_at_source = nil
        params.one_off = nil
    end
    return true
end

return function(app)
    -- ── Catalogue ───────────────────────────────────────────────────────────
    app:get("/api/v2/tax/pension-payment-categories", AuthMiddleware.requireAuth(function(_)
        local rows = PensionPaymentQueries.categories()
        local data = {}
        for _, r in ipairs(rows) do
            data[#data + 1] = {
                key = r.category_key,
                label = r.label,
                description = r.description,
                hmrc_mapping = r.hmrc_mapping,
                supports_relief_flag = r.supports_relief_flag == true,
                supports_one_off_flag = r.supports_one_off_flag == true,
                display_order = r.display_order,
            }
        end
        return { json = { data = #data > 0 and data or cjson.empty_array }, status = 200 }
    end))

    -- ── Summary (read-only, derived) ────────────────────────────────────────
    app:get("/api/v2/tax/pension/summary", AuthMiddleware.requireAuth(function(self)
        local tax_year = self.params.tax_year
        if not valid_tax_year(tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local result, err = PensionPaymentQueries.summary(tax_year, self.current_user)
        if not result then
            return { json = { error = err or "Failed to build summary" }, status = 400 }
        end
        if #result.sections == 0 then result.sections = cjson.empty_array end
        return { json = { data = result }, status = 200 }
    end))

    -- ── Payment rows ────────────────────────────────────────────────────────
    app:get("/api/v2/tax/pension-payments", AuthMiddleware.requireAuth(function(self)
        local result, err = PensionPaymentQueries.all(self.params, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list pension payments" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:post("/api/v2/tax/pension-payments", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        local active = PensionPaymentQueries.active_categories()
        local category = active[self.params.category_key]
        if not category then
            return { json = { error = "category_key is not an active pension payment section" }, status = 400 }
        end
        local ok, vmsg = validate_payment(self.params, true, category)
        if not ok then return { json = { error = vmsg }, status = 400 } end
        local row, err = PensionPaymentQueries.create(self.params, self.current_user)
        if not row then return { json = { error = err or "Failed to save the payment" }, status = 400 } end
        return { json = { data = row }, status = 201 }
    end))

    app:put("/api/v2/tax/pension-payments/:uuid", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        local existing = PensionPaymentQueries.show(tostring(self.params.uuid), self.current_user)
        if not existing then return { json = { error = "Payment not found" }, status = 404 } end
        local active = PensionPaymentQueries.active_categories()
        -- Grandfather an unchanged category_key (admin may have retired the
        -- section since) — but a CHANGED key must name an active section.
        local target_key = self.params.category_key or existing.category_key
        local category = active[target_key]
        if self.params.category_key ~= nil then
            if self.params.category_key == existing.category_key then
                self.params.category_key = nil
            elseif not category then
                return { json = { error = "category_key is not an active pension payment section" }, status = 400 }
            end
        end
        local ok, vmsg = validate_payment(self.params, false, category)
        if not ok then return { json = { error = vmsg }, status = 400 } end
        local row, err = PensionPaymentQueries.update(tostring(self.params.uuid), self.params, self.current_user)
        if not row then return { json = { error = err or "Payment not found" }, status = err and 400 or 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:delete("/api/v2/tax/pension-payments/:uuid", AuthMiddleware.requireAuth(function(self)
        local ok = PensionPaymentQueries.archive(tostring(self.params.uuid), self.current_user)
        if not ok then return { json = { error = "Payment not found" }, status = 404 } end
        return { json = { message = "Payment removed" }, status = 200 }
    end))
end
