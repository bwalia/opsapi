-- Outbound link handling: UTM tagging, query-param helpers and click-tracking rewrite
-- of rendered email HTML/text.
local L = {}

local function unescape_amp(s)
    return (s:gsub("&amp;", "&"))
end

local function escape_amp(s)
    return (s:gsub("&", "&amp;"))
end

--- Does the URL's query string already carry `name`?
function L.has_param(url, name)
    local q = url:match("%?([^#]*)")
    if not q then return false end
    for k in q:gmatch("([^&=]+)=?[^&]*") do
        if k == name then return true end
    end
    return false
end

--- Append params (ordered list of {k, v}) before any #fragment; existing keys win.
function L.add_params(url, params)
    local base, frag = url:match("^([^#]*)(#?.*)$")
    local parts = {}
    for _, kv in ipairs(params) do
        local k, v = kv[1], kv[2]
        if v ~= nil and v ~= "" and not L.has_param(base, k) then
            parts[#parts + 1] = ngx.escape_uri(k) .. "=" .. ngx.escape_uri(tostring(v))
        end
    end
    if #parts == 0 then return url end
    local sep = base:find("?", 1, true) and (base:match("[?&]$") and "" or "&") or "?"
    return base .. sep .. table.concat(parts, "&") .. frag
end

--- Lower-case slug for utm_campaign defaults.
function L.slug(s)
    s = tostring(s or ""):lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
    return s ~= "" and s:sub(1, 80) or "campaign"
end

--- UTM params for a campaign (tracking.utm overrides defaults).
function L.utm_params(campaign, tracking, variant_key)
    local utm = type(tracking.utm) == "table" and tracking.utm or {}
    if utm.enabled == false then return {} end
    return {
        { "utm_source", utm.source or "opsapi" },
        { "utm_medium", utm.medium or campaign.channel or "email" },
        { "utm_campaign", utm.campaign or L.slug(campaign.name) },
        { "utm_content", utm.content or variant_key },
        { "utm_id", campaign.uuid },
    }
end

local function trackable(url, skip)
    if not url:match("^https?://") then return false end
    for _, s in ipairs(skip or {}) do
        if url:find(s, 1, true) then return false end
    end
    return true
end

--- Rewrite every <a href="http(s)://..."> through fn(url) -> url. Links carrying
-- data-mkt-notrack, and any containing a `skip` substring, are left untouched.
function L.rewrite_html(html, fn, skip)
    if type(html) ~= "string" or html == "" then return html end
    return (html:gsub("(<[aA]%s[^>]*>)", function(tag)
        if tag:lower():find("data-mkt-notrack", 1, true) then return tag end
        return (tag:gsub("([hH][rR][eE][fF]%s*=%s*)([\"'])(.-)%2", function(pre, q, raw)
            local url = unescape_amp(raw)
            if not trackable(url, skip) then return pre .. q .. raw .. q end
            local out = fn(url)
            if not out then return pre .. q .. raw .. q end
            return pre .. q .. escape_amp(out) .. q
        end, 1))
    end))
end

--- Rewrite bare http(s) URLs in a plain-text body.
function L.rewrite_text(text, fn, skip)
    if type(text) ~= "string" or text == "" then return text end
    return (text:gsub("https?://[^%s<>\"']+", function(url)
        -- Keep trailing sentence punctuation outside the link.
        local core, tail = url:match("^(.-)([%.,;:!%)]*)$")
        if not trackable(core, skip) then return url end
        return (fn(core) or core) .. tail
    end))
end

return L
