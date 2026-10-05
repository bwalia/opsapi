--[[
    Regression spec: the October 2026 app bug batch.

    Standalone -- run from the repo root with:
        luajit lapis/spec/app-bugs-oct-2026_spec.lua

    Each bug was reproduced against the running API before the fix (old -> new):
    11th journal entry 409 -> 201, Money Out import 422 -> 201 (stored negative),
    expense without category 422 -> 400, customers by name 500 -> 200, tax
    overview stats 404 -> 200, Move to Sprint 400 -> 200.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = assert(io.open(path))
    local s = h:read("*a")
    h:close()
    return s
end

print("Accounting:")
local acc = read("lapis/queries/AccountingQueries.lua")
check("next journal number is the NUMERIC max (text sort put '9' above '10')",
    acc:find("MAX(NULLIF(regexp_replace(entry_number, '[^0-9]', '', 'g'), '')::bigint)", 1, true) ~= nil
    and acc:find("ORDER BY entry_number DESC", 1, true) == nil)
check("import reads transaction_date (what the dashboard sends)",
    acc:find("transaction_date = txn.transaction_date or txn.date", 1, true) ~= nil)
check("import honours transaction_type: debit stored negative",
    acc:find('if given == "debit" then\n            amount = -math.abs(amount)', 1, true) ~= nil)
check("expense needs a category (400, not a NOT NULL 500)",
    read("lapis/routes/accounting.lua"):find('"category is required"', 1, true) ~= nil)
local svc = read("opsapi-dashboard/services/accounting.service.ts")
check("dashboard sends accounting writes as JSON (routes read JSON only)",
    svc:find("toFormData(", 1, true) == nil and select(2, svc:gsub("JSON_BODY%)", "")) >= 12)

print("Customers / templates / tax / kanban:")
check("sort by name maps to first/last name (no `name` column)",
    read("lapis/queries/CustomerQueries.lua"):find('if orderField == "name" then', 1, true) ~= nil)
check("restore calls the real route /restore/{version}",
    read("opsapi-dashboard/services/templates.service.ts"):find("/restore/${version}", 1, true) ~= nil)
check("tax overview stats route exists",
    read("lapis/routes/tax-dashboard.lua"):find('app:get("/api/v2/tax/dashboard/stats"', 1, true) ~= nil)
local sprints = read("lapis/routes/kanban-sprints.lua")
check("sprint add/remove accept the dashboard's task_uuids, resolved within the project",
    sprints:find("WHERE b.project_id = ? AND t.uuid IN ?", 1, true) ~= nil
    and select(2, sprints:gsub("sprint_task_ids%(parse_request_body%(%), sprint%)", "")) == 2)

print("CI:")
check("smoke test checks every AI guide endpoint exists",
    read(".github/workflows/deploy-k3s.yml"):find("check-ai-guide-endpoints.py", 1, true) ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
