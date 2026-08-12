--[[
    CMS HTTP helpers
    ================
    Shared request/response utilities for the CMS routes (posts, pages,
    taxonomy). Kept small and dependency-light; mirrors the inline helpers in
    routes/academy.lua but factored out so the three CMS route files agree.
]]

local cJson = require("cjson")
local NamespaceQueries = require "queries.NamespaceQueries"

local CmsHttp = {}

--- Parse a JSON or form-encoded body into a table.
--- Large bodies (a post's rich content_html) exceed client_body_buffer_size, so
--- nginx spills them to a temp file — in that case get_body_data() is empty and
--- we read the body file ourselves. JSON is tried first, then urlencoded.
function CmsHttp.parse_body()
    ngx.req.read_body()

    local ctype = ngx.var.content_type or ""
    local is_json = ctype:find("application/json", 1, true) ~= nil

    if not is_json then
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then return post_args end
    end

    local body = ngx.req.get_body_data()
    if not body or body == "" then
        local path = ngx.req.get_body_file()
        if path then
            local f = io.open(path, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end
    if not body or body == "" then return {} end

    local ok, decoded = pcall(cJson.decode, body)
    if ok and type(decoded) == "table" then return decoded end

    local args = ngx.decode_args(body)
    if type(args) == "table" then return args end
    return {}
end

--- House response shape: { success, data } or { success=false, error }.
function CmsHttp.api_response(status, data, error_msg)
    if error_msg then
        return { status = status, json = { success = false, error = error_msg } }
    end
    return { status = status, json = { success = true, data = data } }
end

--- Coerce loose truthy values (forms send strings).
function CmsHttp.to_bool(v, default)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    local s = tostring(v):lower()
    return s == "true" or s == "1" or s == "yes" or s == "on"
end

--- Normalise a tag list from any transport into a clean Lua array of strings.
--- Accepts a real JSON array, a JSON-array string, a comma-separated string, or
--- a single string. Each entry is trimmed and capped at 60 chars; empties and
--- duplicates (case-insensitive) are dropped.
function CmsHttp.coerce_list(v)
    if v == nil then return nil end
    local raw = {}
    if type(v) == "table" then
        for _, item in ipairs(v) do raw[#raw + 1] = item end
    elseif type(v) == "string" then
        local s = v:gsub("^%s+", ""):gsub("%s+$", "")
        if s == "" then return {} end
        if s:sub(1, 1) == "[" then
            local ok, decoded = pcall(cJson.decode, s)
            if ok and type(decoded) == "table" then
                for _, item in ipairs(decoded) do raw[#raw + 1] = item end
            end
        else
            for part in s:gmatch("[^,]+") do raw[#raw + 1] = part end
        end
    else
        return {}
    end

    local out, seen = {}, {}
    for _, item in ipairs(raw) do
        local str = tostring(item):gsub("^%s+", ""):gsub("%s+$", "")
        if #str > 60 then str = str:sub(1, 60) end
        local key = str:lower()
        if str ~= "" and not seen[key] then
            seen[key] = true
            out[#out + 1] = str
        end
    end
    return out
end

--- Resolve the public namespace from :namespace (slug) in the URL.
function CmsHttp.resolve_namespace(self)
    return NamespaceQueries.findBySlug(self.params.namespace)
end

return CmsHttp
