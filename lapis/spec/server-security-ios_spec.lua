--[[
    Spec: security fixes found while building the native iOS app (wslcrm-app #47).
    - Bookkeeping: every /api/v2/accounting route needs an `accounting` permission (it needed
      only workspace membership, so a member with an empty role could read and change the books).
    - Delivery partners: search results reach any signed-in user across workspaces, so they never
      carry bank details, documents or account ids, and stores are offered verified partners only
      (a missing `is_verified` meant "unverified only").
    - HMRC sign-in: the return address must be the app or a trusted frontend (was an open redirect).
    - HMRC fraud-prevention headers: a request from the app is MOBILE_APP_VIA_SERVER with the
      device's own Gov-Client-User-Agent, never a browser's headers.

    Run from the repo root: /usr/local/openresty/luajit/bin/luajit lapis/spec/server-security-ios_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end

-- ---------------------------------------------------------------------------
print("== Bookkeeping routes need an accounting permission")
local accounting = read("lapis/routes/accounting.lua")
check("no route relies on workspace membership alone",
    not accounting:find("NamespaceMiddleware.requireNamespace%(function"))
local guarded = select(2, accounting:gsub('requirePermission%("accounting", "%a+", function%(self%)', ""))
check("all 38 handlers check accounting.<action>", guarded == 38, guarded)
local function action_for(path_pattern)
    local at = accounting:find(path_pattern, 1, true)
    if not at then return nil end
    return accounting:match('requirePermission%("accounting", "(%a+)"', at)
end
check("reading the chart of accounts needs read", action_for('app:get("/api/v2/accounting/accounts"') == "read")
check("creating a journal entry needs create", action_for('app:post("/api/v2/accounting/journal-entries"') == "create")
check("voiding a journal entry needs update",
    action_for('app:post("/api/v2/accounting/journal-entries/:uuid/void"') == "update")
check("importing bank transactions needs create",
    action_for('app:post("/api/v2/accounting/bank-transactions/import"') == "create")
check("deleting an expense needs delete", action_for('app:delete("/api/v2/accounting/expenses/:uuid"') == "delete")
check("submitting a VAT return needs update",
    action_for('app:post("/api/v2/accounting/vat-returns/:uuid/submit"') == "update")

-- ---------------------------------------------------------------------------
print("== Delivery partner search shows other workspaces only what a store needs")
local delivery = read("lapis/routes/delivery-partners.lua")
local private = delivery:match("local PRIVATE_PARTNER_FIELDS = (%b{})") or ""
for _, field in ipairs({ "bank_account_number", "bank_name", "bank_ifsc_code", "verification_documents", "user_id",
                         "namespace_id" }) do
    check("search hides " .. field, private:find('"' .. field .. '"', 1, true) ~= nil)
end
local _, stripped = delivery:gsub("\n%s+public_partner%(partner%)\n", "")
check("both search and by-area strip private fields", stripped == 2, stripped)
check("stores are offered verified partners; only a platform admin can list unverified ones",
    delivery:find("is_verified = not %(params.is_verified == 'false'") ~= nil
    and delivery:find("AdminCheck.isPlatformAdmin%(self.current_user%)") ~= nil)

-- ---------------------------------------------------------------------------
print("== HMRC sign-in returns only to the app or a trusted frontend")
package.loaded["middleware.cors"] = {
    trustedFrontend = function(origin, extra)
        if origin == "https://app.example.co.uk" then return origin end
        if extra and extra[origin] then return origin end
        return nil
    end,
}
local HMRCReturn = require("helper.hmrc-return")
check("the iOS app", HMRCReturn.safe("wslcrm://hmrc") == "wslcrm://hmrc")
check("a trusted dashboard with its path", HMRCReturn.safe("https://app.example.co.uk/dashboard/tax/")
    == "https://app.example.co.uk/dashboard/tax")
check("a trusted bare origin", HMRCReturn.safe("https://app.example.co.uk") == "https://app.example.co.uk")
check("another site is refused", HMRCReturn.safe("https://evil.example/dashboard/tax") == nil)
check("user@host tricks are refused", HMRCReturn.safe("https://app.example.co.uk@evil.example/x") == nil)
check("a query or fragment is refused", HMRCReturn.safe("https://app.example.co.uk/x?next=https://evil.example") == nil
    and HMRCReturn.safe("https://app.example.co.uk/#evil") == nil)
check("other schemes are refused", HMRCReturn.safe("javascript:alert(1)") == nil
    and HMRCReturn.safe("wslcrm://hmrc.evil") == nil and HMRCReturn.safe("http:/app.example.co.uk") == nil)
check("nothing given: nil (the caller uses its default)", HMRCReturn.safe(nil) == nil and HMRCReturn.safe("") == nil)

-- ---------------------------------------------------------------------------
print("== HMRC fraud-prevention headers: app or browser")
local request_headers = {}
_G.ngx = {
    req = { get_headers = function() return request_headers end },
    var = { remote_addr = "81.2.69.160", http_user_agent = "Mozilla/5.0 Safari", remote_port = "51234" },
    shared = {},
    escape_uri = function(s) return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end,
    log = function() end, ERR = 1, WARN = 2, INFO = 3, time = os.time,
}
package.loaded["lapis.db"] = { query = function() return {} end }
package.loaded["resty.http"] = { new = function() return {} end }
package.loaded["helper.global"] = { generateStaticUUID = function() return "server-device" end,
                                     getEnvVar = function() return nil end }
local ok, HMRC = pcall(require, "helper.hmrc")
check("helper.hmrc loads", ok, HMRC)
if ok then
    request_headers = {
        ["x-gov-client-connection-method"] = "MOBILE_APP_VIA_SERVER",
        ["x-gov-client-user-agent"] = "os-family=iOS&os-version=18.4&device-manufacturer=Apple&device-model=iPhone17%2C1",
        ["x-gov-client-device-id"] = "6A3E0C42-1D7B-4F38-9E61-2C5D7A9B0F11",
        ["x-gov-client-screens"] = "width=402&height=874&scaling-factor=3&colour-depth=24",
        ["x-gov-client-window-size"] = "width=402&height=874",
        ["x-gov-client-timezone"] = "UTC+00:00",
        ["x-gov-client-user-ids"] = "opsapi=u-1",
    }
    local app = HMRC.build_fraud_headers()
    check("the app is MOBILE_APP_VIA_SERVER", app["Gov-Client-Connection-Method"] == "MOBILE_APP_VIA_SERVER")
    check("with the phone's own user agent", app["Gov-Client-User-Agent"] == request_headers["x-gov-client-user-agent"])
    check("and no browser header", app["Gov-Client-Browser-JS-User-Agent"] == nil)
    check("its device id is the app's", app["Gov-Client-Device-ID"] == request_headers["x-gov-client-device-id"])

    request_headers = { ["x-gov-client-browser-js-user-agent"] = "Mozilla/5.0 (Macintosh) Chrome" }
    local web = HMRC.build_fraud_headers()
    check("the dashboard stays WEB_APP_VIA_SERVER", web["Gov-Client-Connection-Method"] == "WEB_APP_VIA_SERVER")
    check("with the browser's user agent", web["Gov-Client-Browser-JS-User-Agent"] == "Mozilla/5.0 (Macintosh) Chrome")
    check("and no mobile header", web["Gov-Client-User-Agent"] == nil)

    request_headers = { ["x-gov-client-connection-method"] = "SOMETHING_ELSE" }
    check("an unknown method is treated as the web",
        HMRC.build_fraud_headers()["Gov-Client-Connection-Method"] == "WEB_APP_VIA_SERVER")
end

print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
