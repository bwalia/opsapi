--[[
    Spec: landlord residential finance costs (Section 24) in the tax agent.

    Guards:
      * set_property_finance_costs saves the figure by MERGING into the session
        profile (jsonb ||), never overwriting income types etc.;
      * set_tax_profile merges too (so it can't wipe the finance costs), and clears
        year-specific figures when the tax year changes;
      * the estimate turns residential interest into the 20% tax reduction — and
        takes it back out of expenses if the bank data already deducted it;
      * self-employed + property only gets the credit when the rental figures are
        given separately (no invented split).

    Standalone (no DB): lapis.db and resty.http are stubbed; needs cjson, so run
    it in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/tax-agent-finance-costs_spec.lua
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
local year_row = { gross_income = 0, total_expenses = 0, finance_interest = 0, unreviewed = 0 }
local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
package.loaded["lapis.db"] = {
    NULL = NULL,
    query = function(sql, ...)
        queries[#queries + 1] = { sql = sql, args = { ... } }
        if sql:find("FROM tax_rates") then return {} end -- -> 2025-26 fallback rates
        if sql:find("AS gross_income") then return { year_row } end
        return { affected_rows = 1 }
    end,
}
package.loaded["resty.http"] = { new = function() error("no http in spec") end }

local TaxTools = require("lib.agent.tax-tools")

local function ctx(profile, year)
    return {
        namespace_id = 7, user_id = 42, session_id = 99, tax_year = year or "2025-26",
        has_permission = function() return true end,
        _profile = profile,
    }
end
local function last_update()
    for i = #queries, 1, -1 do
        if queries[i].sql:find("UPDATE tax_agent_sessions") then return queries[i] end
    end
end

print("tax agent: property finance costs")

-- merge_profile is a pure shallow merge.
local merged = TaxTools.merge_profile({ income_types = { "uk_property" }, tax_year = "2025-26" },
    { property_finance_costs = 512400 })
check("merge keeps income_types", merged.income_types and merged.income_types[1] == "uk_property")
check("merge adds the new key", merged.property_finance_costs == 512400)

-- The tool is offered to the model with an interest-not-capital description.
local def
for _, d in ipairs(TaxTools.definitions()) do
    if d["function"].name == "set_property_finance_costs" then def = d["function"] end
end
check("tool is registered", def ~= nil)
check("description asks for INTEREST, not capital", def and def.description:find("INTEREST")
    and def.description:find("capital"))
check("residential_finance_costs is required", def and def.parameters.required[1] == "residential_finance_costs")

-- Saving finance costs merges, scoped to the caller's session.
local c = ctx({ income_types = { "uk_property" }, tax_year = "2025-26", is_scottish_taxpayer = false })
local res, err = TaxTools.execute(c, "set_property_finance_costs", { residential_finance_costs = 512400 })
check("set_property_finance_costs succeeds", res and res.saved, err)
local q = last_update()
check("UPDATE merges with jsonb ||", q and q.sql:find("COALESCE%(profile, '{}'::jsonb%) || %?::jsonb"))
check("UPDATE does not overwrite the whole profile", q and not q.sql:find("profile = %?::jsonb"))
check("UPDATE is scoped to session + namespace + user",
    q and q.args[4] == 99 and q.args[5] == 7 and q.args[6] == 42)
local patch = q and cjson.decode(q.args[1]) or {}
check("patch carries only the new figure", patch.property_finance_costs == 512400 and patch.income_types == nil)
check("income_types column left alone (NULL -> COALESCE)", q and q.args[2] == NULL)
check("in-turn profile keeps income types", c._profile.income_types[1] == "uk_property")
check("in-turn profile has the finance costs", c._profile.property_finance_costs == 512400)

local _, bad = TaxTools.execute(c, "set_property_finance_costs", { residential_finance_costs = -5 })
check("negative finance costs rejected", bad ~= nil)

-- set_tax_profile (same year) merges and keeps the finance costs.
local r2 = TaxTools.execute(c, "set_tax_profile", { income_types = { "uk_property" }, tax_year = "2025-26" })
check("set_tax_profile saved", r2 and r2.saved)
local q2 = last_update()
local p2 = cjson.decode(q2.args[1])
check("set_tax_profile patch has no finance-cost key (same year)", p2.property_finance_costs == nil)
check("set_tax_profile uses jsonb ||", q2.sql:find("|| %?::jsonb") ~= nil)
check("finance costs survive set_tax_profile", c._profile.property_finance_costs == 512400)

-- Switching tax year clears the year-specific figures.
local c3 = ctx({ income_types = { "uk_property" }, property_finance_costs = 9000 }, "2025-26")
TaxTools.execute(c3, "set_tax_profile", { income_types = { "uk_property" }, tax_year = "2024-25" })
local p3 = cjson.decode(last_update().args[1])
check("year switch nulls property_finance_costs in the patch", p3.property_finance_costs == cjson.null)
check("year switch: in-turn figure no longer counts", tonumber(c3._profile.property_finance_costs) == nil)
check("year switch updates ctx.tax_year", c3.tax_year == "2024-25")

-- Estimate: property only. Rents 1,698,949, allowable expenses 250,000, interest 512,400.
local land = { income_types = { "uk_property" } }
local before = TaxTools.estimate(1698949, 250000, "2025-26", land)
check("before: no reduction", near(before.finance_cost_reduction, 0))
check("before: income tax", near(before.income_tax_due, 638230.05), before.income_tax_due)
land.property_finance_costs = 512400
local after = TaxTools.estimate(1698949, 250000, "2025-26", land)
check("after: reduction = 20% x 512,400", near(after.finance_cost_reduction, 102480), after.finance_cost_reduction)
check("after: income tax", near(after.income_tax_due, 535750.05), after.income_tax_due)
check("after: total due drops by the reduction",
    near(before.total_tax_due - after.total_tax_due, 102480))
check("no NIC on property", after.nic_applied == false and near(after.class4_nic, 0))

-- Interest the classifier already deducted is moved out (not deducted AND credited).
local dbl = TaxTools.estimate(1698949, 762400, "2025-26", land, { finance_interest = 600000 })
check("classified interest moved out of expenses", near(dbl.finance_costs_moved_from_expenses, 512400))
check("allowable expenses exclude residential interest", near(dbl.total_expenses, 250000))
check("same tax as when it was never deducted", near(dbl.income_tax_due, 535750.05), dbl.income_tax_due)

-- compute_estimate in the same turn sees the figure saved by the tool.
year_row = { gross_income = 1698949, total_expenses = 250000, finance_interest = 0, unreviewed = 0 }
local c4 = ctx({ income_types = { "uk_property" } })
TaxTools.execute(c4, "set_property_finance_costs", { residential_finance_costs = 512400 })
local est = TaxTools.execute(c4, "compute_estimate", {})
check("compute_estimate (same turn) applies the reduction", est and near(est.finance_cost_reduction, 102480))

-- Self-employed + landlord: no split given -> no credit, and a note says why.
local mixed = TaxTools.estimate(100000, 20000, "2025-26",
    { income_types = { "self_employment", "uk_property" }, property_finance_costs = 9000 })
check("mixed without split: no reduction", near(mixed.finance_cost_reduction, 0))
check("mixed without split: explains why", mixed.notes and mixed.notes[1]
    and mixed.notes[1]:find("rental income") ~= nil)
-- ...with the rental figures stated, the bank totals are split and the credit applies.
local split = TaxTools.estimate(100000, 20000, "2025-26", { income_types = { "self_employment", "uk_property" },
    property_finance_costs = 9000, property_rents = 30000, property_expenses = 5000 })
check("mixed with split: reduction", near(split.finance_cost_reduction, 1800), split.finance_cost_reduction)
check("mixed with split: trading profit is the remainder", near(split.schedules.trading_profit, 55000))
check("mixed with split: property profit", near(split.schedules.property_profit, 25000))

print(failures == 0 and "all passed" or (failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
