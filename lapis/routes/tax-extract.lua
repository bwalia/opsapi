--[[
    Tax Extraction Routes

    Endpoints for extracting transactions from uploaded bank statements.
    Supports PDF, CSV, and image files with multi-bank layout detection.

    POST /api/v2/tax/extract/bank-details  — Detect bank name, account, sort code
    POST /api/v2/tax/extract               — Extract all transactions from a statement
    GET  /api/v2/tax/extract/:statement_id  — Get extracted transactions for a statement
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local RateLimit = require("middleware.rate-limit")
local MinioClient = require("helper.minio")
local Global = require("helper.global")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

return function(app)

    -- POST /api/v2/tax/extract/bank-details — detect bank details from file
    app:post("/api/v2/tax/extract/bank-details",
        RateLimit.wrap({ rate = 10, window = 60, prefix = "extract:bank" },
            AuthMiddleware.requireAuth(function(self)
                local statement_id = self.params.statement_id
                if not statement_id then
                    return { status = 400, json = { error = "statement_id is required" } }
                end

                local user_id = getUserId(self.current_user)
                if not user_id then
                    return { status = 401, json = { error = "User not found" } }
                end

                -- Fetch statement
                local statements = db.select(
                    "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                    statement_id, user_id
                )
                if #statements == 0 then
                    return { status = 404, json = { error = "Statement not found" } }
                end
                local stmt = statements[1]

                -- Download file from MinIO to temp path
                local file_key = stmt.minio_key or stmt.file_path
                if not file_key then
                    return { status = 400, json = { error = "Statement has no file attached" } }
                end

                -- For bank detail detection, we need the raw content
                -- Use pdftotext or read CSV directly
                local file_type = stmt.file_type or "pdf"
                local tmp_path = "/tmp/opsapi-extract-" .. ngx.time() .. "-" .. statement_id

                -- Download from MinIO
                local minio = MinioClient.getDefault()
                if not minio then
                    return { status = 500, json = { error = "MinIO not configured" } }
                end

                local presigned_url = minio:getPresignedUrl(file_key, 300)
                if not presigned_url then
                    return { status = 500, json = { error = "Could not get file from storage" } }
                end

                -- Download file
                local ok_http, http = pcall(require, "resty.http")
                if not ok_http then
                    return { status = 500, json = { error = "HTTP client not available" } }
                end

                local httpc = http.new()
                httpc:set_timeout(30000)
                local res, dl_err = httpc:request_uri(presigned_url, {
                    method = "GET",
                    ssl_verify = false,
                })

                if not res or res.status ~= 200 then
                    return { status = 500, json = { error = "Failed to download file from storage" } }
                end

                -- Write to temp file
                local f = io.open(tmp_path, "wb")
                if f then
                    f:write(res.body)
                    f:close()
                end

                -- Detect bank details
                local ok_ext, Extraction = pcall(require, "lib.tax-extraction")
                if not ok_ext then
                    os.remove(tmp_path)
                    return { status = 500, json = { error = "Extraction module not available" } }
                end

                local details
                if file_type == "csv" then
                    details = Extraction.detect_bank_details(res.body, "csv")
                else
                    details = Extraction.detect_bank_details(tmp_path, "pdf")
                end

                os.remove(tmp_path)

                -- Update statement with detected details if found
                if details and details.bank_name then
                    local updates = {}
                    if details.bank_name then updates.bank_name = details.bank_name end
                    if details.opening_balance then updates.opening_balance = details.opening_balance end
                    if details.closing_balance then updates.closing_balance = details.closing_balance end
                    if details.period_start then updates.period_start = details.period_start end
                    if details.period_end then updates.period_end = details.period_end end
                    if next(updates) then
                        updates.updated_at = db.raw("NOW()")
                        db.update("tax_statements", updates, { id = statement_id })
                    end
                end

                return { status = 200, json = { data = details } }
            end)
        )
    )

    -- POST /api/v2/tax/extract — extract transactions from a statement
    app:post("/api/v2/tax/extract",
        RateLimit.wrap({ rate = 10, window = 60, prefix = "extract:txn" },
            AuthMiddleware.requireAuth(function(self)
                local statement_id = self.params.statement_id
                if not statement_id then
                    return { status = 400, json = { error = "statement_id is required" } }
                end

                local user_id = getUserId(self.current_user)
                if not user_id then
                    return { status = 401, json = { error = "User not found" } }
                end

                local statements = db.select(
                    "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                    statement_id, user_id
                )
                if #statements == 0 then
                    return { status = 404, json = { error = "Statement not found" } }
                end
                local stmt = statements[1]

                -- Check workflow step
                if stmt.workflow_step and stmt.workflow_step ~= "UPLOADED" and stmt.workflow_step ~= "EXTRACTED" then
                    return { status = 409, json = { error = "Statement is past extraction stage" } }
                end

                local file_key = stmt.minio_key or stmt.file_path
                if not file_key then
                    return { status = 400, json = { error = "Statement has no file attached" } }
                end

                local file_type = stmt.file_type or "pdf"
                local tmp_path = "/tmp/opsapi-extract-" .. ngx.time() .. "-" .. statement_id

                -- Download from MinIO
                local minio = MinioClient.getDefault()
                if not minio then
                    return { status = 500, json = { error = "MinIO not configured" } }
                end

                local presigned_url = minio:getPresignedUrl(file_key, 300)
                if not presigned_url then
                    return { status = 500, json = { error = "Could not get file from storage" } }
                end

                local ok_http, http = pcall(require, "resty.http")
                if not ok_http then
                    return { status = 500, json = { error = "HTTP client not available" } }
                end

                local httpc = http.new()
                httpc:set_timeout(30000)
                local res, dl_err = httpc:request_uri(presigned_url, {
                    method = "GET",
                    ssl_verify = false,
                })

                if not res or res.status ~= 200 then
                    return { status = 500, json = { error = "Failed to download file" } }
                end

                local f = io.open(tmp_path, "wb")
                if f then
                    f:write(res.body)
                    f:close()
                end

                -- Update status to processing
                db.update("tax_statements", {
                    processing_status = "PROCESSING",
                    updated_at = db.raw("NOW()"),
                }, { id = statement_id })

                -- Run extraction
                local ok_ext, Extraction = pcall(require, "lib.tax-extraction")
                if not ok_ext then
                    os.remove(tmp_path)
                    db.update("tax_statements", { processing_status = "ERROR", updated_at = db.raw("NOW()") }, { id = statement_id })
                    return { status = 500, json = { error = "Extraction module not available" } }
                end

                local langfuse = pcall(require, "lib.langfuse") and require("lib.langfuse") or nil
                local trace_id = langfuse and langfuse.trace_start("extract_statement", { statement_id = statement_id })

                local result, err = Extraction.extract(tmp_path, file_type, {
                    content = (file_type == "csv") and res.body or nil,
                    bank_hint = stmt.bank_name,
                    trace_id = trace_id,
                })

                os.remove(tmp_path)

                if not result then
                    db.update("tax_statements", {
                        processing_status = "ERROR",
                        updated_at = db.raw("NOW()"),
                    }, { id = statement_id })
                    return { status = 422, json = { error = "Extraction failed: " .. tostring(err) } }
                end

                -- Insert extracted transactions
                local inserted = 0
                for _, txn in ipairs(result.transactions or {}) do
                    local ok_insert = pcall(function()
                        db.insert("tax_transactions", {
                            uuid = Global.generateStaticUUID(),
                            statement_id = tonumber(statement_id),
                            bank_account_id = stmt.bank_account_id,
                            user_id = user_id,
                            transaction_date = txn.date,
                            description = txn.description,
                            amount = txn.amount,
                            balance = txn.balance or db.NULL,
                            transaction_type = txn.transaction_type,
                            confirmation_status = "PENDING",
                            classification_status = "PENDING",
                            created_at = db.raw("NOW()"),
                            updated_at = db.raw("NOW()"),
                        })
                    end)
                    if ok_insert then
                        inserted = inserted + 1
                    end
                end

                -- Update statement
                local stmt_updates = {
                    processing_status = "COMPLETED",
                    workflow_step = "EXTRACTED",
                    transaction_count = inserted,
                    updated_at = db.raw("NOW()"),
                }
                if result.bank then stmt_updates.bank_name = result.bank end
                if result.bank_details then
                    if result.bank_details.opening_balance then
                        stmt_updates.opening_balance = result.bank_details.opening_balance
                    end
                    if result.bank_details.closing_balance then
                        stmt_updates.closing_balance = result.bank_details.closing_balance
                    end
                end
                db.update("tax_statements", stmt_updates, { id = statement_id })

                -- Audit log
                pcall(function()
                    db.insert("tax_audit_logs", {
                        uuid = Global.generateStaticUUID(),
                        entity_type = "STATEMENT",
                        entity_id = stmt.uuid or tostring(statement_id),
                        action = "EXTRACT",
                        user_id = user_id,
                        new_values = cjson.encode({
                            transactions_extracted = inserted,
                            bank = result.bank,
                            format = result.format,
                        }),
                        created_at = db.raw("NOW()"),
                    })
                end)

                return {
                    status = 200,
                    json = {
                        message = "Extraction complete",
                        transactions_extracted = inserted,
                        bank = result.bank,
                        format = result.format,
                        statement_id = statement_id,
                    }
                }
            end)
        )
    )

    -- GET /api/v2/tax/extract/:statement_id — get extracted transactions
    app:get("/api/v2/tax/extract/:statement_id",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            -- Verify statement belongs to user
            local statements = db.select(
                "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                self.params.statement_id, user_id
            )
            if #statements == 0 then
                return { status = 404, json = { error = "Statement not found" } }
            end

            local page = tonumber(self.params.page) or 1
            local per_page = tonumber(self.params.per_page) or 100
            local offset = (page - 1) * per_page

            local transactions = db.select(
                "* FROM tax_transactions WHERE statement_id = ? ORDER BY transaction_date ASC, id ASC LIMIT ? OFFSET ?",
                self.params.statement_id, per_page, offset
            )

            local count_result = db.select(
                "COUNT(*) as total FROM tax_transactions WHERE statement_id = ?",
                self.params.statement_id
            )
            local total = count_result[1] and count_result[1].total or 0

            return {
                status = 200,
                json = {
                    data = transactions,
                    total = total,
                    page = page,
                    per_page = per_page,
                }
            }
        end)
    )
end
