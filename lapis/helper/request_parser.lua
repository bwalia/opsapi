-- Request Parser Helper
-- Utility functions for parsing HTTP request data

local cjson = require "cjson"

local RequestParser = {}

---
-- Reconstruct nested objects from flat form-urlencoded keys
-- Converts keys like "permissions[dashboard][0]" back to nested tables
-- @param flat_params The flat parameters from ngx.req.get_post_args()
-- @return params Reconstructed nested parameters
local function reconstruct_nested_params(flat_params)
    local params = {}
    local nested_keys = {} -- Track which base keys have nested data

    for k, v in pairs(flat_params) do
        -- Check if this is a nested key like "permissions[dashboard][0]"
        local base_key = k:match("^([^%[]+)%[")

        if base_key then
            -- This is a nested key - mark it for later processing
            nested_keys[base_key] = nested_keys[base_key] or {}

            -- Parse all bracket contents: "permissions[dashboard][0]" -> {"dashboard", "0"}
            local path = {}
            for part in k:gmatch("%[([^%]]+)%]") do
                table.insert(path, part)
            end

            -- Build the nested structure
            local current = nested_keys[base_key]
            for i = 1, #path - 1 do
                local key = path[i]
                -- Convert numeric strings to numbers for array indices
                local idx = tonumber(key)
                if idx ~= nil then
                    key = idx + 1 -- Lua arrays are 1-indexed
                end
                current[key] = current[key] or {}
                current = current[key]
            end

            -- Set the final value
            local final_key = path[#path]
            local idx = tonumber(final_key)
            if idx ~= nil then
                final_key = idx + 1 -- Lua arrays are 1-indexed
            end
            current[final_key] = v
        else
            -- Regular key - check if value looks like JSON
            if type(v) == "string" and (v:match("^%s*{") or v:match("^%s*%[")) then
                local ok, json_val = pcall(cjson.decode, v)
                if ok then
                    params[k] = json_val
                else
                    params[k] = v
                end
            else
                params[k] = v
            end
        end
    end

    -- Convert nested arrays from {[1]="a", [2]="b"} to {"a", "b"}
    local function convert_to_array_if_needed(tbl)
        if type(tbl) ~= "table" then
            return tbl
        end

        -- Check if all keys are sequential integers starting from 1
        local is_array = true
        local max_idx = 0
        local has_numeric = false

        for k, _ in pairs(tbl) do
            if type(k) == "number" then
                has_numeric = true
                if k > max_idx then
                    max_idx = k
                end
            else
                is_array = false
            end
        end

        -- Recursively convert nested tables
        for k, v in pairs(tbl) do
            tbl[k] = convert_to_array_if_needed(v)
        end

        -- If it's an array-like table with numeric keys, convert to proper array
        if is_array and has_numeric then
            local arr = {}
            for i = 1, max_idx do
                if tbl[i] ~= nil then
                    table.insert(arr, tbl[i])
                end
            end
            return arr
        end

        return tbl
    end

    -- Merge nested keys into params
    for base_key, nested_val in pairs(nested_keys) do
        params[base_key] = convert_to_array_if_needed(nested_val)
    end

    return params
end

---
-- Parse request body and return params and files
-- Handles both JSON and form-urlencoded data
-- @param self The Lapis request context
-- @return params, files
function RequestParser.parse_request(self)
    local params = {}
    local files = {}

    -- Copy URL params first
    if self.params then
        for k, v in pairs(self.params) do
            params[k] = v
        end
    end

    local content_type = self.req.headers["content-type"] or ""

    -- Handle JSON content type
    if content_type:match("application/json") then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body and body ~= "" then
            local ok, json_data = pcall(cjson.decode, body)
            if ok and type(json_data) == "table" then
                for k, v in pairs(json_data) do
                    params[k] = v
                end
            end
        end
    -- Handle multipart form data
    elseif content_type:match("multipart/form%-data") then
        ngx.req.read_body()
        local post_args = ngx.req.get_post_args()
        if post_args then
            local reconstructed = reconstruct_nested_params(post_args)
            for k, v in pairs(reconstructed) do
                params[k] = v
            end
        end
        -- TODO: Handle file uploads if needed
    -- Handle form-urlencoded (default for Lapis)
    else
        ngx.req.read_body()
        local post_args = ngx.req.get_post_args()
        if post_args then
            local reconstructed = reconstruct_nested_params(post_args)
            for k, v in pairs(reconstructed) do
                params[k] = v
            end
        end
    end

    return params, files
end

---
-- Validate that required parameters are present
-- @param params The parameters table
-- @param required_fields Array of required field names
-- @return is_valid, missing_fields
function RequestParser.require_params(params, required_fields)
    local missing = {}

    for _, field in ipairs(required_fields) do
        if params[field] == nil or params[field] == "" then
            table.insert(missing, field)
        end
    end

    return #missing == 0, missing
end

---
-- Get a parameter with a default value
-- @param params The parameters table
-- @param key The parameter key
-- @param default The default value if not found
-- @return The parameter value or default
function RequestParser.get_param(params, key, default)
    if params[key] ~= nil and params[key] ~= "" then
        return params[key]
    end
    return default
end

---
-- Get an integer parameter with bounds checking
-- @param params The parameters table
-- @param key The parameter key
-- @param default The default value
-- @param min Minimum allowed value (optional)
-- @param max Maximum allowed value (optional)
-- @return The integer value
function RequestParser.get_int_param(params, key, default, min, max)
    local value = tonumber(params[key])
    if value == nil then
        return default
    end

    if min and value < min then
        value = min
    end

    if max and value > max then
        value = max
    end

    return math.floor(value)
end

---
-- Get pagination parameters
-- @param params The parameters table
-- @return limit, offset
function RequestParser.get_pagination(params)
    local limit = RequestParser.get_int_param(params, "limit", 10, 1, 100)
    local offset = RequestParser.get_int_param(params, "offset", 0, 0)

    -- Also support page-based pagination
    local page = tonumber(params.page)
    if page and page > 0 then
        offset = (page - 1) * limit
    end

    return limit, offset
end

---
-- Get sorting parameters
-- @param params The parameters table
-- @param default_field Default sort field
-- @param allowed_fields Table of allowed field names
-- @return sort_field, sort_direction
function RequestParser.get_sorting(params, default_field, allowed_fields)
    local sort_field = params.sort_by or params.order_by or default_field
    local sort_dir = (params.sort_dir or params.order_dir or "asc"):lower()

    -- Validate sort direction
    if sort_dir ~= "asc" and sort_dir ~= "desc" then
        sort_dir = "asc"
    end

    -- Validate sort field if allowed_fields provided
    if allowed_fields then
        local is_allowed = false
        for _, field in ipairs(allowed_fields) do
            if field == sort_field then
                is_allowed = true
                break
            end
        end
        if not is_allowed then
            sort_field = default_field
        end
    end

    return sort_field, sort_dir
end

return RequestParser
