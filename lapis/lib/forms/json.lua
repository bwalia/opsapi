--[[
    The JSON encoder forms use. A private cjson instance: other modules flip
    encode_empty_table_as_object on the SHARED one, which would turn an empty
    object (settings, answers) into []. Arrays are marked with cjson.array_mt
    (shared by every instance), so empty lists still encode as [].
]]
local J = require("cjson").new()
J.encode_empty_table_as_object(true)
J.decode_array_with_array_mt(true)
J.encode_escape_forward_slash(false)
return J
