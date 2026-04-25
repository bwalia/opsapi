--[[
    Tax Admin Profiles Routes

    Admin CRUD for classification_profiles + CSV upload/parse/import.
    Profiles created here are stored in the DB and loaded by FastAPI's
    ProfileLoader (which checks DB first, filesystem second).

    CRUD /api/v2/tax/admin/profiles
    CSV  /api/v2/tax/admin/profiles/:uuid/upload-csv
         /api/v2/tax/admin/profiles/:uuid/save-transactions
         /api/v2/tax/admin/profiles/:uuid/suggest-rules
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")

local function isAdmin(user)
    if not user then return false end
    local roles = user.roles or ""
    if type(roles) == "string" then
        return roles:match("admin") ~= nil or roles:match("tax_admin") ~= nil
    end
    if type(roles) == "table" then
        for _, r in ipairs(roles) do
            local name = r.role_name or r
            if name == "administrative" or name == "tax_admin" then return true end
        end
    end
    local user_uuid = user.uuid or user.id
    local rows = db.query([[
        SELECT r.name FROM roles r
        JOIN user__roles ur ON ur.role_id = r.id
        JOIN users u ON u.id = ur.user_id
        WHERE u.uuid = ? AND r.name IN ('administrative', 'tax_admin')
        LIMIT 1
    ]], user_uuid)
    return rows and #rows > 0
end

-- ============================================================================
-- Category mapping (accountant label → system category)
-- Same as Python dedupe script's CATEGORY_MAP
-- ============================================================================
local CATEGORY_MAP = {
    ["purchase"] = { "purchases", "costOfGoods", true },
    ["cost of sales"] = { "cost_of_sales", "costOfGoods", true },
    ["cost of goods sold"] = { "cost_of_sales", "costOfGoods", true },
    ["materials - cost of sales"] = { "cost_of_sales", "costOfGoods", true },
    ["debtors"] = { "income_sales", "", false },
    ["split income"] = { "income_sales", "", false },
    ["refund"] = { "income_refund", "", false },
    ["tax account"] = { "transfer", "", false },
    ["credit card"] = { "transfer", "", false },
    ["creditors"] = { "transfer", "", false },
    ["split expense"] = { "transfer", "", false },
    ["amazon loans"] = { "loan_repayments", "", false },
    ["bounce back loan"] = { "loan_repayments", "", false },
    ["directors loan accounts"] = { "directors_loan_account", "", false },
    ["director's current account"] = { "directors_loan_account", "", false },
    ["director's current account 1"] = { "directors_loan_account", "", false },
    ["owners drawings"] = { "drawings", "", false },
    ["dividends"] = { "dividend_payments", "", false },
    ["corporation tax"] = { "tax_payments", "", false },
    ["paye and ni payable"] = { "employer_ni", "staffCosts", true },
    ["paye and ni"] = { "employer_ni", "staffCosts", true },
    ["wages control"] = { "salaries_wages", "staffCosts", true },
    ["wages"] = { "salaries_wages", "staffCosts", true },
    ["wages and salaries control"] = { "salaries_wages", "staffCosts", true },
    ["salaries"] = { "salaries_wages", "staffCosts", true },
    ["subcontracted services"] = { "subcontractors", "staffCosts", true },
    ["staff training and welfare"] = { "staff_welfare", "staffCosts", true },
    ["staff welfare"] = { "staff_welfare", "staffCosts", true },
    ["staff training"] = { "training_expense", "adminCosts", true },
    ["pensions"] = { "pension_expense", "staffCosts", true },
    ["travel expense"] = { "travel_expense", "travelCosts", true },
    ["travelling expenses"] = { "travel_expense", "travelCosts", true },
    ["motor expenses"] = { "travel_expense", "travelCosts", true },
    ["motor running expenses"] = { "travel_expense", "travelCosts", true },
    ["fuel"] = { "travel_expense", "travelCosts", true },
    ["parking"] = { "travel_expense", "travelCosts", true },
    ["auto"] = { "travel_expense", "travelCosts", true },
    ["accountancy"] = { "accountancy_fees", "professionalFees", true },
    ["legal and professional fees"] = { "legal_and_professional_fees", "professionalFees", true },
    ["legal & professional fees"] = { "legal_and_professional_fees", "professionalFees", true },
    ["professional fees"] = { "professional_fees", "professionalFees", true },
    ["software"] = { "software_subscriptions", "adminCosts", true },
    ["tools"] = { "software_subscriptions", "adminCosts", true },
    ["dues and subscriptions"] = { "dues_and_subscriptions", "adminCosts", true },
    ["subscriptions"] = { "dues_and_subscriptions", "adminCosts", true },
    ["telephone expense"] = { "telephone_expense", "adminCosts", true },
    ["telephone"] = { "telephone_expense", "adminCosts", true },
    ["printing and reproduction"] = { "printing_and_reproduction", "adminCosts", true },
    ["postage and delivery"] = { "shipping_and_delivery", "adminCosts", true },
    ["office expenses, repairs & maintenance"] = { "repair_and_maintenance", "maintenanceCosts", true },
    ["office/general administrative expenses"] = { "general_admin_expenses", "adminCosts", true },
    ["sundry"] = { "general_admin_expenses", "adminCosts", true },
    ["sundry expenses"] = { "general_admin_expenses", "adminCosts", true },
    ["equipment expensed"] = { "equipment_rental", "otherExpenses", true },
    ["insurance"] = { "insurance_expense", "otherExpenses", true },
    ["insurance expense"] = { "insurance_expense", "otherExpenses", true },
    ["bank charges"] = { "bank_charges", "otherExpenses", true },
    ["entertaining"] = { "meals_and_entertainment", "businessEntertainmentCosts", false },
    ["meals and entertainment"] = { "meals_and_entertainment", "businessEntertainmentCosts", false },
    ["charitable donations"] = { "charitable_contributions", "otherExpenses", false },
    ["charitable contributions"] = { "charitable_contributions", "otherExpenses", false },
}

-- ============================================================================
-- Helpers
-- ============================================================================

local function parseJSON(self)
    local ok, result = pcall(function()
        local body = ngx.req.read_body()
        local data = ngx.req.get_body_data()
        if not data or data == "" then return {} end
        return cjson.decode(data)
    end)
    return ok and result or {}
end

local function parseAmount(raw)
    if not raw or raw == "" then return nil end
    local cleaned = tostring(raw):gsub("[£,]", "")
    return tonumber(cleaned)
end

local function extractCategory(classification_text)
    if not classification_text or classification_text == "" then
        return nil, nil
    end
    local val = tostring(classification_text)
    for _, prefix in ipairs({
        "Credit Card Payment:", "Bill Payment:", "Tax Payment:",
        "Journal Entry:", "Expense:", "Payment:", "Transfer:", "Deposit:"
    }) do
        if val:find(prefix, 1, true) then
            local after = val:match(prefix .. "%s*(.+)")
            if after then
                local label = after:gsub("%d%d/%d%d/%d%d%d%d.*$", ""):gsub("£[%d,]+%.?%d*$", "")
                label = label:match("^%s*(.-)%s*$") or label
                return prefix:gsub(":%s*$", ""):match("^%s*(.-)%s*$"), label
            end
        end
    end
    return nil, nil
end

local function mapCategory(prefix, label, custom_mappings)
    if not prefix then return nil end
    local key = (label or ""):lower():match("^%s*(.-)%s*$") or ""

    if prefix == "Credit Card Payment" then return { "transfer", "", false } end
    if prefix == "Tax Payment" then return { "tax_payments", "", false } end
    if prefix == "Journal Entry" then
        if key:find("split income") then return { "income_sales", "", false } end
        return { "transfer", "", false }
    end
    if prefix == "Payment" and key == "debtors" then return { "income_sales", "", false } end
    if prefix == "Payment" and key == "creditors" then return { "transfer", "", false } end
    if prefix == "Deposit" then
        if key == "debtors" then return { "income_sales", "", false } end
        return { "income_refund", "", false }
    end

    -- Check per-profile custom mappings first
    if custom_mappings and custom_mappings[key] then
        local custom = custom_mappings[key]
        return { custom, "otherExpenses", true }
    end

    -- Global map
    if CATEGORY_MAP[key] then return CATEGORY_MAP[key] end

    -- Fuzzy substring
    for substr, result in pairs(CATEGORY_MAP) do
        if key:find(substr, 1, true) or substr:find(key, 1, true) then
            return result
        end
    end

    -- Prefix fallbacks
    if prefix == "Bill Payment" or prefix == "Transfer" or prefix == "Payment" then
        return { "transfer", "", false }
    end
    if prefix == "Expense" then return nil end -- unmapped expense → admin must pick

    return nil
end

-- Merchant name cleaning (matches Python clean_merchant_name)
local function cleanMerchant(desc)
    if not desc or desc == "" then return "" end
    local text = desc:match("^%s*(.-)%s*$") or desc
    text = text:gsub("^TRANSFER%s+VIA%s+FASTER%s+PAYMENT%s+TO%s+", "")
    text = text:gsub("^[VIS|BP|DD|SO|CR|FPI|BGC|FPO|TFR|DR|STO|DEB]+%s+", "")
    text = text:gsub("%*[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]+", "")
    text = text:gsub("%*", " ")
    text = text:gsub("%s+CD%s+%d%d%d%d", "")
    text = text:gsub("%d%d/%d%d/?%d*", "")
    text = text:gsub("%d%d[A-Z][A-Z][A-Z]%d%d%d?%d?", "")
    text = text:gsub("%s+L%s+REF.*$", "")
    text = text:gsub("%s*REF%s*[:;]?%s*.*$", "")
    text = text:gsub("%s*MANDATE%s+NO%s*[:;]?%s*%w+.*$", "")
    text = text:gsub("%s+%d%d%d%d%d%d%d+%s*$", "")
    text = text:gsub("%s+LTD%s*%.?%s*$", "")
    text = text:gsub("%s+PLC%s*%.?%s*$", "")
    text = text:gsub("%s+LIMITED%s*%.?%s*$", "")
    text = text:gsub("%s*,%s*$", "")
    text = text:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    return text:upper()
end

local function amountBand(amount)
    if amount < 50 then return "small"
    elseif amount < 200 then return "medium"
    else return "large" end
end

return function(app)

    -- ========================================
    -- LIST profiles
    -- ========================================
    app:get("/api/v2/tax/admin/profiles",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local rows = db.query([[
                SELECT cp.*,
                    (SELECT COUNT(*) FROM classification_reference_data
                     WHERE client_business_type = cp.profile_key) as reference_count
                FROM classification_profiles cp
                WHERE cp.is_active = true
                ORDER BY cp.display_name
            ]])

            return { status = 200, json = { data = rows or {}, total = #(rows or {}) } }
        end)
    )

    -- ========================================
    -- GET single profile
    -- ========================================
    app:get("/api/v2/tax/admin/profiles/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local rows = db.query([[
                SELECT cp.*,
                    (SELECT COUNT(*) FROM classification_reference_data
                     WHERE client_business_type = cp.profile_key) as reference_count
                FROM classification_profiles cp
                WHERE cp.uuid = ? AND cp.is_active = true
                LIMIT 1
            ]], self.params.uuid)

            if not rows or #rows == 0 then
                return { status = 404, json = { error = "Profile not found" } }
            end

            return { status = 200, json = { data = rows[1] } }
        end)
    )

    -- ========================================
    -- CREATE profile
    -- ========================================
    app:post("/api/v2/tax/admin/profiles",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local body = parseJSON(self)
            if not body.profile_key or not body.display_name then
                return { status = 400, json = { error = "profile_key and display_name are required" } }
            end

            -- Check uniqueness
            local existing = db.query("SELECT id FROM classification_profiles WHERE profile_key = ?", body.profile_key)
            if existing and #existing > 0 then
                return { status = 409, json = { error = "Profile key already exists" } }
            end

            local uuid = require("helper.global").generateStaticUUID()
            db.query([[
                INSERT INTO classification_profiles
                    (uuid, profile_key, display_name, industry, user_profile_type,
                     category_affinity, personal_indicators, excluded_categories,
                     rules_markdown, keyword_rules, category_mappings,
                     is_active, namespace_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?,
                        ?::jsonb, ?::jsonb, ?::jsonb,
                        ?, ?::jsonb, ?::jsonb,
                        true, 0, NOW(), NOW())
            ]],
                uuid,
                body.profile_key,
                body.display_name,
                body.industry or db.NULL,
                body.user_profile_type or "limited_company",
                cjson.encode(body.category_affinity or {}),
                cjson.encode(body.personal_indicators or {}),
                cjson.encode(body.excluded_categories or {}),
                body.rules_markdown or db.NULL,
                cjson.encode(body.keyword_rules or {}),
                cjson.encode(body.category_mappings or {})
            )

            local created = db.query("SELECT * FROM classification_profiles WHERE uuid = ?", uuid)
            return { status = 201, json = { data = created and created[1] or {} } }
        end)
    )

    -- ========================================
    -- UPDATE profile
    -- ========================================
    app:put("/api/v2/tax/admin/profiles/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local body = parseJSON(self)
            local existing = db.query("SELECT id FROM classification_profiles WHERE uuid = ?", self.params.uuid)
            if not existing or #existing == 0 then
                return { status = 404, json = { error = "Profile not found" } }
            end

            local sets = {}
            local vals = {}
            local function add(col, val, is_json)
                if val ~= nil then
                    if is_json then
                        table.insert(sets, col .. " = " .. db.interpolate_query("?::jsonb", cjson.encode(val)))
                    else
                        table.insert(sets, col .. " = " .. db.interpolate_query("?", val))
                    end
                end
            end

            add("display_name", body.display_name)
            add("industry", body.industry)
            add("user_profile_type", body.user_profile_type)
            add("category_affinity", body.category_affinity, true)
            add("personal_indicators", body.personal_indicators, true)
            add("excluded_categories", body.excluded_categories, true)
            add("rules_markdown", body.rules_markdown)
            add("keyword_rules", body.keyword_rules, true)
            add("category_mappings", body.category_mappings, true)
            table.insert(sets, "updated_at = NOW()")

            if #sets > 0 then
                db.query("UPDATE classification_profiles SET " .. table.concat(sets, ", ") ..
                    " WHERE uuid = ?", self.params.uuid)
            end

            local updated = db.query("SELECT * FROM classification_profiles WHERE uuid = ?", self.params.uuid)
            return { status = 200, json = { data = updated and updated[1] or {} } }
        end)
    )

    -- ========================================
    -- DELETE profile (soft delete)
    -- ========================================
    app:delete("/api/v2/tax/admin/profiles/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local existing = db.query("SELECT id, profile_key FROM classification_profiles WHERE uuid = ?", self.params.uuid)
            if not existing or #existing == 0 then
                return { status = 404, json = { error = "Profile not found" } }
            end

            db.query("UPDATE classification_profiles SET is_active = false, updated_at = NOW() WHERE uuid = ?",
                self.params.uuid)

            return { status = 200, json = { message = "Profile deactivated" } }
        end)
    )

    -- ========================================
    -- UPLOAD CSV — parse + map categories
    -- ========================================
    app:post("/api/v2/tax/admin/profiles/:uuid/upload-csv",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local profile = db.query("SELECT * FROM classification_profiles WHERE uuid = ? AND is_active = true",
                self.params.uuid)
            if not profile or #profile == 0 then
                return { status = 404, json = { error = "Profile not found" } }
            end
            profile = profile[1]

            local body = parseJSON(self)
            local csv_content = body.csv_content
            if not csv_content or csv_content == "" then
                return { status = 400, json = { error = "csv_content is required" } }
            end

            -- Parse custom mappings from profile
            local custom_mappings = {}
            if profile.category_mappings then
                local ok, decoded = pcall(cjson.decode, profile.category_mappings)
                if ok and type(decoded) == "table" then
                    custom_mappings = decoded
                end
            end

            -- Parse CSV lines
            local lines = {}
            for line in csv_content:gmatch("[^\r\n]+") do
                table.insert(lines, line)
            end

            if #lines < 2 then
                return { status = 400, json = { error = "CSV must have a header row + at least 1 data row" } }
            end

            -- Parse header to detect format
            local header = lines[1]:lower()
            local is_natwest = header:find("spent") ~= nil
            local is_lloyds = header:find("amount") ~= nil

            if not is_natwest and not is_lloyds then
                return { status = 400, json = {
                    error = "Unrecognized CSV format. Expected Lloyds (DATE, DESCRIPTION, AMOUNT, ...) or NatWest (date, Bank description, Spent, Received, ...)",
                    accepted_formats = {
                        { name = "Lloyds", columns = "DATE, DESCRIPTION, AMOUNT, Payee, ADDED OR MATCHED, Rule" },
                        { name = "NatWest", columns = "date, Bank description, Spent, Received, From/To, Transaction Posted" },
                    }
                } }
            end

            -- Simple CSV field parser (handles quoted fields with commas)
            local function parseCSVLine(line)
                local fields = {}
                local pos = 1
                while pos <= #line do
                    if line:sub(pos, pos) == '"' then
                        local closing = line:find('"', pos + 1)
                        while closing and line:sub(closing + 1, closing + 1) == '"' do
                            closing = line:find('"', closing + 2)
                        end
                        if closing then
                            table.insert(fields, line:sub(pos + 1, closing - 1):gsub('""', '"'))
                            pos = closing + 2 -- skip closing quote + comma
                        else
                            table.insert(fields, line:sub(pos + 1))
                            break
                        end
                    else
                        local next_comma = line:find(",", pos)
                        if next_comma then
                            table.insert(fields, line:sub(pos, next_comma - 1))
                            pos = next_comma + 1
                        else
                            table.insert(fields, line:sub(pos))
                            break
                        end
                    end
                end
                return fields
            end

            local mapped = {}
            local unmapped = {}
            local skipped = 0

            for i = 2, #lines do
                local fields = parseCSVLine(lines[i])
                if #fields < 3 then
                    skipped = skipped + 1
                    goto continue
                end

                local date_raw, desc_raw, amount, classification_text

                if is_natwest then
                    -- NatWest: date, Bank description, Spent, Received, From/To, Transaction Posted
                    date_raw = fields[1]
                    desc_raw = fields[2]
                    local spent = parseAmount(fields[3])
                    local received = parseAmount(fields[4])
                    if (not spent or spent == 0) and (not received or received == 0) then
                        skipped = skipped + 1
                        goto continue
                    end
                    amount = (received and received > 0) and received or -(spent or 0)
                    classification_text = fields[6] or fields[5] -- Transaction Posted or From/To
                else
                    -- Lloyds: DATE, DESCRIPTION, AMOUNT, Payee, ADDED OR MATCHED, Rule
                    date_raw = fields[1]
                    desc_raw = fields[2]
                    amount = parseAmount(fields[3])
                    classification_text = fields[5]
                end

                if not desc_raw or desc_raw == "" or not amount then
                    skipped = skipped + 1
                    goto continue
                end

                local prefix, label = extractCategory(classification_text)
                local mapping = mapCategory(prefix, label, custom_mappings)
                local cleaned = cleanMerchant(desc_raw)
                local is_credit = amount > 0
                local tx_type = is_credit and "CREDIT" or "DEBIT"

                local row = {
                    description = cleaned,
                    description_raw = desc_raw,
                    amount = math.abs(amount),
                    transaction_type = tx_type,
                    transaction_date = date_raw or "",
                    original_label = label or "",
                    row_index = i,
                }

                if mapping then
                    row.category = mapping[1]
                    row.hmrc_category = mapping[2]
                    row.is_tax_deductible = mapping[3]
                    row.auto_mapped = true
                    table.insert(mapped, row)
                elseif prefix == "Expense" then
                    row.auto_mapped = false
                    table.insert(unmapped, row)
                else
                    skipped = skipped + 1
                end

                ::continue::
            end

            return {
                status = 200,
                json = {
                    format_detected = is_natwest and "NatWest" or "Lloyds",
                    total_rows = #lines - 1,
                    parsed_count = #mapped + #unmapped,
                    mapped_count = #mapped,
                    unmapped_count = #unmapped,
                    skipped_count = skipped,
                    mapped = mapped,
                    unmapped = unmapped,
                }
            }
        end)
    )

    -- ========================================
    -- SAVE TRANSACTIONS — dedup + insert
    -- ========================================
    app:post("/api/v2/tax/admin/profiles/:uuid/save-transactions",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local profile = db.query("SELECT * FROM classification_profiles WHERE uuid = ? AND is_active = true",
                self.params.uuid)
            if not profile or #profile == 0 then
                return { status = 404, json = { error = "Profile not found" } }
            end
            profile = profile[1]

            local body = parseJSON(self)
            local transactions = body.transactions
            if not transactions or #transactions == 0 then
                return { status = 400, json = { error = "transactions array is required" } }
            end

            -- Save any new custom mappings
            if body.new_mappings and type(body.new_mappings) == "table" then
                local existing_mappings = {}
                if profile.category_mappings then
                    local ok, decoded = pcall(cjson.decode, profile.category_mappings)
                    if ok then existing_mappings = decoded end
                end
                for k, v in pairs(body.new_mappings) do
                    existing_mappings[k:lower()] = v
                end
                db.query("UPDATE classification_profiles SET category_mappings = ?::jsonb, updated_at = NOW() WHERE uuid = ?",
                    cjson.encode(existing_mappings), self.params.uuid)
            end

            -- Amount-banded dedup
            local seen = {}
            local deduped = {}
            for _, tx in ipairs(transactions) do
                local desc = (tx.description or ""):lower():match("^%s*(.-)%s*$") or ""
                local key = desc .. "|" .. (tx.category or "") .. "|" ..
                    (tx.transaction_type or "") .. "|" .. amountBand(tx.amount or 0) .. "|" ..
                    profile.profile_key
                if not seen[key] then
                    seen[key] = true
                    table.insert(deduped, tx)
                end
            end

            -- Insert into classification_reference_data
            local inserted = 0
            local Global = require("helper.global")
            for _, tx in ipairs(deduped) do
                local ok, err = pcall(function()
                    db.query([[
                        INSERT INTO classification_reference_data
                            (uuid, description, description_raw, amount, transaction_type,
                             transaction_date, category, hmrc_category, confidence,
                             is_tax_deductible, reasoning, original_label,
                             client_business_type, user_profile_type, industry,
                             source_file, row_index, namespace_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?,
                                ?, ?, ?, 1.0000,
                                ?, ?, ?,
                                ?, ?, ?,
                                ?, ?, 0, NOW(), NOW())
                        ON CONFLICT (source_file, row_index) DO NOTHING
                    ]],
                        Global.generateStaticUUID(),
                        tx.description or "",
                        tx.description_raw or "",
                        tx.amount or 0,
                        tx.transaction_type or "DEBIT",
                        tx.transaction_date or "",
                        tx.category or "uncategorised_expense",
                        tx.hmrc_category or "otherExpenses",
                        tx.is_tax_deductible ~= false,
                        "Accountant classified as '" .. (tx.original_label or "") .. "' for " .. (profile.industry or "business"),
                        tx.original_label or "",
                        profile.profile_key,
                        profile.user_profile_type or "limited_company",
                        profile.industry or "",
                        "admin-upload-" .. profile.profile_key,
                        tx.row_index or 0
                    )
                    inserted = inserted + 1
                end)
                if not ok then
                    ngx.log(ngx.WARN, "Failed to insert reference row: " .. tostring(err))
                end
            end

            return {
                status = 200,
                json = {
                    inserted = inserted,
                    deduped_from = #transactions,
                    deduped_to = #deduped,
                    duplicates_removed = #transactions - #deduped,
                }
            }
        end)
    )

    -- ========================================
    -- SUGGEST RULES — from reference data
    -- ========================================
    app:post("/api/v2/tax/admin/profiles/:uuid/suggest-rules",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local profile = db.query("SELECT * FROM classification_profiles WHERE uuid = ? AND is_active = true",
                self.params.uuid)
            if not profile or #profile == 0 then
                return { status = 404, json = { error = "Profile not found" } }
            end
            profile = profile[1]

            -- Find frequently occurring (description, category) pairs
            local rows = db.query([[
                SELECT description, category, COUNT(*) as cnt
                FROM classification_reference_data
                WHERE client_business_type = ?
                  AND description != ''
                GROUP BY description, category
                HAVING COUNT(*) >= 2
                ORDER BY cnt DESC
                LIMIT 50
            ]], profile.profile_key)

            local suggestions = {}
            for _, row in ipairs(rows or {}) do
                table.insert(suggestions, {
                    keyword = row.description,
                    category = row.category,
                    count = tonumber(row.cnt),
                    reason = "Appeared " .. row.cnt .. "x in accountant data",
                })
            end

            return { status = 200, json = { suggestions = suggestions, total = #suggestions } }
        end)
    )

    -- ========================================
    -- LIST reference transactions for profile
    -- ========================================
    app:get("/api/v2/tax/admin/profiles/:uuid/transactions",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local profile = db.query("SELECT profile_key FROM classification_profiles WHERE uuid = ?",
                self.params.uuid)
            if not profile or #profile == 0 then
                return { status = 404, json = { error = "Profile not found" } }
            end

            local page = tonumber(self.params.page) or 1
            local limit = math.min(tonumber(self.params.limit) or 50, 200)
            local offset = (page - 1) * limit

            local rows = db.query([[
                SELECT description, description_raw, amount, transaction_type,
                       category, hmrc_category, original_label, source_file, row_index
                FROM classification_reference_data
                WHERE client_business_type = ?
                ORDER BY source_file, row_index
                LIMIT ? OFFSET ?
            ]], profile[1].profile_key, limit, offset)

            local count = db.query([[
                SELECT COUNT(*) as cnt FROM classification_reference_data
                WHERE client_business_type = ?
            ]], profile[1].profile_key)

            return {
                status = 200,
                json = {
                    data = rows or {},
                    total = count and count[1] and tonumber(count[1].cnt) or 0,
                    page = page,
                    limit = limit,
                }
            }
        end)
    )

    -- ========================================
    -- CLEAR reference data for profile
    -- ========================================
    app:delete("/api/v2/tax/admin/profiles/:uuid/transactions",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local profile = db.query("SELECT profile_key FROM classification_profiles WHERE uuid = ?",
                self.params.uuid)
            if not profile or #profile == 0 then
                return { status = 404, json = { error = "Profile not found" } }
            end

            local result = db.query([[
                DELETE FROM classification_reference_data
                WHERE client_business_type = ?
            ]], profile[1].profile_key)

            return { status = 200, json = { message = "Reference data cleared", profile_key = profile[1].profile_key } }
        end)
    )

end
