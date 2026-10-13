-- luacheck: max line length 140
--[[
    Plain-Lua unit test for lib/shop-customer-auth.lua (no nginx, no DB, no busted).
    Covers the rules that keep shop sign-in safe: only a same-site `next`, only a
    well-formed nonce, only google/apple/facebook, and a state that round-trips.

    Run from lapis/:
        luajit spec/shop-customer-auth-test.lua
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
local A = require("lib.shop-customer-auth")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local NONCE = "abcdefghijklmnop_QRS-0123"

-- next ------------------------------------------------------------------------------
for _, p in ipairs({ "/account", "/account?tab=quotes", "/quotes/abc-123?t=xyz", "/" }) do
    check("next kept: " .. p, A.safe_next(p) == p, A.safe_next(p))
end
for _, p in ipairs({
    "https://evil.example", "//evil.example", "/\\evil.example", "evil.example", "javascript:alert(1)",
    "/a b", "/<script>", "", ("/" .. ("a"):rep(250)),
}) do
    check("next refused: " .. p:sub(1, 30), A.safe_next(p) == "/account", A.safe_next(p))
end
check("next refused: non-string", A.safe_next(nil) == "/account" and A.safe_next({}) == "/account")

-- nonce / slug ------------------------------------------------------------------------
check("nonce ok", A.valid_nonce(NONCE))
check("nonce too short", not A.valid_nonce("short"))
check("nonce bad chars", not A.valid_nonce("abcdefghijklmnop&q=1"))
check("nonce too long", not A.valid_nonce(("a"):rep(129)))
check("slug ok", A.valid_slug("workstation"))
check("slug refused", not A.valid_slug("Workstation") and not A.valid_slug("../x") and not A.valid_slug(""))

-- state -------------------------------------------------------------------------------
local st, why = A.build_state("workstation", { provider = "google", nonce = NONCE, next = "/account" })
check("state built", st and st.shop.ns == "workstation" and st.shop.n == NONCE and st.shop.next == "/account", why)
check("state allows facebook", A.build_state("workstation", { provider = "facebook", nonce = NONCE }) ~= nil)
check("state refuses unknown provider", A.build_state("workstation", { provider = "twitter", nonce = NONCE }) == nil)
check("state refuses bad nonce", A.build_state("workstation", { provider = "apple", nonce = "x" }) == nil)
check("state sanitises next", A.build_state("workstation", { provider = "apple", nonce = NONCE, next = "//evil" }).shop.next == "/account")

local back = A.from_state(st)
check("from_state round trip", back and back.ns == "workstation" and back.nonce == NONCE and back.next == "/account")
check("dashboard state is not a shop sign-in", A.from_state({ from = "/", frontend_url = "https://x" }) == nil)
check("forged state with bad next is sanitised",
    A.from_state({ shop = { ns = "workstation", n = NONCE, next = "https://evil.example" } }).next == "/account")
check("forged state with bad nonce refused", A.from_state({ shop = { ns = "workstation", n = "1", next = "/" } }) == nil)
check("non-table state", A.from_state(nil) == nil and A.from_state("/") == nil)

-- urls --------------------------------------------------------------------------------
local landing = A.landing_url("https://int-shop.workstation.co.uk/", "TOK_en-1", { nonce = NONCE, next = "/account?tab=q" })
check("landing url", landing == "https://int-shop.workstation.co.uk/account/verify?t=TOK_en-1&n=" .. NONCE
    .. "&next=%2Faccount%3Ftab%3Dq", landing)
check("error url", A.error_url("https://shop.workstation.co.uk", "email_unverified")
    == "https://shop.workstation.co.uk/login?error=email_unverified")
local g = A.google_authorize_url("id.apps", "https://opsapi.workstation.co.uk/auth/google/callback", '{"shop":1}')
check("google url escapes state", g:find("state=%7B%22shop%22%3A1%7D", 1, true) ~= nil, g)

local f = A.facebook_authorize_url("123", "https://opsapi.workstation.co.uk/auth/facebook/callback", '{"shop":1}')
check("facebook url asks only for email", f:find("scope=email&", 1, true) ~= nil and f:find("state=%7B%22shop%22%3A1%7D", 1, true) ~= nil, f)

-- password sign-in --------------------------------------------------------------------
check("code ok", A.valid_code("012345"))
for _, c in ipairs({ "12345", "1234567", "12a456", " 123456", 123456 }) do
    check("code refused: " .. tostring(c), not A.valid_code(c))
end
check("mask email", A.mask_email("jane.doe@example.com") == "j***@example.com", A.mask_email("jane.doe@example.com"))
check("mask non-email", A.mask_email("nope") == nil and A.mask_email(nil) == nil)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
