--[[
    Spec: Global.encryptSecret / decryptSecret (helper/global.lua) v2 AES-GCM values.
    get_aead_tag() with no size returns key_size / 2, so under a 16-byte key (int,
    test, acc) values were written with an 8-byte tag that decryptSecret — reading
    16 — could never open: every NINO saved there failed to decrypt. New values
    carry a 16-byte tag; the 8-byte ones already stored must still open.

    resty.openssl needs the nginx runtime, so this runs under `resty`, not the
    plain luajit CI uses (it is on CI's skip list). From the repo root, once per
    key size:
        OPENSSL_SECRET_KEY=kkkkkkkkkkkkkkkk OPENSSL_SECRET_IV=iiiiiiiiiiiiiiii \
            resty lapis/spec/secret-gcm-tag_spec.lua
        OPENSSL_SECRET_KEY=$(openssl rand -hex 32) OPENSSL_SECRET_IV=iiiiiiiiiiiiiiii \
            resty lapis/spec/secret-gcm-tag_spec.lua
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

-- global.lua's top-level requires; nothing encryption needs.
package.loaded["bcrypt"] = {}
package.loaded["helper.uuid"] = {}
local Global = require("helper.global")
local cipher = require("resty.openssl.cipher")

-- What encryptSecret wrote before the tag length was pinned.
local function short_tag_value(plain, key)
    local nonce = ("n"):rep(12)
    local c = cipher.new("aes-128-gcm")
    local ct = assert(c:encrypt(key, nonce, plain, false))
    local tag = assert(c:get_aead_tag(8))
    return "v2:" .. ngx.encode_base64(nonce .. tag .. ct)
end

local function blob_of(v) return ngx.decode_base64(v:sub(4)) end

local function flip_last(v)
    local b = blob_of(v)
    return "v2:" .. ngx.encode_base64(b:sub(1, -2) .. string.char((b:byte(-1) + 1) % 256))
end

-- The key exactly as encryptSecret uses it (hex decoded where that gives a valid size).
local key = os.getenv("OPENSSL_SECRET_KEY") or ""
if #key == 64 and key:match("^%x+$") then
    key = key:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
end

print("AES-" .. (#key * 8) .. ":")
local v = Global.encryptSecret("HS809445C")
check("writes nonce[12] | tag[16] | ciphertext", #blob_of(v) == 12 + 16 + 9, #blob_of(v))
local ok, plain = pcall(Global.decryptSecret, v)
check("round trip", ok and plain == "HS809445C", plain)
check("a changed ciphertext doesn't open", not pcall(Global.decryptSecret, flip_last(v)))

if #key == 16 then
    print("values already stored with an 8-byte tag:")
    local old = short_tag_value("HS809445C", key)
    local ok2, plain2 = pcall(Global.decryptSecret, old)
    check("still open", ok2 and plain2 == "HS809445C", plain2)
    check("a changed one doesn't open", not pcall(Global.decryptSecret, flip_last(old)))
end

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
