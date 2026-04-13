-- Input Sanitization Module
-- Protects against XSS, SQL injection, and other injection attacks

local Sanitizer = {}

-- HTML entities for escaping
local HTML_ENTITIES = {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&#x27;",
    ["/"] = "&#x2F;",
}

-- SQL dangerous characters
local SQL_DANGEROUS_CHARS = {
    "'", '"', ";", "--", "/*", "*/", "xp_", "sp_", "0x"
}

---
-- Escape HTML special characters to prevent XSS
-- @param str string The string to escape
-- @return string The escaped string
---
function Sanitizer.escapeHTML(str)
    if not str or type(str) ~= "string" then
        return str
    end

    return (str:gsub("[&<>\"'/]", HTML_ENTITIES))
end

---
-- Remove all HTML tags from string
-- @param str string The string to strip
-- @return string String without HTML tags
---
function Sanitizer.stripHTML(str)
    if not str or type(str) ~= "string" then
        return str
    end

    -- Remove all HTML tags
    local cleaned = str:gsub("<[^>]*>", "")
    -- Remove HTML entities
    cleaned = cleaned:gsub("&[%w#]+;", "")

    return cleaned
end

---
-- Sanitize string for safe SQL usage (defense in depth)
-- Note: Should still use parameterized queries as primary defense
-- @param str string The string to sanitize
-- @return string Sanitized string
---
function Sanitizer.sanitizeSQL(str)
    if not str or type(str) ~= "string" then
        return str
    end

    -- Escape single quotes (most common SQL injection vector)
    local sanitized = str:gsub("'", "''")

    -- Remove dangerous SQL keywords in unusual positions
    sanitized = sanitized:gsub("%;%s*(%w+)", function(keyword)
        local dangerous = {"DROP", "DELETE", "INSERT", "UPDATE", "CREATE", "ALTER", "EXEC", "EXECUTE"}
        for _, danger in ipairs(dangerous) do
            if keyword:upper() == danger then
                return "; " -- Remove the keyword, keep semicolon
            end
        end
        return "; " .. keyword
    end)

    return sanitized
end

---
-- Validate and sanitize email address
-- @param email string Email address to sanitize
-- @return string|nil Sanitized email or nil if invalid
---
function Sanitizer.sanitizeEmail(email)
    if not email or type(email) ~= "string" then
        return nil
    end

    -- Convert to lowercase
    email = email:lower()

    -- Trim whitespace
    email = email:gsub("^%s*(.-)%s*$", "%1")

    -- Basic email pattern validation
    if not email:match("^[a-zA-Z0-9.!#$%%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:%.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$") then
        return nil
    end

    -- Check for common disposable email domains (optional)
    local disposable_domains = {
        "tempmail.com", "10minutemail.com", "guerrillamail.com",
        "mailinator.com", "throwaway.email", "temp-mail.org"
    }

    for _, domain in ipairs(disposable_domains) do
        if email:match("@" .. domain:gsub("%.", "%%.") .. "$") then
            return nil, "Disposable email addresses are not allowed"
        end
    end

    return email
end

---
-- Sanitize phone number to digits only
-- @param phone string Phone number to sanitize
-- @return string|nil Sanitized phone or nil if invalid
---
function Sanitizer.sanitizePhone(phone)
    if not phone or type(phone) ~= "string" then
        return nil
    end

    -- Remove all non-digit characters except + at start
    local sanitized = phone:gsub("^%+", "PLUS"):gsub("[^%d]", ""):gsub("PLUS", "+")

    -- Validate length (international numbers: 10-15 digits)
    local digits = sanitized:gsub("[^%d]", "")
    if #digits < 10 or #digits > 15 then
        return nil, "Phone number must be 10-15 digits"
    end

    return sanitized
end

---
-- Sanitize URL
-- @param url string URL to sanitize
-- @return string|nil Sanitized URL or nil if invalid
---
function Sanitizer.sanitizeURL(url)
    if not url or type(url) ~= "string" then
        return nil
    end

    -- Trim whitespace
    url = url:gsub("^%s*(.-)%s*$", "%1")

    -- Check for valid protocol
    if not url:match("^https?://") then
        return nil, "URL must start with http:// or https://"
    end

    -- Prevent javascript: and data: URIs
    if url:match("^javascript:") or url:match("^data:") then
        return nil, "Invalid URL protocol"
    end

    -- Basic URL validation
    if not url:match("^https?://[%w%-%.]+") then
        return nil, "Invalid URL format"
    end

    return url
end

---
-- Sanitize string to alphanumeric characters only
-- @param str string String to sanitize
-- @param allow_spaces boolean Whether to allow spaces (default: false)
-- @return string Sanitized string
---
function Sanitizer.sanitizeAlphanumeric(str, allow_spaces)
    if not str or type(str) ~= "string" then
        return ""
    end

    if allow_spaces then
        return str:gsub("[^%w%s]", "")
    else
        return str:gsub("[^%w]", "")
    end
end

---
-- Sanitize integer
-- @param value any Value to sanitize as integer
-- @param min number|nil Minimum allowed value
-- @param max number|nil Maximum allowed value
-- @return number|nil Sanitized integer or nil if invalid
---
function Sanitizer.sanitizeInteger(value, min, max)
    local num = tonumber(value)

    if not num then
        return nil, "Must be a number"
    end

    -- Convert to integer
    num = math.floor(num)

    -- Check bounds
    if min and num < min then
        return nil, "Must be at least " .. min
    end

    if max and num > max then
        return nil, "Must be at most " .. max
    end

    return num
end

---
-- Sanitize decimal number
-- @param value any Value to sanitize as decimal
-- @param min number|nil Minimum allowed value
-- @param max number|nil Maximum allowed value
-- @param decimals number|nil Number of decimal places (default: 2)
-- @return number|nil Sanitized decimal or nil if invalid
---
function Sanitizer.sanitizeDecimal(value, min, max, decimals)
    local num = tonumber(value)

    if not num then
        return nil, "Must be a number"
    end

    -- Round to specified decimal places
    local places = decimals or 2
    local multiplier = 10 ^ places
    num = math.floor(num * multiplier + 0.5) / multiplier

    -- Check bounds
    if min and num < min then
        return nil, "Must be at least " .. min
    end

    if max and num > max then
        return nil, "Must be at most " .. max
    end

    return num
end

---
-- Sanitize slug (URL-friendly string)
-- @param str string String to convert to slug
-- @return string Sanitized slug
---
function Sanitizer.sanitizeSlug(str)
    if not str or type(str) ~= "string" then
        return ""
    end

    -- Convert to lowercase
    local slug = str:lower()

    -- Remove accents/diacritics (basic version)
    slug = slug:gsub("[áàâãä]", "a")
    slug = slug:gsub("[éèêë]", "e")
    slug = slug:gsub("[íìîï]", "i")
    slug = slug:gsub("[óòôõö]", "o")
    slug = slug:gsub("[úùûü]", "u")

    -- Replace spaces and special chars with hyphens
    slug = slug:gsub("[^%w]", "-")

    -- Remove multiple consecutive hyphens
    slug = slug:gsub("%-+", "-")

    -- Trim hyphens from start and end
    slug = slug:gsub("^%-+", ""):gsub("%-+$", "")

    return slug
end

---
-- Sanitize JSON string
-- @param str string JSON string to validate
-- @return table|nil Parsed JSON or nil if invalid
---
function Sanitizer.sanitizeJSON(str)
    if not str or type(str) ~= "string" then
        return nil, "Invalid JSON"
    end

    local success, result = pcall(function()
        return require("cjson").decode(str)
    end)

    if not success then
        return nil, "Invalid JSON format"
    end

    return result
end

---
-- Sanitize and validate date string (YYYY-MM-DD)
-- @param date_str string Date string to validate
-- @return string|nil Sanitized date or nil if invalid
---
function Sanitizer.sanitizeDate(date_str)
    if not date_str or type(date_str) ~= "string" then
        return nil, "Invalid date"
    end

    -- Match YYYY-MM-DD format
    local year, month, day = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")

    if not year or not month or not day then
        return nil, "Date must be in YYYY-MM-DD format"
    end

    -- Validate ranges
    year = tonumber(year)
    month = tonumber(month)
    day = tonumber(day)

    if year < 1900 or year > 2100 then
        return nil, "Invalid year"
    end

    if month < 1 or month > 12 then
        return nil, "Invalid month"
    end

    if day < 1 or day > 31 then
        return nil, "Invalid day"
    end

    -- Check valid days in month (simplified)
    local days_in_month = {31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if day > days_in_month[month] then
        return nil, "Invalid day for month"
    end

    return date_str
end

---
-- Sanitize text input (general purpose)
-- Removes dangerous content while preserving readability
-- @param text string Text to sanitize
-- @param max_length number|nil Maximum allowed length
-- @return string Sanitized text
---
function Sanitizer.sanitizeText(text, max_length)
    if not text or type(text) ~= "string" then
        return ""
    end

    -- Trim whitespace
    text = text:gsub("^%s*(.-)%s*$", "%1")

    -- Remove null bytes
    text = text:gsub("%z", "")

    -- Escape HTML to prevent XSS
    text = Sanitizer.escapeHTML(text)

    -- Truncate if needed
    if max_length and #text > max_length then
        text = text:sub(1, max_length)
    end

    return text
end

---
-- Sanitize object by applying sanitizers to each field
-- @param data table Object to sanitize
-- @param schema table Schema defining sanitization rules
-- @return table Sanitized object
-- @return table|nil Errors if any
---
function Sanitizer.sanitizeObject(data, schema)
    local sanitized = {}
    local errors = {}

    for field, rules in pairs(schema) do
        local value = data[field]
        local sanitizer_func = rules.sanitizer
        local required = rules.required or false

        -- Check required fields
        if required and (value == nil or value == "") then
            errors[field] = "Field is required"
        else
            if value ~= nil and sanitizer_func then
                local result, err = sanitizer_func(value)
                if result == nil and err then
                    errors[field] = err
                else
                    sanitized[field] = result
                end
            else
                sanitized[field] = value
            end
        end
    end

    if next(errors) then
        return nil, errors
    end

    return sanitized
end

return Sanitizer
