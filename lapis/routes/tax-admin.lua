--[[
    Tax Admin Routes

    System-wide admin endpoints for managing the tax platform.
    All endpoints require admin role.

    GET  /api/v2/admin/dashboard                    — System stats
    GET  /api/v2/admin/bank-accounts                — Cross-user bank accounts
    GET  /api/v2/admin/statements                   — Cross-user statements
    GET  /api/v2/admin/transactions/low-confidence  — Review queue
    GET  /api/v2/admin/export/:statement_id          — CSV export
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

return function(app)

    -- GET /api/v2/admin/dashboard
    app:get("/api/v2/admin/dashboard",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local stats = {}

            -- User counts
            local user_rows = db.query("SELECT COUNT(*) as total, COUNT(*) FILTER (WHERE is_active = true OR is_active IS NULL) as active FROM users")
            stats.users = user_rows and user_rows[1] or { total = 0, active = 0 }

            -- Statement counts
            local stmt_rows = db.query([[
                SELECT COUNT(*) as total,
                    COUNT(*) FILTER (WHERE workflow_step = 'FILED') as filed,
                    COUNT(*) FILTER (WHERE workflow_step = 'TAX_CALCULATED') as calculated,
                    COUNT(*) FILTER (WHERE workflow_step = 'CLASSIFIED') as classified,
                    COUNT(*) FILTER (WHERE workflow_step = 'EXTRACTED') as extracted,
                    COUNT(*) FILTER (WHERE workflow_step = 'UPLOADED') as uploaded
                FROM tax_statements
            ]])
            stats.statements = stmt_rows and stmt_rows[1] or {}

            -- Transaction counts
            local txn_rows = db.query([[
                SELECT COUNT(*) as total,
                    COUNT(*) FILTER (WHERE classification_status = 'CLASSIFIED') as classified,
                    COUNT(*) FILTER (WHERE classification_status = 'PENDING' OR classification_status IS NULL) as pending,
                    COUNT(*) FILTER (WHERE confidence_score IS NOT NULL AND confidence_score < 0.7) as low_confidence,
                    COALESCE(AVG(confidence_score), 0) as avg_confidence
                FROM tax_transactions
            ]])
            stats.transactions = txn_rows and txn_rows[1] or {}

            -- Filing counts
            local filing_rows = db.query("SELECT COUNT(*) as total, COUNT(*) FILTER (WHERE status = 'FILED') as filed FROM tax_returns")
            stats.filings = filing_rows and filing_rows[1] or {}

            -- Training data
            local training_rows = db.query([[
                SELECT COUNT(*) as total,
                    COUNT(embedding) as with_embedding,
                    COUNT(*) FILTER (WHERE source = 'accountant_correction') as accountant_corrections
                FROM classification_training_data
            ]])
            stats.training_data = training_rows and training_rows[1] or {}

            return { status = 200, json = { data = stats } }
        end)
    )

    -- GET /api/v2/admin/bank-accounts
    app:get("/api/v2/admin/bank-accounts",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local page = tonumber(self.params.page) or 1
            local per_page = tonumber(self.params.per_page) or 25
            local offset = (page - 1) * per_page

            local rows = db.query(string.format([[
                SELECT ba.*, u.email as user_email, u.first_name, u.last_name
                FROM tax_bank_accounts ba
                LEFT JOIN users u ON u.id = ba.user_id
                ORDER BY ba.created_at DESC
                LIMIT %d OFFSET %d
            ]], per_page, offset))

            local count = db.query("SELECT COUNT(*) as total FROM tax_bank_accounts")

            return {
                status = 200,
                json = {
                    data = rows or {},
                    total = count and count[1] and count[1].total or 0,
                    page = page,
                    per_page = per_page,
                }
            }
        end)
    )

    -- GET /api/v2/admin/statements
    app:get("/api/v2/admin/statements",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local page = tonumber(self.params.page) or 1
            local per_page = tonumber(self.params.per_page) or 25
            local offset = (page - 1) * per_page

            local where_clauses = { "1=1" }
            if self.params.workflow_step then
                table.insert(where_clauses, "s.workflow_step = " .. db.escape_literal(self.params.workflow_step))
            end
            if self.params.tax_year then
                table.insert(where_clauses, "s.tax_year = " .. db.escape_literal(self.params.tax_year))
            end
            if self.params.search then
                local search = db.escape_literal("%" .. self.params.search .. "%")
                table.insert(where_clauses, "(u.email ILIKE " .. search .. " OR s.bank_name ILIKE " .. search .. ")")
            end

            local where = table.concat(where_clauses, " AND ")

            local rows = db.query(string.format([[
                SELECT s.*, u.email as user_email, u.first_name, u.last_name
                FROM tax_statements s
                LEFT JOIN users u ON u.id = s.user_id
                WHERE %s
                ORDER BY s.created_at DESC
                LIMIT %d OFFSET %d
            ]], where, per_page, offset))

            local count = db.query(string.format(
                "SELECT COUNT(*) as total FROM tax_statements s LEFT JOIN users u ON u.id = s.user_id WHERE %s", where
            ))

            return {
                status = 200,
                json = {
                    data = rows or {},
                    total = count and count[1] and count[1].total or 0,
                    page = page,
                    per_page = per_page,
                }
            }
        end)
    )

    -- GET /api/v2/admin/transactions/low-confidence
    app:get("/api/v2/admin/transactions/low-confidence",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local page = tonumber(self.params.page) or 1
            local per_page = tonumber(self.params.per_page) or 50
            local offset = (page - 1) * per_page
            local threshold = tonumber(self.params.threshold) or 0.7

            local rows = db.query(string.format([[
                SELECT t.*, s.bank_name, u.email as user_email
                FROM tax_transactions t
                LEFT JOIN tax_statements s ON s.id = t.statement_id
                LEFT JOIN users u ON u.id = t.user_id
                WHERE t.confidence_score IS NOT NULL
                AND t.confidence_score < %f
                AND (t.classification_status = 'NEEDS_REVIEW' OR t.classification_status = 'CLASSIFIED')
                ORDER BY t.confidence_score ASC
                LIMIT %d OFFSET %d
            ]], threshold, per_page, offset))

            local count = db.query(string.format([[
                SELECT COUNT(*) as total FROM tax_transactions
                WHERE confidence_score IS NOT NULL AND confidence_score < %f
                AND (classification_status = 'NEEDS_REVIEW' OR classification_status = 'CLASSIFIED')
            ]], threshold))

            return {
                status = 200,
                json = {
                    data = rows or {},
                    total = count and count[1] and count[1].total or 0,
                    page = page,
                    per_page = per_page,
                    threshold = threshold,
                }
            }
        end)
    )

    -- GET /api/v2/admin/export/:statement_id
    app:get("/api/v2/admin/export/:statement_id",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local transactions = db.select([[
                * FROM tax_transactions WHERE statement_id = ? ORDER BY transaction_date ASC, id ASC
            ]], self.params.statement_id)

            if not transactions or #transactions == 0 then
                return { status = 404, json = { error = "No transactions found" } }
            end

            -- Build CSV
            local csv_lines = { "Date,Description,Amount,Type,Category,HMRC Category,Confidence,Tax Deductible,Status" }
            for _, txn in ipairs(transactions) do
                local line = string.format(
                    '%s,"%s",%.2f,%s,%s,%s,%.2f,%s,%s',
                    txn.transaction_date or "",
                    (txn.description or ""):gsub('"', '""'),
                    tonumber(txn.amount) or 0,
                    txn.transaction_type or "",
                    txn.category or "",
                    txn.hmrc_category or "",
                    tonumber(txn.confidence_score) or 0,
                    tostring(txn.is_tax_deductible or false),
                    txn.classification_status or ""
                )
                table.insert(csv_lines, line)
            end

            local csv_content = table.concat(csv_lines, "\n")

            ngx.header["Content-Type"] = "text/csv; charset=utf-8"
            ngx.header["Content-Disposition"] = "attachment; filename=statement_" .. self.params.statement_id .. "_export.csv"
            return { status = 200, layout = false, csv_content }
        end)
    )
end
