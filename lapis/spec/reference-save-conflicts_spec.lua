--[[
    Pure helpers for reference-data save conflict detection / resolve gaps.

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

-- Mirror of pickPreferredRefRow ranking used in tax-admin-profiles.lua
local function pickPreferredRefRow(rows)
    if not rows or #rows == 0 then return nil end
    local best = rows[1]
    local function rank(row)
        local source = tostring(row.source_file or "")
        local test_boost = (source:sub(1, 11) == "admin-test-") and 1 or 0
        return test_boost, tostring(row.updated_at or ""), tonumber(row.id) or 0
    end
    local b1, b2, b3 = rank(best)
    for i = 2, #rows do
        local a1, a2, a3 = rank(rows[i])
        if a1 > b1 or (a1 == b1 and a2 > b2) or (a1 == b1 and a2 == b2 and a3 > b3) then
            best = rows[i]
            b1, b2, b3 = a1, a2, a3
        end
    end
    return best
end

-- Build the conflict payload fields the UI needs (upload vs existing).
local function buildConflictSides(upload_set, db_set, db_rows)
    local existing_payload = {}
    for _, row in ipairs(db_rows or {}) do
        table.insert(existing_payload, {
            category = row.category,
            source_file = row.source_file,
            description = row.description,
        })
    end
    return {
        categories = sortedKeys(unionCategories(upload_set, db_set)),
        upload_categories = sortedKeys(upload_set or {}),
        existing_categories = sortedKeys(db_set or {}),
        existing = existing_payload,
    }
end

-- Index rows by a provided cleanMerchant function (tests pass identity or stub).
local function indexByCleanedMerchant(rows, cleanMerchant)
    local by_merchant = {}
    for _, row in ipairs(rows or {}) do
        local keys = {}
        local d = cleanMerchant(row.description or "")
        local r = cleanMerchant(row.description_raw or "")
        if d ~= "" then keys[d] = true end
        if r ~= "" then keys[r] = true end
        for merchant, _ in pairs(keys) do
            if not by_merchant[merchant] then by_merchant[merchant] = {} end
            local seen = false
            for _, existing in ipairs(by_merchant[merchant]) do
                if existing.id == row.id then seen = true; break end
            end
            if not seen then
                table.insert(by_merchant[merchant], row)
            end
        end
    end
    return by_merchant
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

check("resolution with third category clears conflict",
    not isConflict(
        { office_supplies = true },
        { personal_expense = true },
        { category = "travel_expense" }
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

local sides = buildConflictSides(
    { office_supplies = true },
    { personal_expense = true },
    {
        { category = "personal_expense", source_file = "admin-upload-x", description = "TESCO" },
    }
)
check("conflict payload separates upload vs existing categories",
    sides.upload_categories[1] == "office_supplies"
        and sides.existing_categories[1] == "personal_expense"
        and #sides.existing == 1
        and sides.existing[1].category == "personal_expense")

local preferred = pickPreferredRefRow({
    { id = 1, source_file = "admin-upload-x", updated_at = "2026-01-02", category = "a" },
    { id = 2, source_file = "admin-test-1", updated_at = "2026-01-01", category = "b" },
    { id = 3, source_file = "admin-upload-x", updated_at = "2026-01-03", category = "c" },
})
check("preferred row prefers admin-test over newer csv",
    preferred and preferred.category == "b")

-- Legacy unclean description still indexes under cleaned merchant.
local function fakeClean(s)
    s = tostring(s or ""):upper()
    s = s:gsub(" CD %d+", "")
    s = s:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    return s
end
local indexed = indexByCleanedMerchant({
    { id = 10, description = "TESCO CD 1234", description_raw = "TESCO CD 1234", category = "personal_expense" },
    { id = 11, description = "TESCO", description_raw = "TESCO STORE", category = "office_supplies" },
}, fakeClean)
check("legacy unclean description joins cleaned merchant key",
    indexed["TESCO"] and #indexed["TESCO"] == 2,
    indexed["TESCO"] and tostring(#indexed["TESCO"]) or "nil")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all ok")
