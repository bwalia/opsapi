-- Centralized Error Handler for Lapis API
-- Provides consistent error responses and logging

local cjson = require("cjson")

local ErrorHandler = {}

-- Error codes and messages
ErrorHandler.ERRORS = {
    -- Authentication Errors (1xx)
    UNAUTHORIZED = { code = 101, message = "Authentication required", status = 401 },
    INVALID_TOKEN = { code = 102, message = "Invalid or expired token", status = 401 },
    FORBIDDEN = { code = 103, message = "Insufficient permissions", status = 403 },

    -- Validation Errors (2xx)
    VALIDATION_FAILED = { code = 201, message = "Validation failed", status = 400 },
    MISSING_REQUIRED_FIELD = { code = 202, message = "Required field missing", status = 400 },
    INVALID_FORMAT = { code = 203, message = "Invalid data format", status = 400 },
    INVALID_EMAIL = { code = 204, message = "Invalid email format", status = 400 },
    INVALID_PHONE = { code = 205, message = "Invalid phone number format", status = 400 },

    -- Resource Errors (3xx)
    NOT_FOUND = { code = 301, message = "Resource not found", status = 404 },
    ALREADY_EXISTS = { code = 302, message = "Resource already exists", status = 409 },
    CONFLICT = { code = 303, message = "Resource conflict", status = 409 },

    -- Business Logic Errors (4xx)
    INSUFFICIENT_STOCK = { code = 401, message = "Insufficient stock", status = 400 },
    CART_EMPTY = { code = 402, message = "Cart is empty", status = 400 },
    PAYMENT_FAILED = { code = 403, message = "Payment processing failed", status = 402 },
    ORDER_INVALID_STATUS = { code = 404, message = "Invalid order status transition", status = 400 },
    STORE_NOT_VERIFIED = { code = 405, message = "Store not verified", status = 403 },

    -- System Errors (5xx)
    INTERNAL_ERROR = { code = 501, message = "Internal server error", status = 500 },
    DATABASE_ERROR = { code = 502, message = "Database operation failed", status = 500 },
    EXTERNAL_API_ERROR = { code = 503, message = "External service unavailable", status = 503 },
}

-- Sanitize error message to prevent sensitive data leakage
function ErrorHandler.sanitizeMessage(message, include_details)
    if not include_details then
        -- In production, don't expose internal details
        return nil
    end

    -- Remove sensitive patterns
    local sanitized = message
    sanitized = sanitized:gsub("password[%s]*=%s*[^%s,]+", "password=***")
    sanitized = sanitized:gsub("token[%s]*=%s*[^%s,]+", "token=***")
    sanitized = sanitized:gsub("secret[%s]*=%s*[^%s,]+", "secret=***")
    sanitized = sanitized:gsub("api[_%-]?key[%s]*=%s*[^%s,]+", "api_key=***")

    return sanitized
end

-- Log error with appropriate level
function ErrorHandler.logError(error_type, message, context)
    local log_entry = {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        error_type = error_type,
        message = message,
        context = context or {}
    }

    -- Use nginx logging
    if error_type.status >= 500 then
        ngx.log(ngx.ERR, "[ERROR] ", cjson.encode(log_entry))
    elseif error_type.status >= 400 then
        ngx.log(ngx.WARN, "[WARN] ", cjson.encode(log_entry))
    else
        ngx.log(ngx.INFO, "[INFO] ", cjson.encode(log_entry))
    end
end

-- Create standardized error response
function ErrorHandler.createErrorResponse(error_type, details, field)
    local response = {
        error = {
            code = error_type.code,
            message = error_type.message,
        }
    }

    -- Add details if provided (only in development)
    local env = os.getenv("LAPIS_ENVIRONMENT") or "development"
    if details and env == "development" then
        response.error.details = ErrorHandler.sanitizeMessage(details, true)
    end

    -- Add field name for validation errors
    if field then
        response.error.field = field
    end

    -- Add timestamp
    response.error.timestamp = os.date("%Y-%m-%dT%H:%M:%S")

    return { json = response, status = error_type.status }
end

-- Handle validation errors
function ErrorHandler.validationError(field, message)
    ErrorHandler.logError(ErrorHandler.ERRORS.VALIDATION_FAILED, message, { field = field })
    return ErrorHandler.createErrorResponse(
        ErrorHandler.ERRORS.VALIDATION_FAILED,
        message,
        field
    )
end

-- Handle not found errors
function ErrorHandler.notFound(resource_type)
    local error = ErrorHandler.ERRORS.NOT_FOUND
    error.message = (resource_type or "Resource") .. " not found"
    ErrorHandler.logError(error, error.message, { resource = resource_type })
    return ErrorHandler.createErrorResponse(error)
end

-- Handle unauthorized errors
function ErrorHandler.unauthorized(message)
    local details = message or "Authentication required"
    ErrorHandler.logError(ErrorHandler.ERRORS.UNAUTHORIZED, details)
    return ErrorHandler.createErrorResponse(ErrorHandler.ERRORS.UNAUTHORIZED, details)
end

-- Handle forbidden errors
function ErrorHandler.forbidden(message)
    local details = message or "Insufficient permissions"
    ErrorHandler.logError(ErrorHandler.ERRORS.FORBIDDEN, details)
    return ErrorHandler.createErrorResponse(ErrorHandler.ERRORS.FORBIDDEN, details)
end

-- Handle internal errors with proper logging
function ErrorHandler.internalError(error_message, context)
    ErrorHandler.logError(ErrorHandler.ERRORS.INTERNAL_ERROR, error_message, context)
    return ErrorHandler.createErrorResponse(ErrorHandler.ERRORS.INTERNAL_ERROR, error_message)
end

-- Handle database errors
function ErrorHandler.databaseError(operation, error_message)
    local context = { operation = operation, error = error_message }
    ErrorHandler.logError(ErrorHandler.ERRORS.DATABASE_ERROR, error_message, context)
    return ErrorHandler.createErrorResponse(ErrorHandler.ERRORS.DATABASE_ERROR, error_message)
end

-- Wrap function with error handling
function ErrorHandler.wrap(handler)
    return function(self)
        local success, result = pcall(handler, self)

        if not success then
            -- Log the error
            ngx.log(ngx.ERR, "[UNCAUGHT ERROR] ", tostring(result))

            -- Return standardized error
            return ErrorHandler.internalError(tostring(result))
        end

        return result
    end
end

-- Validate required fields
function ErrorHandler.validateRequired(params, required_fields)
    for _, field in ipairs(required_fields) do
        if not params[field] or params[field] == "" then
            return false, ErrorHandler.validationError(field, "Field '" .. field .. "' is required")
        end
    end
    return true, nil
end

-- Validate email format
function ErrorHandler.validateEmail(email)
    if not email or email == "" then
        return false, ErrorHandler.validationError("email", "Email is required")
    end

    -- RFC 5322 compliant email regex
    local pattern = "^[a-zA-Z0-9.!#$%%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:%.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$"

    if not email:match(pattern) then
        return false, ErrorHandler.createErrorResponse(ErrorHandler.ERRORS.INVALID_EMAIL)
    end

    return true, nil
end

-- Validate UUID format
function ErrorHandler.validateUUID(uuid, field_name)
    if not uuid or uuid == "" then
        return false, ErrorHandler.validationError(field_name or "uuid", "UUID is required")
    end

    -- UUID v4 pattern
    local pattern = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

    if not uuid:match(pattern) then
        return false, ErrorHandler.validationError(field_name or "uuid", "Invalid UUID format")
    end

    return true, nil
end

-- Validate positive number
function ErrorHandler.validatePositiveNumber(value, field_name)
    local num = tonumber(value)
    if not num or num <= 0 then
        return false, ErrorHandler.validationError(field_name, "Must be a positive number")
    end
    return true, nil
end

-- Validate string length
function ErrorHandler.validateLength(value, field_name, min, max)
    if not value then
        return false, ErrorHandler.validationError(field_name, "Field is required")
    end

    local len = string.len(value)
    if min and len < min then
        return false, ErrorHandler.validationError(field_name, "Minimum length is " .. min)
    end
    if max and len > max then
        return false, ErrorHandler.validationError(field_name, "Maximum length is " .. max)
    end

    return true, nil
end

-- Validate enum values
function ErrorHandler.validateEnum(value, field_name, allowed_values)
    if not value then
        return false, ErrorHandler.validationError(field_name, "Field is required")
    end

    for _, allowed in ipairs(allowed_values) do
        if value == allowed then
            return true, nil
        end
    end

    return false, ErrorHandler.validationError(
        field_name,
        "Invalid value. Allowed: " .. table.concat(allowed_values, ", ")
    )
end

return ErrorHandler
