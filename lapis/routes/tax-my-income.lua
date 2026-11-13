--[[
    My Income — definition-driven income types (dashboard).

    Customer — requireAuth + requireNamespace; only their own rows (namespace + user):
      GET    /api/v2/tax/my-income?tax_year=                    overview: one card per type
      GET    /api/v2/tax/my-income/types/:key?tax_year=         one type: form, entities,
                                                                figures, statement suggestions
      PUT    /api/v2/tax/my-income/types/:key/record            { tax_year, entity_uuid?, values,
                                                                  sources?, status: in_progress|done }
      PUT    /api/v2/tax/my-income/types/:key/not-applicable    { tax_year, not_applicable }
      POST   /api/v2/tax/my-income/types/:key/entities          { label } add a property/job/…
      PUT    /api/v2/tax/my-income/entities/:uuid               { label }
      DELETE /api/v2/tax/my-income/entities/:uuid               archive (soft)

    Administrators — RBAC module tax_income_types (platform admins and, by default,
    namespace owner/admin roles; grant it to an accountant role to let them maintain it):
      GET  /api/v2/tax/income-types?include_inactive=true       read
      GET  /api/v2/tax/income-types/meta                        read  builder vocabulary
      POST /api/v2/tax/income-types/validate                    read  dry-run validation
      POST /api/v2/tax/income-types                             create  workspace's own type
      PUT  /api/v2/tax/income-types/:key                        update  (system type → this
                                                                workspace's override; scope=global
                                                                edits the platform default and
                                                                needs a platform admin)
      POST /api/v2/tax/income-types/:key/reset                  update  drop the override
      POST /api/v2/tax/income-types/reorder                     update  { keys: [...] }

    The diy-tax-return-uk routes (routes/my-incomes.lua, routes/tax-admin-income-types.lua)
    are untouched. Rules live in lib/income-types; SQL in queries/TaxIncomeQueries.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local IncomeTypes = require("lib.income-types")
local Q = require("queries.TaxIncomeQueries")
local TaxCalc = require("lib.tax-calc")

local function read_body(_self)
    local data = {}
    pcall(function()
        ngx.req.read_body()
        local raw = ngx.req.get_body_data()
        if not raw then
            local f = ngx.req.get_body_file()
            if f then
                local h = io.open(f, "r")
                if h then raw = h:read("*a"); h:close() end
            end
        end
        if raw and raw:match("^%s*[{%[]") then
            local ok, t = pcall(cjson.decode, raw)
            if ok and type(t) == "table" then data = t end
        end
    end)
    return data
end

local function fail(status, message, extra)
    local body = { success = false, error = message }
    for k, v in pairs(extra or {}) do body[k] = v end
    return { status = status, json = body }
end

local function ok(data, status)
    return { status = status or 200, json = { success = true, data = data } }
end

local function arr(t)
    if type(t) ~= "table" or next(t) == nil then return cjson.empty_array end
    return t
end
-- An empty Lua table encodes as {} (cjson's default), which is what the dashboard
-- expects for the JSONB maps it reads with Object.keys.
local function obj(t)
    return type(t) == "table" and t or {}
end

local function current_user(self)
    local u = self.current_user
    local id = u and (u.uuid or u.id)
    if not id then return nil end
    return db.query("SELECT id, uuid FROM users WHERE uuid = ? LIMIT 1", id)[1]
end

local function tax_year_of(v)
    if v == nil or v == "" then return TaxCalc.filing_tax_year() end
    return IncomeTypes.valid_tax_year(v) and v or nil
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- The public shape of a resolved type (what both the user and admin screens read).
local function type_json(t, extra)
    local out = {
        key = t.income_type_key,
        name = t.display_name,
        description = t.description,
        help_text = t.help_text,
        icon = t.icon,
        display_order = tonumber(t.display_order) or 0,
        is_active = t.is_active == true,
        origin = t.origin,
        overridden = obj(t.overridden),
        entity_type = (t.entity_type ~= nil and t.entity_type ~= "" and type(t.entity_type) ~= "userdata")
            and t.entity_type or cjson.null,
        entity_label = t.entity_label,
        schedule = t.linked_form_title,
        schedule_description = t.linked_form_description,
        schedule_link = t.linked_form_weblink,
        estimate_note = t.estimate_note,
        field_schema = { sections = arr(t.field_schema and t.field_schema.sections) },
        estimator_mapping = arr(t.estimator_mapping),
        in_estimate = type(t.estimator_mapping) == "table" and #t.estimator_mapping > 0,
        has_form = t.has_form == true,
    }
    for k, v in pairs(extra or {}) do out[k] = v end
    return out
end

local function record_json(r, t)
    if not r then return cjson.null end
    return {
        uuid = r.uuid,
        entity_uuid = r.entity_uuid,
        values = obj(r.values),
        sources = obj(r.value_sources),
        status = r.status,
        updated_at = r.updated_at,
        totals = IncomeTypes.record_totals(t.field_schema, r.values, t.estimator_mapping),
    }
end

local function sum_totals(acc, t)
    for k, v in pairs(t) do acc[k] = (acc[k] or 0) + v end
    return acc
end

local function has_entities(t)
    return t.entity_type ~= nil and t.entity_type ~= "" and type(t.entity_type) ~= "userdata"
end

return function(app)
    local auth = function(fn)
        return AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(fn))
    end
    local perm = function(action, fn)
        return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("tax_income_types", action, fn))
    end

    -- ── Customer ──────────────────────────────────────────────────────────────

    app:get("/api/v2/tax/my-income", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "User not found") end
        local year = tax_year_of(self.params.tax_year)
        if not year then return fail(400, "tax_year must look like 2025-26") end
        local ns = self.namespace.id
        local types = Q.types_for(ns)
        local records = Q.records(ns, u.id, year)
        local entities = Q.entities_by_type(ns, u.id)
        local by_type = {}
        for _, r in ipairs(records) do
            by_type[r.income_type_key] = by_type[r.income_type_key] or {}
            table.insert(by_type[r.income_type_key], r)
        end
        local cards, statuses = {}, {}
        for _, t in ipairs(types) do
            local recs = by_type[t.income_type_key] or {}
            local ents = has_entities(t) and (entities[t.entity_type] or {}) or {}
            local live = {}
            for _, e in ipairs(ents) do live[e.uuid] = true end
            local totals = { income = 0, expense = 0, tax_paid = 0, relief = 0 }
            local done = 0
            for _, r in ipairs(recs) do
                -- an archived entity's figures no longer count
                local counts = r.status ~= "not_applicable"
                    and (not has_entities(t) or (r.entity_uuid and live[r.entity_uuid]))
                if counts then
                    sum_totals(totals, IncomeTypes.record_totals(t.field_schema, r.values, t.estimator_mapping))
                    if r.status == "done" then done = done + 1 end
                end
            end
            local status = IncomeTypes.type_status(t, recs, ents)
            statuses[#statuses + 1] = status
            local card = type_json(t, {
                status = status, totals = totals,
                entity_count = #ents, done_count = done,
            })
            card.field_schema, card.estimator_mapping = nil, nil -- the overview doesn't need the form
            cards[#cards + 1] = card
        end
        local est = Q.estimator_inputs(u.id, year, ns)
        return ok({
            tax_year = year,
            types = arr(cards),
            progress = IncomeTypes.year_progress(statuses),
            estimate_inputs = obj(est.inputs),
        })
    end))

    app:get("/api/v2/tax/my-income/types/:key", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "User not found") end
        local year = tax_year_of(self.params.tax_year)
        if not year then return fail(400, "tax_year must look like 2025-26") end
        local ns = self.namespace.id
        local t = Q.type_for(ns, tostring(self.params.key or ""))
        if not t then return fail(404, "Income type not found") end
        local recs = Q.records(ns, u.id, year, t.income_type_key)
        local year_record, not_applicable, by_entity = nil, false, {}
        for _, r in ipairs(recs) do
            if r.entity_uuid == nil or type(r.entity_uuid) == "userdata" then
                if r.status == "not_applicable" then not_applicable = true else year_record = r end
            else
                by_entity[r.entity_uuid] = r
            end
        end
        local ents = {}
        local live = {}
        if has_entities(t) then
            for _, e in ipairs(Q.entities(ns, u.id, t.entity_type)) do
                live[#live + 1] = e
                ents[#ents + 1] = { uuid = e.uuid, label = e.label, created_at = e.created_at,
                    record = record_json(by_entity[e.uuid], t) }
            end
        end
        return ok({
            tax_year = year,
            type = type_json(t),
            status = IncomeTypes.type_status(t, recs, live),
            not_applicable = not_applicable,
            record = record_json(year_record, t),
            entities = arr(ents),
            suggestions = obj(Q.statement_suggestions(u.id, year, t.field_schema)),
        })
    end))

    app:put("/api/v2/tax/my-income/types/:key/record", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "User not found") end
        local body = read_body(self)
        local year = tax_year_of(body.tax_year or self.params.tax_year)
        if not year then return fail(400, "tax_year must look like 2025-26") end
        local ns = self.namespace.id
        local t = Q.type_for(ns, tostring(self.params.key or ""))
        if not t then return fail(404, "Income type not found") end
        if not t.has_form then return fail(400, "This income type has no form yet.") end
        local status = body.status == "done" and "done" or "in_progress"

        local entity_uuid = body.entity_uuid
        if entity_uuid == cjson.null or entity_uuid == "" then entity_uuid = nil end
        if has_entities(t) then
            if not entity_uuid then
                return fail(400, "Choose which " .. (t.entity_label or "item") .. " these figures are for.")
            end
            local e = Q.entity(ns, u.id, entity_uuid)
            if not e or e.entity_type ~= t.entity_type then return fail(404, "Not found") end
        elseif entity_uuid then
            return fail(400, "This income type isn't recorded per item.")
        end

        local clean, errors = IncomeTypes.validate_values(t.field_schema, body.values,
            { complete = status == "done" })
        if not clean then
            return fail(422, "Please check the highlighted fields.", { field_errors = errors })
        end
        local sources = {}
        if type(body.sources) == "table" then
            for k, v in pairs(body.sources) do
                if clean[k] ~= nil and (v == "statements" or v == "manual") then sources[k] = v end
            end
        end
        -- A not-applicable marker for the year no longer applies once figures are given.
        Q.set_not_applicable(ns, u.id, year, t.income_type_key, false)
        local r = Q.upsert_record(ns, u.id, year, t.income_type_key, entity_uuid, clean, sources, status)
        return ok(record_json(r, t))
    end))

    app:put("/api/v2/tax/my-income/types/:key/not-applicable", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "User not found") end
        local body = read_body(self)
        local year = tax_year_of(body.tax_year or self.params.tax_year)
        if not year then return fail(400, "tax_year must look like 2025-26") end
        local ns = self.namespace.id
        local t = Q.type_for(ns, tostring(self.params.key or ""))
        if not t then return fail(404, "Income type not found") end
        local on = body.not_applicable == true
        if on then
            -- Refuse silently discarding figures: the user must clear them first.
            for _, r in ipairs(Q.records(ns, u.id, year, t.income_type_key)) do
                if r.status ~= "not_applicable" and type(r.values) == "table" and next(r.values) ~= nil then
                    return fail(409, "You've already entered figures for this. Delete them first, or keep them.")
                end
            end
        end
        Q.set_not_applicable(ns, u.id, year, t.income_type_key, on)
        return ok({ not_applicable = on })
    end))

    app:post("/api/v2/tax/my-income/types/:key/entities", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "User not found") end
        local ns = self.namespace.id
        local t = Q.type_for(ns, tostring(self.params.key or ""))
        if not t then return fail(404, "Income type not found") end
        if not has_entities(t) then return fail(400, "This income type isn't recorded per item.") end
        local label = trim(read_body(self).label)
        if label == "" then return fail(422, "Give it a name you'll recognise.") end
        if #label > 120 then return fail(422, "Keep the name under 120 characters.") end
        local e = Q.create_entity(ns, u.id, u.uuid, t.entity_type, label)
        return ok({ uuid = e.uuid, label = e.label, record = cjson.null }, 201)
    end))

    app:put("/api/v2/tax/my-income/entities/:uuid", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "User not found") end
        local ns = self.namespace.id
        local label = trim(read_body(self).label)
        if label == "" then return fail(422, "Give it a name you'll recognise.") end
        if #label > 120 then return fail(422, "Keep the name under 120 characters.") end
        if not Q.entity(ns, u.id, self.params.uuid) then return fail(404, "Not found") end
        local e = Q.rename_entity(ns, u.id, self.params.uuid, label)
        return ok({ uuid = e.uuid, label = e.label })
    end))

    app:delete("/api/v2/tax/my-income/entities/:uuid", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "User not found") end
        if not Q.archive_entity(self.namespace.id, u.id, tostring(self.params.uuid or "")) then
            return fail(404, "Not found")
        end
        return ok({ archived = true })
    end))

    -- ── Administrators ────────────────────────────────────────────────────────

    app:get("/api/v2/tax/income-types", perm("read", function(self)
        local ns = self.namespace.id
        local include_inactive = self.params.include_inactive == "true"
        local usage = Q.usage_counts(ns)
        local out = {}
        for _, t in ipairs(Q.types_for(ns, { include_inactive = include_inactive })) do
            out[#out + 1] = type_json(t, { usage_count = usage[t.income_type_key] or 0 })
        end
        return ok({
            types = arr(out),
            can_edit = NamespaceMiddleware.hasPermission(self, "tax_income_types", "update"),
            can_create = NamespaceMiddleware.hasPermission(self, "tax_income_types", "create"),
            can_edit_global = self.is_platform_admin == true,
        })
    end))

    app:get("/api/v2/tax/income-types/meta", perm("read", function()
        local inputs = {}
        for k, d in pairs(IncomeTypes.ESTIMATOR_INPUTS) do inputs[#inputs + 1] = { key = k, description = d } end
        table.sort(inputs, function(a, b) return a.key < b.key end)
        local cats = db.query([[SELECT DISTINCT ON (key) key, label, type FROM tax_categories
            WHERE is_active = true ORDER BY key, id]])
        local field_types = {}
        for k in pairs(IncomeTypes.FIELD_TYPES) do field_types[#field_types + 1] = k end
        table.sort(field_types)
        return ok({
            field_types = field_types,
            roles = { "income", "expense", "tax_paid", "relief", "info" },
            estimator_inputs = inputs,
            categories = arr(cats),
            entity_types = { "property", "overseas_property", "employment", "business", "pension", "holding" },
        })
    end))

    app:post("/api/v2/tax/income-types/validate", perm("read", function(self)
        local body = read_body(self)
        local cur = nil
        if body.key and not body.creating then
            cur = Q.type_for(self.namespace.id, body.key, { include_inactive = true })
        end
        local valid, errs = IncomeTypes.validate_definition(body, { creating = body.creating == true, current = cur })
        return ok({ valid = valid == true, errors = arr(errs) })
    end))

    app:post("/api/v2/tax/income-types", perm("create", function(self)
        local body = read_body(self)
        local valid, errs = IncomeTypes.validate_definition(body, { creating = true })
        if not valid then return fail(422, "Please fix the problems listed.", { errors = errs }) end
        local t, err, status = Q.create_custom(self.namespace.id, body)
        if not t then return fail(status or 400, err) end
        return ok(type_json(t), 201)
    end))

    app:post("/api/v2/tax/income-types/reorder", perm("update", function(self)
        local keys = read_body(self).keys
        if type(keys) ~= "table" or #keys == 0 then return fail(400, "keys must list every income type in order") end
        local known = Q.by_key(Q.types_for(self.namespace.id, { include_inactive = true }))
        for _, k in ipairs(keys) do
            if not known[k] then return fail(400, "Unknown income type: " .. tostring(k)) end
        end
        local out = {}
        for _, t in ipairs(Q.reorder(self.namespace.id, keys)) do out[#out + 1] = type_json(t) end
        return ok(arr(out))
    end))

    app:put("/api/v2/tax/income-types/:key", perm("update", function(self)
        local body = read_body(self)
        local ns = self.namespace.id
        local key = tostring(self.params.key or "")
        local cur = Q.type_for(ns, key, { include_inactive = true })
        if not cur then return fail(404, "Income type not found") end
        local scope = body.scope == "global" and "global" or "namespace"
        if scope == "global" then
            if not self.is_platform_admin then
                return fail(403, "Only a platform administrator can change the default for every workspace.")
            end
            if cur.origin ~= "system" then scope = "namespace" end
        end
        body.key = nil -- keys are immutable
        if cur.origin == "system" and scope == "namespace" then
            -- a workspace can't change what an entity IS for a built-in type
            body.entity_type, body.entity_label = nil, nil
        end
        local valid, errs = IncomeTypes.validate_definition(body, { current = cur })
        if not valid then return fail(422, "Please fix the problems listed.", { errors = errs }) end
        local t, err, status = Q.update_type(ns, key, body, scope)
        if not t then return fail(status or 400, err) end
        return ok(type_json(t))
    end))

    app:post("/api/v2/tax/income-types/:key/reset", perm("update", function(self)
        local t, err, status = Q.reset_override(self.namespace.id, tostring(self.params.key or ""))
        if not t then return fail(status or 400, err) end
        return ok(type_json(t))
    end))
end
