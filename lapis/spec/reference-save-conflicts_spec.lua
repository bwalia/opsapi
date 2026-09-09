--[[
    Pure helpers for reference-data save conflict detection.

    Run from repo root:
        luajit lapis/spec/reference-save-conflicts_spec.lua
]]

local function setSize(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

local function sortedKeys(set)
    local keys = {}
    for k in pairs(set) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function unionCategories(upload_set, db_set)
    local union = {}
    for c, _ in pairs(upload_set or {}) do union[c] = true end
    for c, _ in pairs(db_set or {}) do union[c] = true end
    return union
end

local function isConflict(upload_set, db_set, resolution)
    if resolution and (resolution.skip == true or (resolution.category and resolution.category ~= "")) then
        return false
    end
    return setSize(unionCategories(upload_set, db_set)) > 1
end

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

print("reference-save-conflicts")

check("same category upload+db is not a conflict",
    not isConflict({ office_supplies = true }, { office_supplies = true }, nil))

check("different categories across upload+db is a conflict",
    isConflict({ office_supplies = true }, { personal_expense = true }, nil))

check("in-batch two categories is a conflict",
    isConflict({ office_supplies = true, personal_expense = true }, {}, nil))

check("resolution with category clears conflict",
    not isConflict(
        { office_supplies = true },
        { personal_expense = true },
        { category = "office_supplies" }
    ))

check("resolution with skip clears conflict",
    not isConflict(
        { office_supplies = true },
        { personal_expense = true },
        { skip = true }
    ))

local keys = sortedKeys({ b = true, a = true })
check("sortedKeys orders categories",
    keys[1] == "a" and keys[2] == "b",
    table.concat(keys, ","))

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all ok")
