-- Typed merge-field registry. Templates may only reference allowlisted keys.
local U = require("opsapi_marketing.util")
local S = require("opsapi_marketing.sanitize")
local db = require("lapis.db")

local BUILTIN = {
    { key = "contact.first_name", label = "First name", field_type = "string", source_path = "contact.first_name", allow_html = false, default_value = "there" },
    { key = "contact.last_name", label = "Last name", field_type = "string", source_path = "contact.last_name", allow_html = false },
    { key = "contact.email", label = "Email", field_type = "string", source_path = "contact.email", allow_html = false },
    { key = "contact.phone", label = "Phone", field_type = "string", source_path = "contact.phone", allow_html = false },
    { key = "contact.company", label = "Company", field_type = "string", source_path = "contact.company", allow_html = false },
    { key = "campaign.name", label = "Campaign name", field_type = "string", source_path = "campaign.name", allow_html = false },
    { key = "deal.value", label = "Deal value", field_type = "number", source_path = "deal.value", allow_html = false },
    { key = "custom.industry", label = "Industry (custom)", field_type = "string", source_path = "custom.industry", allow_html = false },
    { key = "unsubscribe_url", label = "Unsubscribe URL", field_type = "string", source_path = "unsubscribe_url", allow_html = false },
    { key = "preferences_url", label = "Preferences URL", field_type = "string", source_path = "preferences_url", allow_html = false },
    { key = "view_online_url", label = "View in browser URL", field_type = "string", source_path = "view_online_url", allow_html = false },
}

local M = {}

function M.builtins()
    return BUILTIN
end

local function index_of(list)
    local idx = {}
    for _, f in ipairs(list) do idx[f.key] = f end
    return idx
end

function M.for_namespace(ns)
    local rows = db.query([[
        SELECT key, label, field_type, source_path, default_value, allow_html
        FROM mkt_merge_fields WHERE namespace_id = ? ORDER BY key
    ]], ns)
    local out, seen = {}, {}
    for _, b in ipairs(BUILTIN) do
        out[#out + 1] = b
        seen[b.key] = true
    end
    for _, r in ipairs(rows) do
        if not seen[r.key] then
            out[#out + 1] = r
            seen[r.key] = true
        end
    end
    return out
end

function M.ensure_defaults(ns)
    for _, b in ipairs(BUILTIN) do
        local exists = U.one("SELECT id FROM mkt_merge_fields WHERE namespace_id = ? AND key = ?", ns, b.key)
        if not exists then
            db.query([[
                INSERT INTO mkt_merge_fields (namespace_id, key, label, field_type, source_path, default_value, allow_html)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ]], ns, b.key, b.label, b.field_type, b.source_path,
                b.default_value and b.default_value or db.NULL, b.allow_html)
        end
    end
end

--- Validate that all {{keys}} in subject/html/text are in the registry.
-- @return ok, { unknown = {...}, fields = {...} }
function M.validate_template(ns, payload)
    M.ensure_defaults(ns)
    local allowed = index_of(M.for_namespace(ns))
    local used, unknown = {}, {}
    local seen = {}
    for _, part in ipairs({ payload.subject, payload.body_html, payload.body_text, payload.html, payload.text }) do
        for _, key in ipairs(S.extract_merge_keys(part)) do
            if not seen[key] then
                seen[key] = true
                used[#used + 1] = key
                if not allowed[key] then unknown[#unknown + 1] = key end
            end
        end
    end
    if #unknown > 0 then
        return false, { unknown = unknown, fields = used }
    end
    return true, { fields = used }
end

--- Resolve a dotted path against a merge context table.
local function resolve(data, path)
    local cur = data
    for seg in path:gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[seg]
    end
    return cur
end

--- Build a context for TemplateRenderer: only registry keys. Values stay raw — the
-- renderer HTML-escapes them in HTML bodies (escaping here as well showed "O&amp;#39;Brien").
function M.build_context(ns, raw)
    local fields = M.for_namespace(ns)
    local ctx = {}
    for _, f in ipairs(fields) do
        local val = resolve(raw or {}, f.source_path)
        if val == nil or val == "" then val = f.default_value end
        if val ~= nil then
            -- Nest into dotted structure for {{contact.first_name}}
            local parts = {}
            for seg in f.key:gmatch("[^%.]+") do parts[#parts + 1] = seg end
            local node = ctx
            for i = 1, #parts - 1 do
                node[parts[i]] = node[parts[i]] or {}
                node = node[parts[i]]
            end
            local leaf = parts[#parts]
            node[leaf] = f.allow_html and S.strip_html(tostring(val)) or val
        end
    end
    -- Also expose top-level unsubscribe_url etc if present in raw
    if raw and raw.unsubscribe_url and not (ctx.unsubscribe_url) then
        ctx.unsubscribe_url = raw.unsubscribe_url
    end
    return ctx
end

function M.upsert(ns, data)
    local key = data.key
    if type(key) ~= "string" or not key:match("^[%w_%.]+$") or #key > 128 then
        return nil, "invalid key"
    end
    -- Block secrets / sensitive paths
    local banned = { password = true, secret = true, token = true, ssn = true, nino = true, medical = true }
    for part in key:gmatch("[%w_]+") do
        if banned[part:lower()] then return nil, "forbidden field" end
    end
    local existing = U.one("SELECT id FROM mkt_merge_fields WHERE namespace_id = ? AND key = ?", ns, key)
    if existing then
        db.query([[
            UPDATE mkt_merge_fields SET label = ?, field_type = ?, source_path = ?,
                default_value = ?, allow_html = ? WHERE id = ?
        ]], data.label or key, data.field_type or "string", data.source_path or key,
            data.default_value and data.default_value or db.NULL,
            data.allow_html == true, existing.id)
        return U.one("SELECT * FROM mkt_merge_fields WHERE id = ?", existing.id)
    end
    db.query([[
        INSERT INTO mkt_merge_fields (namespace_id, key, label, field_type, source_path, default_value, allow_html)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], ns, key, data.label or key, data.field_type or "string", data.source_path or key,
        data.default_value and data.default_value or db.NULL, data.allow_html == true)
    return U.one("SELECT * FROM mkt_merge_fields WHERE namespace_id = ? AND key = ?", ns, key)
end

return M
