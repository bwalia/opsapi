--[[
    Self-Employment Routes — the sole-trader hub's backend surface.

    Endpoints (all auth-required):
      GET    /api/v2/tax/business-line-categories             admin catalogue → fixed-box form
      GET    /api/v2/tax/self-employment/summary?tax_year=    hub summary strip (read-only, derived)
      GET    /api/v2/tax/businesses?tax_year=                 list + per-business totals
      POST   /api/v2/tax/businesses                           { label }
      GET    /api/v2/tax/businesses/:uuid
      PUT    /api/v2/tax/businesses/:uuid                     { label?, metadata_json?, display_order? }
      DELETE /api/v2/tax/businesses/:uuid                     soft archive
      GET    /api/v2/tax/businesses/:uuid/values?tax_year=    fixed-box values for one year
      PUT    /api/v2/tax/businesses/:uuid/values              { tax_year, values: [{category_key, amount?, disallowable_amount?}] }
      GET    /api/v2/tax/business-ca-catalogue                CA grid pools + rows (admin catalogues)
      GET    /api/v2/tax/businesses/:uuid/capital-allowances?tax_year=
      PUT    /api/v2/tax/businesses/:uuid/capital-allowances  { tax_year, pool_key, cells: [{row_key, amount?}] }

    Business-scope QUESTIONS are not served here — they come from the
    Profile Builder (/api/v2/profile-builder/schema?context=business&entity=<uuid>)
    so admins keep full control of what's asked per business.
]]

local cjson = require("cjson")
local BusinessQueries = require "queries.BusinessQueries"
local BusinessValueQueries = require "queries.BusinessValueQueries"
local AuthMiddleware = require("middleware.auth")

-- YYYY-YY (e.g. 2026-27) — same contract as my-incomes / tax-properties.
local function valid_tax_year(s)
    if type(s) ~= "string" then return false end
    local y1, y2 = s:match("^(%d%d%d%d)%-(%d%d)$")
    if not y1 or not y2 then return false end
    return tonumber(y2) == (tonumber(y1) + 1) % 100
end

-- Parse JSON or form body with cjson.null normalisation at the boundary —
-- same helper as tax-properties.lua (JSON null is a truthy lightuserdata
-- that would otherwise reach tostring()/db escaping). Batch endpoints here
-- carry nested arrays whose inner nulls ("clear this box") are handled by
-- the queries' parse_amount, so only top-level nulls are stripped.
local function parse_request_body()
    ngx.req.read_body()
    local content_type = ngx.var.content_type or ""
    if content_type:find("application/json", 1, true) then
        local ok, result = pcall(function()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                -- Bodies over client_body_buffer_size (16k default) are
                -- spooled to disk and get_body_data() returns nil — the
                -- 200-entry values batches this route allows can exceed
                -- that. Same fallback as academy.lua.
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

-- Normalise one batch entry: cjson.null fields → nil so "clear this box"
-- and "field absent" behave identically all the way down.
local function scrub_entry(entry)
    if type(entry) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(entry) do
        if v ~= cjson.null then out[k] = v end
    end
    return out
end

return function(app)
    -- ── Catalogues ──────────────────────────────────────────────────────────
    app:get("/api/v2/tax/business-line-categories", AuthMiddleware.requireAuth(function(_)
        local rows = BusinessValueQueries.categories()
        local data = {}
        for _, r in ipairs(rows) do
            data[#data + 1] = {
                key = r.category_key,
                label = r.label,
                kind = r.kind,
                description = r.description,
                hmrc_mapping = r.hmrc_mapping,
                supports_disallowable = r.supports_disallowable,
                display_order = r.display_order,
            }
        end
        return { json = { data = #data > 0 and data or cjson.empty_array }, status = 200 }
    end))

    app:get("/api/v2/tax/business-ca-catalogue", AuthMiddleware.requireAuth(function(_)
        local cat = BusinessValueQueries.ca_catalogue()
        local pools, rows = {}, {}
        for _, p in ipairs(cat.pools) do
            pools[#pools + 1] = { key = p.pool_key, label = p.label, display_order = p.display_order }
        end
        for _, r in ipairs(cat.rows) do
            rows[#rows + 1] = { key = r.row_key, label = r.label, display_order = r.display_order }
        end
        return {
            json = {
                data = {
                    pools = #pools > 0 and pools or cjson.empty_array,
                    rows = #rows > 0 and rows or cjson.empty_array,
                },
            },
            status = 200,
        }
    end))

    -- ── Hub summary (read-only, derived) ────────────────────────────────────
    app:get("/api/v2/tax/self-employment/summary", AuthMiddleware.requireAuth(function(self)
        local tax_year = self.params.tax_year
        if not valid_tax_year(tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local result, err = BusinessQueries.summary(tax_year, self.current_user)
        if not result then
            return { json = { error = err or "Failed to build summary" }, status = 400 }
        end
        -- Force [] (not {}) for an empty list — cjson encodes empty Lua
        -- tables as objects.
        if #result.businesses == 0 then result.businesses = cjson.empty_array end
        return { json = { data = result }, status = 200 }
    end))

    -- ── Businesses ──────────────────────────────────────────────────────────
    app:get("/api/v2/tax/businesses", AuthMiddleware.requireAuth(function(self)
        local result, err = BusinessQueries.all(self.params, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list businesses" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:post("/api/v2/tax/businesses", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if not self.params.label or tostring(self.params.label):gsub("%s", "") == "" then
            return { json = { error = "label is required" }, status = 400 }
        end
        if #tostring(self.params.label) > 120 then
            return { json = { error = "label must be 120 characters or fewer" }, status = 400 }
        end
        local row, err = BusinessQueries.create(self.params, self.current_user)
        if not row then return { json = { error = err or "Failed to create business" }, status = 400 } end
        return { json = { data = row }, status = 201 }
    end))

    app:get("/api/v2/tax/businesses/:uuid", AuthMiddleware.requireAuth(function(self)
        local row = BusinessQueries.show(tostring(self.params.uuid), self.current_user)
        if not row then return { json = { error = "Business not found" }, status = 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:put("/api/v2/tax/businesses/:uuid", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if self.params.label ~= nil and #tostring(self.params.label) > 120 then
            return { json = { error = "label must be 120 characters or fewer" }, status = 400 }
        end
        local row, err = BusinessQueries.update(tostring(self.params.uuid), self.params, self.current_user)
        if not row then return { json = { error = err or "Business not found" }, status = err and 400 or 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:delete("/api/v2/tax/businesses/:uuid", AuthMiddleware.requireAuth(function(self)
        local ok = BusinessQueries.archive(tostring(self.params.uuid), self.current_user)
        if not ok then return { json = { error = "Business not found" }, status = 404 } end
        return { json = { message = "Business archived" }, status = 200 }
    end))

    -- ── Fixed-box values ────────────────────────────────────────────────────
    app:get("/api/v2/tax/businesses/:uuid/values", AuthMiddleware.requireAuth(function(self)
        -- Ownership check first so an unknown/foreign business 404s rather
        -- than returning an empty list.
        local biz = BusinessQueries.show(tostring(self.params.uuid), self.current_user)
        if not biz then return { json = { error = "Business not found" }, status = 404 } end
        if not valid_tax_year(self.params.tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local result, err = BusinessValueQueries.values_for(tostring(self.params.uuid), self.params.tax_year, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list values" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:put("/api/v2/tax/businesses/:uuid/values", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if not valid_tax_year(self.params.tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local values = self.params.values
        if type(values) ~= "table" or #values == 0 then
            return { json = { error = "values array is required" }, status = 400 }
        end
        if #values > 200 then
            return { json = { error = "values batch too large (max 200)" }, status = 400 }
        end
        local cleaned = {}
        for _, v in ipairs(values) do
            cleaned[#cleaned + 1] = scrub_entry(v) or {}
        end
        local result, err = BusinessValueQueries.upsert_values(
            tostring(self.params.uuid), self.params.tax_year, cleaned, self.current_user)
        if not result then
            local status = (err == "Business not found") and 404 or 400
            return { json = { error = err or "Failed to save values" }, status = status }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        if #result.errors == 0 then result.errors = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    -- ── Capital Allowances grid ─────────────────────────────────────────────
    app:get("/api/v2/tax/businesses/:uuid/capital-allowances", AuthMiddleware.requireAuth(function(self)
        local biz = BusinessQueries.show(tostring(self.params.uuid), self.current_user)
        if not biz then return { json = { error = "Business not found" }, status = 404 } end
        if not valid_tax_year(self.params.tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local result, err = BusinessValueQueries.ca_values_for(tostring(self.params.uuid), self.params.tax_year, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list capital allowances" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:put("/api/v2/tax/businesses/:uuid/capital-allowances", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if not valid_tax_year(self.params.tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        if not self.params.pool_key or self.params.pool_key == "" then
            return { json = { error = "pool_key is required" }, status = 400 }
        end
        local cells = self.params.cells
        if type(cells) ~= "table" or #cells == 0 then
            return { json = { error = "cells array is required" }, status = 400 }
        end
        if #cells > 100 then
            return { json = { error = "cells batch too large (max 100)" }, status = 400 }
        end
        local cleaned = {}
        for _, c in ipairs(cells) do
            cleaned[#cleaned + 1] = scrub_entry(c) or {}
        end
        local result, err = BusinessValueQueries.upsert_ca(
            tostring(self.params.uuid), self.params.tax_year,
            tostring(self.params.pool_key), cleaned, self.current_user)
        if not result then
            local status = (err == "Business not found") and 404 or 400
            return { json = { error = err or "Failed to save capital allowances" }, status = status }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        if #result.errors == 0 then result.errors = cjson.empty_array end
        return { json = result, status = 200 }
    end))
end
