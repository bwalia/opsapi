--[[
    Page scopes for the AI assistant
    ================================

    One knowledge file per dashboard area in lib/agent/knowledge/<key>.md:

        ---
        title: Timesheets
        pages: /dashboard/timesheets            (dashboard path prefixes)
        api: /api/v2/timesheets                 (prefixes call_api may touch; empty = guide only)
        modules: timesheets                     (RBAC modules -> the user's permissions in the prompt)
        tools: create_timesheet, list_timesheets  (typed tools from lib/agent/tools)
        suggestions: Log 7.5 hours today | ...  (starter prompts)
        readonly: false                         (true = GET only)
        ---
        <markdown guide the model gets as its instructions for that page>

    resolve(path) picks the file whose `pages:` prefix is the longest match for
    the URL the user is on; "general" is the fallback. The scope key also keys
    the conversation history, so each page area keeps its own thread.
    Adding a page = adding a file.

    The guide's backticked endpoints (`POST /api/v2/timesheets/{uuid}/submit`)
    are also the allow-list: call_api may only make a documented method + path,
    inside the `api:` prefixes. A placeholder matches one path segment; an id
    placeholder ({uuid}, {id}, {x_uuid}, {x_id}) only an id-shaped one (number
    or uuid), so `PUT .../{uuid}` can't reach a fixed sibling like
    `PUT .../sync-settings`. What the model is told is exactly what it can do.
]]

local ProjectLoader = require("helper.project-loader")

local Scopes = {}

local DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "lib/agent") .. "/knowledge"

-- Used when no knowledge files ship (or none matches): the all-round assistant.
local FALLBACK = {
    key = "general",
    title = "Assistant",
    pages = {},
    api = {},
    modules = {},
    tools = nil, -- nil = every typed tool
    suggestions = {},
    readonly = false,
    guide = "",
}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function list(value, sep)
    local out = {}
    for part in (value or ""):gmatch("[^" .. sep .. "]+") do
        part = trim(part)
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

local function strip_slash(p)
    return #p > 1 and (p:gsub("/+$", "")) or p
end

local METHODS = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true }

local function segments(path)
    local out = {}
    for seg in path:gmatch("[^/]+") do out[#out + 1] = seg end
    return out
end

local function is_id(seg)
    return seg:match("^%d+$") ~= nil or (#seg >= 8 and seg:match("^[%x%-]+$") ~= nil and seg:find("-", 1, true) ~= nil)
end

-- `GET /api/v2/x/{uuid}/y?page` -> { method = "GET", path = "/api/v2/x/{uuid}/y",
--   segs = { "api", "v2", "x", { id = true }, "y" } }
local function endpoints_in(body)
    local out = {}
    for method, path in body:gmatch("`(%u+)%s+(/[^%s`?]+)") do
        if METHODS[method] then
            local segs = {}
            for i, seg in ipairs(segments(path)) do
                local name = seg:match("^{([^}]*)}$") or seg:match("^:([%a_][%w_]*)$")
                if name then
                    name = name:lower()
                    segs[i] = { id = name == "id" or name:match("uuid$") ~= nil or name:match("_id$") ~= nil }
                else
                    segs[i] = seg
                end
            end
            out[#out + 1] = { method = method, path = path, segs = segs }
        end
    end
    return out
end

local function matches(e, path_segs)
    if #e.segs ~= #path_segs then return false end
    for i, want in ipairs(e.segs) do
        local got = path_segs[i]
        if type(want) == "string" then
            if want ~= got then return false end
        elseif want.id and not is_id(got) then
            return false
        end
    end
    return true
end

--- Parse one knowledge file. Returns the scope table, or nil if malformed.
function Scopes.parse(key, text)
    local front, body = text:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n?(.*)$")
    if not front then return nil end
    local meta = {}
    for line in front:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*:%s*(.-)%s*$")
        if k then meta[k:lower()] = v end
    end
    local scope = {
        key = key,
        title = meta.title ~= "" and meta.title or key,
        pages = {},
        api = {},
        modules = list(meta.modules, ","),
        tools = list(meta.tools, ","),
        suggestions = list(meta.suggestions, "|"),
        readonly = meta.readonly == "true",
        guide = trim(body or ""),
        endpoints = endpoints_in(body or ""),
    }
    for _, p in ipairs(list(meta.pages, ",")) do scope.pages[#scope.pages + 1] = strip_slash(p) end
    for _, p in ipairs(list(meta.api, ",")) do scope.api[#scope.api + 1] = strip_slash(p) end
    return scope
end

local cache

local function load_all()
    if cache then return cache end
    local by_key = {}
    for _, name in ipairs(ProjectLoader.listDir(DIR)) do
        local key = name:match("^([%w%-_]+)%.md$")
        local f = key and io.open(DIR .. "/" .. name, "r")
        if f then
            local scope = Scopes.parse(key, f:read("*a"))
            f:close()
            if scope then
                by_key[key] = scope
            else
                ngx.log(ngx.WARN, "[assistant] skipped malformed knowledge file ", name)
            end
        end
    end
    cache = by_key
    return cache
end

--- The scope for a key, or the general fallback.
function Scopes.get(key)
    local all = load_all()
    return all[key] or all.general or FALLBACK
end

--- The scope for a dashboard URL path (longest `pages:` prefix wins).
function Scopes.resolve(path)
    local all = load_all()
    path = strip_slash(tostring(path or ""):match("^[^?#]*"))
    local best, best_len = nil, -1
    for _, scope in pairs(all) do
        for _, p in ipairs(scope.pages) do
            if (path == p or path:sub(1, #p + 1) == p .. "/") and #p > best_len then
                best, best_len = scope, #p
            end
        end
    end
    return best or all.general or FALLBACK
end

--- May call_api make `method path` (no query string) on this scope? It must
-- be under an `api:` prefix and, when the guide documents endpoints, be one.
function Scopes.allows_api(scope, path, method)
    path = strip_slash(path)
    local under = false
    for _, p in ipairs(scope.api or {}) do
        local nxt = path:sub(#p + 1, #p + 1)
        if path:sub(1, #p) == p and (nxt == "" or nxt == "/") then under = true break end
    end
    if not under then return false end
    if #(scope.endpoints or {}) == 0 then return true end
    local path_segs = segments(path)
    for _, e in ipairs(scope.endpoints) do
        if e.method == method and matches(e, path_segs) then return true end
    end
    return false
end

--- What the dashboard needs to label the panel.
function Scopes.public(scope)
    return { key = scope.key, title = scope.title, suggestions = scope.suggestions }
end

return Scopes
