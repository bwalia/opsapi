--[[
    Extra content for the lead confirmation email, sent by a trusted caller.

    The shop's "What do I need?" survey (a BFF call carrying X-Shop-Key) passes
    `confirmation` with the public lead: a few bullet points read back from the
    visitor's answers, and how to reach an engineer now. The public endpoint is
    unauthenticated, so this is honoured ONLY for the BFF (otherwise anyone could
    mail our branded email, with their own words, to any address), and every
    field is checked here: plain strings, bounded lengths, https links only.
]]

local LeadConfirmation = {}

local MAX_HIGHLIGHTS = 8

local function text(v, max)
    if type(v) ~= "string" then return nil end
    v = v:gsub("[%c]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then return nil end
    if #v > max then v = v:sub(1, max) end
    return v
end

local function https_url(v)
    v = text(v, 500)
    if v and v:match("^https://[%w%.%-]+%.[%a][%a]+[/?#]?[%w%-%._~:/?#%[%]@!$&'()*+,;=%%]*$") then return v end
    return nil
end

local function phone(v)
    v = text(v, 40)
    if v and v:match("^[%d%+%(%)%-%s]+$") then return v end
    return nil
end

--- Validate a caller-supplied confirmation table. Returns a clean table, or nil when nothing usable is left.
function LeadConfirmation.sanitize(c)
    if type(c) ~= "table" then return nil end
    local out = { highlights = {} }
    if type(c.highlights) == "table" then
        for _, h in ipairs(c.highlights) do
            if #out.highlights >= MAX_HIGHLIGHTS then break end
            local t = text(h, 240)
            if t then out.highlights[#out.highlights + 1] = t end
        end
    end
    out.intro = text(c.intro, 400)
    out.handover = text(c.handover, 400)
    out.call_phone = phone(c.call_phone)
    out.call_url = https_url(c.call_url)
    if not out.call_phone then out.call_url = nil end
    out.book_url = https_url(c.book_url)
    out.subject = text(c.subject, 120)
    if #out.highlights == 0 and not out.intro and not out.handover and not out.call_phone and not out.book_url then return nil end
    return out
end

return LeadConfirmation
