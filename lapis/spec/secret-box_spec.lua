--[[
    Spec: helper/secret-box.lua seals workspace secrets (AI provider keys,
    connector passwords) with AES-256-GCM: round trip, tamper -> nil, a key
    per purpose, and no OPENSSL_SECRET_KEY -> open returns nil + why (never a
    raise that 500s every request), while seal still refuses to store.

    Run from the repo root (what CI does):
        luajit lapis/spec/secret-box_spec.lua
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

local b64 = require("spec.fixtures.openssl")
ngx = { encode_base64 = b64.encode_base64, decode_base64 = b64.decode_base64 } -- luacheck: ignore 111

local KEY = "deployment-secret"
local real_getenv = os.getenv
os.getenv = function(k) if k == "OPENSSL_SECRET_KEY" then return KEY end return real_getenv(k) end -- luacheck: ignore 122
local Box = require("helper.secret-box")

print("seal / open:")
local sealed = Box.seal("sk-live-123456", "ai_provider")
check("sealed value is gcm1:<iv>:<tag>:<ct>", type(sealed) == "string" and sealed:match("^gcm1:[^:]+:[^:]+:.+$") ~= nil)
check("never contains the plain text", not sealed:find("sk-live", 1, true))
check("round trip", Box.open(sealed, "ai_provider") == "sk-live-123456")
check("a fresh IV each time", Box.seal("sk-live-123456", "ai_provider") ~= sealed)
check("hint shows the last 4 only", Box.hint("sk-live-123456") == "…3456")

print("tamper / purpose:")
local p, iv, tag, ct = sealed:match("^([^:]+):([^:]+):([^:]+):(.*)$")
local flipped = ct:sub(1, -2) .. (ct:sub(-1) == "0" and "1" or "0")
local plain, err = Box.open(table.concat({ p, iv, tag, flipped }, ":"), "ai_provider")
check("a changed ciphertext doesn't open", plain == nil and err ~= nil, err)
check("a swapped tag doesn't open", Box.open(table.concat({ p, iv, ("0"):rep(32), ct }, ":"), "ai_provider") == nil)
check("another purpose's key doesn't open it", Box.open(sealed, "connector") == nil)
check("garbage is refused, not raised", select(2, Box.open("nope", "ai_provider")) == "unknown secret format")

print("no OPENSSL_SECRET_KEY:")
KEY = nil
local ok, plain2, why = pcall(Box.open, sealed, "ai_provider")
check("open returns nil + why instead of raising", ok and plain2 == nil and tostring(why):find("OPENSSL_SECRET_KEY", 1, true),
    tostring(plain2) .. " / " .. tostring(why))
check("seal still refuses (nothing is stored unsealed)", not pcall(Box.seal, "x", "ai_provider"))

os.getenv = real_getenv -- luacheck: ignore 122
print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
