-- Classify tracking hits from security scanners, link checkers and crawlers so they
-- don't inflate opens/clicks or trigger attribution. Heuristic: user agent + timing.
local B = {}

-- Lower-case substrings seen in mail-security scanners, prefetchers and HTTP libraries.
local UA_MARKERS = {
    "bot", "crawler", "spider", "slurp", "scanner", "linkcheck", "preview",
    "barracuda", "proofpoint", "mimecast", "messagelabs", "symantec", "trendmicro",
    "forcepoint", "fireeye", "sophos", "cisco", "ironport", "safelinks", "urldefense",
    "headlesschrome", "phantomjs", "puppeteer", "playwright",
    "python-requests", "python-urllib", "aiohttp", "curl/", "wget", "go-http-client",
    "java/", "okhttp", "apache-httpclient", "libwww", "httpclient", "node-fetch", "axios/",
    "facebookexternalhit", "whatsapp", "skypeuripreview", "discordbot",
}

-- Gmail and Yahoo proxy images when the human opens the message: real opens.
local HUMAN_PROXIES = { "googleimageproxy", "yahoomailproxy" }

--- @return is_bot boolean, reason string|nil
function B.classify(user_agent, opts)
    opts = opts or {}
    local ua = type(user_agent) == "string" and user_agent:lower() or ""
    if opts.method == "HEAD" then return true, "head_request" end
    for _, p in ipairs(HUMAN_PROXIES) do
        if ua:find(p, 1, true) then return false, nil end
    end
    if ua == "" then return true, "no_user_agent" end
    for _, m in ipairs(UA_MARKERS) do
        if ua:find(m, 1, true) then return true, "ua:" .. m end
    end
    -- A click within a couple of seconds of hand-off is a scanner following links.
    if opts.seconds_since_send and opts.seconds_since_send >= 0 and opts.seconds_since_send < 3 then
        return true, "too_fast"
    end
    return false, nil
end

return B
