--[[
    Spec: My Income — definition-driven income types.

    Guards:
      * every seeded system definition is a valid schema + estimator mapping, and the
        seed covers exactly the 13 catalogue keys diy-tax-return-uk uses;
      * admin schema / mapping / definition validation (server-side);
      * user value validation (draft vs "mark as done", show_if, money parsing);
      * override resolution: system defaults + this namespace's own types/overrides,
        never another namespace's;
      * status + year progress;
      * records → lib/tax-calc inputs (ownership share, sign, groups, agent types) and
        the estimate overlay in lib/agent/tax-tools (My Income wins per schedule);
      * compute_full's new pension / other income / tax-at-source inputs;
      * the agent's income types come from the table (legacy keys still work);
      * TaxIncomeQueries scopes every user query by namespace_id AND user_id, and a
        workspace edit of a system type writes an override, never the shared row.

    Standalone (no DB / nginx): lapis.db, resty.http and helper.global are stubbed.
        docker run --rm -v "$PWD:/repo" -w /repo bwalia/opsapi-base:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/my-income-types_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local cjson = require("cjson")

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function near(a, b) return math.abs((tonumber(a) or -1e9) - b) < 0.01 end

-- ---- stubs -----------------------------------------------------------------
local queries = {}
local responders = {} -- { pattern, fn(args) -> rows }
local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
package.loaded["lapis.db"] = {
    NULL = NULL,
    query = function(sql, ...)
        local args = { ... }
        queries[#queries + 1] = { sql = sql, args = args }
        for _, r in ipairs(responders) do
            if sql:find(r[1], 1, true) then return r[2](args) end
        end
        if sql:find("FROM tax_rates") then return {} end
        return { affected_rows = 1 }
    end,
    select = function() return {} end,
    escape_identifier = function(s) return '"' .. s .. '"' end,
    interpolate_query = function(q, ...)
        local vals = { ... }
        local i = 0
        return (q:gsub("%?", function()
            i = i + 1
            local v = vals[i]
            if type(v) == "string" then return "'" .. v:gsub("'", "''") .. "'" end
            return tostring(v)
        end))
    end,
}
package.loaded["resty.http"] = { new = function() error("no http in spec") end }
package.loaded["helper.global"] = { generateUUID = function() return "uuid-test" end }

local IncomeTypes = require("lib.income-types")
local SEED = require("lib.income-types-seed")
local TaxCalc = require("lib.tax-calc")

-- ============================================================================
print("seeded definitions")
-- ============================================================================
local CATALOGUE = { "salary", "self_employment", "dividends", "foreign_dividends", "other_dividends",
    "rental", "overseas_property", "interest", "foreign_interest", "pension", "pension_payments",
    "capital_gains", "other" }
local seeded = {}
for _, s in ipairs(SEED) do
    seeded[s.key] = s
    local ok, errs = IncomeTypes.validate_schema(s.field_schema)
    check("seed " .. s.key .. ": schema valid", ok, errs and table.concat(errs, "; "))
    local okm, merrs = IncomeTypes.validate_mapping(s.estimator_mapping, s.field_schema)
    check("seed " .. s.key .. ": mapping valid", okm, merrs and table.concat(merrs, "; "))
    check("seed " .. s.key .. ": has an icon and help", type(s.icon) == "string" and type(s.help_text) == "string")
end
for _, k in ipairs(CATALOGUE) do check("seed covers catalogue key " .. k, seeded[k] ~= nil) end
check("seed has no keys outside the catalogue", #SEED == #CATALOGUE)
check("capital gains explains it isn't in the estimate", seeded.capital_gains.estimate_note ~= nil
    and #seeded.capital_gains.estimator_mapping == 0)
check("property types track entities", seeded.rental.entity_type == "property"
    and seeded.overseas_property.entity_type == "overseas_property"
    and seeded.salary.entity_type == "employment" and seeded.self_employment.entity_type == "business")
-- every currency field carries a role so the overview totals add up
local roleless = {}
for _, s in ipairs(SEED) do
    for _, f in ipairs(IncomeTypes.fields(s.field_schema)) do
        if f.type == "currency" and not f.role then roleless[#roleless + 1] = s.key .. "." .. f.key end
    end
end
check("every seeded money field has a role", #roleless == 0, table.concat(roleless, ", "))

-- ============================================================================
print("schema validation")
-- ============================================================================
local function schema(fields) return { sections = { { key = "main", title = "Main", fields = fields } } } end
local ok, errs = IncomeTypes.validate_schema({ sections = {} })
check("empty schema rejected", not ok and errs[1]:find("section"))
ok, errs = IncomeTypes.validate_schema(schema({
    { key = "a", label = "A", type = "currency" }, { key = "a", label = "A2", type = "currency" } }))
check("duplicate field keys rejected", not ok and table.concat(errs):find("duplicate field key"))
ok, errs = IncomeTypes.validate_schema(schema({ { key = "Bad Key", label = "x", type = "currency" } }))
check("non-snake key rejected", not ok and table.concat(errs):find("lower_snake_case"))
ok, errs = IncomeTypes.validate_schema(schema({ { key = "a", label = "A", type = "money" } }))
check("unknown field type rejected", not ok and table.concat(errs):find("type must be"))
ok, errs = IncomeTypes.validate_schema(schema({ { key = "a", label = "A", type = "select" } }))
check("select without options rejected", not ok and table.concat(errs):find("option"))
ok, errs = IncomeTypes.validate_schema(schema({ { key = "a", label = "A", type = "text",
    prefill = { categories = { "rental_income" }, direction = "credit" } } }))
check("pre-fill on a text field rejected", not ok and table.concat(errs):find("pre%-fill"))
ok, errs = IncomeTypes.validate_schema(schema({ { key = "a", label = "A", type = "currency",
    prefill = { categories = { "rental_income" }, direction = "sideways" } } }))
check("pre-fill direction checked", not ok and table.concat(errs):find("direction"))
ok, errs = IncomeTypes.validate_schema(schema({ { key = "a", label = "A", type = "currency",
    show_if = { field = "nope" } } }))
check("show_if must name a field", not ok and table.concat(errs):find("show_if"))
ok, errs = IncomeTypes.validate_schema(schema({ { key = "a", label = "", type = "currency" } }))
check("label required", not ok and table.concat(errs):find("label is required"))
ok = IncomeTypes.validate_schema(schema({ { key = "a", label = "A", type = "currency", role = "income",
    min = 0, prefill = { categories = { "rental_income" }, direction = "credit" } },
    { key = "kind", label = "Kind", type = "select", options = { { value = "res", label = "Residential" } } } }))
check("a good schema passes", ok)

-- ============================================================================
print("mapping + definition validation")
-- ============================================================================
local s1 = schema({ { key = "rent", label = "Rent", type = "currency" },
    { key = "share", label = "Share", type = "percentage" }, { key = "note", label = "Note", type = "text" } })
check("valid mapping", IncomeTypes.validate_mapping({ { field = "rent", input = "property_rents",
    scale_by = "share" } }, s1))
ok, errs = IncomeTypes.validate_mapping({ { field = "rent", input = "rocket_fuel" } }, s1)
check("unknown estimator input rejected", not ok and errs[1]:find("not an estimator input"))
ok, errs = IncomeTypes.validate_mapping({ { field = "note", input = "dividends" } }, s1)
check("text field can't feed the estimate", not ok and errs[1]:find("currency or number"))
ok = IncomeTypes.validate_mapping({ { field = "share", input = "dividends" } }, s1)
check("percentage field can't feed the estimate", not ok)
ok, errs = IncomeTypes.validate_mapping({ { field = "rent", input = "property_rents", scale_by = "note" } }, s1)
check("scale_by must be a percentage field", not ok and errs[1]:find("scale_by"))
ok, errs = IncomeTypes.validate_mapping({ { field = "missing", input = "dividends" } }, s1)
check("mapping to a missing field rejected", not ok and errs[1]:find("not in the schema"))
check("empty mapping is fine (not in the estimate)", IncomeTypes.validate_mapping({}, s1))

ok, errs = IncomeTypes.validate_definition({ display_name = "Crypto" }, { creating = true })
check("create needs a key and a schema", not ok and table.concat(errs, "|"):find("Key"))
ok, errs = IncomeTypes.validate_definition({ key = "crypto_staking", display_name = "Crypto staking",
    icon = "Coins",
    field_schema = schema({ { key = "rewards", label = "Rewards", type = "currency", role = "income" } }),
    estimator_mapping = { { field = "rewards", input = "other_income" } } }, { creating = true })
check("a good custom type passes", ok, errs and table.concat(errs, "; "))
ok, errs = IncomeTypes.validate_definition(
    { field_schema = schema({ { key = "other", label = "O", type = "currency" } }) },
    { current = { field_schema = s1, estimator_mapping = { { field = "rent", input = "property_rents" } } } })
check("schema edit that orphans a mapping is rejected", not ok and table.concat(errs):find("rent"))
ok = IncomeTypes.validate_definition({ icon = "<script>" }, {})
check("icon must be an icon name", not ok)
ok, errs = IncomeTypes.validate_definition({ linked_form_weblink = "javascript:alert(1)" }, {})
check("reference link must be http(s)", not ok and table.concat(errs):find("https"))

-- ============================================================================
print("user values")
-- ============================================================================
local rental = seeded.rental.field_schema
local clean, verrs = IncomeTypes.validate_values(rental, { rents = "£12,000.505", repairs = "", junk = 5 })
check("money parsed and rounded", clean and near(clean.rents, 12000.51), verrs and cjson.encode(verrs))
check("empty string becomes absent", clean and clean.repairs == nil)
check("unknown keys dropped", clean and clean.junk == nil)
clean, verrs = IncomeTypes.validate_values(rental, { rents = -5 })
check("negative money rejected next to the field", not clean and verrs.rents ~= nil)
clean, verrs = IncomeTypes.validate_values(rental, { ownership_share = 150 })
check("percentage capped at 100", not clean and verrs.ownership_share ~= nil)
clean = IncomeTypes.validate_values(rental, { repairs = 100 })
check("draft save allows missing required fields", clean ~= nil)
clean, verrs = IncomeTypes.validate_values(rental, { repairs = 100 }, { complete = true })
check("mark as done enforces required fields", not clean and verrs.rents and verrs.rents:find("required"))
local sal = seeded.salary.field_schema
clean = IncomeTypes.validate_values(sal, { pay = 30000, left_in_year = "false" }, { complete = true })
check("boolean strings normalised", clean and clean.left_in_year == false)
clean, verrs = IncomeTypes.validate_values(sal, { pay = 30000, left_in_year = true, end_date = "5/4/25" })
check("bad date rejected", not clean and verrs.end_date ~= nil)

-- ============================================================================
print("override resolution")
-- ============================================================================
local rows = {
    { id = 1, income_type_key = "rental", display_name = "Rental", display_order = 40, is_active = true,
        namespace_id = nil, field_schema = rental },
    { id = 2, income_type_key = "salary", display_name = "Salary", display_order = 10, is_active = "t",
        namespace_id = 0 },
    { id = 3, income_type_key = "capital_gains", display_name = "Gains", display_order = 70, is_active = false },
    { id = 4, income_type_key = "ns7_crypto", display_name = "Crypto", display_order = 50, is_active = true,
        namespace_id = 7 },
    { id = 5, income_type_key = "ns9_secret", display_name = "Other firm's type", display_order = 5,
        is_active = true, namespace_id = 9 },
}
local overrides = {
    { namespace_id = 7, income_type_id = 1, display_name = "Buy-to-let", display_order = 5, is_active = nil },
    { namespace_id = 9, income_type_id = 2, is_active = false },
}
local seen = IncomeTypes.resolve(rows, overrides, 7)
local keys = {}
for _, r in ipairs(seen) do keys[#keys + 1] = r.income_type_key end
check("namespace sees system + its own active types, in order",
    table.concat(keys, ",") == "rental,salary,ns7_crypto", table.concat(keys, ","))
check("another namespace's type is never visible", not table.concat(keys, ","):find("ns9"))
check("override renames for this namespace", seen[1].display_name == "Buy-to-let" and seen[1].overridden.display_name)
check("NULL override column inherits", seen[1].is_active == true and not seen[1].overridden.is_active)
check("origin marks system vs custom", seen[1].origin == "system" and seen[3].origin == "custom")
check("another namespace's override doesn't apply", seen[2].is_active == true)
local admin = IncomeTypes.resolve(rows, overrides, 7, { include_inactive = true })
check("admin view includes inactive types", #admin == 4)
local other = IncomeTypes.resolve(rows, overrides, 9)
local hidden = true
for _, r in ipairs(other) do if r.income_type_key == "salary" then hidden = false end end
check("a namespace can hide a system type for itself", hidden)
check("custom keys are namespaced", IncomeTypes.custom_key(7, "crypto") == "ns7_crypto")

-- ============================================================================
print("status + progress")
-- ============================================================================
local flat = { income_type_key = "dividends" }
local prop = { income_type_key = "rental", entity_type = "property" }
check("no record → not started", IncomeTypes.type_status(flat, {}, {}) == "not_started")
check("draft → in progress", IncomeTypes.type_status(flat, { { status = "in_progress" } }) == "in_progress")
check("done → done", IncomeTypes.type_status(flat, { { status = "done" } }) == "done")
check("not for me", IncomeTypes.type_status(prop, { { status = "not_applicable" } }, {}) == "not_applicable")
check("entity type with no entities → not started", IncomeTypes.type_status(prop, {}, {}) == "not_started")
check("one of two properties done → in progress", IncomeTypes.type_status(prop,
    { { entity_uuid = "a", status = "done" } }, { { uuid = "a" }, { uuid = "b" } }) == "in_progress")
check("every property done → done", IncomeTypes.type_status(prop,
    { { entity_uuid = "a", status = "done" }, { entity_uuid = "b", status = "done" } },
    { { uuid = "a" }, { uuid = "b" } }) == "done")
local p = IncomeTypes.year_progress({ "done", "not_applicable", "in_progress", "not_started" })
check("progress counts done + not-for-me as reviewed", p.reviewed == 2 and p.total == 4 and p.started == 2)

-- ============================================================================
print("estimator inputs")
-- ============================================================================
local by_key = {}
for _, s in ipairs(SEED) do by_key[s.key] = s end
local est = IncomeTypes.estimator_inputs(by_key, {
    { income_type_key = "rental", entity_uuid = "p1", status = "done",
        values = { ownership_share = 50, rents = 20000, repairs = 2000, residential_finance_costs = 6000 } },
    { income_type_key = "rental", entity_uuid = "p2", status = "in_progress", values = { rents = 1000 } },
    { income_type_key = "salary", entity_uuid = "j1", status = "done",
        values = { pay = 40000, benefits = 1500, expenses = 200, tax_taken_off = 5500 } },
    { income_type_key = "other", status = "done", values = { amount = 900, expenses = 100 } },
    { income_type_key = "dividends", status = "not_applicable", values = { uk_dividends = 999 } },
    { income_type_key = "capital_gains", status = "done", values = { gains = 50000 } },
})
local i = est.inputs
check("ownership share halves the rent", near(i.property_rents, 10000 + 1000), i.property_rents)
check("share applies to expenses", near(i.property_expenses, 1000))
check("share applies to finance costs", near(i.property_finance_costs, 3000))
check("employment = pay + benefits", near(i.employment_income, 41500))
check("employment expenses + PAYE", near(i.employment_expenses, 200) and near(i.paye_deducted, 5500))
check("sign -1 nets other income's costs", near(i.other_income, 800))
check("not-applicable rows ignored", i.dividends == nil)
check("capital gains has no estimator input", i.capital_gains == nil)
check("property group supplied", est.groups.property == true and not est.groups.self_employment)
local at = table.concat(est.agent_types, ",")
check("agent types derived", at:find("uk_property") and at:find("employment") and at:find("other")
    and not at:find("capital_gains"), at)
check("has_data", est.has_data)
check("nothing → no data", not IncomeTypes.estimator_inputs(by_key, {}).has_data)

-- ============================================================================
print("compute_full: pension, other income, tax at source")
-- ============================================================================
local base = TaxCalc.compute_full({ employment_income = 20000 }, {})
local withp = TaxCalc.compute_full({ employment_income = 20000, pension_income = 5000 }, {})
check("pension income taxed at basic rate", near(withp.income_tax_due - base.income_tax_due, 1000))
check("pension income has no Class 4 NIC", withp.class4_nic == 0)
local paid = TaxCalc.compute_full({ employment_income = 20000, pension_income = 5000,
    tax_deducted_at_source = 1000 }, {})
check("tax taken off at source reduces the balance", near(withp.balancing_payment - paid.balancing_payment, 1000))
check("negative other income can't go below zero",
    near(TaxCalc.compute_full({ employment_income = 20000, other_income = -500 }, {}).income_tax_due,
        base.income_tax_due))

-- ============================================================================
print("estimate overlay (lib/agent/tax-tools)")
-- ============================================================================
local TaxTools = require("lib.agent.tax-tools")
local mi_prop = IncomeTypes.estimator_inputs(by_key, {
    { income_type_key = "rental", entity_uuid = "p1", status = "done",
        values = { rents = 18000, repairs = 3000, residential_finance_costs = 5000 } } })
-- A dashboard user who never chatted: profile defaults to self-employment.
local e1 = TaxTools.estimate(18000, 3000, "2025-26", { income_types = { "self_employment" }, _defaulted = true },
    { my_income = mi_prop })
check("defaulted profile takes types from My Income (property only, no NIC)", e1.nic_applied == false
    and near(e1.schedules.trading_profit, 0), cjson.encode(e1.schedules))
check("property profit from My Income", near(e1.schedules.property_profit, 15000))
-- 20% of the lowest of finance costs (5000), property profit (15000), income above PA (2430)
check("Section 24 credit from My Income finance costs", near(e1.finance_cost_reduction, 486), e1.finance_cost_reduction)

local mi_se = IncomeTypes.estimator_inputs(by_key, {
    { income_type_key = "self_employment", entity_uuid = "b1", status = "done",
        values = { turnover = 50000, expenses = 10000 } } })
local e2 = TaxTools.estimate(70000, 5000, "2025-26", { income_types = { "self_employment" } }, { my_income = mi_se })
check("My Income self-employment replaces the bank totals", near(e2.schedules.trading_profit, 40000))
check("…and says so", e2.notes and e2.notes[1]:find("My Income"))
check("Class 4 NIC on My Income trading profit", e2.class4_nic > 0 and e2.nic_applied)

local mi_sal = IncomeTypes.estimator_inputs(by_key, {
    { income_type_key = "salary", entity_uuid = "j1", status = "done",
        values = { pay = 30000, tax_taken_off = 3486 } } })
local e3 = TaxTools.estimate(0, 0, "2025-26", { income_types = { "self_employment" }, employment_income = 99999 },
    { my_income = mi_sal })
check("My Income employment overrides the chat figure", near(e3.schedules.employment, 30000))
check("PAYE credited", near(e3.paye_deducted, 3486))
local e4 = TaxTools.estimate(1000, 0, "2025-26", { income_types = { "self_employment" } },
    { my_income = IncomeTypes.estimator_inputs(by_key, {}) })
check("no My Income data → unchanged behaviour", near(e4.schedules.trading_profit, 0) and e4.my_income_inputs == nil)

-- ============================================================================
print("agent: income types from the table")
-- ============================================================================
local valid = { salary = true, rental = true, self_employment = true, interest = true, ns7_crypto = true }
local clean_t, bad = IncomeTypes.normalise_agent_types({ "uk_property", "employment", "rental", "ns7_crypto",
    "Self-Employment", "lottery" }, valid)
local ct = table.concat(clean_t, ",")
check("legacy keys still work", ct:find("uk_property") and ct:find("employment"), ct)
check("catalogue key maps to the agent key without duplicates", select(2, ct:gsub("uk_property", "")) == 1, ct)
check("a workspace's own type is accepted", ct:find("ns7_crypto"))
check("spelling normalised", ct:find("self_employment"))
check("unknown reported", bad[1] == "lottery")

-- set_tax_profile reads the namespace's catalogue from the DB.
responders = {
    { "FROM income_types", function(args)
        check("catalogue query is scoped to the namespace", args[1] == 7)
        return { { id = 1, income_type_key = "rental", display_name = "Rental", display_order = 1,
            is_active = true }, { id = 4, income_type_key = "ns7_crypto", display_name = "Crypto",
            display_order = 2, is_active = true, namespace_id = 7 } }
    end },
    { "FROM income_type_namespace_overrides", function() return {} end },
}
local ctx = { namespace_id = 7, user_id = 42, session_id = 99, tax_year = "2025-26",
    has_permission = function() return true end, _profile = {} }
local res, err = TaxTools.execute(ctx, "set_tax_profile", { income_types = { "ns7_crypto", "uk_property", "salary" } })
check("set_tax_profile accepts table-driven types", res and res.saved, err)
check("…keeps the legacy key and the custom one", res and table.concat(res.income_types, ","):find("ns7_crypto")
    and table.concat(res.income_types, ","):find("uk_property"))
check("…rejects a type this workspace doesn't have", res and res.ignored and res.ignored[1] == "salary")
local found_tool = false
for _, d in ipairs(TaxTools.definitions()) do
    if d["function"].name == "get_my_income" then found_tool = true end
end
check("get_my_income tool is registered", found_tool)
responders = {}
res = TaxTools.execute(ctx, "set_tax_profile", { income_types = { "employment" } })
check("no catalogue → falls back to the original keys", res and res.saved and res.income_types[1] == "employment")

-- ============================================================================
print("queries: tenant scoping")
-- ============================================================================
local Q = require("queries.TaxIncomeQueries")
local function last(pat)
    for k = #queries, 1, -1 do if queries[k].sql:find(pat, 1, true) then return queries[k] end end
end
queries = {}
Q.records(7, 42, "2025-26", "rental")
local q = last("FROM tax_income_records")
check("records scoped by namespace + user + year + type", q and q.sql:find("namespace_id = %?")
    and q.sql:find("user_id = %?") and q.args[1] == 7 and q.args[2] == 42 and q.args[3] == "2025-26")
Q.entities(7, 42, "property")
q = last("FROM user_profile_entities")
check("entities scoped by namespace + user + type, live only", q and q.args[1] == 7 and q.args[2] == 42
    and q.sql:find("is_archived = false"))
Q.entity(7, 42, "abc")
q = last("FROM user_profile_entities")
check("single entity lookup is ownership-checked", q and q.sql:find("namespace_id = %?") and q.sql:find("user_id = %?"))
Q.archive_entity(7, 42, "abc")
q = last("UPDATE user_profile_entities")
check("archive is ownership-checked and soft", q and q.sql:find("is_archived = true")
    and q.args[2] == 7 and q.args[3] == 42)
Q.upsert_record(7, 42, "2025-26", "rental", "p1", { rents = 1 }, {}, "done")
q = last("INSERT INTO tax_income_records")
check("upsert keyed on the slot index",
    q and q.sql:find("ON CONFLICT %(namespace_id, user_id, tax_year, income_type_key"))
check("upsert writes the caller's namespace + user", q and q.args[2] == 7 and q.args[3] == 42)
Q.types_for(7)
q = last("FROM income_types")
check("catalogue read = system rows + this namespace only",
    q and q.sql:find("COALESCE%(namespace_id, 0%) = 0 OR namespace_id = %?") and q.args[1] == 7)

-- workspace edit of a system type → override row, not the shared catalogue row
responders = {
    { "SELECT * FROM income_types WHERE income_type_key", function()
        return { { id = 1, income_type_key = "rental", namespace_id = NULL } }
    end },
}
queries = {}
Q.update_type(7, "rental", { display_name = "Buy-to-let" }, "namespace")
local wrote_shared = last("UPDATE income_types SET")
local wrote_override = last("UPDATE income_type_namespace_overrides SET")
check("workspace edit never updates the shared row", wrote_shared == nil)
check("workspace edit writes this namespace's override", wrote_override ~= nil
    and wrote_override.args[1] == 7 and wrote_override.sql:find("display_name"))
queries = {}
Q.update_type(7, "rental", { display_name = "Rental (all)" }, "global")
check("platform-default edit updates the shared row", last("UPDATE income_types SET") ~= nil)
responders = {}

-- diy-facing catalogue reads stay system-only
local ITQ = require("queries.IncomeTypeQueries")
queries = {}
ITQ.list_active()
q = last("FROM income_types")
check("diy dropdown excludes workspaces' own types", q and q.sql:find("COALESCE%(namespace_id, 0%) = 0"))
ITQ.manual_entry_keys()
q = last("FROM income_types")
check("diy validation excludes workspaces' own types", q and q.sql:find("COALESCE%(namespace_id, 0%) = 0"))

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
