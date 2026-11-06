-- luacheck: max line length 140
--[[
    Shop legal acceptances: lib/shop-legal.lua rules + the wiring that makes the ledger trustworthy
    (migration registered, append-only trigger, BFF-only write, admin list).

    Standalone — run from the repo root with:
        luajit lapis/spec/shop-legal_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path
local L = require("lib.shop-legal")

local failures = 0
local function check(name, ok, detail)
    print((ok and "  ok   - " or "  FAIL - ") .. name .. ((not ok and detail) and ("  [" .. tostring(detail) .. "]") or ""))
    if not ok then failures = failures + 1 end
end

local function read(path)
    local f = assert(io.open(path))
    local s = f:read("*a")
    f:close()
    return s
end

local HASH = string.rep("ab", 32)
local function body(over)
    local b = {
        email = "  Partner@Firm.CO.UK ",
        checkpoint = "checkout",
        subject_ref = "cart_9f2c",
        ip = "203.0.113.7",
        user_agent = "Mozilla/5.0",
        documents = {
            { key = "terms-of-sale", version = "2026-11", hash = HASH, statement = "I agree to the Terms of Sale." },
            { key = "privacy-notice", version = "2026-11", statement = "I have read How Workstation uses your information." },
        },
    }
    for k, v in pairs(over or {}) do b[k] = v end
    return b
end

-- validate ---------------------------------------------------------------------------
local rec, code = L.validate(body())
check("valid body accepted", rec ~= nil, code)
check("email lower-cased and trimmed", rec and rec.email == "partner@firm.co.uk")
check("documents kept in order", rec and #rec.documents == 2 and rec.documents[1].key == "terms-of-sale")
check("hash kept, optional hash nil", rec and rec.documents[1].hash == HASH and rec.documents[2].hash == nil)
check("ip and user agent kept", rec and rec.ip == "203.0.113.7" and rec.user_agent == "Mozilla/5.0")

local _, c1 = L.validate(body({ email = "nope" }))
check("bad email rejected", c1 == "INVALID_EMAIL")
local _, c2 = L.validate(body({ checkpoint = "whenever" }))
check("unknown checkpoint rejected", c2 == "INVALID_CHECKPOINT")
local _, c3 = L.validate(body({ documents = {} }))
check("no documents rejected", c3 == "NO_DOCUMENTS")
local _, c4 = L.validate(body({ documents = { { key = "Terms Of Sale", version = "1", statement = "x" } } }))
check("bad key rejected", c4 == "INVALID_DOCUMENT")
local _, c5 = L.validate(body({ documents = { { key = "terms-of-sale", version = "v 1", statement = "x" } } }))
check("bad version rejected", c5 == "INVALID_DOCUMENT")
local _, c6 = L.validate(body({ documents = { { key = "terms-of-sale", version = "1", statement = "  " } } }))
check("empty statement rejected", c6 == "INVALID_DOCUMENT")
local _, c7 = L.validate(body({ documents = { { key = "terms-of-sale", version = "1", hash = "xyz", statement = "ok" } } }))
check("non-sha256 hash rejected", c7 == "INVALID_DOCUMENT")
local _, c8 = L.validate(body({ subject_ref = "quote; DROP TABLE" }))
check("unsafe subject_ref rejected", c8 == "INVALID_SUBJECT")

local many = {}
for i = 1, L.MAX_DOCUMENTS + 1 do many[i] = { key = "doc-" .. i, version = "1", statement = "s" } end
local _, c9 = L.validate(body({ documents = many }))
check("too many documents rejected", c9 == "TOO_MANY_DOCUMENTS")

local dup = L.validate(body({ documents = {
    { key = "trade-terms", version = "2026-10", statement = "I agree." },
    { key = "trade-terms", version = "2026-10", statement = "I agree." },
    { key = "trade-terms", version = "2026-10", statement = "I am authorised to act for this business." },
} }))
check("duplicate statements collapse, distinct statements kept", dup and #dup.documents == 2)

local junk_ip = L.validate(body({ ip = "<script>" }))
check("junk ip dropped, not fatal", junk_ip and junk_ip.ip == nil)
local long = L.validate(body({ user_agent = string.rep("u", 900),
    documents = { { key = "ai-assistant", version = "1", statement = string.rep("s", 1500) } } }))
check("long user agent and statement truncated", long and #long.user_agent == L.MAX_UA and #long.documents[1].statement == L.MAX_STATEMENT)

-- latest -----------------------------------------------------------------------------
local latest = L.latest({
    { document_key = "terms-of-sale", document_version = "2026-10", checkpoint = "register", created_at = "2026-10-01 10:00:00+00" },
    { document_key = "terms-of-sale", document_version = "2026-11", checkpoint = "checkout", created_at = "2026-11-06 09:00:00+00" },
    { document_key = "privacy-notice", document_version = "2026-11", checkpoint = "chat", created_at = "2026-11-02 09:00:00+00" },
})
check("latest picks newest per document", latest["terms-of-sale"].version == "2026-11" and latest["terms-of-sale"].checkpoint == "checkout")
check("latest keeps other documents", latest["privacy-notice"].version == "2026-11")

-- wiring -----------------------------------------------------------------------------
local mig = read("lapis/migrations.lua")
check("migration registered as zzs37", mig:find("zzs37_shop_legal_acceptances", 1, true) ~= nil)
check("migration module loaded", mig:find('"migrations.shop-legal"', 1, true) ~= nil)
local sql = read("lapis/migrations/shop-legal.lua")
check("table is append-only (UPDATE trigger)", sql:find("BEFORE UPDATE ON shop_legal_acceptances", 1, true) ~= nil)
for _, c in ipairs(L.CHECKPOINTS) do
    check("migration CHECK allows checkpoint " .. c, sql:find("'" .. c .. "'", 1, true) ~= nil)
end
local pub = read("lapis/routes/shop-public.lua")
local post_at = pub:find('app:post(BASE .. "/legal/acceptances"', 1, true)
check("public POST /legal/acceptances exists", post_at ~= nil)
check("POST is BFF only", post_at and pub:find("if not is_bff(self) then return U.fail(403", post_at, true) ~= nil)
check("public GET /legal/acceptances exists", pub:find('app:get(BASE .. "/legal/acceptances"', 1, true) ~= nil)
local admin = read("lapis/routes/shop-admin.lua")
check("admin GET /legal/acceptances behind guard", admin:find('"/legal/acceptances", guard("read"', 1, true) ~= nil)

print(failures == 0 and "\nall shop-legal checks passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
