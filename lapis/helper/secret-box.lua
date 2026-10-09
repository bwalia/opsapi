--[[
    Secret box: AES-256-GCM for secrets a workspace saves (LLM keys, connector
    credentials). Each value gets its own random 96-bit IV and a 128-bit tag,
    so a tampered or swapped value fails to open instead of decrypting to junk.

      local Box = require("helper.secret-box")
      local sealed = Box.seal("sk-...", "ai_provider")   -- "gcm1:<iv>:<tag>:<ct>" (base64 parts)
      local plain  = Box.open(sealed, "ai_provider")     -- nil, err when tampered / wrong purpose

    The key is SHA-256(OPENSSL_SECRET_KEY .. "|" .. purpose): one deployment
    secret, a different key per purpose. Never log `plain`; return only
    Box.hint(plain) ("…a1b2") to a browser.
]]

local aes = require("resty.aes")
local random = require("resty.random")
local sha256 = require("resty.sha256")

local Box = {}

local PREFIX = "gcm1"

local function key_for(purpose)
    local secret = os.getenv("OPENSSL_SECRET_KEY")
    if not secret or secret == "" then error("OPENSSL_SECRET_KEY is not set; secrets can't be stored") end
    local h = sha256:new()
    h:update(secret .. "|" .. (purpose or "default"))
    return h:final()
end

function Box.seal(plain, purpose)
    if plain == nil then return nil end
    local iv = random.bytes(12, true)
    if not iv then error("no secure random bytes available") end
    local c = assert(aes:new(key_for(purpose), nil, aes.cipher(256, "gcm"), { iv = iv }))
    local out = c:encrypt(tostring(plain))
    if type(out) ~= "table" then error("encryption failed") end
    return table.concat({ PREFIX, ngx.encode_base64(iv), ngx.encode_base64(out[2]), ngx.encode_base64(out[1]) }, ":")
end

function Box.open(sealed, purpose)
    if type(sealed) ~= "string" then return nil, "nothing stored" end
    local p, iv, tag, ct = sealed:match("^([^:]+):([^:]+):([^:]+):(.*)$")
    if p ~= PREFIX then return nil, "unknown secret format" end
    iv, tag, ct = ngx.decode_base64(iv), ngx.decode_base64(tag), ngx.decode_base64(ct)
    if not iv or not tag or not ct then return nil, "corrupt secret" end
    local c = aes:new(key_for(purpose), nil, aes.cipher(256, "gcm"), { iv = iv })
    local plain = c and c:decrypt(ct, tag)
    if not plain then return nil, "secret could not be decrypted (tampered or the deployment key changed)" end
    return plain
end

--- What a browser may see of a saved secret: its last 4 characters.
function Box.hint(plain)
    if type(plain) ~= "string" or plain == "" then return nil end
    return "…" .. plain:sub(-4)
end

return Box
