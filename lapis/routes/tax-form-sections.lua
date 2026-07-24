--[[
    Form Section Routes — user surface of the generic sections/sub-forms
    engine. One set of endpoints serves EVERY income type whose page is a
    stack of admin-defined sections (repeating rows of description +
    amount + configured checkboxes) — adding the next such screen needs
    catalogue rows, not routes.

    Endpoints (all auth-required):
      GET    /api/v2/tax/form-sections?income_type=        active sections + sub-form config
      GET    /api/v2/tax/form-items?income_type=&tax_year=&section=
      POST   /api/v2/tax/form-items                        { income_type_key, section_key, tax_year, amount, description?, extra? }
      PUT    /api/v2/tax/form-items/:uuid                  { amount?, description?, extra? }
      DELETE /api/v2/tax/form-items/:uuid                  soft archive
      GET    /api/v2/tax/form-summary?income_type=&tax_year=
      GET    /api/v2/tax/form-card-summary                 all-years per-type totals (overview cards)

    RECORD MODE (types whose sections define config.fields — SA102
    employment shape: repeating records, each a fixed field-form):
      GET    /api/v2/tax/form-records?income_type=&tax_year=
      POST   /api/v2/tax/form-records                      { income_type_key, tax_year, data }
      PUT    /api/v2/tax/form-records/:uuid                { data }   (full-document replace)
      DELETE /api/v2/tax/form-records/:uuid                soft archive
    `data` is validated against the type's field catalogue: unknown keys
    dropped, typed per field def, required fields enforced. A record's
    income type / tax year are immutable — delete + re-add to move.

    `extra` is the checkbox values object. It is validated against the
    TARGET section's config: only configured keys persist (true-only,
    false is absence), unknown keys are stripped, and rows whose section
    an admin has retired have their checkboxes frozen. A row's income
    type / section / tax year are immutable — delete + re-add to move.
]]

local cjson = require("cjson")
local FormSectionQueries = require "queries.FormSectionQueries"
local AuthMiddleware = require("middleware.auth")
-- Phase 1 salary → profile-builder dual-write fork. Every entry point
-- is safe to call unconditionally (feature-flag check + pcall guard
-- are inside the helper), so we hang the fork onto every successful
-- primary write without gating in this file. Turning dual-write off
-- (INCOME_ENGINE_SALARY_DUAL_WRITE unset) makes the helper a no-op
-- immediately — no route change or redeploy needed to disable the
-- shadow writes. See docs/PROFILE_BUILDER_UNIFICATION_PLAN.md §4-5 in
-- the diy-tax-return-uk repo.
local SalaryFork = require("helper.salary-profile-builder-fork")
local PensionFork = require("helper.pension-profile-builder-fork")

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

-- JSON bodies carry real booleans; form bodies carry strings ("on" is a
-- bare HTML checkbox) — "false"/"0" are truthy in Lua, so normalise.
local function to_bool(v)
    return v == true or v == "true" or v == "1" or v == 1 or v == "on"
end

-- Build the stored extra_json from a submitted `extra` object and the
-- TARGET section's checkbox config: configured keys only, true-only
-- (false = absence). Returns nil (SQL NULL / clear) when nothing is true.
-- A nil section (retired) freezes checkboxes: returns "SKIP".
local function encode_extra(extra, section)
    if not section then return "SKIP" end
    if type(extra) ~= "table" then return nil end
    local allowed = FormSectionQueries.checkbox_keys(section.config)
    local out = {}
    for key in pairs(allowed) do
        if to_bool(extra[key]) then out[key] = true end
    end
    if not next(out) then return nil end
    return cjson.encode(out)
end

local function validate_common(params, is_create)
    if is_create or params.amount ~= nil then
        local n = tonumber(params.amount)
        if not n or n ~= n or n <= 0 then
            return false, "amount is required and must be a positive number"
        end
        if n > FormSectionQueries.MAX_AMOUNT then
            return false, "amount is too large"
        end
        params.amount = n
    end
    if params.description ~= nil then
        -- Reject non-strings up front: a JSON number/object (or repeated
        -- form key → Lua table) would otherwise reach SQL interpolation.
        if type(params.description) ~= "string" then
            return false, "description must be a string"
        end
        if #params.description > 500 then
            return false, "description must be 500 characters or fewer"
        end
    end
    if params.extra ~= nil and type(params.extra) ~= "table" then
        return false, "extra must be an object of checkbox values"
    end
    return true
end

return function(app)
    -- ── Section catalogue for one income type ──────────────────────────────
    app:get("/api/v2/tax/form-sections", AuthMiddleware.requireAuth(function(self)
        local income_type = self.params.income_type
        if type(income_type) ~= "string" or income_type == "" then
            return { json = { error = "income_type is required" }, status = 400 }
        end
        local rows = FormSectionQueries.sections_for_type(income_type)
        return { json = { data = #rows > 0 and rows or cjson.empty_array }, status = 200 }
    end))

    -- ── Items ───────────────────────────────────────────────────────────────
    app:get("/api/v2/tax/form-items", AuthMiddleware.requireAuth(function(self)
        local result, err = FormSectionQueries.items(self.params, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list entries" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:post("/api/v2/tax/form-items", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if type(self.params.income_type_key) ~= "string" or type(self.params.section_key) ~= "string" then
            return { json = { error = "income_type_key and section_key are required" }, status = 400 }
        end
        local section = FormSectionQueries.active_section(
            self.params.income_type_key, self.params.section_key)
        if not section then
            return { json = { error = "section_key is not an active section of this income type" }, status = 400 }
        end
        -- Record-mode sections take records, not row items. Without this
        -- guard a stale client (old bundle, boolean engine probe) could
        -- write items that inflate card_summary while being invisible on
        -- the records page.
        if #FormSectionQueries.field_defs(section.config) > 0 then
            return { json = { error = "This section is part of a record form — use form-records" }, status = 400 }
        end
        if not valid_tax_year(self.params.tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local ok, vmsg = validate_common(self.params, true)
        if not ok then return { json = { error = vmsg }, status = 400 } end
        self.params.extra_json = encode_extra(self.params.extra, section)
        local row, err = FormSectionQueries.create_item(self.params, self.current_user)
        if not row then return { json = { error = err or "Failed to save the entry" }, status = 400 } end
        -- Fork write. No-op when the pension_payments flag is off (default)
        -- or when this row is a different income type. Any failure is
        -- pcall-swallowed inside the helper — primary create stays
        -- authoritative. Passes the identifying triple; the helper
        -- reads current bucket state itself so we don't have to
        -- serialise the row here.
        if row.income_type_key == "pension_payments" then
            PensionFork.on_change(row.user_id, row.tax_year, row.section_key)
        end
        return { json = { data = row }, status = 201 }
    end))

    app:put("/api/v2/tax/form-items/:uuid", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        local existing = FormSectionQueries.show_item(tostring(self.params.uuid), self.current_user)
        if not existing then return { json = { error = "Entry not found" }, status = 404 } end
        local ok, vmsg = validate_common(self.params, false)
        if not ok then return { json = { error = vmsg }, status = 400 } end

        local data = { amount = self.params.amount, description = self.params.description }
        if self.params.extra ~= nil then
            -- Checkbox edits validate against the row's OWN section; a
            -- retired section freezes them (encode_extra → "SKIP").
            local section = FormSectionQueries.active_section(
                existing.income_type_key, existing.section_key)
            local encoded = encode_extra(self.params.extra, section)
            if encoded ~= "SKIP" then
                -- nil means "all false" here, which must CLEAR the stored
                -- value — pass "" so update_item writes NULL (its own nil
                -- means "not provided").
                data.extra_json = encoded or ""
            end
        end
        local row, err = FormSectionQueries.update_item(tostring(self.params.uuid), data, self.current_user)
        if not row then return { json = { error = err or "Entry not found" }, status = err and 400 or 404 } end
        if row.income_type_key == "pension_payments" then
            PensionFork.on_change(row.user_id, row.tax_year, row.section_key)
        end
        return { json = { data = row }, status = 200 }
    end))

    app:delete("/api/v2/tax/form-items/:uuid", AuthMiddleware.requireAuth(function(self)
        -- Look up before archiving so the fork's on_change has the row's
        -- bucket identity (user + year + section) — the row itself is
        -- about to become is_archived=true and rebuild_bucket filters
        -- those out. show_item enforces user-owned-only, same guard
        -- archive_item runs; nil here means archive would also 404.
        local existing = FormSectionQueries.show_item(tostring(self.params.uuid), self.current_user)
        local ok = FormSectionQueries.archive_item(tostring(self.params.uuid), self.current_user)
        if not ok then return { json = { error = "Entry not found" }, status = 404 } end
        if existing and existing.income_type_key == "pension_payments" then
            PensionFork.on_change(existing.user_id, existing.tax_year, existing.section_key)
        end
        return { json = { message = "Entry removed" }, status = 200 }
    end))

    -- ── Records (record mode) ───────────────────────────────────────────────
    app:get("/api/v2/tax/form-records", AuthMiddleware.requireAuth(function(self)
        local result, err = FormSectionQueries.records(self.params, self.current_user)
        if not result then
            return { json = { error = err or "Failed to list records" }, status = 400 }
        end
        if #result.data == 0 then result.data = cjson.empty_array end
        return { json = result, status = 200 }
    end))

    app:post("/api/v2/tax/form-records", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        if type(self.params.income_type_key) ~= "string" or self.params.income_type_key == "" then
            return { json = { error = "income_type_key is required" }, status = 400 }
        end
        if not valid_tax_year(self.params.tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local defs = FormSectionQueries.collect_fields(self.params.income_type_key)
        if #defs == 0 then
            return { json = { error = "This income type does not take records" }, status = 400 }
        end
        -- Second return is the error on failure, the summary total on success.
        local validated, total = FormSectionQueries.validate_record_data(defs, self.params.data)
        if not validated then return { json = { error = total }, status = 400 } end
        local row, err = FormSectionQueries.create_record({
            income_type_key = self.params.income_type_key,
            tax_year = self.params.tax_year,
            data_json = cjson.encode(validated),
            total = total,
        }, self.current_user)
        if not row then return { json = { error = err or "Failed to save" }, status = 400 } end
        -- Fork write. No-op when INCOME_ENGINE_SALARY_DUAL_WRITE is
        -- unset (default). Any failure is pcall-swallowed inside the
        -- helper — the primary create stays authoritative.
        SalaryFork.on_create(row)
        return { json = { data = row }, status = 201 }
    end))

    app:put("/api/v2/tax/form-records/:uuid", AuthMiddleware.requireAuth(function(self)
        merge_params(self)
        local existing = FormSectionQueries.show_record(tostring(self.params.uuid), self.current_user)
        if not existing then return { json = { error = "Record not found" }, status = 404 } end
        -- Full-document replace against the record's OWN type; the field
        -- catalogue is read live so admin edits apply to the next save.
        local defs = FormSectionQueries.collect_fields(existing.income_type_key)
        if #defs == 0 then
            -- Type retired from record mode since — freeze rather than
            -- wiping the document against an empty catalogue.
            return { json = { error = "This income type no longer takes records" }, status = 400 }
        end
        -- Second return is the error on failure, the summary total on success.
        local validated, total = FormSectionQueries.validate_record_data(defs, self.params.data)
        if not validated then return { json = { error = total }, status = 400 } end
        local row, err = FormSectionQueries.update_record(tostring(self.params.uuid), {
            data_json = cjson.encode(validated),
            total = total,
        }, self.current_user)
        if not row then return { json = { error = err or "Record not found" }, status = err and 400 or 404 } end
        SalaryFork.on_update(row)
        return { json = { data = row }, status = 200 }
    end))

    app:delete("/api/v2/tax/form-records/:uuid", AuthMiddleware.requireAuth(function(self)
        -- Look up before archiving so the fork's on_delete has the row's
        -- uuid + income_type_key (needed to derive the shadow entity
        -- uuid + to gate on the income_type flag). show_record enforces
        -- the same user-owned-only check archive_record does; a not-owned
        -- record returns nil here and the archive would also 404 below.
        local existing = FormSectionQueries.show_record(tostring(self.params.uuid), self.current_user)
        local ok = FormSectionQueries.archive_record(tostring(self.params.uuid), self.current_user)
        if not ok then return { json = { error = "Record not found" }, status = 404 } end
        if existing then SalaryFork.on_delete(existing) end
        return { json = { message = "Record removed" }, status = 200 }
    end))

    -- ── Summaries (read-only, derived) ──────────────────────────────────────
    app:get("/api/v2/tax/form-summary", AuthMiddleware.requireAuth(function(self)
        local income_type = self.params.income_type
        if type(income_type) ~= "string" or income_type == "" then
            return { json = { error = "income_type is required" }, status = 400 }
        end
        if not valid_tax_year(self.params.tax_year) then
            return { json = { error = "tax_year must be YYYY-YY (e.g. 2026-27)" }, status = 400 }
        end
        local result, err = FormSectionQueries.summary(income_type, self.params.tax_year, self.current_user)
        if not result then
            return { json = { error = err or "Failed to build summary" }, status = 400 }
        end
        if #result.sections == 0 then result.sections = cjson.empty_array end
        return { json = { data = result }, status = 200 }
    end))

    app:get("/api/v2/tax/form-card-summary", AuthMiddleware.requireAuth(function(self)
        local rows, err = FormSectionQueries.card_summary(self.current_user)
        if not rows then
            return { json = { error = err or "Failed to build summary" }, status = 400 }
        end
        return { json = { data = #rows > 0 and rows or cjson.empty_array }, status = 200 }
    end))
end
