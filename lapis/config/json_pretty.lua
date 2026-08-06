--[[
  Deterministic pretty-printed JSON for CMI files.

  cjson.encode is fast but emits everything on one line with unstable key
  order — useless for git diffs. This module walks a Lua value and emits
  a canonical form:

    * 2-space indentation
    * object keys sorted alphabetically (stable across runs)
    * strings escaped per RFC 8259
    * empty arrays as `[]`, empty objects as `{}`
    * numbers as printed by Lua's `%.17g` for floats, `%d` for integers

  Arrays and objects are distinguished by cjson's convention: a table
  intended as an array carries `cjson.array_mt` OR has only 1..N integer
  keys. Everything else is an object.

  The output round-trips through `cjson.decode` byte-for-byte (values,
  not the pretty form).
]]

local cjson = require("cjson")
local M = {}

local function is_array(t)
    if getmetatable(t) == cjson.array_mt then return true end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then
        -- Empty: caller's intent unknown. Default to object; explicit array
        -- callers use cjson.empty_array (which has array_mt).
        return false
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local escape_map = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function escape_string(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        return escape_map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local encode_value

local function encode_scalar(v)
    local tv = type(v)
    if tv == "string" then
        return escape_string(v)
    elseif tv == "number" then
        if v ~= v then return "null" end -- NaN → null (cjson raises; safer)
        if v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return string.format("%.17g", v)
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif v == cjson.null or v == nil then
        return "null"
    end
    error("cannot encode value of type " .. tv)
end

encode_value = function(v, indent, depth)
    if type(v) ~= "table" then return encode_scalar(v) end
    local pad = string.rep(indent, depth)
    local pad_next = string.rep(indent, depth + 1)

    if is_array(v) then
        if #v == 0 then return "[]" end
        local parts = {}
        for i = 1, #v do
            parts[i] = pad_next .. encode_value(v[i], indent, depth + 1)
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    end

    -- Object: collect keys, sort them
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    if #keys == 0 then return "{}" end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do
        parts[i] = pad_next .. escape_string(k) .. ": " .. encode_value(v[k], indent, depth + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

--- Pretty-print a Lua value as canonical JSON (2-space indent, sorted keys).
-- Terminates with a trailing newline so text editors don't complain.
function M.encode(value)
    return encode_value(value, "  ", 0) .. "\n"
end

--- Convenience: read a JSON file, return the parsed Lua value.
-- Returns (value, nil) on success or (nil, err_string) on failure.
function M.read_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    local ok, parsed = pcall(cjson.decode, content)
    if not ok then return nil, parsed end
    return parsed, nil
end

--- Convenience: write a Lua value to a file as canonical JSON.
-- Returns (true, nil) on success or (nil, err_string) on failure.
function M.write_file(path, value)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(M.encode(value))
    f:close()
    return true, nil
end

return M
