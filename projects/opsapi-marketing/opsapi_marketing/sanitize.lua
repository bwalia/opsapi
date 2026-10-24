-- HTML / URL sanitisation for marketing templates (email-safe).
-- Strips scripts, event handlers, dangerous protocols; validates http(s) URLs.
-- Note: Lua patterns do NOT support | alternation — check protocols individually.
local S = {}

local function is_dangerous_proto(url)
    if type(url) ~= "string" then return true end
    local u = url:lower():match("^%s*(.-)%s*$") or ""
    return u:match("^javascript%s*:") or u:match("^vbscript%s*:")
        or u:match("^data%s*:") or u:match("^file%s*:")
end

function S.strip_html(html)
    if type(html) ~= "string" then return "" end
    -- A rich-text editor can auto-link a typed merge tag ("contact.company" looks like a domain),
    -- storing {{<a href="http://contact.company">contact.company</a>}}: unwrap it back to {{contact.company}}.
    html = html:gsub("{{%s*<[Aa]%s[^>]*>%s*([%w_%.]+)%s*</[Aa]%s*>%s*}}", "{{%1}}")
    html = html:gsub("<%s*[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-<%s*/%s*[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", "")
    html = html:gsub("<%s*[Ss][Tt][Yy][Ll][Ee][^>]*>.-<%s*/%s*[Ss][Tt][Yy][Ll][Ee]%s*>", "")
    html = html:gsub("<%s*[Ii][Ff][Rr][Aa][Mm][Ee][^>]*>.-<%s*/%s*[Ii][Ff][Rr][Aa][Mm][Ee]%s*>", "")
    html = html:gsub("<%s*[Oo][Bb][Jj][Ee][Cc][Tt][^>]*>.-<%s*/%s*[Oo][Bb][Jj][Ee][Cc][Tt]%s*>", "")
    html = html:gsub("<%s*[Ee][Mm][Bb][Ee][Dd][^>]*/?%s*>", "")
    html = html:gsub("<%s*[Ff][Oo][Rr][Mm][^>]*>.-<%s*/%s*[Ff][Oo][Rr][Mm]%s*>", "")
    html = html:gsub("<%s*[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>", "")
    html = html:gsub("<%s*[Ii][Ff][Rr][Aa][Mm][Ee][^>]*>", "")
    html = html:gsub("%s[Oo][Nn]%w+%s*=%s*\"[^\"]*\"", "")
    html = html:gsub("%s[Oo][Nn]%w+%s*=%s*'[^']*'", "")
    html = html:gsub("%s[Oo][Nn]%w+%s*=%s*[^%s>]+", "")

    -- Lua patterns have no | alternation — scrub href and src separately.
    local function scrub_dq(attr, url)
        if is_dangerous_proto(url) then return attr .. '="#"' end
        return attr .. '="' .. url .. '"'
    end
    local function scrub_sq(attr, url)
        if is_dangerous_proto(url) then return attr .. "='#'" end
        return attr .. "='" .. url .. "'"
    end
    html = html:gsub("([Hh][Rr][Ee][Ff])%s*=%s*\"([^\"]*)\"", scrub_dq)
    html = html:gsub("([Ss][Rr][Cc])%s*=%s*\"([^\"]*)\"", scrub_dq)
    html = html:gsub("([Hh][Rr][Ee][Ff])%s*=%s*'([^']*)'", scrub_sq)
    html = html:gsub("([Ss][Rr][Cc])%s*=%s*'([^']*)'", scrub_sq)
    return html
end

function S.safe_url(url)
    if type(url) ~= "string" or url == "" then return nil, "empty url" end
    local u = url:match("^%s*(.-)%s*$")
    if u:match("^{{.+}}$") then return u end
    if u:match("^#") then return u end
    if u:match("^mailto:[^%s]+@[^%s]+$") then return u end
    if is_dangerous_proto(u) then return nil, "dangerous protocol" end
    if u:match("^https?://[%w%-%._~:/%?#%[%]@!$&'()*+,;=%%]+$") then
        if u:match("^https?://(localhost|127%.|10%.|192%.168%.|169%.254%.)") then
            return nil, "private host"
        end
        return u
    end
    return nil, "invalid url"
end

function S.extract_merge_keys(tpl)
    local keys, seen = {}, {}
    if type(tpl) ~= "string" then return keys end
    for key in tpl:gmatch("{{%s*([%w_%.]+)%s*}}") do
        if not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    return keys
end

function S.warnings(payload, channel)
    local w = {}
    channel = channel or "email"
    local html = payload.body_html or payload.html or ""
    local text = payload.body_text or payload.text or ""
    local subject = payload.subject or ""

    if channel == "email" then
        if subject == "" then w[#w + 1] = "missing_subject" end
        if html == "" and text == "" then w[#w + 1] = "missing_body" end
        local blob = (html .. " " .. text):lower()
        if not blob:find("unsubscribe", 1, true) and not blob:find("{{unsubscribe", 1, true) then
            w[#w + 1] = "missing_unsubscribe_link"
        end
        if html:lower():find("<script", 1, true) or html:lower():find("javascript:", 1, true) then
            w[#w + 1] = "unsafe_html_detected"
        end
        if #subject > 78 then w[#w + 1] = "subject_long_for_inbox" end
    elseif channel == "sms" then
        if text == "" then w[#w + 1] = "missing_body" end
        if #text > 160 then w[#w + 1] = "sms_multipart" end
        if #text > 1600 then w[#w + 1] = "sms_too_long" end
        if not text:lower():find("stop", 1, true) then
            w[#w + 1] = "missing_stop_keyword_hint"
        end
    end
    return w
end

return S
