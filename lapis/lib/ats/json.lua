--[[
    ATS — the JSON encoder/decoder the module uses. A private cjson instance (as
    lib/forms/json.lua): other modules flip encode_empty_table_as_object on the
    shared one. Decoding never throws: decode() returns nil, err.
]]

local cjson = require("cjson")
local J = cjson.new()
J.encode_empty_table_as_object(true)
J.decode_array_with_array_mt(true)
J.encode_escape_forward_slash(false)

local M = {}

M.null = cjson.null
M.array_mt = cjson.array_mt

function M.encode(v)
    return J.encode(v)
end

function M.decode(s)
    if type(s) ~= "string" or s == "" then return nil, "empty" end
    local ok, v = pcall(J.decode, s)
    if not ok then return nil, v end
    return v
end

--- Marks a Lua table as a JSON array (so an empty one encodes as []).
function M.array(t)
    return setmetatable(t or {}, cjson.array_mt)
end

--- nil for JSON null / ngx null / missing.
function M.val(v)
    if v == nil or v == cjson.null then return nil end
    if type(v) == "userdata" then return nil end
    return v
end

return M
