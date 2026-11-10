-- luacheck: max line length 140
--[[
    lib/mail-recipients.lua: reserved test domains are never mailed (they only bounce).
    Standalone — run from the repo root:  luajit lapis/spec/mail-recipients_spec.lua
]]
package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path
local R = require("lib.mail-recipients")

local failures = 0
local function check(name, ok, detail)
    print((ok and "  ok   - " or "  FAIL - ") .. name .. ((not ok and detail) and ("  [" .. tostring(detail) .. "]") or ""))
    if not ok then failures = failures + 1 end
end

for _, a in ipairs({ "lp-rep1@e2e.invalid", "x@example.com", "y@EXAMPLE.ORG", "z@mail.example.net", "manager@workstation.test",
                     "a@foo.example", "b@localhost", "Sam <sam@e2e.invalid>", "c@co.invalid." }) do
    check("undeliverable: " .. a, R.undeliverable(a))
end
for _, a in ipairs({ "harcharan@workstation.co.uk", "someone@gmail.com", "x@example.co.uk", "y@notexample.com",
                     "test@company.com", "Ann <ann@diytaxreturn.co.uk>", "not-an-email", "" }) do
    check("deliverable (or not an address): " .. a, not R.undeliverable(a))
end

local kept, dropped = R.filter("lp-rep1@e2e.invalid")
check("a single fake address leaves nothing", kept == nil and #dropped == 1)
kept, dropped = R.filter("real@workstation.co.uk")
check("a single real address stays a string", kept == "real@workstation.co.uk" and #dropped == 0)
kept, dropped = R.filter({ "a@workstation.co.uk", "b@e2e.invalid", "c@gmail.com" })
check("a list keeps the real ones",
    type(kept) == "table" and #kept == 2 and kept[2] == "c@gmail.com" and dropped[1] == "b@e2e.invalid")
kept, dropped = R.filter("a@workstation.co.uk, b@example.com")
check("a comma-separated string keeps the real one", kept == "a@workstation.co.uk" and dropped[1] == "b@example.com")
kept = R.filter(nil)
check("nothing in, nothing out", kept == nil)

local mail = assert(io.open("lapis/helper/mail.lua")):read("*a")
local send_at = mail:find("function Mail.send", 1, true)
check("Mail.send filters to/cc/bcc before SMTP", send_at
    and mail:find('keep("to")', send_at, true) ~= nil
    and mail:find('keep("cc")', send_at, true) ~= nil
    and mail:find('keep("bcc")', send_at, true) ~= nil)
check("…and before the async send",
    mail:find('keep("to")', send_at, true) < mail:find("ngx.timer.at(0, function(premature)", send_at, true))

print(failures == 0 and "\nall mail-recipients checks passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
