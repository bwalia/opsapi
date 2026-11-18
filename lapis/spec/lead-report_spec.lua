--[[
    Spec: the AI lead report (lib/crm/lead-report.lua) and the held new-lead email.

    Standalone (no busted). From the repo root:
        luajit lapis/spec/lead-report_spec.lua
    The database paths (hold → analysis → PDF in MinIO → email with the link → download) are driven
    for real in the INT check described in the PR.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3, WARN = 4, time = os.time } -- luacheck: ignore 111
package.loaded["cjson"] = package.loaded["cjson"] or { null = setmetatable({}, { __tostring = function() return "null" end }),
    decode = function() error("not needed") end }

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = assert(io.open(path))
    local s = h:read("*a")
    h:close()
    return s
end

local Report = require("lib.crm.lead-report")
local null = require("cjson").null

-- rating out of 10
check("72 → 7/10", Report.rating(72) == 7)
check("75 → 8/10 (rounded)", Report.rating(75) == 8)
check("0 → 0, 100 → 10", Report.rating(0) == 0 and Report.rating(100) == 10)
check("out of range is clamped", Report.rating(140) == 10 and Report.rating(-5) == 0)
check("no score → nil", Report.rating(nil) == nil and Report.rating(null) == nil)
check("words", Report.rating_word(9) == "Hot lead" and Report.rating_word(6) == "Good lead"
    and Report.rating_word(4) == "Maybe" and Report.rating_word(2) == "Weak lead" and Report.rating_word(nil) == "Not rated")

-- where it came from
check("host of a referrer", Report.host("https://www.google.co.uk/search?q=x") == "www.google.co.uk")
check("no host for junk", Report.host("not a url") == nil and Report.host(nil) == nil)
check("website form with campaign and referrer",
    Report.origin({ source = "website_form", campaign = "spring", referrer_url = "https://google.com/x" })
        == "Website form · campaign spring · from google.com", Report.origin({ source = "website_form", campaign = "spring",
        referrer_url = "https://google.com/x" }))
check("email source", Report.origin({ source = "email" }) == "Email")
check("unknown source is humanized", Report.origin({ source = "trade_show" }) == "Trade show")
check("no source", Report.origin({}) == "Unknown")

-- the PDF
local bytes = Report.build({
    workspace = "Workstation",
    currency = "GBP",
    lead = { first_name = "Jane", last_name = "Buyer", company_name = "Acme (UK) Ltd", email = "jane@acme.test",
             source = "website_form", referrer_url = "https://www.bing.com/", notes = "We need 4 GPU servers — £40k budget.",
             created_at = "2026-11-18 10:00:00" },
    analysis = { uuid = "a1", model = "qwen", result = {
        score = 81, summary = "A school wants GPU servers.", origin = "A website form after a Bing search: actively shopping.",
        wants = "4 GPU servers", intent = "buy", urgency = "high", estimated_value = 40000, value_low = 30000, value_high = 50000,
        value_source = "web_search", value_basis = "secret research notes", score_reasons = { "Clear budget", "Urgent" },
        flags = { spam = false, vulnerable = false, existing_customer = true, out_of_scope = false },
        next_best_action = { label = "Call now", reason = "Hot and urgent", when = "now" },
        partner_suggestions = {}, questions = { "When do you need them?" },
        first_reply = { channel = "email", subject = "Your GPU servers", body = "Thanks for getting in touch." },
        research = { sources = { "https://example.com/grounded" } },
    } },
    lead_url = "https://dash.example/dashboard/leads/x",
})
check("a PDF", bytes:sub(1, 8) == "%PDF-1.4" and bytes:sub(-6) == "%%EOF\n")
check("rating on the page", bytes:find("(8/10)", 1, true) ~= nil)
check("name escaped in the title", bytes:find("Acme \\(UK\\) Ltd", 1, true) ~= nil)
check("origin sentence", bytes:find("actively shopping", 1, true) ~= nil)
check("web research notes are never in the report", not bytes:find("secret research notes", 1, true)
    and not bytes:find("grounded", 1, true))
check("says the value came from a web search", bytes:find("From a web price search", 1, true) ~= nil)
check("existing customer warning", bytes:find("Already a customer", 1, true) ~= nil)
check("value formatted", bytes:find("\16340,000", 1, true) ~= nil)
local probe = io.popen("command -v pdftotext 2>/dev/null")
local has = probe and probe:read("*a") or ""
if probe then probe:close() end
if has:match("%S") then
    local path = os.tmpname()
    local f = assert(io.open(path, "wb"))
    f:write(bytes)
    f:close()
    local p = io.popen("pdftotext -enc UTF-8 " .. path .. " - 2>&1")
    local txt = p:read("*a")
    p:close()
    os.remove(path)
    check("pdftotext: every section", txt:find("Where it came from", 1, true) and txt:find("Suggested next step", 1, true)
        and txt:find("Their message", 1, true) and txt:find("£40k budget", 1, true), txt:sub(1, 300))
end

-- an analysis with nothing in it still draws
check("an empty analysis still makes a PDF", Report.build({ lead = {}, analysis = { result = {} } }):sub(1, 8) == "%PDF-1.4")

-- signed links (fake hmac: the real one is resty.openssl)
local function hmac(key, msg)
    local h = 0
    for i = 1, #msg do h = (h * 31 + msg:byte(i) + #key) % 2147483647 end
    return tostring(h)
end
local now = 1800000000
local tok = Report.sign("11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", now, "k", hmac)
local t = Report.verify(tok, now + 10, "k", hmac)
check("a link verifies", t and t.analysis_uuid == "11111111-2222-3333-4444-555555555555"
    and t.lead_uuid == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
local _, why = Report.verify(tok, now + Report.LINK_DAYS * 86400 + 1, "k", hmac)
check("expires after LINK_DAYS", why == "expired")
local _, why2 = Report.verify(tok, now, "other key", hmac)
check("another key is refused", why2 == "invalid")
local _, why3 = Report.verify(tok:gsub("^.", function(c) return c == "a" and "b" or "a" end), now, "k", hmac)
check("a changed link is refused", why3 == "invalid")

-- wiring
local notif = read("lapis/queries/CrmLeadNotificationQueries.lua")
check("fresh leads hold the admin email when the AI is on", notif:find("Report.should_hold(namespace.id)", 1, true)
    and notif:find("not to and not payload.staff and lead.id", 1, true))
check("a held email skips only the admin email", notif:find("if not p.hold_admin and s.notify_admin", 1, true) ~= nil)
check("sendHeld sends the admin email only", notif:find("send_confirmation = false, telegram_enabled = false", 1, true) ~= nil)
local ai = read("lapis/lib/crm/lead-ai.lua")
check("every run makes its report and releases the email", ai:find('require("lib.crm.lead-report").after_run', 1, true) ~= nil)
check("the prompt asks where it came from", ai:find('"origin":', 1, true) ~= nil)
check("the sweep runs", read("lapis/lib/crm/lead-jobs.lua"):find("release_overdue()", 1, true) ~= nil)
check("AI off releases at once", read("lapis/lib/crm/lead-pipeline.lua"):find('require("lib.crm.lead-report").release', 1, true) ~= nil)
check("release claims before sending (never twice)",
    read("lapis/lib/crm/lead-report.lua"):find("SET alert_held_at = NULL WHERE id = ? AND alert_held_at IS NOT NULL", 1, true) ~= nil)
check("the staff download falls back to the latest finished analysis",
    read("lapis/lib/crm/lead-report.lua"):find("WHERE lead_id = ? AND status = 'done' ORDER BY created_at DESC", 1, true) ~= nil)
check("the template shows the report link", read("lapis/views/emails/lead_admin_notification.etlua"):find("ai_report_url", 1, true) ~= nil)
local pub = read("lapis/routes/crm-leads-public.lua")
check("the public download is rate limited and checks the lead", pub:find('prefix = "lead_report"', 1, true)
    and pub:find("deleted_at IS NULL", 1, true))
check("staff download needs crm_leads read and a visible lead",
    read("lapis/routes/crm-leads.lua"):find('app:get("/api/v2/crm/leads/:uuid/report", H("crm_leads", "read"', 1, true) ~= nil)

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
