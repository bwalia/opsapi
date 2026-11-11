--[[
    Spec: extra lead-confirmation content (lib/crm/lead-confirmation.lua), honoured for the shop BFF only.

    Standalone, from the repo root:
        luajit lapis/spec/lead-confirmation_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path
local LC = require("lib.crm.lead-confirmation")

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
    local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end

print("clean content is kept")
local c = LC.sanitize({
    highlights = { "  It looks like you need it as soon as possible (within 6 weeks).  ", "Private AI for my team" },
    call_phone = "+44 7515 356 146",
    call_url = "https://wa.me/447515356146",
    book_url = "https://www.workstation.co.uk/en/book-online",
    subject = "Your AI build: what happens next",
})
check("highlights trimmed", c and c.highlights[1] == "It looks like you need it as soon as possible (within 6 weeks).", c and c.highlights[1])
check("two highlights", c and #c.highlights == 2)
check("phone kept", c and c.call_phone == "+44 7515 356 146")
check("WhatsApp link kept", c and c.call_url == "https://wa.me/447515356146")
check("booking link kept", c and c.book_url == "https://www.workstation.co.uk/en/book-online")
check("subject kept", c and c.subject == "Your AI build: what happens next")

print("unsafe or oversized content is dropped")
local many = {}
for i = 1, 20 do many[i] = string.rep("x", 500) end
many[3] = { nested = true }
c = LC.sanitize({ highlights = many, call_phone = "call me <b>now</b>", call_url = "javascript:alert(1)", book_url = "http://example.com/book" })
check("at most 8 highlights", #c.highlights == 8, #c.highlights)
check("highlight capped at 240 chars", #c.highlights[1] == 240, #c.highlights[1])
check("non-numeric phone dropped", c.call_phone == nil)
check("javascript: link dropped", c.call_url == nil)
check("http (not https) link dropped", c.book_url == nil)
c = LC.sanitize({ highlights = { "line one\nline two\tthree" } })
check("control characters flattened", c.highlights[1] == "line one line two three", c.highlights[1])

print("nothing usable gives nil")
check("nil input", LC.sanitize(nil) == nil)
check("string input", LC.sanitize("x") == nil)
check("only blanks", LC.sanitize({ highlights = { "", "   " }, call_url = "ftp://x" }) == nil)

print("wiring")
local route = read("lapis/routes/crm-leads-public.lua")
check("public route honours confirmation only for the shop BFF",
    route:find("secure_equals", 1, true) ~= nil and route:find("SHOP_BFF_KEY", 1, true) ~= nil and route:find("LeadConfirmation.sanitize", 1, true) ~= nil)
local tpl = read("lapis/views/emails/lead_confirmation.etlua")
check("template no longer says no action is required", not tpl:lower():find("no action is required", 1, true))
check("template escapes highlights (<%= not <%-)", tpl:find("<%= h %>", 1, true) ~= nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
