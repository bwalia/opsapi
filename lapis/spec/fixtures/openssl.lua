-- resty.aes / resty.sha256 call OpenSSL through ffi.C, which nginx links in. Plain luajit (how the
-- specs run) has to load libcrypto globally first. Also stands in for ngx's base64 (as hex).
local ffi = require("ffi")
local loaded = false
for _, lib in ipairs({ "/usr/local/openresty/openssl3/lib/libcrypto.so.3", "/usr/lib/libcrypto.so.3", "crypto" }) do
    if not loaded and pcall(ffi.load, lib, true) then loaded = true end
end
assert(loaded, "libcrypto not found")

return {
    encode_base64 = function(s)
        return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
    end,
    decode_base64 = function(s)
        if s:find("[^%x]") or #s % 2 == 1 then return nil end
        return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
    end,
}
