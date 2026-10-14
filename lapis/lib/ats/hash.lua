--[[
    ATS — hashes.
    notice(): FNV-1a 64-bit of the UTF-8 bytes, 16 lowercase hex digits; the
    same as InterviewPrompts.hash in the Snazzy app, so a notice acknowledged in
    either place records the same value for the same wording.
    sha256_hex() / random_token(): link tokens (only the hash is stored).
]]

local bit = require("bit")

local H = {}

function H.notice(text)
    local h = 0xcbf29ce484222325ULL
    local prime = 0x100000001b3ULL
    local s = tostring(text or "")
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i) + 0ULL)
        h = h * prime
    end
    return bit.tohex(h, 16)
end

--- SHA-256 as lowercase hex (resty.sha256 in OpenResty).
function H.sha256_hex(s)
    local sha256 = require("resty.sha256")
    local str = require("resty.string")
    local d = sha256:new()
    d:update(s)
    return str.to_hex(d:final())
end

--- 256 bits of randomness, URL-safe base64 (43 characters).
function H.random_token()
    local random = require("resty.random")
    local bytes = random.bytes(32, true) or random.bytes(32)
    return (ngx.encode_base64(bytes):gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

return H
