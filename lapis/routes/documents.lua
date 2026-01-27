--[[
    Document Management Routes
    ==========================

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.

    API endpoints for managing documents with direct MinIO/S3 file uploads.

    Features:
    - Direct file upload to MinIO (no intermediate Node.js service)
    - File type and size validation
    - Tag management
    - Pagination and filtering
    - Secure file deletion

    Endpoints:
    - GET    /api/v2/documents          - List documents with pagination
    - POST   /api/v2/documents          - Create document with file upload
    - GET    /api/v2/documents/:id      - Get single document
    - PUT    /api/v2/documents/:id      - Update document
    - DELETE /api/v2/documents/:id      - Delete document
    - DELETE /api/v2/documents          - Bulk delete documents
    - GET    /api/v2/all-documents      - Get all documents (no pagination)
    - POST   /api/v2/documents/upload   - Standalone file upload
]]

local respond_to = require("lapis.application").respond_to
local DocumentQueries = require("queries.DocumentQueries")
local Global = require("helper.global")
local MinioClient = require("helper.minio")
local AuthMiddleware = require("middleware.auth")

-- Configuration
local MAX_FILE_SIZE = 10 * 1024 * 1024  -- 10MB
local ALLOWED_CATEGORIES = { "image", "document" }  -- Allowed file categories

return function(app)
    ----------------- Helper Functions --------------------

    --- Validate document input
    local function validateDocumentInput(data, is_update)
        local errors = {}

        if not is_update then
            if not data.title or data.title == "" then
                table.insert(errors, "Title is required")
            end
        end

        if data.title and #data.title > 255 then
            table.insert(errors, "Title must be less than 255 characters")
        end

        if data.status and data.status ~= "true" and data.status ~= "false" then
            table.insert(errors, "Status must be 'true' or 'false'")
        end

        if #errors > 0 then
            return false, table.concat(errors, "; ")
        end
        return true
    end

    --- Standard API response wrapper
    local function apiResponse(status, data, message, meta)
        local response = { status = status }

        if status >= 200 and status < 300 then
            response.json = {
                success = true,
                data = data,
                message = message,
                meta = meta
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

    --- Validate and upload file
    local function handleFileUpload(file, prefix)
        if not file then
            return nil, nil, "No file provided"
        end

        if not file.content or file.content == "" then
            return nil, nil, "File content is empty"
        end

        -- Validate file using MinIO client
        local minio = MinioClient.getDefault()
        local file_valid, file_err = minio:validateFile(file, {
            max_size = MAX_FILE_SIZE,
            allowed_categories = ALLOWED_CATEGORIES
        })

        if not file_valid then
            return nil, nil, file_err
        end

        -- Upload file
        local url, upload_err, metadata = Global.uploadToMinio(file, file.filename, {
            prefix = prefix or "documents"
        })

        if not url then
            return nil, nil, "File upload failed: " .. (upload_err or "Unknown error")
        end

        return url, metadata, nil
    end

    ----------------- Document Routes --------------------

    -- GET /api/v2/all-documents - Get all documents without pagination
    app:get("/api/v2/all-documents", AuthMiddleware.requireAuth(function(self)
        local result = DocumentQueries.allData()

        if not result or not result.data then
            return apiResponse(500, nil, "Failed to fetch documents")
        end

        return apiResponse(200, result.data, nil, {
            total = #result.data
        })
    end))

    -- Main documents endpoint
    app:match("documents", "/api/v2/documents", respond_to({
        before = AuthMiddleware.requireAuthBefore,

        -- GET /api/v2/documents - List documents with pagination
        GET = function(self)
            local params = {
                page = tonumber(self.params.page) or 1,
                perPage = tonumber(self.params.perPage) or 10,
                orderBy = self.params.orderBy or "id",
                orderDir = self.params.orderDir or "desc"
            }

            local result = DocumentQueries.all(params)

            if not result then
                return apiResponse(500, nil, "Failed to fetch documents")
            end

            return apiResponse(200, result.data, nil, {
                total = result.total,
                page = params.page,
                perPage = params.perPage,
                totalPages = math.ceil((result.total or 0) / params.perPage)
            })
        end,

        -- POST /api/v2/documents - Create document with file upload
        POST = function(self)
            local data = self.params
            local file = data.cover_image

            -- Pass user UUID from JWT token for MinIO folder structure
            if self.current_user and self.current_user.uuid then
                data.user_uuid = self.current_user.uuid
            end

            -- Validate input
            local valid, validation_err = validateDocumentInput(data, false)
            if not valid then
                return apiResponse(400, nil, validation_err)
            end

            -- Validate file is provided (upload handled in DocumentQueries with custom path)
            if not file or type(file) ~= "table" or not file.content then
                return apiResponse(400, nil, "Cover image is required")
            end

            -- Create document (handles file upload with path: {user_uuid}/{doc_uuid}.ext)
            local result = DocumentQueries.create(data)

            if not result then
                return apiResponse(500, nil, "Failed to create document")
            end

            if result.status == 400 then
                return apiResponse(400, nil, result.json and result.json.error or "Invalid request")
            end

            if result.data and result.data.error then
                return apiResponse(500, nil, result.data.error)
            end

            return apiResponse(201, result.data, "Document created successfully")
        end,

        -- DELETE /api/v2/documents - Bulk delete documents
        DELETE = function(self)
            if not self.params.ids then
                return apiResponse(400, nil, "Document IDs are required")
            end

            local result = DocumentQueries.deleteMultiple(self.params)

            if not result then
                return apiResponse(500, nil, "Failed to delete documents")
            end

            return apiResponse(200, result.data, "Documents deleted successfully")
        end
    }))

    -- Single document endpoint
    app:match("edit_documents", "/api/v2/documents/:id", respond_to({
        before = function(self)
            -- First authenticate
            AuthMiddleware.requireAuthBefore(self)
            -- If auth failed and wrote response, stop processing
            if self.res and self.res.status then return end

            local record = DocumentQueries.show(tostring(self.params.id))
            if not record then
                self:write(apiResponse(404, nil, "Document not found"))
                return
            end
            self.document = record
        end,

        -- GET /api/v2/documents/:id - Get single document
        GET = function(self)
            if not self.document then
                return apiResponse(404, nil, "Document not found")
            end
            return apiResponse(200, self.document)
        end,

        -- PUT /api/v2/documents/:id - Update document
        PUT = function(self)
            if not self.document then
                return apiResponse(404, nil, "Document not found")
            end

            local data = self.params
            local file = data.cover_image

            -- Validate input
            local valid, validation_err = validateDocumentInput(data, true)
            if not valid then
                return apiResponse(400, nil, validation_err)
            end

            -- Handle file upload if new file provided
            if file and type(file) == "table" and file.content then
                local url, metadata, upload_err = handleFileUpload(file, "documents")

                if not url then
                    return apiResponse(400, nil, upload_err)
                end

                data._uploaded_url = url
                data._file_metadata = metadata

                -- Delete old file if exists
                if self.document.cover_image then
                    local deleted, del_err = Global.deleteFromMinio(self.document.cover_image)
                    if not deleted then
                        ngx.log(ngx.WARN, "[Documents] Failed to delete old file: ", del_err)
                    end
                end
            end

            -- Store internal_id for update
            data.internal_id = self.document.internal_id

            -- Update document
            local result = DocumentQueries.update(tostring(self.params.id), data)

            if not result or not result.data then
                return apiResponse(500, nil, "Failed to update document")
            end

            return apiResponse(200, result.data, "Document updated successfully")
        end,

        -- DELETE /api/v2/documents/:id - Delete document
        DELETE = function(self)
            if not self.document then
                return apiResponse(404, nil, "Document not found")
            end

            -- Delete associated file from MinIO
            if self.document.cover_image then
                local deleted, del_err = Global.deleteFromMinio(self.document.cover_image)
                if not deleted then
                    ngx.log(ngx.WARN, "[Documents] Failed to delete file from MinIO: ", del_err)
                end
            end

            -- Delete document record
            local result = DocumentQueries.destroy(tostring(self.params.id))

            if not result then
                return apiResponse(500, nil, "Failed to delete document")
            end

            return apiResponse(200, nil, "Document deleted successfully")
        end
    }))

    -- POST /api/v2/documents/upload - Standalone file upload
    app:post("/api/v2/documents/upload", AuthMiddleware.requireAuth(function(self)
        local file = self.params.file or self.params.image or self.params.cover_image

        if not file then
            return apiResponse(400, nil, "No file uploaded")
        end

        if type(file) ~= "table" or not file.content then
            return apiResponse(400, nil, "Invalid file format")
        end

        -- Determine prefix from query param or default
        local prefix = self.params.prefix or "uploads"

        local url, metadata, upload_err = handleFileUpload(file, prefix)

        if not url then
            return apiResponse(400, nil, upload_err)
        end

        return apiResponse(200, {
            url = url,
            filename = file.filename,
            content_type = metadata and metadata.content_type,
            size = metadata and metadata.size,
            key = metadata and metadata.key
        }, "File uploaded successfully")
    end))

    -- GET /api/v2/documents/presigned/:key - Get presigned URL for file
    app:get("/api/v2/documents/presigned/(.*)", AuthMiddleware.requireAuth(function(self)
        local object_key = self.params.splat

        if not object_key or object_key == "" then
            return apiResponse(400, nil, "Object key is required")
        end

        -- URL decode the key
        object_key = ngx.unescape_uri(object_key)

        local expires_in = tonumber(self.params.expires) or 3600  -- Default 1 hour

        local presigned_url, err = Global.getMinioPresignedUrl(object_key, expires_in)

        if not presigned_url then
            return apiResponse(500, nil, "Failed to generate presigned URL: " .. (err or "Unknown error"))
        end

        return apiResponse(200, {
            url = presigned_url,
            expires_in = expires_in
        })
    end))
end
