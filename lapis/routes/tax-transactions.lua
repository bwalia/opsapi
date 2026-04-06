--[[
    Tax Transaction Routes

    CRUD endpoints for tax transactions.
    All endpoints require authentication.
    Users can only access their own transactions.
]]

local respond_to = require("lapis.application").respond_to
local db = require("lapis.db")
local TaxTransactionQueries = require "queries.TaxTransactionQueries"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local AuthMiddleware = require("middleware.auth")
local cjson = require("cjson")

-- ============================================================================
-- Server-side filtering, sorting, pagination for user's own transactions
-- ============================================================================

local SORT_COLUMNS = {
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
    bank_name = "ba.bank_name",
}

local function clamp(val, lo, hi)
    if val < lo then return lo end
    if val > hi then return hi end
    return val
end

--- Resolve the authenticated user's internal integer ID from their JWT UUID.
local function resolveUserId(user)
    local uuid = user.uuid or user.id or user.sub
    if not uuid then return nil end
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", uuid)
    return (rows and #rows > 0) and rows[1].id or nil
end

--- Build WHERE conditions for user-scoped transaction queries.
-- Always includes user_id scoping; never trusts client-supplied user_id.
local function build_user_filters(params, user_id)
    local conds = { "t.user_id = ?" }
    local vals = { user_id }

    if params.search and params.search ~= "" then
        table.insert(conds, "t.description ILIKE ?")
        table.insert(vals, "%" .. params.search .. "%")
    end

    if params.transaction_type and params.transaction_type ~= "" then
        local tt = params.transaction_type:upper()
        if tt == "DEBIT" or tt == "CREDIT" then
            table.insert(conds, "t.transaction_type = ?")
            table.insert(vals, tt)
        end
    end

    if params.category and params.category ~= "" then
        table.insert(conds, "t.category = ?")
        table.insert(vals, params.category)
    end

    if params.hmrc_category and params.hmrc_category ~= "" then
        table.insert(conds, "t.hmrc_category = ?")
        table.insert(vals, params.hmrc_category)
    end

    if params.amount_min and params.amount_min ~= "" then
        local v = tonumber(params.amount_min)
        if v then
            table.insert(conds, "ABS(t.amount) >= ?")
            table.insert(vals, v)
        end
    end

    if params.amount_max and params.amount_max ~= "" then
        local v = tonumber(params.amount_max)
        if v then
            table.insert(conds, "ABS(t.amount) <= ?")
            table.insert(vals, v)
        end
    end

    if params.date_from and params.date_from:match("^%d%d%d%d%-%d%d%-%d%d$") then
        table.insert(conds, "t.transaction_date >= ?")
        table.insert(vals, params.date_from)
    end

    if params.date_to and params.date_to:match("^%d%d%d%d%-%d%d%-%d%d$") then
        table.insert(conds, "t.transaction_date <= ?")
        table.insert(vals, params.date_to)
    end

    if params.classification_status and params.classification_status ~= "" then
        local cs = params.classification_status:upper()
        if cs == "PENDING" or cs == "CONFIRMED" or cs == "MODIFIED" then
            table.insert(conds, "t.classification_status = ?")
            table.insert(vals, cs)
        end
    end

    if params.is_tax_deductible and params.is_tax_deductible ~= "" then
        local v = params.is_tax_deductible:lower()
        if v == "true" then
            table.insert(conds, "t.is_tax_deductible = TRUE")
        elseif v == "false" then
            table.insert(conds, "t.is_tax_deductible = FALSE")
        end
    end

    if params.bank_account_id and params.bank_account_id ~= "" then
        local v = tonumber(params.bank_account_id)
        if v then
            table.insert(conds, "t.bank_account_id = ?")
            table.insert(vals, v)
        end
    end

    return conds, vals
end

-- Parse request body (supports both JSON and form-urlencoded)
local function parse_request_body()
    ngx.req.read_body()

    -- Check content type to determine parsing method
    local content_type = ngx.var.content_type or ""

    -- If JSON content type, parse as JSON
    if content_type:find("application/json", 1, true) then
        local ok, result = pcall(function()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cjson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
        end
        return {}
    end

    -- Otherwise, try form params (application/x-www-form-urlencoded)
    local post_args = ngx.req.get_post_args()
    if post_args and next(post_args) then
        return post_args
    end

    return {}
end

-- Merge body params into self.params
local function merge_params(self)
    local body_params = parse_request_body()
    for k, v in pairs(body_params) do
        if self.params[k] == nil then
            self.params[k] = v
        end
    end
end

return function(app)
    -- =========================================================================
    -- GET /api/v2/tax/transactions
    -- List ALL of the authenticated user's transactions (across all statements)
    -- with server-side filtering, sorting, and pagination.
    -- =========================================================================
    app:get("/api/v2/tax/transactions", AuthMiddleware.requireAuth(function(self)
        local user_id = resolveUserId(self.current_user)
        if not user_id then
            return { status = 401, json = { error = "User not found" } }
        end

        -- Pagination
        local page = math.max(tonumber(self.params.page) or 1, 1)
        local limit = clamp(tonumber(self.params.limit) or 25, 1, 100)
        local offset = (page - 1) * limit

        -- Sorting (whitelist only)
        local sort_key = self.params.sort_by or "transaction_date"
        local sort_col = SORT_COLUMNS[sort_key] or "t.transaction_date"
        local sort_dir = "DESC"
        if self.params.sort_order and self.params.sort_order:upper() == "ASC" then
            sort_dir = "ASC"
        end

        -- Filters (always scoped to this user)
        local conds, vals = build_user_filters(self.params, user_id)
        local where = "WHERE " .. table.concat(conds, " AND ")

        local from = [[
            FROM tax_transactions t
            LEFT JOIN tax_statements s ON t.statement_id = s.id
            LEFT JOIN tax_bank_accounts ba ON t.bank_account_id = ba.id
        ]]

        -- Count
        local count_sql = "SELECT COUNT(*) AS total " .. from .. " " .. where
        local ok_count, count_rows = pcall(db.query, count_sql, table.unpack(vals))
        if not ok_count then
            ngx.log(ngx.ERR, "[TX] Count query failed: ", tostring(count_rows))
            return { status = 500, json = { error = "Failed to count transactions" } }
        end
        local total = (count_rows and #count_rows > 0) and tonumber(count_rows[1].total) or 0
        local total_pages = math.max(math.ceil(total / limit), 1)

        -- Fetch page
        local qvals = {}
        for _, v in ipairs(vals) do qvals[#qvals + 1] = v end
        qvals[#qvals + 1] = limit
        qvals[#qvals + 1] = offset

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
                s.uuid AS statement_uuid,
                s.file_name AS statement_file_name,
                s.tax_year AS statement_tax_year,
                ba.uuid AS bank_account_uuid,
                ba.bank_name,
                ba.account_name
        ]] .. from .. " " .. where ..
            " ORDER BY " .. sort_col .. " " .. sort_dir ..
            " LIMIT ? OFFSET ?"

        local ok_data, rows = pcall(db.query, select_sql, table.unpack(qvals))
        if not ok_data then
            ngx.log(ngx.ERR, "[TX] Data query failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to fetch transactions" } }
        end

        local items = {}
        for _, r in ipairs(rows or {}) do
            items[#items + 1] = {
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
                statement_uuid = r.statement_uuid,
                statement_file_name = r.statement_file_name,
                statement_tax_year = r.statement_tax_year,
                bank_account_uuid = r.bank_account_uuid,
                bank_name = r.bank_name,
                account_name = r.account_name,
            }
        end

        return {
            status = 200,
            json = {
                items = items,
                total = total,
                page = page,
                limit = limit,
                total_pages = total_pages,
            }
        }
    end))

    -- =========================================================================
    -- GET /api/v2/tax/transactions/summary
    -- Aggregate stats for the authenticated user's transactions
    -- =========================================================================
    app:get("/api/v2/tax/transactions/summary", AuthMiddleware.requireAuth(function(self)
        local user_id = resolveUserId(self.current_user)
        if not user_id then
            return { status = 401, json = { error = "User not found" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT
                COUNT(*) AS total_transactions,
                COALESCE(SUM(CASE WHEN transaction_type = 'CREDIT' THEN ABS(amount) ELSE 0 END), 0) AS total_income,
                COALESCE(SUM(CASE WHEN transaction_type = 'DEBIT'  THEN ABS(amount) ELSE 0 END), 0) AS total_expenses,
                COALESCE(SUM(CASE WHEN classification_status = 'PENDING' THEN 1 ELSE 0 END), 0) AS pending_classification
            FROM tax_transactions
            WHERE user_id = ?
        ]], user_id)

        if not ok or not rows or #rows == 0 then
            return { status = 500, json = { error = "Failed to fetch summary" } }
        end

        local s = rows[1]
        return {
            status = 200,
            json = {
                total_transactions = tonumber(s.total_transactions) or 0,
                total_income = tonumber(s.total_income) or 0,
                total_expenses = tonumber(s.total_expenses) or 0,
                pending_classification = tonumber(s.pending_classification) or 0,
            }
        }
    end))

    -- =========================================================================
    -- GET /api/v2/tax/transactions/categories
    -- Distinct categories for the authenticated user (for filter dropdowns)
    -- =========================================================================
    app:get("/api/v2/tax/transactions/categories", AuthMiddleware.requireAuth(function(self)
        local user_id = resolveUserId(self.current_user)
        if not user_id then
            return { status = 401, json = { error = "User not found" } }
        end

        local ok_cat, cat_rows = pcall(db.query, [[
            SELECT category, COUNT(*) AS count
            FROM tax_transactions
            WHERE user_id = ? AND category IS NOT NULL AND category != ''
            GROUP BY category ORDER BY count DESC
        ]], user_id)

        local ok_hmrc, hmrc_rows = pcall(db.query, [[
            SELECT hmrc_category, COUNT(*) AS count
            FROM tax_transactions
            WHERE user_id = ? AND hmrc_category IS NOT NULL AND hmrc_category != ''
            GROUP BY hmrc_category ORDER BY count DESC
        ]], user_id)

        if not ok_cat or not ok_hmrc then
            return { status = 500, json = { error = "Failed to fetch categories" } }
        end

        local categories = {}
        for _, r in ipairs(cat_rows or {}) do
            categories[#categories + 1] = { name = r.category, count = tonumber(r.count) }
        end
        local hmrc_categories = {}
        for _, r in ipairs(hmrc_rows or {}) do
            hmrc_categories[#hmrc_categories + 1] = { name = r.hmrc_category, count = tonumber(r.count) }
        end

        return {
            status = 200,
            json = { categories = categories, hmrc_categories = hmrc_categories }
        }
    end))

    -- List transactions for a statement
    app:get("/api/v2/tax/statements/:statement_id/transactions", AuthMiddleware.requireAuth(function(self)
        local transactions = TaxTransactionQueries.byStatement(
            tostring(self.params.statement_id),
            self.params,
            self.current_user
        )
        return {
            json = transactions,
            status = 200
        }
    end))

    -- Bulk create transactions (from AI extraction)
    app:post("/api/v2/tax/statements/:statement_id/transactions/bulk", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.transactions then
            return {
                json = { error = "transactions array is required" },
                status = 400
            }
        end

        local transactions = self.params.transactions
        if type(transactions) == "string" then
            local ok, parsed = pcall(cjson.decode, transactions)
            if not ok then
                return {
                    json = { error = "Invalid transactions JSON" },
                    status = 400
                }
            end
            transactions = parsed
        end

        local result, err = TaxTransactionQueries.bulkCreate(
            tostring(self.params.statement_id),
            transactions,
            self.current_user
        )

        if not result then
            return {
                json = { error = err or "Failed to create transactions" },
                status = 400
            }
        end

        return {
            json = result,
            status = 201
        }
    end))

    -- Bulk update classifications (from AI classification)
    app:post("/api/v2/tax/statements/:statement_id/transactions/classify", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.classifications then
            return {
                json = { error = "classifications array is required" },
                status = 400
            }
        end

        local classifications = self.params.classifications
        if type(classifications) == "string" then
            local ok, parsed = pcall(cjson.decode, classifications)
            if not ok then
                return {
                    json = { error = "Invalid classifications JSON" },
                    status = 400
                }
            end
            classifications = parsed
        end

        local result, err = TaxTransactionQueries.bulkUpdateClassification(
            tostring(self.params.statement_id),
            classifications,
            self.current_user
        )

        if not result then
            return {
                json = { error = err or "Failed to update classifications" },
                status = 400
            }
        end

        return {
            json = result,
            status = 200
        }
    end))

    -- Bulk confirm transactions
    app:post("/api/v2/tax/statements/:statement_id/transactions/bulk-confirm", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.transaction_ids then
            return {
                json = { error = "transaction_ids array is required" },
                status = 400
            }
        end

        local transaction_ids = self.params.transaction_ids
        if type(transaction_ids) == "string" then
            local ok, parsed = pcall(cjson.decode, transaction_ids)
            if ok then
                transaction_ids = parsed
            end
        end

        local result, err = TaxTransactionQueries.bulkConfirm(
            tostring(self.params.statement_id),
            transaction_ids,
            self.params,
            self.current_user
        )

        if not result then
            return {
                json = { error = err or "Failed to confirm transactions" },
                status = 400
            }
        end

        return {
            json = result,
            status = 200
        }
    end))

    -- Bulk confirm classifications
    app:post("/api/v2/tax/statements/:statement_id/transactions/bulk-confirm-classification", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.transaction_ids then
            return {
                json = { error = "transaction_ids array is required" },
                status = 400
            }
        end

        local transaction_ids = self.params.transaction_ids
        if type(transaction_ids) == "string" then
            local ok, parsed = pcall(cjson.decode, transaction_ids)
            if ok then
                transaction_ids = parsed
            end
        end

        local result, err = TaxTransactionQueries.bulkConfirmClassification(
            tostring(self.params.statement_id),
            transaction_ids,
            self.params,
            self.current_user
        )

        if not result then
            return {
                json = { error = err or "Failed to confirm classifications" },
                status = 400
            }
        end

        return {
            json = result,
            status = 200
        }
    end))

    -- Get, update, or patch a single transaction
    app:match("/api/v2/tax/transactions/:id", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local transaction = TaxTransactionQueries.show(tostring(self.params.id), self.current_user)

            if not transaction then
                return {
                    json = { error = "Transaction not found" },
                    status = 404
                }
            end

            return {
                json = { data = transaction },
                status = 200
            }
        end),
        PUT = AuthMiddleware.requireAuth(function(self)
            merge_params(self)

            local transaction = TaxTransactionQueries.update(tostring(self.params.id), self.params, self.current_user)

            if not transaction then
                return {
                    json = { error = "Transaction not found" },
                    status = 404
                }
            end

            return {
                json = { data = transaction },
                status = 200
            }
        end),
        PATCH = AuthMiddleware.requireAuth(function(self)
            merge_params(self)

            local transaction = TaxTransactionQueries.update(tostring(self.params.id), self.params, self.current_user)

            if not transaction then
                return {
                    json = { error = "Transaction not found" },
                    status = 404
                }
            end

            return {
                json = { data = transaction },
                status = 200
            }
        end)
    }))

    -- Confirm a single transaction
    app:post("/api/v2/tax/transactions/:id/confirm", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        local transaction = TaxTransactionQueries.confirm(tostring(self.params.id), self.params, self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = { data = transaction },
            status = 200
        }
    end))

    -- Confirm a single transaction classification
    app:post("/api/v2/tax/transactions/:id/confirm-classification", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        local transaction = TaxTransactionQueries.confirmClassification(tostring(self.params.id), self.params, self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = { data = transaction },
            status = 200
        }
    end))

    -- Get transaction history (audit trail)
    app:get("/api/v2/tax/transactions/:id/history", AuthMiddleware.requireAuth(function(self)
        local transaction = TaxTransactionQueries.show(tostring(self.params.id), self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        local audit_logs = TaxAuditLogQueries.getByEntity("TRANSACTION", tostring(self.params.id), self.params)
        return {
            json = audit_logs,
            status = 200
        }
    end))
end
