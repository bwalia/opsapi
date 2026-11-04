--[[
    iCalendar invites (RFC 5545 / iTIP RFC 5546)
    ============================================

    One VEVENT per meeting. The UID stays the same for the meeting's whole
    life and SEQUENCE goes up on every change, so Google, Outlook and Apple
    calendars update (or remove, METHOD:CANCEL) the event they already have
    instead of adding a second one. Times are UTC ("Z"), which every client
    shows in the reader's own zone. Pure module, unit tested in spec/crm_ics_spec.lua.
]]

local ICS = {}

-- TEXT escaping (RFC 5545 §3.3.11).
function ICS.escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub(";", "\\;"):gsub(",", "\\,"):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
    return s
end

-- Lines longer than 75 octets are folded (CRLF + one space), never inside a
-- UTF-8 sequence.
function ICS.fold(line)
    if #line <= 75 then return line end
    local out, i, limit = {}, 1, 75
    while i <= #line do
        local j = math.min(i + limit - 1, #line)
        -- Step back to a UTF-8 boundary: never end before a continuation byte.
        while j < #line and j > i and line:byte(j + 1) and line:byte(j + 1) >= 0x80 and line:byte(j + 1) < 0xC0 do
            j = j - 1
        end
        out[#out + 1] = line:sub(i, j)
        i = j + 1
        limit = 74 -- continuation lines start with a space
    end
    return table.concat(out, "\r\n ")
end

--- "2026-11-05T14:30:00Z" (or any ISO with a "Z"/offset handled by the
-- caller) -> "20261105T143000Z". The caller passes UTC.
function ICS.utc(iso)
    local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d?%d?)")
    if not y then return nil end
    if s == "" then s = "00" end
    return y .. mo .. d .. "T" .. h .. mi .. s .. "Z"
end

local function mailto(person)
    local cn = person.name and person.name ~= "" and (";CN=" .. ICS.escape(person.name):gsub(":", "")) or ""
    return cn, "mailto:" .. tostring(person.email)
end

--- e = { uid, sequence, method ("REQUEST"|"CANCEL"), starts_utc, ends_utc, stamp_utc,
--        summary, description, location, url, organizer = {email,name},
--        attendees = { {email,name}, ... } }
-- @return the .ics text (CRLF line endings) | nil, err
function ICS.build(e)
    if type(e) ~= "table" then return nil, "event required" end
    local dtstart, dtend = ICS.utc(e.starts_utc), ICS.utc(e.ends_utc)
    if not (e.uid and dtstart and dtend) then return nil, "uid, start and end are required" end
    local method = e.method == "CANCEL" and "CANCEL" or "REQUEST"
    local lines = {
        "BEGIN:VCALENDAR",
        "PRODID:-//OpsAPI//Lead pipeline//EN",
        "VERSION:2.0",
        "CALSCALE:GREGORIAN",
        "METHOD:" .. method,
        "BEGIN:VEVENT",
        "UID:" .. e.uid,
        "SEQUENCE:" .. tostring(math.max(0, math.floor(tonumber(e.sequence) or 0))),
        "DTSTAMP:" .. (ICS.utc(e.stamp_utc) or dtstart),
        "DTSTART:" .. dtstart,
        "DTEND:" .. dtend,
        "SUMMARY:" .. ICS.escape(e.summary or "Meeting"),
        "STATUS:" .. (method == "CANCEL" and "CANCELLED" or "CONFIRMED"),
        "TRANSP:OPAQUE",
    }
    if e.description and e.description ~= "" then lines[#lines + 1] = "DESCRIPTION:" .. ICS.escape(e.description) end
    if e.location and e.location ~= "" then lines[#lines + 1] = "LOCATION:" .. ICS.escape(e.location) end
    if e.url and e.url ~= "" then lines[#lines + 1] = "URL:" .. e.url end
    if e.organizer and e.organizer.email then
        local cn, addr = mailto(e.organizer)
        lines[#lines + 1] = "ORGANIZER" .. cn .. ":" .. addr
    end
    for _, a in ipairs(e.attendees or {}) do
        if a.email and a.email ~= "" then
            local cn, addr = mailto(a)
            lines[#lines + 1] = "ATTENDEE" .. cn .. ";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:" .. addr
        end
    end
    if method == "REQUEST" then
        lines[#lines + 1] = "BEGIN:VALARM"
        lines[#lines + 1] = "TRIGGER:-PT15M"
        lines[#lines + 1] = "ACTION:DISPLAY"
        lines[#lines + 1] = "DESCRIPTION:" .. ICS.escape(e.summary or "Meeting")
        lines[#lines + 1] = "END:VALARM"
    end
    lines[#lines + 1] = "END:VEVENT"
    lines[#lines + 1] = "END:VCALENDAR"
    for i, l in ipairs(lines) do lines[i] = ICS.fold(l) end
    return table.concat(lines, "\r\n") .. "\r\n"
end

return ICS
