--[[
    Spec: the lead pipeline's pure parts — stage rules, working-hours
    arithmetic and calendar invites (lib/crm/lead-stages.lua,
    lib/crm/working-hours.lua, lib/crm/ics.lua). No database.

    Run inside the API container:
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/crm-lead-pipeline-pure_spec.lua
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

local S = require("lib.crm.lead-stages")
print("lead stages")
check("aliases: contacted -> contacting", S.normalise("Contacted ") == "contacting")
check("unknown stage -> nil", S.normalise("won") == nil and S.normalise(nil) == nil)
check("open -> qualified allowed", S.can_move("contacting", "qualified") == true)
check("lost -> contacting allowed (reopen)", S.can_move("lost", "contacting") == true)
local ok, code = S.can_move("meeting", "converted")
check("converted only via convert", ok == nil and code == "use_convert")
ok, code = S.can_move("converted", "lost")
check("converted never moves", ok == nil and code == "converted")
ok, code = S.can_move("new", "new")
check("same stage refused", ok == nil and code == "same_stage")
check("funnel rank", S.rank("new") == 1 and S.rank("converted") == 5 and S.rank("lost") == 0)
local labels = S.labels({ new = "Fresh", bogus = "x", lost = "" })
check("label overrides: known + non-empty only", labels.new == "Fresh" and labels.lost == "Lost" and labels.bogus == nil)

local WH = require("lib.crm.working-hours")
print("working hours")
local h = assert(WH.normalise({ start = "09:00", ["end"] = "17:30", days = { 1, 2, 3, 4, 5 } }))
local d, m = WH.add(h, 1, 10 * 60, 60)          -- Mon 10:00 + 60 -> Mon 11:00
check("inside hours: same day", d == 0 and m == 11 * 60, d .. " " .. m)
d, m = WH.add(h, 5, 17 * 60 + 20, 60)           -- Fri 17:20 + 60 -> Mon 09:50
check("Friday evening rolls to Monday", d == 3 and m == 9 * 60 + 50, d .. " " .. m)
d, m = WH.add(h, 6, 12 * 60, 30)                -- Sat noon + 30 -> Mon 09:30
check("weekend starts Monday morning", d == 2 and m == 9 * 60 + 30, d .. " " .. m)
d, m = WH.add(h, 2, 7 * 60, 0)                  -- Tue 07:00 + 0 -> Tue 09:00
check("before opening, zero minutes = opening time", d == 0 and m == 9 * 60, d .. " " .. m)
d, m = WH.add(h, 3, 16 * 60, 9 * 60)            -- Wed 16:00 + 9h -> Thu 16:30 (1.5h Wed + 7.5h Thu)
check("spans a full day", d == 1 and m == 16 * 60 + 30, d .. " " .. m)
check("inside()", WH.inside(h, 1, 9 * 60) and not WH.inside(h, 1, 17 * 60 + 30) and not WH.inside(h, 7, 600))
local bad, err = WH.normalise({ start = "18:00", ["end"] = "09:00" })
check("end before start refused", bad == nil and err:find("after"), err)
bad, err = WH.normalise({ days = { 9, 0 } })
check("no valid day refused", bad == nil and err ~= nil, err)
local all7 = assert(WH.normalise({ start = "00:00", ["end"] = "23:59", days = { 1, 2, 3, 4, 5, 6, 7 } }))
d, m = WH.add(all7, 1, 100, 30)
check("24/7-ish", d == 0 and m == 130)

local ICS = require("lib.crm.ics")
print("calendar invites")
check("escape", ICS.escape("a,b;c\\d\ne") == "a\\,b\\;c\\\\d\\ne")
check("utc", ICS.utc("2026-11-05T14:30:00Z") == "20261105T143000Z" and ICS.utc("2026-11-05 14:30") == "20261105T143000Z")
local ics = assert(ICS.build({
    uid = "abc@opsapi", sequence = 2, starts_utc = "2026-11-05T14:30:00Z", ends_utc = "2026-11-05T15:00:00Z",
    stamp_utc = "2026-11-04T10:00:00Z", summary = "Call with Ann, re: offer", location = "Zoom",
    url = "https://zoom.us/j/1", organizer = { email = "sam@example.com", name = "Sam Taylor" },
    attendees = { { email = "ann@example.com", name = "Ann Lee" } },
    description = string.rep("Long description line. ", 10),
}))
check("CRLF line endings", ics:find("\r\nEND:VCALENDAR\r\n", 1, true) ~= nil)
check("method request + sequence", ics:find("METHOD:REQUEST", 1, true) and ics:find("SEQUENCE:2", 1, true))
check("summary escaped", ics:find("SUMMARY:Call with Ann\\, re: offer", 1, true) ~= nil)
local unfolded = ics:gsub("\r\n ", "")
check("attendee (after unfolding)", unfolded:find("ATTENDEE;CN=Ann Lee;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:ann@example.com", 1, true) ~= nil)
local too_long = false
for line in ics:gmatch("([^\r\n]*)\r\n") do if #line > 75 then too_long = true end end
check("lines folded to 75 octets", not too_long)
local cancel = assert(ICS.build({ uid = "abc@opsapi", sequence = 3, method = "CANCEL",
    starts_utc = "2026-11-05T14:30:00Z", ends_utc = "2026-11-05T15:00:00Z" }))
check("cancel", cancel:find("METHOD:CANCEL", 1, true) and cancel:find("STATUS:CANCELLED", 1, true)
    and not cancel:find("VALARM", 1, true))
local folded = ICS.fold(string.rep("é", 60))      -- 120 octets of 2-byte chars
local split_inside = false
for part in (folded .. "\r\n "):gmatch("(.-)\r\n ") do
    local last = part:byte(#part)
    if last and last >= 0xC0 then split_inside = true end
end
check("fold never splits a UTF-8 character", not split_inside)
check("missing start refused", ICS.build({ uid = "x", ends_utc = "2026-11-05T15:00:00Z" }) == nil)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
