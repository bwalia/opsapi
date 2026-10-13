-- Small shared helpers for the ai_runner plugin.
local cjson = require("cjson")
local db = require("lapis.db")

local U = {}

U.UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

function U.is_uuid(v)
    return type(v) == "string" and v:match(U.UUID) ~= nil
end

function U.one(sql, ...)
    return db.query(sql, ...)[1]
end

function U.array(t)
    return setmetatable(t or {}, cjson.array_mt)
end

--- jsonb may come back decoded or as a string.
function U.json(v)
    if type(v) == "string" then
        local ok, decoded = pcall(cjson.decode, v)
        if ok then return decoded end
    end
    return v
end

--- nil -> JSON null, so API objects keep a stable set of keys.
function U.null(v)
    if v == nil then return cjson.null end
    return v
end

function U.sha256(s)
    local h = require("resty.sha256"):new()
    h:update(s)
    return require("resty.string").to_hex(h:final())
end

--- A new token: prefix ("oprn_" runner, "oprt_" run) + 48 hex (24 bytes from the OS CSPRNG).
-- Returns raw, sha256 hex, display hint.
function U.new_token(prefix)
    local bytes = require("resty.random").bytes(24, true)
    if not bytes then error("ai_runner: no secure random bytes available") end -- never fall back to math.random
    local raw = (prefix or "oprn_") .. require("resty.string").to_hex(bytes)
    return raw, U.sha256(raw), raw:sub(1, 11)
end

--- Run fn in a transaction (a savepoint when nested). Re-raises after rolling back.
function U.tx(fn)
    local depth = ngx.ctx.ar_tx or 0
    local sp = "ar_sp" .. depth
    db.query(depth == 0 and "BEGIN" or ("SAVEPOINT " .. sp))
    ngx.ctx.ar_tx = depth + 1
    local ok, a, b, c = pcall(fn)
    ngx.ctx.ar_tx = depth
    if ok then
        db.query(depth == 0 and "COMMIT" or ("RELEASE SAVEPOINT " .. sp))
        return a, b, c
    end
    db.query(depth == 0 and "ROLLBACK" or ("ROLLBACK TO SAVEPOINT " .. sp))
    error(a, 0)
end

--- A user-facing error carried through error(): status, message, extra top-level fields ({ conflict = ... }).
function U.fail(status, message, extra)
    error({ ar_error = true, status = status, message = message, extra = extra }, 0)
end

function U.invalid(details)
    U.fail(422, "Validation failed", { details = details })
end

--- A JSON object (not a list) or nil.
function U.object(v)
    if type(v) == "table" and (next(v) == nil or v[1] == nil) then return v end
end

--- A list of up to `max` strings, each 1 to `len` bytes once trimmed, duplicates dropped; nil or null -> empty.
-- check(entry) may rewrite an entry, or return nil + message to refuse it. Anything else: 422 on `field`.
function U.strings(v, field, max, len, check)
    if v == nil or v == cjson.null then return U.array() end
    if type(v) ~= "table" or (next(v) ~= nil and v[1] == nil) or #v > max then
        U.invalid({ [field] = "must be a list of up to " .. max .. " entries" })
    end
    local out, seen = {}, {}
    for _, x in ipairs(v) do
        x = type(x) == "string" and U.clean(x:match("^%s*(.-)%s*$")) or nil
        if not x or x == "" or #x > len then U.invalid({ [field] = "each entry is 1 to " .. len .. " characters" }) end
        if check then
            local fixed, message = check(x)
            if not fixed then U.invalid({ [field] = message }) end
            x = fixed
        end
        if not seen[x] then
            seen[x] = true
            out[#out + 1] = x
        end
    end
    return U.array(out)
end

--- A folder glob as stored (§27.2, §27.3): no trailing slash ("/" and "~" stay). See U.folder_match.
function U.folder_glob(g)
    local trimmed = g:gsub("/+$", "")
    if trimmed == "" or trimmed == "~" then return g:sub(1, 1) end
    return trimmed
end

--- Turn U.fail errors and constraint violations into the house error envelope; anything else is logged and
-- re-raised (the app's handler answers a generic 500, never the error text). Also names the request's workspace
-- for U.redact (machine credentials name theirs once they are checked).
function U.guard(fn)
    return function(self)
        ngx.ctx.ar_ns = self.namespace and self.namespace.id or nil
        local ok, res = pcall(fn, self)
        if ok then return res end
        if type(res) == "table" and res.ar_error then
            local json = { success = false, error = res.message }
            for k, v in pairs(res.extra or {}) do json[k] = v end
            return { status = res.status, json = json }
        end
        local msg = tostring(res):match(".*\n(ERROR:.*)$") or tostring(res)
        if msg:find("duplicate key value", 1, true) then
            return { status = 409, json = { success = false, error = "A record with these values already exists" } }
        end
        if msg:find("foreign key constraint", 1, true) then
            return { status = 422, json = { success = false, error = "A referenced record does not exist" } }
        end
        ngx.log(ngx.ERR, "[ai_runner] ", tostring(res))
        error(res, 0)
    end
end

--- Valid UTF-8 without NUL bytes (Postgres refuses both), cut to at most `max` bytes on a character boundary.
-- Invalid bytes become "?".
function U.clean(s, max)
    if s == nil then return nil end
    s = tostring(s):gsub("%z", "")
    if s:find("[\128-\255]") then
        local out, i, n = {}, 1, #s
        while i <= n do
            local c = s:byte(i)
            local len, lo, hi = 0, 0x80, 0xBF
            if c < 0x80 then len = 1
            elseif c >= 0xC2 and c <= 0xDF then len = 2
            elseif c >= 0xE0 and c <= 0xEF then
                len, lo, hi = 3, c == 0xE0 and 0xA0 or 0x80, c == 0xED and 0x9F or 0xBF
            elseif c >= 0xF0 and c <= 0xF4 then
                len, lo, hi = 4, c == 0xF0 and 0x90 or 0x80, c == 0xF4 and 0x8F or 0xBF
            end
            local ok = len > 0
            for k = 1, len - 1 do
                local b = s:byte(i + k)
                if not b or b < (k == 1 and lo or 0x80) or b > (k == 1 and hi or 0xBF) then ok = false break end
            end
            if ok then out[#out + 1] = s:sub(i, i + len - 1); i = i + len
            else out[#out + 1] = "?"; i = i + 1 end
        end
        s = table.concat(out)
    end
    if max and #s > max then
        local i = max
        while i > 0 and s:byte(i + 1) >= 0x80 and s:byte(i + 1) < 0xC0 do i = i - 1 end
        s = s:sub(1, i)
    end
    return s
end

-- Obvious credentials, so a log line or summary never stores (or shows) one: OpsAPI keys, runner and run tokens,
-- bearer tokens, provider keys (sk-..., long only so "task-12" stays), GitHub, GitLab, Slack, Stripe, npm and AWS
-- keys, JWTs, private keys, passwords in URLs (§25.6). A third value is the shortest match that counts as a key.
local SECRETS = {
    { "%-%-%-%-%-BEGIN [%u ]*PRIVATE KEY%-%-%-%-%-.-%-%-%-%-%-END [%u ]*PRIVATE KEY%-%-%-%-%-",
      "[REDACTED PRIVATE KEY]" },
    { "opsk_[%w]+", "opsk_[REDACTED]" },
    { "oprn_[%w]+", "oprn_[REDACTED]" },
    { "oprt_[%w]+", "oprt_[REDACTED]" },
    { "[Bb][Ee][Aa][Rr][Ee][Rr]%s+[%w%-%._~%+/]+=*", "Bearer [REDACTED]" },
    { "github_pat_[%w_]+", "github_pat_[REDACTED]" },
    { "%f[%w]gh[pousr]_[%w]+", "gh_[REDACTED]" },
    { "%f[%w]glpat%-[%w%-_]+", "glpat-[REDACTED]" },
    { "%f[%w]xox[abprs]%-[%w%-]+", "xox-[REDACTED]" },
    { "%f[%w]AKIA[%u%d]+", "AKIA[REDACTED]" },
    { "%f[%w]sk_live_[%w]+", "sk_live_[REDACTED]" },
    { "%f[%w]sk_test_[%w]+", "sk_test_[REDACTED]" },
    { "%f[%w]rk_live_[%w]+", "rk_live_[REDACTED]" },
    { "%f[%w]whsec_[%w]+", "whsec_[REDACTED]" },
    { "%f[%w]npm_[%w]+", "npm_[REDACTED]", 30 },
    { "%f[%w]sk%-[%w%-_]+", "sk-[REDACTED]", 20 },
    { "%f[%w]eyJ[%w%-_]+%.[%w%-_]+%.[%w%-_]*", "[REDACTED JWT]" },
    { "://[^/%s:@]*:[^/%s@]+@", "://[REDACTED]@" },
}

-- KEY=value assignments whose name says it holds a secret.
local function secret_name(k)
    k = k:upper():gsub("%-", "_")
    for _, w in ipairs({ "SECRET", "PASSWORD", "TOKEN", "API_KEY" }) do
        if k:find(w, 1, true) then return true end
    end
end

-- §27.4: the request's workspace (ngx.ctx.ar_ns) adds its own patterns (ar_settings.safety.extra_redactions,
-- regexes checked when saved), read once per request. A read that fails leaves the built-in patterns only.
local function workspace_patterns()
    local ns = ngx.ctx.ar_ns
    if not ns then return nil end
    local cached = ngx.ctx.ar_redact
    if cached and cached.ns == ns then return cached.list end
    local ok, row = pcall(U.tx, function() -- a savepoint: callers may be inside a transaction
        return U.one("SELECT safety FROM ar_settings WHERE namespace_id = ?", ns)
    end)
    if not ok then ngx.log(ngx.ERR, "[ai_runner] workspace redactions not read: ", tostring(row)) end
    local safety = ok and row and U.json(row.safety)
    local list = type(safety) == "table" and type(safety.extra_redactions) == "table" and safety.extra_redactions or {}
    ngx.ctx.ar_redact = { ns = ns, list = list }
    return list
end

function U.redact(s)
    if type(s) ~= "string" then return s end
    for _, p in ipairs(SECRETS) do
        if p[3] then
            s = s:gsub(p[1], function(m) if #m >= p[3] then return p[2] end end)
        else
            s = s:gsub(p[1], p[2])
        end
    end
    s = s:gsub("([%w_%.%-]+)=([\"'])(.-)%2", function(k, q)
        if secret_name(k) then return k .. "=" .. q .. "[REDACTED]" .. q end
    end)
    s = s:gsub("([%w_%.%-]+)=([^%s\"']+)", function(k)
        if secret_name(k) then return k .. "=[REDACTED]" end
    end)
    for _, re in ipairs(workspace_patterns() or {}) do
        local out, _, err = ngx.re.gsub(s, re, "[REDACTED]", "jo")
        if not out then -- PCRE gave up (match limit): mask it all rather than store it unmasked
            ngx.log(ngx.WARN, "[ai_runner] workspace redaction failed, text masked: ", tostring(err))
            return "[REDACTED]"
        end
        s = out
    end
    return s
end

--- Is a workspace redaction usable? A PCRE regex, at most 200 bytes, that never matches empty text.
function U.check_regex(re)
    if type(re) ~= "string" or re == "" or #re > 200 then return false, "must be 1 to 200 characters" end
    local from, _, err = ngx.re.find("", re, "j")
    if err then return false, "is not a valid regular expression" end
    if from then return false, "must not match empty text" end
    return true
end

-- ---------------------------------------------------------------------------
-- Globs (§27.2, §27.3), as the runner applies them: * and ? stay within one path segment, ** crosses segments
-- ---------------------------------------------------------------------------

-- Wildcard matching with one backtrack point (the classic greedy algorithm): O(#s * #p) at worst, so a glob can
-- never make it slow (Lua patterns with many .* can). p and s are lists of tokens.
local function wild(p, s, is_star, same)
    local i, j, si, sj = 1, 1, nil, nil
    while i <= #s do
        if j <= #p and is_star(p[j]) then
            si, sj, j = i, j, j + 1
        elseif j <= #p and same(p[j], s[i]) then
            i, j = i + 1, j + 1
        elseif sj then
            si = si + 1
            i, j = si, sj + 1
        else
            return false
        end
    end
    while j <= #p and is_star(p[j]) do j = j + 1 end
    return j > #p
end

local function chars(s)
    local out = {}
    for i = 1, #s do out[i] = s:sub(i, i) end
    return out
end

local function star_char(c) return c == "*" end
local function same_char(p, c) return p == "?" or p == c end

--- Does text match a glob in which * and ? cross every character (a command, §27.4)?
function U.wildcard(glob, text)
    return wild(chars(glob), chars(text), star_char, same_char)
end

local function segments(s)
    local out = {}
    for part in (s .. "/"):gmatch("([^/]*)/") do out[#out + 1] = part end
    return out
end

local function star_segment(seg) return seg == "**" end
local function same_segment(p, s) return wild(chars(p), chars(s), star_char, same_char) end

--- Does a whole path (a branch name) match a glob?
function U.glob(glob, path)
    if type(glob) ~= "string" or glob == "" or type(path) ~= "string" then return false end
    return wild(segments(glob), segments(path), star_segment, same_segment)
end

--- Does a folder match a folder glob, the same way the runner reads one? A glob covers the folder it names and
-- everything below it (~/work is ~/work/**). One starting with / is absolute; ~/ is any user's home (the server
-- doesn't know whose machine it is: /Users/<name>/ or /home/<name>/); any other matches at any depth (node_modules,
-- client-*). An empty glob matches nothing.
function U.folder_match(glob, folder)
    if type(glob) ~= "string" or type(folder) ~= "string" then return false end
    local g = glob:match("^%s*(.-)%s*$")
    if g == "" then return false end
    local candidates
    if g == "~" or g:sub(1, 2) == "~/" then
        candidates = { "/Users/*/" .. g:sub(3), "/home/*/" .. g:sub(3) }
    elseif g:sub(1, 1) == "/" then
        candidates = { g }
    else
        candidates = { "**/" .. g }
    end
    local s = segments((folder:gsub("/+$", "")))
    for _, c in ipairs(candidates) do
        local p = segments((c:gsub("/+$", "")))
        p[#p + 1] = "**"
        if wild(p, s, star_segment, same_segment) then return true end
    end
    return false
end

--- Redact every string inside a decoded JSON value (keys kept). Tables deeper than `depth` levels become
-- "[too deep]", so nothing below the limit is kept unredacted.
function U.redact_value(v, depth)
    depth = depth or 32
    if type(v) == "string" then return U.redact(U.clean(v)) end
    if type(v) ~= "table" then return v end
    if depth <= 0 then return "[too deep]" end
    local out = {}
    for k, x in pairs(v) do out[k] = U.redact_value(x, depth - 1) end
    return setmetatable(out, getmetatable(v))
end

--- JSON with object keys sorted, so the same value always reads the same (rule keys, request summaries).
function U.canonical(v, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 64 then
        local ok, s = pcall(cjson.encode, v)
        return ok and s or "null"
    end
    local keys, out = {}, {}
    for k in pairs(v) do keys[#keys + 1] = k end
    if #keys > 0 and #keys == #v then
        for i = 1, #v do out[i] = U.canonical(v[i], depth + 1) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for i, k in ipairs(keys) do out[i] = cjson.encode(tostring(k)) .. ":" .. U.canonical(v[k], depth + 1) end
    return "{" .. table.concat(out, ",") .. "}"
end

--- Characters (not bytes) in a UTF-8 string.
function U.chars(s)
    return #s - select(2, s:gsub("[\128-\191]", ""))
end

--- At most n characters of a valid UTF-8 string (as U.clean leaves it).
function U.cut(s, n)
    if s == nil or #s <= n then return s end
    local count = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then
            count = count + 1
            if count > n then return s:sub(1, i - 1) end
        end
    end
    return s
end

--- A git branch name we pass on: letters, digits, . _ / -, never starting with "-" (git would read an option, §25.7).
function U.is_branch(v)
    return type(v) == "string" and v:match("^[%w%._/%-]+$") ~= nil and v:sub(1, 1) ~= "-"
end

--- A folder path as reported: absolute, no trailing slash. nil when it isn't one.
function U.path(p)
    if type(p) ~= "string" or p:sub(1, 1) ~= "/" or #p > 1024 or p:find("%z") then return nil end
    p = p:gsub("/+$", "")
    return p == "" and "/" or p
end

return U
