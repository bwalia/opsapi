--[[
    Overseas Property Routes — the "Land and property abroad" hub's backend
    surface (SA106). Thin mirror of tax-properties.lua running the SAME
    query engine with entity_type='overseas_property' and the overseas
    catalogue schedule.

    Endpoints (all auth-required):
      GET    /api/v2/tax/overseas-line-categories             admin catalogue → line forms
      GET    /api/v2/tax/overseas/summary?tax_year=           hub summary strip (read-only, derived)
      GET    /api/v2/tax/overseas-properties?tax_year=        list + per-holding totals
      POST   /api/v2/tax/overseas-properties                  { label }
      GET    /api/v2/tax/overseas-properties/:uuid
      PUT    /api/v2/tax/overseas-properties/:uuid            { label?, metadata_json?, display_order? }
      DELETE /api/v2/tax/overseas-properties/:uuid            soft archive (also archives its lines)
      GET    /api/v2/tax/overseas-properties/:uuid/lines?tax_year=&kind=
      POST   /api/v2/tax/overseas-properties/:uuid/lines      { kind, category_key, amount, tax_year, description?, disallowable_amount? }
      PUT    /api/v2/tax/overseas-property-lines/:uuid
      DELETE /api/v2/tax/overseas-property-lines/:uuid        soft archive

    Kinds go beyond income/expense: 'finance_cost' (restricted residential
    finance costs — excluded from expense totals, as on the SA106 form) and
    'adjustment' (unused residential finance costs brought forward).
    disallowable_amount carries the form's "Private use (£)" split.

    Holding-scope QUESTIONS (country, number of properties, address,
    accounting basis, PIA claim) come from the Profile Builder
    (?context=overseas_property&entity=<uuid>) — admin-configurable.
]]

local cjson = require("cjson")
local PropertyQueries = require "queries.PropertyQueries"
local PropertyLineQueries = require "queries.PropertyLineQueries"
local AuthMiddleware = require("middleware.auth")

local ENTITY_TYPE = "overseas_property"
local SCHEDULE = "overseas_property"
local VALID_KINDS = { income = true, expense = true, finance_cost = true, adjustment = true }

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

-- Validate a line-item payload against the OVERSEAS catalogue.
local function validate_line(params, is_create)
    if is_create or params.kind ~= nil then
        if not VALID_KINDS[params.kind] then
            return false, "kind must be one of income, expense, finance_cost, adjustment"
        end
    end
    if is_create or params.amount ~= nil then
        local n = tonumber(params.amount)
        if not n or n <= 0 then
            return false, "amount is required and must be a positive number"
        end
        params.amount = n
    end
    if params.disallowable_amount ~= nil and params.disallowable_amount ~= "" then
        local d = tonumber(params.disallowable_amount)
        if not d or d < 0 then
            return false, "disallowable_amount (private use) must be a non-negative number"
        end
        params.disallowable_amount = d
    end
    if is_create or params.tax_year ~= nil then
        if not valid_tax_year(params.tax_year) then
            return false, "tax_year must be YYYY-YY (e.g. 2026-27)"
        end
    end
    if is_create or params.category_key ~= nil then
        local kind = params.kind
        if not kind or not VALID_KINDS[kind] then
            return false, "kind must accompany category_key"
        end
        if not PropertyLineQueries.active_keys(kind, SCHEDULE)[params.category_key] then
            return false, "category_key is not an active overseas " .. kind .. " category"
        end
    end
    if params.description and type(params.description) == "string" and #params.description > 500 then
        return false, "description must be 500 characters or fewer"
    end
    return true
end

return function(app)
    -- ── Catalogue ───────────────────────────────────────────────────────────
    app:get("/api/v2/tax/overseas-line-categories", AuthMiddleware.requireAuth(function(_)
        local rows = PropertyLineQueries.categories(SCHEDULE)
        local data = {}
        for _, r in ipairs(rows) do
            data[#data + 1] = {
                key = r.category_key,
                label = r.label,
                kind = r.kind,
                description = r.description,
                hmrc_mapping = r.hmrc_mapping,
                display_order = r.display_order,
            }
        end
        return { json = { data = #data > 0 and data or cjson.empty_array }, status = 200 }
    end))

    -- ── Hub summary (read-only, derived) ────────────────────────────────────
    app:get("/api/v2/tax/overseas/summary", AuthMiddleware.requireAuth(function(self)
        local tax_year = self.params.tax_year
        if not valid_tax_year(tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local result, err = PropertyQueries.summary(tax_year, self.current_user, ENTITY_TYPE)
        if not result then
            return { json = { error = err or "Failed to build summary" }, status = 400 }
        end
        if #result.properties == 0 then result.properties = cjson.empty_array end
        return { json = { data = result }, status = 200 }
    end))

    -- ── Holdings ────────────────────────────────────────────────────────────
    app:get("/api/v2/tax/overseas-properties", AuthMiddleware.requireAuth(function(self)
        local result, err = PropertyQueries.all(self.params, self.current_user, ENTITY_TYPE)
        if not result then
            return { json = { error = err or "Failed to list overseas properties" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:post("/api/v2/tax/overseas-properties", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if not self.params.label or tostring(self.params.label):gsub("%s", "") == "" then
            return { json = { error = "label is required" }, status = 400 }
        end
        if #tostring(self.params.label) > 120 then
            return { json = { error = "label must be 120 characters or fewer" }, status = 400 }
        end
        local row, err = PropertyQueries.create(self.params, self.current_user, ENTITY_TYPE)
        if not row then return { json = { error = err or "Failed to create overseas property" }, status = 400 } end
        return { json = { data = row }, status = 201 }
    end))

    app:get("/api/v2/tax/overseas-properties/:uuid", AuthMiddleware.requireAuth(function(self)
        local row = PropertyQueries.show(tostring(self.params.uuid), self.current_user, ENTITY_TYPE)
        if not row then return { json = { error = "Overseas property not found" }, status = 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:put("/api/v2/tax/overseas-properties/:uuid", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if self.params.label ~= nil and #tostring(self.params.label) > 120 then
            return { json = { error = "label must be 120 characters or fewer" }, status = 400 }
        end
        local row, err = PropertyQueries.update(tostring(self.params.uuid), self.params, self.current_user, ENTITY_TYPE)
        if not row then return { json = { error = err or "Overseas property not found" }, status = err and 400 or 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:delete("/api/v2/tax/overseas-properties/:uuid", AuthMiddleware.requireAuth(function(self)
        local ok = PropertyQueries.archive(tostring(self.params.uuid), self.current_user, ENTITY_TYPE)
        if not ok then return { json = { error = "Overseas property not found" }, status = 404 } end
        return { json = { message = "Overseas property archived" }, status = 200 }
    end))

    -- ── Line items ──────────────────────────────────────────────────────────
    app:get("/api/v2/tax/overseas-properties/:uuid/lines", AuthMiddleware.requireAuth(function(self)
        -- Ownership check first so an unknown/foreign holding 404s rather
        -- than returning an empty list.
        local prop = PropertyQueries.show(tostring(self.params.uuid), self.current_user, ENTITY_TYPE)
        if not prop then return { json = { error = "Overseas property not found" }, status = 404 } end
        local result, err = PropertyLineQueries.all(prop.id, self.params, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list line items" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:post("/api/v2/tax/overseas-properties/:uuid/lines", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        local ok, vmsg = validate_line(self.params, true)
        if not ok then return { json = { error = vmsg }, status = 400 } end
        local row, err = PropertyLineQueries.create(tostring(self.params.uuid), self.params, self.current_user, ENTITY_TYPE)
        if not row then
            local status = (err == "Property not found") and 404 or 400
            return { json = { error = err or "Failed to create line item" }, status = status }
        end
        return { json = { data = row }, status = 201 }
    end))

    app:put("/api/v2/tax/overseas-property-lines/:uuid", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        local existing = PropertyLineQueries.show(tostring(self.params.uuid), self.current_user)
        if not existing then return { json = { error = "Line item not found" }, status = 404 } end
        -- kind is immutable; inject the stored kind so category validation
        -- checks against the right catalogue slice. Grandfather an unchanged
        -- category_key (admin may have retired it since).
        self.params.kind = nil
        if self.params.category_key ~= nil then
            if existing.category_key == self.params.category_key then
                self.params.category_key = nil
            else
                self.params.kind = existing.kind
            end
        end
        local ok, vmsg = validate_line(self.params, false)
        if not ok then return { json = { error = vmsg }, status = 400 } end
        self.params.kind = nil -- never persisted on update
        local row, err = PropertyLineQueries.update(tostring(self.params.uuid), self.params, self.current_user)
        if not row then return { json = { error = err or "Line item not found" }, status = 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:delete("/api/v2/tax/overseas-property-lines/:uuid", AuthMiddleware.requireAuth(function(self)
        local ok = PropertyLineQueries.archive(tostring(self.params.uuid), self.current_user)
        if not ok then return { json = { error = "Line item not found" }, status = 404 } end
        return { json = { message = "Line item archived" }, status = 200 }
    end))
end
