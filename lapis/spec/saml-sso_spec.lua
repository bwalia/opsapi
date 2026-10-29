--[[
    Spec: SAML 2.0 response validation (lib/saml/xml.lua, lib/saml/sp.lua).

    Fixture: a real response signed by BoxyHQ mock-saml (the demo IdP), with its
    public certificate. Each attack below must be refused.

    Standalone, from the repo root:
        luajit lapis/spec/saml-sso_spec.lua
    (CI runs it in the OpenResty base image: .github/workflows/lapis-checks.yml.)
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = assert(io.open(path, "rb"))
    local s = h:read("*a")
    h:close()
    return s
end

-- Plain LuaJIT has no `ngx`: base64 and time are all lib/saml needs from it.
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function enc(data)
    return ((data:gsub(".", function(x)
        local r, b = "", x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return b64chars:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end
local function dec(data)
    data = data:gsub("[^" .. b64chars .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (b64chars:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end
-- Load lua-resty-openssl first: it switches to ngx's base64 when it sees `ngx`.
require("resty.openssl.x509")
require("resty.openssl.digest")
_G.ngx = { encode_base64 = enc, decode_base64 = dec, time = os.time }

local SP = require("lib.saml.sp")
local FIX = "lapis/spec/fixtures/saml/"
local xml = read(FIX .. "mocksaml-response.xml")
local cert = read(FIX .. "mocksaml-idp-cert.pem")
local ACS = "http://127.0.0.1:4021/auth/saml/dbd946b3-4d3c-477e-8db7-0205774340d2/acs"
local NOW = SP.parse_time("2026-10-29T21:35:40Z")

local function opts(over)
    local o = {
        idp_entity_id = "https://saml.example.com/entityid",
        idp_x509_cert = cert,
        sp_entity_id = "http://127.0.0.1:4021/auth/saml/dbd946b3-4d3c-477e-8db7-0205774340d2/metadata",
        acs_url = ACS,
        request_id = "_e81b295bbc95b975927c6eaade2f1bf394a08bcb",
    }
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end
local function validate(doc, over, now)
    return SP.validate_response(enc(doc), opts(over), now or NOW)
end
local function refused(name, doc, over, now, expect)
    local res, err = validate(doc, over, now)
    check(name, res == nil and (not expect or (err or ""):find(expect, 1, true)), err or "accepted!")
end

print("parse_time")
check("UTC with millis", SP.parse_time("2026-10-29T21:35:37.280Z") == 1793309737)
check("offset", SP.parse_time("2026-10-29T22:35:37+01:00") == 1793309737)
check("garbage", SP.parse_time("yesterday") == nil)

print("valid response")
local res, err = validate(xml)
check("accepted", res ~= nil, err)
if res then
    local p = SP.profile(res, {})
    check("email", p.email == "jackson@example.com", p.email)
    check("first name", p.first_name == "jackson", p.first_name)
    check("assertion id", type(res.assertion_id) == "string" and #res.assertion_id > 0)
end

print("refusals")
refused("changed email (digest)", (xml:gsub("jackson@example.com", "admin@example.com")), nil, nil, "digest mismatch")
refused("wrong IdP certificate", xml, { idp_x509_cert = read(FIX .. "mocksaml-idp-metadata.xml"):match(
    "<ds:X509Certificate>(.-)</ds:X509Certificate>"):gsub("A", "B", 1) })
refused("unsigned", (xml:gsub("<Signature.-</Signature>", "")), nil, nil, "not signed")
refused("DTD / XXE", (xml:gsub("^<%?xml[^>]*%?>",
    '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY e SYSTEM "file:///etc/passwd">]>')), nil, nil, "DTD")
local assertion = xml:match("(<saml:Assertion.-</saml:Assertion>)")
local forged = assertion:gsub("<Signature.-</Signature>", ""):gsub("jackson@example.com", "evil@example.com")
    :gsub('ID="', 'ID="x', 1)
refused("signature wrapping (extra assertion)", (xml:gsub("<saml:Assertion", forged .. "<saml:Assertion", 1)))
refused("other request (InResponseTo)", xml, { request_id = "_other" })
refused("unsolicited, IdP-initiated off", xml, { request_id = false })
refused("wrong audience", xml, { sp_entity_id = "https://elsewhere/metadata" }, nil, "Audience")
refused("wrong ACS", xml, { acs_url = "https://elsewhere/acs" })
refused("other issuer", xml, { idp_entity_id = "https://evil.example/idp" }, nil, "Issuer")
refused("expired", xml, nil, NOW + 86400, "expired")
refused("not base64 XML", "hello", nil, nil, nil)

print("IdP metadata")
local md, merr = SP.parse_idp_metadata(read(FIX .. "mocksaml-idp-metadata.xml"))
check("parsed", md ~= nil, merr)
check("entity id", md and md.idp_entity_id == "https://saml.example.com/entityid")
check("certificate PEM", md and md.idp_x509_cert:find("BEGIN CERTIFICATE", 1, true) ~= nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
