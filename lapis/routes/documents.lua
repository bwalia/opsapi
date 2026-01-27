--[[
    Document Management Routes
    ==========================

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.

    API endpoints for managing documents with direct MinIO/S3 file uploads.

    Features:
    - Direct file upload to MinIO (no intermediate Node.js service)
    - Dynamic bucket selection from frontend (with whitelist validation)
    - File type and size validation (configurable per bucket)
    - Tag management
    - Pagination and filtering
    - Secure file deletion
    - Namespace-aware uploads (files organized by user/namespace)

    Endpoints:
    - GET    /api/v2/documents              - List documents with pagination
    - POST   /api/v2/documents              - Create document with file upload
    - GET    /api/v2/documents/:id          - Get single document
    - PUT    /api/v2/documents/:id          - Update document
    - DELETE /api/v2/documents/:id          - Delete document
    - DELETE /api/v2/documents              - Bulk delete documents
    - GET    /api/v2/all-documents          - Get all documents (no pagination)
    - POST   /api/v2/documents/upload       - Standalone file upload (supports bucket param)
    - GET    /api/v2/documents/presigned/*  - Get presigned URL for file
    - GET    /api/v2/documents/buckets      - Get list of allowed buckets

    Environment Variables:
    - MINIO_BUCKET: Default bucket name
    - MINIO_ALLOWED_BUCKETS: Comma-separated list of allowed bucket names (optional)
    - MINIO_MAX_FILE_SIZE: Maximum file size in bytes (default: 10MB)
]]

local respond_to = require("lapis.application").respond_to
local DocumentQueries = require("queries.DocumentQueries")
local Global = require("helper.global")
local MinioClient = require("helper.minio")
local AuthMiddleware = require("middleware.auth")

-- ============================================
-- Configuration
-- ============================================

-- Default max file size (10MB)
local DEFAULT_MAX_FILE_SIZE = 10 * 1024 * 1024

-- Get max file size from environment or use default
local function getMaxFileSize()
    local env_size = Global.getEnvVar("MINIO_MAX_FILE_SIZE")
    if env_size then
        local size = tonumber(env_size)
        if size and size > 0 then
            return size
        end
    end
    return DEFAULT_MAX_FILE_SIZE
end

-- File category configurations with allowed MIME types
local FILE_CATEGORIES = {
    image = {
        mime_types = {
            "image/jpeg", "image/png", "image/gif", "image/webp",
            "image/svg+xml", "image/bmp", "image/tiff", "image/heic", "image/heif"
        },
        max_size = 10 * 1024 * 1024, -- 10MB for images
        description = "Image files (JPEG, PNG, GIF, WebP, SVG, etc.)"
    },
    document = {
        mime_types = {
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "text/plain", "text/csv"
        },
        max_size = 25 * 1024 * 1024, -- 25MB for documents
        description = "Document files (PDF, Word, Excel, PowerPoint, etc.)"
    },
    archive = {
        mime_types = {
            "application/zip", "application/x-rar-compressed",
            "application/x-7z-compressed", "application/gzip", "application/x-tar"
        },
        max_size = 50 * 1024 * 1024, -- 50MB for archives
        description = "Archive files (ZIP, RAR, 7z, etc.)"
    },
    audio = {
        mime_types = {
            "audio/mpeg", "audio/wav", "audio/ogg", "audio/flac", "audio/aac"
        },
        max_size = 50 * 1024 * 1024, -- 50MB for audio
        description = "Audio files (MP3, WAV, OGG, etc.)"
    },
    video = {
        mime_types = {
            "video/mp4", "video/webm", "video/ogg", "video/quicktime", "video/x-msvideo"
        },
        max_size = 100 * 1024 * 1024, -- 100MB for video
        description = "Video files (MP4, WebM, etc.)"
    },
    any = {
        mime_types = nil,            -- Allow any
        max_size = 50 * 1024 * 1024, -- 50MB default
        description = "Any file type"
    }
}

-- Bucket configurations (can be extended via environment)
-- Format: bucket_name -> { allowed_categories, max_size, description }
local function getBucketConfigs()
    local default_bucket = Global.getEnvVar("MINIO_BUCKET") or "opsapi"

    -- Base bucket configurations
    local configs = {
        [default_bucket] = {
            allowed_categories = { "image", "document" },
            max_size = getMaxFileSize(),
            description = "Default bucket for general uploads",
            is_default = true
        },
        ["documents"] = {
            allowed_categories = { "document", "image" },
            max_size = 25 * 1024 * 1024,
            description = "Documents and related images"
        },
        ["avatars"] = {
            allowed_categories = { "image" },
            max_size = 5 * 1024 * 1024,
            description = "User profile avatars"
        },
        ["attachments"] = {
            allowed_categories = { "image", "document", "archive" },
            max_size = 50 * 1024 * 1024,
            description = "Email and chat attachments"
        },
        ["media"] = {
            allowed_categories = { "image", "audio", "video" },
            max_size = 100 * 1024 * 1024,
            description = "Media files"
        },
        ["backups"] = {
            allowed_categories = { "archive", "document" },
            max_size = 500 * 1024 * 1024,
            description = "Backup archives"
        },
        ["temp"] = {
            allowed_categories = { "any" },
            max_size = 50 * 1024 * 1024,
            description = "Temporary uploads (auto-cleaned)"
        }
    }

    -- Add additional buckets from environment variable
    -- Format: MINIO_ALLOWED_BUCKETS=bucket1,bucket2,bucket3
    local allowed_buckets_env = Global.getEnvVar("MINIO_ALLOWED_BUCKETS")
    if allowed_buckets_env then
        for bucket in allowed_buckets_env:gmatch("[^,]+") do
            bucket = bucket:match("^%s*(.-)%s*$") -- trim whitespace
            if bucket and bucket ~= "" and not configs[bucket] then
                configs[bucket] = {
                    allowed_categories = { "image", "document" },
                    max_size = getMaxFileSize(),
                    description = "Custom bucket: " .. bucket
                }
            end
        end
    end

    return configs
end

-- ============================================
-- Helper Functions
-- ============================================

--- Format file size for display
local function formatFileSize(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    end
end

--- Get the default bucket name
local function getDefaultBucket()
    return Global.getEnvVar("MINIO_BUCKET") or "opsapi"
end

--- Validate bucket name and check if it's allowed
--- @param bucket_name string The bucket name to validate
--- @return boolean, string|table Success status and error message or bucket config
local function validateBucket(bucket_name)
    if not bucket_name or bucket_name == "" then
        return false, "Bucket name is required"
    end

    -- Validate bucket name format (S3 bucket naming rules)
    if not bucket_name:match("^[a-z0-9][a-z0-9%-]*[a-z0-9]$") and
        not bucket_name:match("^[a-z0-9]$") then
        -- Check for invalid characters
        if bucket_name:match("[^a-z0-9%-]") then
            return false, "Bucket name can only contain lowercase letters, numbers, and hyphens"
        end
        if bucket_name:match("^%-") or bucket_name:match("%-$") then
            return false, "Bucket name cannot start or end with a hyphen"
        end
    end

    if #bucket_name < 3 or #bucket_name > 63 then
        return false, "Bucket name must be between 3 and 63 characters"
    end

    -- Check if bucket is in whitelist
    local bucket_configs = getBucketConfigs()
    local config = bucket_configs[bucket_name]

    if not config then
        return false, string.format("Bucket '%s' is not in the allowed list", bucket_name)
    end

    return true, config
end

--- Validate file against bucket configuration
--- @param file table The file object
--- @param bucket_config table The bucket configuration
--- @return boolean, string Success status and error message
local function validateFileForBucket(file, bucket_config)
    if not file or not file.content then
        return false, "No file provided"
    end

    local file_size = #file.content

    -- Check file size
    if file_size > bucket_config.max_size then
        return false, string.format(
            "File size (%s) exceeds maximum allowed (%s) for this bucket",
            formatFileSize(file_size),
            formatFileSize(bucket_config.max_size)
        )
    end

    -- Get content type
    local content_type = file.content_type
    if not content_type and file.filename then
        local minio = MinioClient.getDefault()
        content_type = minio:getContentType(file.filename)
    end
    content_type = content_type or "application/octet-stream"

    -- Check allowed categories
    local allowed_categories = bucket_config.allowed_categories
    if allowed_categories then
        local category_allowed = false

        for _, category in ipairs(allowed_categories) do
            if category == "any" then
                category_allowed = true
                break
            end

            local cat_config = FILE_CATEGORIES[category]
            if cat_config and cat_config.mime_types then
                for _, mime in ipairs(cat_config.mime_types) do
                    if mime == content_type then
                        category_allowed = true
                        break
                    end
                end
            end

            if category_allowed then break end
        end

        if not category_allowed then
            local allowed_types = {}
            for _, cat in ipairs(allowed_categories) do
                table.insert(allowed_types, cat)
            end
            return false, string.format(
                "File type '%s' is not allowed in this bucket. Allowed categories: %s",
                content_type,
                table.concat(allowed_types, ", ")
            )
        end
    end

    return true, ""
end

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

--- Handle file upload with bucket support
--- @param file table File object
--- @param options table Upload options { bucket?, prefix?, user_uuid?, namespace_uuid? }
--- @return string|nil URL
--- @return table|nil Metadata
--- @return string|nil Error
local function handleFileUpload(file, options)
    options = options or {}

    if not file then
        return nil, nil, "No file provided"
    end

    if not file.content or file.content == "" then
        return nil, nil, "File content is empty"
    end

    -- Determine bucket (from options or default)
    local bucket = options.bucket or getDefaultBucket()

    -- Validate bucket
    local bucket_valid, bucket_result = validateBucket(bucket)
    if not bucket_valid then
        ---@cast bucket_result string
        return nil, nil, bucket_result
    end

    ---@cast bucket_result table
    local bucket_config = bucket_result

    -- Validate file for this bucket
    local file_valid, file_err = validateFileForBucket(file, bucket_config)
    if not file_valid then
        return nil, nil, file_err
    end

    -- Build prefix based on options
    local prefix = options.prefix or "uploads"

    -- Add user/namespace context to prefix for organization
    if options.user_uuid then
        prefix = prefix .. "/" .. options.user_uuid
    elseif options.namespace_uuid then
        prefix = prefix .. "/" .. options.namespace_uuid
    end

    -- Upload file using MinIO client
    local minio = MinioClient.getDefault()
    local url, err, metadata = minio:upload(file, {
        bucket = bucket,
        prefix = prefix,
        metadata = options.metadata
    })

    if not url then
        return nil, nil, "File upload failed: " .. (err or "Unknown error")
    end

    -- Add bucket info to metadata
    if metadata then
        metadata.bucket = bucket
    end

    return url, metadata, nil
end

return function(app)
    ----------------- Document Routes --------------------

    -- GET /api/v2/documents/buckets - Get list of allowed buckets
    app:get("/api/v2/documents/buckets", AuthMiddleware.requireAuth(function(self)
        local bucket_configs = getBucketConfigs()
        local buckets = {}

        for name, config in pairs(bucket_configs) do
            table.insert(buckets, {
                name = name,
                description = config.description,
                max_size = config.max_size,
                max_size_formatted = formatFileSize(config.max_size),
                allowed_categories = config.allowed_categories,
                is_default = config.is_default or false
            })
        end

        -- Sort by name, but put default first
        table.sort(buckets, function(a, b)
            if a.is_default then return true end
            if b.is_default then return false end
            return a.name < b.name
        end)

        return apiResponse(200, buckets, nil, {
            total = #buckets,
            default_bucket = getDefaultBucket()
        })
    end))

    -- GET /api/v2/documents/categories - Get list of file categories
    app:get("/api/v2/documents/categories", AuthMiddleware.requireAuth(function(self)
        local categories = {}

        for name, config in pairs(FILE_CATEGORIES) do
            table.insert(categories, {
                name = name,
                description = config.description,
                max_size = config.max_size,
                max_size_formatted = formatFileSize(config.max_size),
                mime_types = config.mime_types
            })
        end

        table.sort(categories, function(a, b) return a.name < b.name end)

        return apiResponse(200, categories)
    end))

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

            -- Validate file is provided
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
                local bucket = data.bucket or getDefaultBucket()

                local url, metadata, upload_err = handleFileUpload(file, {
                    bucket = bucket,
                    prefix = "documents",
                    user_uuid = self.current_user and self.current_user.uuid
                })

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

    -- POST /api/v2/documents/upload - Standalone file upload with bucket support
    --
    -- Request body (multipart/form-data):
    --   - file/image/cover_image: The file to upload
    --   - bucket: (optional) Target bucket name (must be in whitelist)
    --   - prefix: (optional) Path prefix within bucket (default: "uploads")
    --   - category: (optional) File category hint for validation
    --
    -- Response:
    --   - url: Public URL of uploaded file
    --   - filename: Original filename
    --   - content_type: MIME type
    --   - size: File size in bytes
    --   - size_formatted: Human-readable file size
    --   - key: Object key in bucket
    --   - bucket: Bucket name where file was stored
    --
    app:post("/api/v2/documents/upload", AuthMiddleware.requireAuth(function(self)
        local file = self.params.file or self.params.image or self.params.cover_image

        if not file then
            return apiResponse(400, nil, "No file uploaded. Use 'file', 'image', or 'cover_image' field.")
        end

        if type(file) ~= "table" or not file.content then
            return apiResponse(400, nil, "Invalid file format")
        end

        -- Get bucket from request (default to environment bucket)
        local bucket = self.params.bucket
        if bucket and bucket ~= "" then
            -- Validate bucket if specified
            local bucket_valid, bucket_err = validateBucket(bucket)
            if not bucket_valid then
                return apiResponse(400, nil, bucket_err)
            end
        else
            bucket = getDefaultBucket()
        end

        -- Determine prefix from query param or default
        local prefix = self.params.prefix or "uploads"

        -- Build upload options
        local upload_options = {
            bucket = bucket,
            prefix = prefix,
            user_uuid = self.current_user and self.current_user.uuid,
            namespace_uuid = self.current_user and self.current_user.namespace and self.current_user.namespace.uuid
        }

        local url, metadata, upload_err = handleFileUpload(file, upload_options)

        if not url then
            return apiResponse(400, nil, upload_err)
        end

        return apiResponse(200, {
            url = url,
            filename = file.filename,
            content_type = metadata and metadata.content_type,
            size = metadata and metadata.size,
            size_formatted = metadata and metadata.size and formatFileSize(metadata.size),
            key = metadata and metadata.key,
            bucket = bucket,
            etag = metadata and metadata.etag
        }, "File uploaded successfully")
    end))

    -- POST /api/v2/documents/upload/:bucket - Upload to specific bucket
    -- This is an alternative URL pattern for cleaner RESTful API
    app:post("/api/v2/documents/upload/:bucket_name", AuthMiddleware.requireAuth(function(self)
        local file = self.params.file or self.params.image or self.params.cover_image
        local bucket = self.params.bucket_name

        if not file then
            return apiResponse(400, nil, "No file uploaded")
        end

        if type(file) ~= "table" or not file.content then
            return apiResponse(400, nil, "Invalid file format")
        end

        -- Validate bucket
        local bucket_valid, bucket_config_or_err = validateBucket(bucket)
        if not bucket_valid then
            return apiResponse(400, nil, bucket_config_or_err)
        end

        local prefix = self.params.prefix or "uploads"

        local upload_options = {
            bucket = bucket,
            prefix = prefix,
            user_uuid = self.current_user and self.current_user.uuid,
            namespace_uuid = self.current_user and self.current_user.namespace and self.current_user.namespace.uuid
        }

        local url, metadata, upload_err = handleFileUpload(file, upload_options)

        if not url then
            return apiResponse(400, nil, upload_err)
        end

        return apiResponse(200, {
            url = url,
            filename = file.filename,
            content_type = metadata and metadata.content_type,
            size = metadata and metadata.size,
            size_formatted = metadata and metadata.size and formatFileSize(metadata.size),
            key = metadata and metadata.key,
            bucket = bucket,
            etag = metadata and metadata.etag
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

        -- Optional bucket parameter
        local bucket = self.params.bucket

        local expires_in = tonumber(self.params.expires) or 3600 -- Default 1 hour

        -- Cap expiration at 7 days for security
        if expires_in > 604800 then
            expires_in = 604800
        end

        local minio = MinioClient.getDefault()
        local presigned_url, err = minio:getPresignedUrl(object_key, expires_in, bucket)

        if not presigned_url then
            return apiResponse(500, nil, "Failed to generate presigned URL: " .. (err or "Unknown error"))
        end

        return apiResponse(200, {
            url = presigned_url,
            expires_in = expires_in,
            expires_at = os.time() + expires_in
        })
    end))
end
