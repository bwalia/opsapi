--[[
    CSS Sanitizer
    =============

    Allowlist-based sanitizer for user-supplied CSS. Runs on BOTH write and
    read paths (defense-in-depth) so even if a malicious row is inserted via
    raw SQL it cannot exfiltrate or alter UI at serve time.

    Blocks:
      - @import            (exfiltration via CSS from attacker domain)
      - @charset hijack    (IE/legacy parser confusion)
      - expression(...)    (legacy IE arbitrary JS)
      - javascript: URIs   (inline JS via background-image etc.)
      - behavior:          (HTC binding attacks)
      - -moz-binding       (XBL binding attacks)
      - vbscript:          (legacy VBScript)
      - data: URIs         (except whitelisted image mimetypes)
      - url()              (except https:// or whitelisted data:image)
      - <script> / <style> tags (accidental HTML-in-CSS pastes)
      - Backslash escapes  (used to obfuscate the keywords above)

    Size caps:
      - 50 KB total
      - 500 lines (prevents compilation bombs)

    The sanitizer is intentionally strict. Users who need richer CSS features
    can request additions — adding to the allowlist is safer than starting
    permissive.
]]

local CssSanitizer = {}

CssSanitizer.MAX_SIZE_BYTES = 50 * 1024
CssSanitizer.MAX_LINES      = 500

-- Hosts allowed inside url(). Keep this short.
-- Dashboards typically reference MinIO-hosted assets via a single CDN.
CssSanitizer.ALLOWED_URL_HOSTS = {
    -- runtime-populated via CssSanitizer.registerAllowedHost(host)
}

-- Google Fonts is explicitly permitted (the token editor's font picker writes
-- @import rules). Other @import sources remain blocked.
CssSanitizer.ALLOWED_IMPORT_HOSTS = {
    ["fonts.googleapis.com"] = true,
    ["fonts.gstatic.com"]    = true,
}

-- Whitelisted data: URI mime types (for tiny inline SVG icons in CSS)
CssSanitizer.ALLOWED_DATA_MIME = {
    ["image/svg+xml"] = true,
    ["image/png"]     = true,
    ["image/jpeg"]    = true,
    ["image/webp"]    = true,
    ["image/gif"]     = true,
}

--- Register an additional allowed host for url() references.
-- Call this at startup with the configured MinIO / CDN host.
function CssSanitizer.registerAllowedHost(host)
    if host and host ~= "" then
        CssSanitizer.ALLOWED_URL_HOSTS[host:lower()] = true
    end
end

-- =============================================================================
-- Internal checks
-- =============================================================================

-- Normalise for pattern matching: strip CSS comments, collapse whitespace,
-- and decode common backslash escapes so obfuscation can't sneak past.
local function normalise(css)
    -- Remove /* ... */ comments (non-greedy)
    css = css:gsub("/%*.-%*/", "")
    -- Decode hex-escape characters used to obfuscate keywords, e.g. \65 = 'A'
    css = css:gsub("\\(%x%x?%x?%x?%x?%x?)%s?", function(hex)
        local n = tonumber(hex, 16)
        if n and n >= 32 and n <= 126 then
            return string.char(n)
        end
        return ""
    end)
    -- Remove stray backslashes so they can't split keywords
    css = css:gsub("\\", "")
    return css:lower()
end

local function is_host_allowed(host, allowlist)
    if not host or host == "" then return false end
    host = host:lower()
    if allowlist[host] then return true end
    -- Allow subdomains of explicitly listed hosts
    for allowed in pairs(allowlist) do
        if host:sub(-#allowed - 1) == "." .. allowed then
            return true
        end
    end
    return false
end

-- Extract the scheme + host from a URL-ish string (best-effort, not a full parser)
local function parse_url(url)
    url = url:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("%s", "")
    local scheme, rest = url:match("^(%a[%w+.-]*):(.*)$")
    if not scheme then return nil, nil, url end
    local host = rest:match("^//([^/%?#]+)") or ""
    -- Strip userinfo and port
    host = host:gsub("^[^@]+@", ""):gsub(":%d+$", "")
    return scheme:lower(), host, url
end

-- =============================================================================
-- Public: sanitise(raw_css) -> (clean_css, { warnings })
-- =============================================================================
--- Sanitise user-supplied CSS. Returns the cleaned CSS (which may be empty)
-- and a table of human-readable warnings for any rules that were stripped.
-- Never throws — the worst case is empty output.
function CssSanitizer.sanitise(raw_css)
    local warnings = {}

    if type(raw_css) ~= "string" or raw_css == "" then
        return "", warnings
    end

    if #raw_css > CssSanitizer.MAX_SIZE_BYTES then
        table.insert(warnings, string.format(
            "CSS too large (%d bytes); truncated to %d bytes",
            #raw_css, CssSanitizer.MAX_SIZE_BYTES
        ))
        raw_css = raw_css:sub(1, CssSanitizer.MAX_SIZE_BYTES)
    end

    -- Enforce line cap
    local line_count = 0
    for _ in raw_css:gmatch("\n") do line_count = line_count + 1 end
    if line_count > CssSanitizer.MAX_LINES then
        table.insert(warnings, string.format(
            "CSS exceeds %d lines; truncated", CssSanitizer.MAX_LINES
        ))
        local cut = 0
        raw_css = raw_css:gsub("\n", function()
            cut = cut + 1
            if cut > CssSanitizer.MAX_LINES then return "" end
            return "\n"
        end)
    end

    local normalised = normalise(raw_css)

    -- HTML tag smuggling
    if normalised:find("<script") or normalised:find("<style") or normalised:find("</script") or normalised:find("</style") then
        table.insert(warnings, "HTML tags are not permitted in CSS; blocked")
        return "", warnings
    end

    -- Dangerous keywords (case-insensitive, escape-decoded)
    local banned_patterns = {
        { "expression%s*%(",     "expression() is not permitted" },
        { "javascript%s*:",      "javascript: URIs are not permitted" },
        { "vbscript%s*:",        "vbscript: URIs are not permitted" },
        { "behavior%s*:",        "behavior: is not permitted" },
        { "%-moz%-binding%s*:",  "-moz-binding is not permitted" },
    }
    for _, rule in ipairs(banned_patterns) do
        if normalised:find(rule[1]) then
            table.insert(warnings, rule[2])
            return "", warnings
        end
    end

    -- @charset hijack
    if normalised:find("@charset") then
        table.insert(warnings, "@charset is not permitted")
        return "", warnings
    end

    -- Validate @import rules — only Google Fonts (and registered allow-listed hosts)
    local import_ok = true
    for import_expr in normalised:gmatch("@import%s+([^;]+);") do
        local url_arg = import_expr:match("url%s*%(([^)]+)%)") or import_expr
        local scheme, host = parse_url(url_arg)
        if scheme ~= "https" or not is_host_allowed(host, CssSanitizer.ALLOWED_IMPORT_HOSTS) then
            table.insert(warnings, string.format(
                "@import blocked (only https://fonts.googleapis.com and fonts.gstatic.com permitted): %s",
                import_expr
            ))
            import_ok = false
            break
        end
    end
    if not import_ok then
        return "", warnings
    end

    -- Validate every url(...) reference
    local url_ok = true
    for url_arg in normalised:gmatch("url%s*%(([^)]+)%)") do
        local scheme, host, cleaned = parse_url(url_arg)
        local allowed = false

        if scheme == "https" then
            -- Always allow https URLs to registered hosts; allow Google Fonts too
            if is_host_allowed(host, CssSanitizer.ALLOWED_URL_HOSTS)
               or is_host_allowed(host, CssSanitizer.ALLOWED_IMPORT_HOSTS) then
                allowed = true
            end
        elseif scheme == "data" then
            -- data:<mime>;base64,... — check mime against allowlist
            local mime = cleaned:match("^data:([%w/%+%-%.]+)[;,]")
            if mime and CssSanitizer.ALLOWED_DATA_MIME[mime:lower()] then
                allowed = true
            end
        elseif scheme == nil then
            -- Relative/anchor url(#id) used for SVG filter references — allow
            if cleaned:sub(1, 1) == "#" then
                allowed = true
            end
        end

        if not allowed then
            table.insert(warnings, string.format(
                "url() blocked (scheme=%s host=%s); only https to allowed hosts and data: images permitted",
                scheme or "none", host or ""
            ))
            url_ok = false
            break
        end
    end
    if not url_ok then
        return "", warnings
    end

    -- Everything passed — return the ORIGINAL css (preserving user formatting),
    -- not the normalised version. The checks above guarantee the original is safe.
    return raw_css, warnings
end

--- Quick yes/no helper — returns true if sanitise() would return the input unchanged
function CssSanitizer.isSafe(css)
    local clean, warnings = CssSanitizer.sanitise(css)
    return clean == css and #warnings == 0
end

return CssSanitizer
