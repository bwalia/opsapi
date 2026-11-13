--[[
    Income types — the pure (no DB, no ngx) core of "My Income".

    An income type is DATA (a row in income_types), not code. Each row carries:
      * field_schema       what the user fills in, per entity (property, job, business…)
                           or once per tax year: sections → fields, with validation,
                           help text, the HMRC box a figure feeds and which bank-statement
                           categories can pre-fill it.
      * estimator_mapping  how those figures become lib/tax-calc compute_full inputs
                           ({ field, input, scale_by?, sign? }). The tax rules stay in
                           tax-calc; this only says "field X is property rent".
      * entity_type        nil (one form per year) or the user_profile_entities.entity_type
                           the user adds several of (property, employment, business…).

    Everything here is pure so it is unit-tested standalone (spec/my-income-types_spec.lua):
      validate_schema / validate_mapping   admin edits (server-side, before saving)
      validate_values                      user edits (draft vs "mark as done")
      resolve                              system defaults + namespace overrides/additions
      type_status / year_progress          not started / in progress / done / not for me
      estimator_inputs                     records → compute_full inputs (+ per-type totals)
      agent keys                           the chat agent's legacy keys ↔ catalogue keys
]]

local IncomeTypes = {}

-- ---------------------------------------------------------------------------
-- Vocabulary
-- ---------------------------------------------------------------------------

IncomeTypes.FIELD_TYPES = {
    currency = true, number = true, percentage = true, boolean = true,
    text = true, date = true, select = true,
}
local NUMERIC = { currency = true, number = true, percentage = true }

-- What a figure IS, for the overview totals ("Income £x · Expenses £y · Tax paid £z").
IncomeTypes.ROLES = { income = true, expense = true, tax_paid = true, relief = true, info = true }

-- lib/tax-calc compute_full inputs an admin may map a field to. Keep in step with
-- compute_full; the description is shown in the admin form builder.
IncomeTypes.ESTIMATOR_INPUTS = {
    employment_income = "Employment pay and taxable benefits (non-savings income)",
    employment_expenses = "Allowable employment expenses (deducted from employment income)",
    paye_deducted = "Tax already taken off under PAYE",
    se_turnover = "Self-employment turnover (Class 4 NIC applies)",
    se_expenses = "Self-employment allowable expenses",
    se_capital_allowances = "Self-employment capital allowances",
    property_rents = "Property income — UK and overseas",
    property_expenses = "Allowable property expenses (not residential finance costs)",
    property_finance_costs = "Residential finance costs — 20% tax reduction (Section 24)",
    finance_costs_brought_forward = "Unused residential finance costs brought forward",
    savings_interest = "Savings interest (savings allowances apply)",
    dividends = "Dividends (dividend allowance and rates apply)",
    pension_income = "Pension income — State and private (non-savings)",
    other_income = "Other taxable income (non-savings); map expenses with sign -1",
    tax_deducted_at_source = "Other UK tax already taken off (e.g. pension PAYE)",
    gift_aid_net = "Gift Aid payments made (net)",
    pension_ras = "Pension contributions paid net under relief at source",
    payments_on_account_made = "Payments on account already made for the year",
}

-- Inputs that together make up one schedule. When My Income supplies any input of a
-- group, the WHOLE group comes from My Income (see lib/agent/tax-tools estimate).
IncomeTypes.GROUPS = {
    self_employment = { "se_turnover", "se_expenses", "se_capital_allowances" },
    property = { "property_rents", "property_expenses", "property_finance_costs",
        "finance_costs_brought_forward" },
}

-- The tax agent's original keys (kept working) → catalogue keys.
IncomeTypes.AGENT_ALIASES = {
    employment = "salary",
    uk_property = "rental",
    savings_interest = "interest",
}
-- Catalogue key → the agent key its routing logic understands.
IncomeTypes.AGENT_KEY_FOR = {
    salary = "employment",
    rental = "uk_property",
    overseas_property = "uk_property", -- property schedule (combined in the estimate)
    interest = "savings_interest",
    foreign_interest = "savings_interest",
    foreign_dividends = "dividends",
    other_dividends = "dividends",
}

IncomeTypes.MAX_FIELDS = 60
IncomeTypes.MAX_SECTIONS = 12
local KEY_PATTERN = "^[a-z][a-z0-9_]*$"

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function is_array(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

local function nonempty(s) return type(s) == "string" and s:match("%S") ~= nil end

local function is_null(v)
    -- cjson.null is a lightuserdata; treat it like nil.
    return v == nil or type(v) == "userdata"
end

function IncomeTypes.valid_key(key)
    return type(key) == "string" and #key <= 60 and key:match(KEY_PATTERN) ~= nil
end

function IncomeTypes.valid_tax_year(s)
    if type(s) ~= "string" then return false end
    local y1, y2 = s:match("^(%d%d%d%d)%-(%d%d)$")
    if not y1 then return false end
    return tonumber(y2) == (tonumber(y1) + 1) % 100
end

local function to_number(v)
    if type(v) == "number" then return (v == v and v ~= math.huge and v ~= -math.huge) and v or nil end
    if type(v) == "string" then
        local s = v:gsub(",", ""):gsub("^%s*£?%s*", ""):gsub("%s+$", "")
        if s == "" then return nil end
        local n = tonumber(s)
        if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
    end
    return nil
end
IncomeTypes.to_number = to_number

--- Every field of a schema, in order, with its section key attached.
function IncomeTypes.fields(schema)
    local out = {}
    if type(schema) ~= "table" or type(schema.sections) ~= "table" then return out end
    for _, sec in ipairs(schema.sections) do
        for _, f in ipairs(type(sec.fields) == "table" and sec.fields or {}) do
            out[#out + 1] = f
        end
    end
    return out
end

local function field_map(schema)
    local m = {}
    for _, f in ipairs(IncomeTypes.fields(schema)) do
        if type(f) == "table" and f.key then m[f.key] = f end
    end
    return m
end
IncomeTypes.field_map = field_map

-- ---------------------------------------------------------------------------
-- Schema validation (admin)
-- ---------------------------------------------------------------------------

--- Validate a field schema. Returns (true) or (false, { "error", ... }).
-- Shape: { sections = [ { key, title, help?, fields = [ field ] } ] }
-- field: { key, label, type, required?, help?, placeholder?, min?, max?, options?,
--          default?, role?, hmrc_box?, show_if? = { field, equals },
--          prefill? = { categories = [..], direction = "credit"|"debit" } }
function IncomeTypes.validate_schema(schema)
    local errs = {}
    local function err(msg) errs[#errs + 1] = msg end
    if type(schema) ~= "table" then return false, { "Field schema must be an object." } end
    if not is_array(schema.sections) or #schema.sections == 0 then
        return false, { "Add at least one section." }
    end
    if #schema.sections > IncomeTypes.MAX_SECTIONS then
        err("At most " .. IncomeTypes.MAX_SECTIONS .. " sections.")
    end
    local seen_sections, seen_fields, total = {}, {}, 0
    for si, sec in ipairs(schema.sections) do
        local where = "Section " .. si
        if type(sec) ~= "table" then
            err(where .. " must be an object.")
        else
            if not IncomeTypes.valid_key(sec.key) then
                err(where .. ": key must be lower_snake_case (letters, digits, _).")
            elseif seen_sections[sec.key] then
                err(where .. ": duplicate section key '" .. sec.key .. "'.")
            else
                seen_sections[sec.key] = true
            end
            if not nonempty(sec.title) then err(where .. ": title is required.") end
            if not is_array(sec.fields) or #sec.fields == 0 then
                err(where .. ": add at least one field.")
            else
                for fi, f in ipairs(sec.fields) do
                    total = total + 1
                    local fw = where .. ", field " .. fi
                    if type(f) ~= "table" then
                        err(fw .. " must be an object.")
                    else
                        if not IncomeTypes.valid_key(f.key) then
                            err(fw .. ": key must be lower_snake_case.")
                        elseif seen_fields[f.key] then
                            err(fw .. ": duplicate field key '" .. f.key .. "'.")
                        else
                            seen_fields[f.key] = f
                            fw = "Field '" .. f.key .. "'"
                        end
                        if not nonempty(f.label) then err(fw .. ": label is required.") end
                        if not IncomeTypes.FIELD_TYPES[f.type] then
                            err(fw .. ": type must be one of currency, number, percentage, boolean, "
                                .. "text, date, select.")
                        end
                        if f.role ~= nil and not IncomeTypes.ROLES[f.role] then
                            err(fw .. ": role must be income, expense, tax_paid, relief or info.")
                        end
                        if f.min ~= nil and to_number(f.min) == nil then err(fw .. ": min must be a number.") end
                        if f.max ~= nil and to_number(f.max) == nil then err(fw .. ": max must be a number.") end
                        if f.min ~= nil and f.max ~= nil and to_number(f.min) and to_number(f.max)
                            and to_number(f.min) > to_number(f.max) then
                            err(fw .. ": min is greater than max.")
                        end
                        if f.type == "select" then
                            if not is_array(f.options) or #f.options == 0 then
                                err(fw .. ": a select needs at least one option.")
                            else
                                for _, o in ipairs(f.options) do
                                    if type(o) ~= "table" or not nonempty(tostring(o.value or ""))
                                        or not nonempty(o.label) then
                                        err(fw .. ": every option needs a value and a label.")
                                        break
                                    end
                                end
                            end
                        end
                        if f.prefill ~= nil then
                            local p = f.prefill
                            if type(p) ~= "table" or not NUMERIC[f.type] then
                                err(fw .. ": statement pre-fill is only for number/currency fields.")
                            else
                                if not is_array(p.categories) or #p.categories == 0 then
                                    err(fw .. ": pre-fill needs at least one category.")
                                else
                                    for _, c in ipairs(p.categories) do
                                        if not IncomeTypes.valid_key(c) then
                                            err(fw .. ": pre-fill category keys must be lower_snake_case.")
                                            break
                                        end
                                    end
                                end
                                if p.direction ~= "credit" and p.direction ~= "debit" then
                                    err(fw .. ": pre-fill direction must be credit (money in) or debit (money out).")
                                end
                            end
                        end
                        if f.help ~= nil and type(f.help) ~= "string" then err(fw .. ": help must be text.") end
                        if type(f.help) == "string" and #f.help > 1000 then err(fw .. ": help is too long.") end
                    end
                end
            end
        end
    end
    if total > IncomeTypes.MAX_FIELDS then err("At most " .. IncomeTypes.MAX_FIELDS .. " fields.") end
    -- show_if must point at an earlier-or-any boolean/select field that exists.
    for key, f in pairs(seen_fields) do
        if f.show_if ~= nil then
            local s = f.show_if
            if type(s) ~= "table" or not seen_fields[s.field] then
                err("Field '" .. key .. "': show_if must name another field in this schema.")
            elseif s.field == key then
                err("Field '" .. key .. "': show_if cannot depend on itself.")
            end
        end
    end
    if #errs > 0 then return false, errs end
    return true
end

--- Validate an estimator mapping against its schema.
-- mapping: [ { field, input, scale_by?, sign? (1|-1) } ]
function IncomeTypes.validate_mapping(mapping, schema)
    local errs = {}
    local function err(msg) errs[#errs + 1] = msg end
    if mapping == nil or (type(mapping) == "table" and next(mapping) == nil) then return true end
    if not is_array(mapping) then return false, { "Estimator mapping must be a list." } end
    local fm = field_map(schema)
    for i, m in ipairs(mapping) do
        local w = "Mapping " .. i
        if type(m) ~= "table" then
            err(w .. " must be an object.")
        else
            local f = fm[m.field]
            if not f then
                err(w .. ": field '" .. tostring(m.field) .. "' is not in the schema.")
            elseif not NUMERIC[f.type] or f.type == "percentage" then
                err(w .. ": only currency or number fields can feed the estimate.")
            end
            if not IncomeTypes.ESTIMATOR_INPUTS[m.input] then
                err(w .. ": '" .. tostring(m.input) .. "' is not an estimator input.")
            end
            if m.scale_by ~= nil then
                local sf = fm[m.scale_by]
                if not sf or sf.type ~= "percentage" then
                    err(w .. ": scale_by must name a percentage field (e.g. your ownership share).")
                end
            end
            if m.sign ~= nil and m.sign ~= 1 and m.sign ~= -1 then
                err(w .. ": sign must be 1 or -1.")
            end
        end
    end
    if #errs > 0 then return false, errs end
    return true
end

--- Validate an admin's create/update payload for an income type.
-- opts.creating: key + display_name + field_schema required.
-- opts.current: the type as it is now (to check a mapping against the schema that
-- will be in force after a partial update). Returns (true) or (false, { errors }).
function IncomeTypes.validate_definition(body, opts)
    opts = opts or {}
    local cur = opts.current or {}
    local errs = {}
    local function err(m) errs[#errs + 1] = m end
    if type(body) ~= "table" then return false, { "Send the income type as a JSON object." } end
    if opts.creating then
        if not IncomeTypes.valid_key(body.key) or #body.key > 40 then
            err("Key must be lower_snake_case, up to 40 characters (e.g. crypto_staking).")
        end
    end
    if opts.creating or body.display_name ~= nil then
        if not nonempty(body.display_name) then err("Name is required.")
        elseif #body.display_name > 120 then err("Name must be 120 characters or fewer.") end
    end
    for _, col in ipairs({ "description", "help_text", "estimate_note" }) do
        local v = body[col]
        if v ~= nil and not is_null(v) and (type(v) ~= "string" or #v > 4000) then
            err(col .. " must be text up to 4000 characters.")
        end
    end
    if body.icon ~= nil and not is_null(body.icon)
        and (type(body.icon) ~= "string" or not body.icon:match("^[A-Za-z0-9]+$") or #body.icon > 60) then
        err("Icon must be an icon name such as Home or Briefcase.")
    end
    if body.entity_type ~= nil and not is_null(body.entity_type) and body.entity_type ~= ""
        and not IncomeTypes.valid_key(body.entity_type) then
        err("Entity type must be lower_snake_case (e.g. property, employment).")
    end
    if body.entity_label ~= nil and not is_null(body.entity_label)
        and (type(body.entity_label) ~= "string" or #body.entity_label > 60) then
        err("Entity label must be up to 60 characters (e.g. property).")
    end
    if body.linked_form_weblink ~= nil and not is_null(body.linked_form_weblink)
        and body.linked_form_weblink ~= ""
        and (type(body.linked_form_weblink) ~= "string" or not body.linked_form_weblink:match("^https?://")) then
        err("Reference link must start with https://")
    end
    if body.display_order ~= nil and not is_null(body.display_order) and to_number(body.display_order) == nil then
        err("Order must be a number.")
    end

    local schema = cur.field_schema
    if opts.creating or (body.field_schema ~= nil and not is_null(body.field_schema)) then
        schema = body.field_schema
        local ok, serrs = IncomeTypes.validate_schema(schema)
        if not ok then for _, e in ipairs(serrs) do err(e) end end
    end
    local mapping = cur.estimator_mapping
    if body.estimator_mapping ~= nil and not is_null(body.estimator_mapping) then mapping = body.estimator_mapping end
    if #errs == 0 then
        local ok, merrs = IncomeTypes.validate_mapping(mapping, schema)
        if not ok then for _, e in ipairs(merrs) do err(e) end end
    end
    if #errs > 0 then return false, errs end
    return true
end

-- ---------------------------------------------------------------------------
-- Value validation (user)
-- ---------------------------------------------------------------------------

local function visible(f, values)
    local s = f.show_if
    if type(s) ~= "table" then return true end
    local v = values[s.field]
    if s.equals == nil then return v == true or v == "true" end
    return v == s.equals or tostring(v) == tostring(s.equals)
end
IncomeTypes.visible = visible

--- Clean + validate a user's values against the schema.
-- opts.complete = true enforces required fields (the "Mark as done" path).
-- Unknown keys are dropped; empty strings become absent. Returns
-- (clean_values, nil) or (nil, { field_key = "message", ... }).
function IncomeTypes.validate_values(schema, values, opts)
    opts = opts or {}
    values = type(values) == "table" and values or {}
    local clean, errors, any = {}, {}, false
    for _, f in ipairs(IncomeTypes.fields(schema)) do
        local v = values[f.key]
        local label = f.label or f.key
        if is_null(v) or v == "" then
            v = nil
        elseif NUMERIC[f.type] then
            local n = to_number(v)
            if n == nil then
                errors[f.key] = label .. " must be a number."; any = true
            else
                local min = to_number(f.min)
                if min == nil and (f.type == "currency" or f.type == "percentage") then min = 0 end
                local max = to_number(f.max)
                if max == nil and f.type == "percentage" then max = 100 end
                if min and n < min then
                    errors[f.key] = label .. " can't be less than " .. min .. "."; any = true
                elseif max and n > max then
                    errors[f.key] = label .. " can't be more than " .. max .. "."; any = true
                else
                    if f.type == "currency" then n = math.floor(n * 100 + 0.5) / 100 end
                    v = n
                end
            end
        elseif f.type == "boolean" then
            if v == true or v == "true" or v == 1 then v = true
            elseif v == false or v == "false" or v == 0 then v = false
            else errors[f.key] = label .. " must be yes or no."; any = true end
        elseif f.type == "date" then
            if type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d$") then
                errors[f.key] = label .. " must be a date (YYYY-MM-DD)."; any = true
            end
        elseif f.type == "select" then
            local ok = false
            for _, o in ipairs(f.options or {}) do
                if tostring(o.value) == tostring(v) then ok = true; v = o.value; break end
            end
            if not ok then errors[f.key] = label .. ": choose one of the options."; any = true end
        else -- text
            v = tostring(v)
            if #v > 500 then errors[f.key] = label .. " must be 500 characters or fewer."; any = true end
        end
        if not errors[f.key] then clean[f.key] = v end
        if opts.complete and f.required and clean[f.key] == nil and visible(f, clean)
            and not errors[f.key] then
            errors[f.key] = label .. " is required before you can mark this as done."; any = true
        end
    end
    if any then return nil, errors end
    return clean
end

-- ---------------------------------------------------------------------------
-- Override resolution (system defaults + namespace)
-- ---------------------------------------------------------------------------

-- Columns a namespace may override on a SYSTEM type (nil = inherit the default).
IncomeTypes.OVERRIDABLE = {
    "display_name", "description", "help_text", "icon", "display_order", "is_active",
    "field_schema", "estimator_mapping", "estimate_note",
}

--- Merge system rows, a namespace's own rows and its overrides into the list a
-- namespace sees. Rows of OTHER namespaces are ignored (defence in depth: the
-- query already filters them). Returns rows sorted by display_order, name, each
-- with origin = "system" | "custom" and overridden = { col = true }.
-- opts.include_inactive keeps deactivated rows (admin view).
function IncomeTypes.resolve(rows, overrides, namespace_id, opts)
    opts = opts or {}
    local ns = tonumber(namespace_id)
    local by_type = {}
    for _, o in ipairs(overrides or {}) do
        if tonumber(o.namespace_id) == ns then by_type[tonumber(o.income_type_id)] = o end
    end
    local out = {}
    for _, r in ipairs(rows or {}) do
        local rns = tonumber(r.namespace_id)
        local is_system = rns == nil or rns == 0
        if is_system or rns == ns then
            local row = {}
            for k, v in pairs(r) do row[k] = v end
            row.origin = is_system and "system" or "custom"
            row.overridden = {}
            local o = is_system and by_type[tonumber(r.id)] or nil
            if o then
                for _, col in ipairs(IncomeTypes.OVERRIDABLE) do
                    if not is_null(o[col]) then
                        row[col] = o[col]
                        row.overridden[col] = true
                    end
                end
            end
            row.is_active = row.is_active == true or row.is_active == "t"
            if row.is_active or opts.include_inactive then out[#out + 1] = row end
        end
    end
    table.sort(out, function(a, b)
        local da, db_ = tonumber(a.display_order) or 0, tonumber(b.display_order) or 0
        if da ~= db_ then return da < db_ end
        return tostring(a.display_name or "") < tostring(b.display_name or "")
    end)
    return out
end

--- Key a namespace's custom type is stored under. income_type_key is globally
-- unique (and other products ON CONFLICT on it), so a namespace's own types are
-- prefixed: no clash with system keys or with another namespace's types.
function IncomeTypes.custom_key(namespace_id, slug)
    return "ns" .. tostring(tonumber(namespace_id) or 0) .. "_" .. slug
end

-- ---------------------------------------------------------------------------
-- Status + progress
-- ---------------------------------------------------------------------------

--- Status of one income type for a year.
-- t: resolved type (entity_type?); records: that type's records for the year
-- ({ entity_uuid?, status }); entities: the user's live entities of its entity_type.
-- → "not_started" | "in_progress" | "done" | "not_applicable"
function IncomeTypes.type_status(t, records, entities)
    records = records or {}
    for _, r in ipairs(records) do
        if r.status == "not_applicable" and is_null(r.entity_uuid) then return "not_applicable" end
    end
    if t.entity_type and t.entity_type ~= "" then
        entities = entities or {}
        if #entities == 0 then
            return #records > 0 and "in_progress" or "not_started"
        end
        local done_for = {}
        for _, r in ipairs(records) do
            if r.status == "done" and not is_null(r.entity_uuid) then done_for[r.entity_uuid] = true end
        end
        for _, e in ipairs(entities) do
            if not done_for[e.uuid] then return "in_progress" end
        end
        return "done"
    end
    for _, r in ipairs(records) do
        if is_null(r.entity_uuid) then
            return r.status == "done" and "done" or "in_progress"
        end
    end
    return "not_started"
end

--- { reviewed, total, started } over a list of statuses. "Reviewed" = done or
-- "not for me" — the user has told us about every income type.
function IncomeTypes.year_progress(statuses)
    local reviewed, started = 0, 0
    for _, s in ipairs(statuses) do
        if s == "done" or s == "not_applicable" then reviewed = reviewed + 1 end
        if s ~= "not_started" and s ~= "not_applicable" then started = started + 1 end
    end
    return { reviewed = reviewed, total = #statuses, started = started }
end

-- ---------------------------------------------------------------------------
-- Totals + estimator inputs
-- ---------------------------------------------------------------------------

--- Per-record totals by role (income / expense / tax_paid / relief), honouring
-- show_if and the ownership share a mapping scales by.
function IncomeTypes.record_totals(schema, values)
    values = values or {}
    local t = { income = 0, expense = 0, tax_paid = 0, relief = 0 }
    for _, f in ipairs(IncomeTypes.fields(schema)) do
        if NUMERIC[f.type] and f.type ~= "percentage" and t[f.role or ""] ~= nil and visible(f, values) then
            t[f.role] = t[f.role] + (to_number(values[f.key]) or 0)
        end
    end
    return t
end

local function r2(x) return math.floor((tonumber(x) or 0) * 100 + 0.5) / 100 end

--- Turn My Income records into compute_full inputs.
-- types_by_key: resolved types keyed by income_type_key.
-- records: { income_type_key, entity_uuid?, status, values } (not_applicable rows ignored).
-- Returns {
--   inputs   = { input = £ },               summed over every type
--   by_type  = { key = { input = £ } },
--   groups   = { self_employment = true, property = true } (schedules supplied),
--   agent_types = { "uk_property", ... }   (the agent's keys, for routing),
--   has_data = bool }
function IncomeTypes.estimator_inputs(types_by_key, records)
    local inputs, by_type, groups, agent_seen, agent_types = {}, {}, {}, {}, {}
    local group_of = {}
    for g, list in pairs(IncomeTypes.GROUPS) do
        for _, k in ipairs(list) do group_of[k] = g end
    end
    local has_data = false
    for _, rec in ipairs(records or {}) do
        local t = types_by_key[rec.income_type_key]
        if t and rec.status ~= "not_applicable" and type(rec.values) == "table" then
            local fm = field_map(t.field_schema)
            local mapping = type(t.estimator_mapping) == "table" and t.estimator_mapping or {}
            local contributed = false
            for _, m in ipairs(mapping) do
                local f = fm[m.field]
                local v = f and visible(f, rec.values) and to_number(rec.values[m.field])
                if v and v ~= 0 and IncomeTypes.ESTIMATOR_INPUTS[m.input] then
                    if m.scale_by then
                        local share = to_number(rec.values[m.scale_by])
                        if share == nil then
                            local sf = fm[m.scale_by]
                            share = sf and to_number(sf.default) or 100
                        end
                        v = v * math.max(0, math.min(100, share)) / 100
                    end
                    if m.sign == -1 then v = -v end
                    inputs[m.input] = r2((inputs[m.input] or 0) + v)
                    by_type[rec.income_type_key] = by_type[rec.income_type_key] or {}
                    local bt = by_type[rec.income_type_key]
                    bt[m.input] = r2((bt[m.input] or 0) + v)
                    if group_of[m.input] then groups[group_of[m.input]] = true end
                    contributed = true
                end
            end
            if contributed then
                has_data = true
                local ak = IncomeTypes.AGENT_KEY_FOR[rec.income_type_key] or rec.income_type_key
                if not agent_seen[ak] then agent_seen[ak] = true; agent_types[#agent_types + 1] = ak end
            end
        end
    end
    return { inputs = inputs, by_type = by_type, groups = groups, agent_types = agent_types,
        has_data = has_data }
end

-- ---------------------------------------------------------------------------
-- Agent keys
-- ---------------------------------------------------------------------------

--- Normalise what the chat agent sent against the namespace's catalogue.
-- valid_keys: set { catalogue_key = true }. Legacy agent keys (employment,
-- uk_property, savings_interest, …) keep working. Returns (clean, bad): clean
-- holds the AGENT key (what the estimate's routing understands).
function IncomeTypes.normalise_agent_types(list, valid_keys)
    local clean, bad, seen = {}, {}, {}
    for _, raw in ipairs(type(list) == "table" and list or {}) do
        local k = tostring(raw):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%s%-]+", "_")
        local catalogue = IncomeTypes.AGENT_ALIASES[k] or k
        local ok = valid_keys[catalogue] or valid_keys[k]
        if ok then
            local agent_key = IncomeTypes.AGENT_KEY_FOR[catalogue] or catalogue
            -- keep the user's own spelling when it was already an agent key
            if IncomeTypes.AGENT_ALIASES[k] then agent_key = k end
            if not seen[agent_key] then seen[agent_key] = true; clean[#clean + 1] = agent_key end
        else
            bad[#bad + 1] = tostring(raw)
        end
    end
    return clean, bad
end

return IncomeTypes
