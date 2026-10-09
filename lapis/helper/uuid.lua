--[[
    UUID v4 from the operating system's CSPRNG.

    Why: UUIDs used to be md5(math.random() .. os.time()) and nothing seeds
    math.random in the workers, so every process walked the SAME sequence — two
    pods (or a pod and its replacement) at the same point in that sequence
    within the same second produced the SAME "unique" id, and ids were
    guessable. 122 random bits from the kernel fix both.

    Source: resty.random (OpenSSL) inside nginx; /dev/urandom from the `lapis`
    CLI (migrations), where ngx and OpenSSL aren't loaded. The math.random
    template is only a last resort for a platform with neither.

    No dependencies on purpose: usable from migrations, specs and plain LuaJIT.
]]

local bit = require("bit")

local Uuid = {}

-- Resolved once: a failed require() re-scans the whole search path every call.
local resty_random
do
    local ok, mod = pcall(require, "resty.random")
    resty_random = ok and mod or nil
end

-- Unbuffered on purpose: nginx forks its workers, and a buffered handle opened
-- before the fork would hand every worker the same buffered "random" bytes.
local urandom

local function random_bytes(n)
    if resty_random then
        local ok, bytes = pcall(resty_random.bytes, n, true)
        if ok and type(bytes) == "string" and #bytes == n then return bytes end
    end
    if urandom == nil then
        urandom = io.open("/dev/urandom", "rb") or false
        if urandom then urandom:setvbuf("no") end
    end
    if urandom then
        local bytes = urandom:read(n)
        if bytes and #bytes == n then return bytes end
    end
    return nil
end

--- A secret string (passwords, codes) of `len` characters from `alphabet`,
-- from the CSPRNG with no modulo bias. Raises rather than fall back to
-- math.random: a guessable secret is worse than a failed request.
function Uuid.random_string(len, alphabet)
    local k, out = #alphabet, {}
    local limit = 256 - 256 % k -- bytes at or above this would favour the first characters
    while #out < len do
        local bytes = random_bytes(len * 2) or error("no CSPRNG available")
        for i = 1, #bytes do
            local b = bytes:byte(i)
            if b < limit then
                out[#out + 1] = alphabet:sub(b % k + 1, b % k + 1)
                if #out == len then break end
            end
        end
    end
    return table.concat(out)
end

local FORMAT = "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"

--- @return string lower-case RFC 4122 version 4 UUID
function Uuid.generate()
    local bytes = random_bytes(16)
    if not bytes then
        return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
            return ("%x"):format(c == "x" and math.random(0, 15) or math.random(8, 11))
        end))
    end
    local b = { bytes:byte(1, 16) }
    b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40) -- version 4
    b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80) -- RFC 4122 variant
    return FORMAT:format(unpack(b))
end

return Uuid
