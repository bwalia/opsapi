--[[
    Tax Admin Transactions Routes

    Admin-only endpoints for managing and viewing all user transactions
    with full server-side filtering, pagination, and aggregate stats.

    All endpoints require admin role (administrative or tax_admin).
]]

local db = require("lapis.db")

local function isAdmin(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query([[
        SELECT r.role_name
        FROM user__roles ur
        JOIN roles r ON ur.role_id = r.id
        JOIN users u ON ur.user_id = u.id
        WHERE u.uuid = ?
        LIMIT 1
    ]], user_uuid)
    if rows and #rows > 0 then
        local role = rows[1].role_name
        return role == "administrative" or role == "tax_admin"
    end
    return false
end

-- Whitelist of columns allowed for sorting
local ALLOWED_SORT_COLUMNS = {
    transaction_date = "t.transaction_date",
    amount = "t.amount",
    description = "t.description",
    category = "t.category",
    hmrc_category = "t.hmrc_category",
    transaction_type = "t.transaction_type",
    confirmation_status = "t.confirmation_status",
    classification_status = "t.classification_status",
    confidence_score = "t.confidence_score",
    created_at = "t.created_at",
    user_email = "u.email",
    bank_name = "ba.bank_name",
}

--- Clamp a numeric value between min and max.
local function clamp(val, min_val, max_val)
    if val < min_val then return min_val end
    if val > max_val then return max_val end
    return val
end

--- Build WHERE conditions and parameter values from request params.
-- Returns conditions (table of SQL fragments) and values (table of bind params).
local function build_filters(params)
    local conditions = {}
    local values = {}

    -- User search: name or email
    if params.user_search and params.user_search ~= "" then
        local search_term = "%" .. params.user_search .. "%"
        table.insert(conditions,
            "(CONCAT(u.first_name, ' ', u.last_name) ILIKE ? OR u.email ILIKE ?)")
        table.insert(values, search_term)
        table.insert(values, search_term)
    end

    -- Description search
    if params.description and params.description ~= "" then
        table.insert(conditions, "t.description ILIKE ?")
        table.insert(values, "%" .. params.description .. "%")
    end

    -- Transaction type
    if params.transaction_type and params.transaction_type ~= "" then
        local tt = params.transaction_type:upper()
        if tt == "DEBIT" or tt == "CREDIT" then
            table.insert(conditions, "t.transaction_type = ?")
            table.insert(values, tt)
        end
    end

    -- Category
    if params.category and params.category ~= "" then
        table.insert(conditions, "t.category = ?")
        table.insert(values, params.category)
    end

    -- HMRC category
    if params.hmrc_category and params.hmrc_category ~= "" then
        table.insert(conditions, "t.hmrc_category = ?")
        table.insert(values, params.hmrc_category)
    end

    -- Amount range (absolute value)
    if params.amount_min and params.amount_min ~= "" then
        local val = tonumber(params.amount_min)
        if val then
            table.insert(conditions, "ABS(t.amount) >= ?")
            table.insert(values, val)
        end
    end
    if params.amount_max and params.amount_max ~= "" then
        local val = tonumber(params.amount_max)
        if val then
            table.insert(conditions, "ABS(t.amount) <= ?")
            table.insert(values, val)
        end
    end

    -- Date range
    if params.date_from and params.date_from ~= "" then
        if params.date_from:match("^%d%d%d%d%-%d%d%-%d%d$") then
            table.insert(conditions, "t.transaction_date >= ?")
            table.insert(values, params.date_from)
        end
    end
    if params.date_to and params.date_to ~= "" then
        if params.date_to:match("^%d%d%d%d%-%d%d%-%d%d$") then
            table.insert(conditions, "t.transaction_date <= ?")
            table.insert(values, params.date_to)
        end
    end

    -- Confirmation status
    if params.confirmation_status and params.confirmation_status ~= "" then
        local cs = params.confirmation_status:upper()
        if cs == "PENDING" or cs == "CONFIRMED" or cs == "REJECTED" then
            table.insert(conditions, "t.confirmation_status = ?")
            table.insert(values, cs)
        end
    end

    -- Classification status
    if params.classification_status and params.classification_status ~= "" then
        local cs = params.classification_status:upper()
        if cs == "PENDING" or cs == "CONFIRMED" or cs == "REJECTED" then
            table.insert(conditions, "t.classification_status = ?")
            table.insert(values, cs)
        end
    end

    -- Tax deductible
    if params.is_tax_deductible and params.is_tax_deductible ~= "" then
        local val = params.is_tax_deductible:lower()
        if val == "true" then
            table.insert(conditions, "t.is_tax_deductible = TRUE")
        elseif val == "false" then
            table.insert(conditions, "t.is_tax_deductible = FALSE")
        end
    end

    -- Statement ID
    if params.statement_id and params.statement_id ~= "" then
        local val = tonumber(params.statement_id)
        if val then
            table.insert(conditions, "t.statement_id = ?")
            table.insert(values, val)
        end
    end

    -- User ID (internal)
    if params.user_id and params.user_id ~= "" then
        local val = tonumber(params.user_id)
        if val then
            table.insert(conditions, "t.user_id = ?")
            table.insert(values, val)
        end
    end

    return conditions, values
end

--- Build the base FROM/JOIN clause used by list and count queries.
local function base_from()
    return [[
        FROM tax_transactions t
        LEFT JOIN users u ON t.user_id = u.id
        LEFT JOIN tax_statements s ON t.statement_id = s.id
        LEFT JOIN tax_bank_accounts ba ON t.bank_account_id = ba.id
    ]]
end

--- Collect filters_applied summary for the response.
local function filters_applied(params)
    local applied = {}
    local check_fields = {
        "user_search", "description", "transaction_type", "category",
        "hmrc_category", "amount_min", "amount_max", "date_from", "date_to",
        "confirmation_status", "classification_status", "is_tax_deductible",
        "statement_id", "user_id",
    }
    for _, field in ipairs(check_fields) do
        if params[field] and params[field] ~= "" then
            applied[field] = params[field]
        end
    end
    return applied
end

return function(app)

    -- =========================================================================
    -- GET /api/v2/tax/admin/transactions
    -- Returns paginated transactions with full server-side filtering
    -- Admin only
    -- =========================================================================
    app:get("/api/v2/tax/admin/transactions", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end
        if not isAdmin(user) then
            return { status = 403, json = { error = "Admin access required" } }
        end

        -- Pagination
        local page = math.max(tonumber(self.params.page) or 1, 1)
        local limit = clamp(tonumber(self.params.limit) or 25, 1, 100)
        local offset = (page - 1) * limit

        -- Sorting
        local sort_by = "transaction_date"
        if self.params.sort_by and ALLOWED_SORT_COLUMNS[self.params.sort_by] then
            sort_by = self.params.sort_by
        end
        local sort_column = ALLOWED_SORT_COLUMNS[sort_by] or "t.transaction_date"

        local sort_order = "DESC"
        if self.params.sort_order and self.params.sort_order:upper() == "ASC" then
            sort_order = "ASC"
        end

        -- Build filters
        local conditions, values = build_filters(self.params)
        local where_clause = ""
        if #conditions > 0 then
            where_clause = "WHERE " .. table.concat(conditions, " AND ")
        end

        local from_clause = base_from()

        -- Count total matching rows
        local count_sql = "SELECT COUNT(*) AS total " .. from_clause .. " " .. where_clause
        local count_ok, count_rows = pcall(db.query, count_sql, unpack(values))
        if not count_ok then
            return { status = 500, json = { error = "Failed to count transactions" } }
        end
        local total = (count_rows and #count_rows > 0) and tonumber(count_rows[1].total) or 0
        local total_pages = math.ceil(total / limit)
        if total_pages < 1 then total_pages = 1 end

        -- Fetch page of results
        local select_sql = [[
            SELECT
                t.uuid,
                t.transaction_date,
                t.description,
                t.amount,
                t.balance,
                t.transaction_type,
                t.category,
                t.hmrc_category,
                t.confidence_score,
                t.is_tax_deductible,
                t.is_vat_applicable,
                t.vat_rate,
                t.confirmation_status,
                t.classification_status,
                t.is_manually_reviewed,
                t.user_notes,
                t.created_at,
                CONCAT(u.first_name, ' ', u.last_name) AS user_name,
                u.email AS user_email,
                s.file_name AS statement_file_name,
                s.tax_year AS statement_tax_year,
                ba.bank_name,
                ba.account_name
        ]] .. from_clause .. " " .. where_clause ..
            " ORDER BY " .. sort_column .. " " .. sort_order ..
            " LIMIT ? OFFSET ?"

        -- Append pagination params
        local query_values = {}
        for _, v in ipairs(values) do
            table.insert(query_values, v)
        end
        table.insert(query_values, limit)
        table.insert(query_values, offset)

        local data_ok, rows = pcall(db.query, select_sql, unpack(query_values))
        if not data_ok then
            return { status = 500, json = { error = "Failed to fetch transactions" } }
        end

        -- Format items
        local items = {}
        for _, r in ipairs(rows or {}) do
            table.insert(items, {
                uuid = r.uuid,
                transaction_date = r.transaction_date,
                description = r.description,
                amount = tonumber(r.amount),
                balance = tonumber(r.balance),
                transaction_type = r.transaction_type,
                category = r.category,
                hmrc_category = r.hmrc_category,
                confidence_score = tonumber(r.confidence_score),
                is_tax_deductible = r.is_tax_deductible,
                is_vat_applicable = r.is_vat_applicable,
                vat_rate = tonumber(r.vat_rate),
                confirmation_status = r.confirmation_status,
                classification_status = r.classification_status,
                is_manually_reviewed = r.is_manually_reviewed,
                user_notes = r.user_notes,
                created_at = r.created_at,
                user_name = r.user_name,
                user_email = r.user_email,
                statement_file_name = r.statement_file_name,
                statement_tax_year = r.statement_tax_year,
                bank_name = r.bank_name,
                account_name = r.account_name,
            })
        end

        return {
            status = 200,
            json = {
                items = items,
                total = total,
                page = page,
                limit = limit,
                total_pages = total_pages,
                filters_applied = filters_applied(self.params),
            }
        }
    end)

    -- =========================================================================
    -- GET /api/v2/tax/admin/transactions/stats
    -- Returns aggregate stats for admin dashboard header
    -- Admin only
    -- =========================================================================
    app:get("/api/v2/tax/admin/transactions/stats", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end
        if not isAdmin(user) then
            return { status = 403, json = { error = "Admin access required" } }
        end

        local stats_sql = [[
            SELECT
                COUNT(*) AS total_transactions,
                COALESCE(SUM(CASE WHEN transaction_type = 'CREDIT' THEN ABS(amount) ELSE 0 END), 0) AS total_income,
                COALESCE(SUM(CASE WHEN transaction_type = 'DEBIT' THEN ABS(amount) ELSE 0 END), 0) AS total_expenses,
                COALESCE(SUM(CASE WHEN classification_status = 'PENDING' THEN 1 ELSE 0 END), 0) AS pending_classification,
                COUNT(DISTINCT user_id) AS unique_users
            FROM tax_transactions
        ]]

        local ok, rows = pcall(db.query, stats_sql)
        if not ok or not rows or #rows == 0 then
            return { status = 500, json = { error = "Failed to fetch transaction stats" } }
        end

        local s = rows[1]
        return {
            status = 200,
            json = {
                total_transactions = tonumber(s.total_transactions) or 0,
                total_income = tonumber(s.total_income) or 0,
                total_expenses = tonumber(s.total_expenses) or 0,
                pending_classification = tonumber(s.pending_classification) or 0,
                unique_users = tonumber(s.unique_users) or 0,
            }
        }
    end)

    -- =========================================================================
    -- GET /api/v2/tax/admin/transactions/categories
    -- Returns distinct categories with counts for filter dropdowns
    -- Admin only
    -- =========================================================================
    app:get("/api/v2/tax/admin/transactions/categories", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end
        if not isAdmin(user) then
            return { status = 403, json = { error = "Admin access required" } }
        end

        local categories_sql = [[
            SELECT category, COUNT(*) AS count
            FROM tax_transactions
            WHERE category IS NOT NULL AND category != ''
            GROUP BY category
            ORDER BY count DESC
        ]]

        local hmrc_sql = [[
            SELECT hmrc_category, COUNT(*) AS count
            FROM tax_transactions
            WHERE hmrc_category IS NOT NULL AND hmrc_category != ''
            GROUP BY hmrc_category
            ORDER BY count DESC
        ]]

        local cat_ok, cat_rows = pcall(db.query, categories_sql)
        local hmrc_ok, hmrc_rows = pcall(db.query, hmrc_sql)

        if not cat_ok or not hmrc_ok then
            return { status = 500, json = { error = "Failed to fetch categories" } }
        end

        local categories = {}
        for _, r in ipairs(cat_rows or {}) do
            table.insert(categories, {
                name = r.category,
                count = tonumber(r.count),
            })
        end

        local hmrc_categories = {}
        for _, r in ipairs(hmrc_rows or {}) do
            table.insert(hmrc_categories, {
                name = r.hmrc_category,
                count = tonumber(r.count),
            })
        end

        return {
            status = 200,
            json = {
                categories = categories,
                hmrc_categories = hmrc_categories,
            }
        }
    end)

end
