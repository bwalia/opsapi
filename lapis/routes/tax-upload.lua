--[[
    Tax Upload Routes

    Endpoint for uploading bank statements to MinIO storage.
    Creates statement records linked to bank accounts.
    All endpoints require authentication.
    Users can only upload to their own bank accounts.
]]

local Global = require("helper.global")
local MinioClient = require("helper.minio")
local TaxBankAccountQueries = require("queries.TaxBankAccountQueries")
local TaxStatementQueries = require("queries.TaxStatementQueries")
local TaxAuditLogQueries = require("queries.TaxAuditLogQueries")
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")

-- File type configurations
local ALLOWED_FILE_TYPES = {
    ["application/pdf"] = { extensions = { "pdf" }, type = "pdf" },
    ["text/csv"] = { extensions = { "csv" }, type = "csv" },
    ["image/jpeg"] = { extensions = { "jpg", "jpeg" }, type = "image" },
    ["image/png"] = { extensions = { "png" }, type = "image" },
    ["image/gif"] = { extensions = { "gif" }, type = "image" },
    ["image/webp"] = { extensions = { "webp" }, type = "image" },
}

-- Extension to MIME type mapping
local EXTENSION_TO_TYPE = {
    pdf = "pdf",
    csv = "csv",
    jpg = "image",
    jpeg = "image",
    png = "image",
    gif = "image",
    webp = "image"
}

-- Max file size (25MB for statements)
local MAX_FILE_SIZE = 25 * 1024 * 1024

-- Helper to get user's internal ID from UUID
local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local user_record
    if user.uuid then
        user_record = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        user_record = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if user_record and #user_record > 0 then
        return user_record[1].id
    end
    return nil
end

-- Get file type from extension
local function getFileType(filename)
    if not filename then return nil end
    local ext = filename:match("%.([^%.]+)$")
    if ext then
        return EXTENSION_TO_TYPE[ext:lower()]
    end
    return nil
end

-- Validate file before upload
local function validateFile(file)
    if not file then
        return false, "No file provided"
    end

    if not file.content or file.content == "" then
        return false, "File content is empty"
    end

    local file_size = #file.content
    if file_size > MAX_FILE_SIZE then
        return false, string.format(
            "File size (%d bytes) exceeds maximum allowed (%d bytes / 25MB)",
            file_size, MAX_FILE_SIZE
        )
    end

    -- Check file type
    local file_type = getFileType(file.filename)
    if not file_type then
        return false, "Only PDF, CSV, and image files (JPG, PNG, GIF, WebP) are supported"
    end

    return true, file_type
end

-- Handle file upload to MinIO
local function uploadToMinio(file, bank_account_uuid, user_uuid)
    -- Generate MinIO object key with proper path structure
    local timestamp = os.date("!%Y/%m/%d/%H%M%S")
    local safe_filename = file.filename:gsub("[^%w%.%-_]", "_")
    local object_key = string.format("statements/account_%s/%s_%s",
        bank_account_uuid, timestamp, safe_filename)

    -- Upload using MinIO client
    local minio = MinioClient.getDefault()
    local bucket = Global.getEnvVar("MINIO_BUCKET") or "opsapi"

    local url, err, metadata = minio:upload(file, {
        bucket = bucket,
        object_key = object_key,
        prefix = nil  -- We're using object_key directly
    })

    if not url then
        return nil, nil, nil, "File upload failed: " .. (err or "Unknown error")
    end

    return url, object_key, metadata, nil
end

-- Standard API response wrapper
local function apiResponse(status, data, message)
    local response = { status = status }

    if status >= 200 and status < 300 then
        response.json = {
            success = true,
            data = data,
            message = message
        }
    else
        response.json = {
            success = false,
            error = message or "An error occurred",
            details = data
        }
    end

    return response
end

return function(app)
    -- POST /api/v2/tax/upload - Upload a bank statement
    --
    -- Request body (multipart/form-data):
    --   - file: The file to upload (PDF, CSV, or image)
    --   - bank_account_id: UUID of the bank account to associate with
    --
    -- Response:
    --   - statement_id: UUID of created statement
    --   - bank_account_id: UUID of associated bank account
    --   - file_name: Original filename
    --   - file_type: Type of file (pdf, csv, image)
    --   - status: Processing status (UPLOADED)
    --
    app:post("/api/v2/tax/upload", AuthMiddleware.requireAuth(function(self)
        -- Get file from request (multipart form-data)
        local file = self.params.file or self.params.statement or self.params.document

        if not file then
            return apiResponse(400, nil, "No file uploaded. Use 'file', 'statement', or 'document' field.")
        end

        if type(file) ~= "table" or not file.content then
            return apiResponse(400, nil, "Invalid file format")
        end

        -- Get bank_account_id from form data
        local bank_account_id = self.params.bank_account_id
        if not bank_account_id or bank_account_id == "" then
            return apiResponse(400, nil, "bank_account_id is required")
        end

        -- Validate file
        local valid, file_type_or_error = validateFile(file)
        if not valid then
            return apiResponse(400, nil, file_type_or_error)
        end
        local file_type = file_type_or_error

        -- Get user ID
        local user_id = getUserId(self.current_user)
        if not user_id then
            return apiResponse(401, nil, "User not found")
        end

        -- Verify bank account exists and belongs to user
        local bank_account = TaxBankAccountQueries.show(bank_account_id, self.current_user)
        if not bank_account then
            return apiResponse(404, nil, "Bank account not found or access denied")
        end

        -- Check if bank account is active
        if bank_account.is_active == false then
            return apiResponse(400, nil, "Bank account is not active")
        end

        -- Upload file to MinIO
        local url, object_key, metadata, upload_err = uploadToMinio(
            file,
            bank_account_id,
            self.current_user.uuid
        )

        if not url then
            ngx.log(ngx.ERR, "[TaxUpload] MinIO upload failed: ", upload_err)
            return apiResponse(500, nil, upload_err)
        end

        ngx.log(ngx.INFO, "[TaxUpload] File uploaded to MinIO: ", object_key)

        -- Create statement record
        local bucket = Global.getEnvVar("MINIO_BUCKET") or "opsapi"
        local statement_data = {
            bank_account_uuid = bank_account_id,
            bank_account_id = bank_account_id,  -- TaxStatementQueries uses this
            minio_bucket = bucket,
            minio_object_key = object_key,
            file_name = file.filename,
            file_size_bytes = #file.content,
            file_type = file_type,
            processing_status = "UPLOADED",
            workflow_step = "UPLOADED"
        }

        local statement_result, statement_err = TaxStatementQueries.create(statement_data, self.current_user)

        if not statement_result then
            ngx.log(ngx.ERR, "[TaxUpload] Failed to create statement: ", statement_err)
            -- Try to clean up the uploaded file
            local minio = MinioClient.getDefault()
            minio:delete(object_key, bucket)
            return apiResponse(500, nil, "Failed to create statement record: " .. (statement_err or "Unknown error"))
        end

        local statement = statement_result.data

        ngx.log(ngx.INFO, "[TaxUpload] Statement created: ", statement.id, " for bank account ", bank_account_id)

        -- Return response matching Python API format
        return {
            status = 201,
            json = {
                statement_id = statement.id,
                bank_account_id = bank_account_id,
                bank_name = bank_account.bank_name,
                account_name = bank_account.account_name,
                file_name = statement.file_name,
                file_type = statement.file_type,
                file_size_bytes = statement.file_size_bytes,
                status = statement.processing_status,
                uploaded_at = statement.uploaded_at
            }
        }
    end))

    -- GET /api/v2/tax/upload/presigned/:statement_id - Get presigned URL for statement file
    app:get("/api/v2/tax/upload/presigned/:statement_id", AuthMiddleware.requireAuth(function(self)
        local statement_id = tostring(self.params.statement_id)

        -- Get statement and verify access
        local statement = TaxStatementQueries.show(statement_id, self.current_user)
        if not statement then
            return apiResponse(404, nil, "Statement not found")
        end

        if not statement.minio_object_key then
            return apiResponse(400, nil, "Statement has no associated file")
        end

        -- Generate presigned URL (valid for 1 hour)
        local expires_in = tonumber(self.params.expires) or 3600
        if expires_in > 86400 then
            expires_in = 86400  -- Cap at 24 hours
        end

        local minio = MinioClient.getDefault()
        local presigned_url, err = minio:getPresignedUrl(
            statement.minio_object_key,
            expires_in,
            statement.minio_bucket
        )

        if not presigned_url then
            return apiResponse(500, nil, "Failed to generate presigned URL: " .. (err or "Unknown error"))
        end

        return apiResponse(200, {
            url = presigned_url,
            expires_in = expires_in,
            expires_at = os.time() + expires_in,
            file_name = statement.file_name,
            file_type = statement.file_type
        })
    end))
end
