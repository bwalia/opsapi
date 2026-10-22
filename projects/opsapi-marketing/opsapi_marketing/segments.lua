-- Dynamic segment evaluation against CRM contacts (nested AND/OR, safe field allowlist).
local db = require("lapis.db")
local U = require("opsapi_marketing.util")

local Seg = {}

-- Only these CRM columns may appear in segment rules (no raw SQL).
local FIELDS = {
    email = { col = "c.email", type = "string" },
    first_name = { col = "c.first_name", type = "string" },
    last_name = { col = "c.last_name", type = "string" },
    phone = { col = "c.phone", type = "string" },
    mobile = { col = "c.mobile", type = "string" },
    status = { col = "c.status", type = "string" },
    job_title = { col = "c.job_title", type = "string" },
    company = { col = "a.name", type = "string", join_accounts = true },
}

local OPS = {
    eq = true, neq = true, contains = true, not_contains = true,
    starts_with = true, is_empty = true, not_empty = true,
}

local function escape_like(s)
    return (tostring(s):gsub("([%%_\\])", "\\%1"))
end

--- Compile a rule node to SQL fragment + bind args. Returns nil, err on invalid.
local function compile(node, args, needs)
    if type(node) ~= "table" then return nil, "invalid rule" end

    if node["and"] then
        local parts = {}
        for _, child in ipairs(node["and"]) do
            local sql, err = compile(child, args, needs)
            if not sql then return nil, err end
            parts[#parts + 1] = "(" .. sql .. ")"
        end
        if #parts == 0 then return "TRUE" end
        return table.concat(parts, " AND ")
    end

    if node["or"] then
        local parts = {}
        for _, child in ipairs(node["or"]) do
            local sql, err = compile(child, args, needs)
            if not sql then return nil, err end
            parts[#parts + 1] = "(" .. sql .. ")"
        end
        if #parts == 0 then return "TRUE" end
        return table.concat(parts, " OR ")
    end

    local field = node.field
    local op = node.op
    local meta = FIELDS[field]
    if not meta then return nil, "unknown field: " .. tostring(field) end
    if not OPS[op] then return nil, "unknown op: " .. tostring(op) end
    if meta.join_accounts then needs.accounts = true end

    local col = meta.col
    if op == "is_empty" then
        return "(" .. col .. " IS NULL OR " .. col .. " = '')"
    end
    if op == "not_empty" then
        return "(" .. col .. " IS NOT NULL AND " .. col .. " <> '')"
    end

    local val = node.value
    if val == nil then return nil, "value required for " .. op end
    if op == "eq" then
        args[#args + 1] = val
        return col .. " = ?"
    elseif op == "neq" then
        args[#args + 1] = val
        return col .. " IS DISTINCT FROM ?"
    elseif op == "contains" then
        args[#args + 1] = "%" .. escape_like(val) .. "%"
        return col .. " ILIKE ? ESCAPE '\\'"
    elseif op == "not_contains" then
        args[#args + 1] = "%" .. escape_like(val) .. "%"
        return "(" .. col .. " IS NULL OR " .. col .. " NOT ILIKE ? ESCAPE '\\')"
    elseif op == "starts_with" then
        args[#args + 1] = escape_like(val) .. "%"
        return col .. " ILIKE ? ESCAPE '\\'"
    end
    return nil, "unsupported op"
end

function Seg.fields()
    local out = {}
    for k, v in pairs(FIELDS) do
        out[#out + 1] = { field = k, type = v.type }
    end
    table.sort(out, function(a, b) return a.field < b.field end)
    return out
end

function Seg.ops()
    return { "eq", "neq", "contains", "not_contains", "starts_with", "is_empty", "not_empty" }
end

--- Preview matching contact uuids (capped).
function Seg.preview(ns, rule, limit)
    limit = math.min(tonumber(limit) or 100, 500)
    local args, needs = { ns }, {}
    local where, err = compile(rule or {}, args, needs)
    if not where then return nil, err end
    args[#args + 1] = limit
    local join = ""
    if needs.accounts then
        join = " LEFT JOIN crm_accounts a ON a.id = c.account_id AND a.namespace_id = c.namespace_id "
    end
    local sql = [[
        SELECT c.uuid, c.first_name, c.last_name, c.email, c.phone, c.status
        FROM crm_contacts c ]] .. join .. [[
        WHERE c.namespace_id = ? AND c.deleted_at IS NULL AND (]] .. where .. [[)
        ORDER BY c.created_at DESC
        LIMIT ?
    ]]
    local rows = db.query(sql, unpack(args))
    local count_args = { ns }
    local count_where, cerr = compile(rule or {}, count_args, needs)
    if not count_where then return nil, cerr end
    local count_sql = [[
        SELECT COUNT(*)::int AS n FROM crm_contacts c ]] .. join .. [[
        WHERE c.namespace_id = ? AND c.deleted_at IS NULL AND (]] .. count_where .. [[)
    ]]
    local total = U.one(count_sql, unpack(count_args))
    return { contacts = rows, total = total and total.n or #rows }
end

--- Materialise dynamic list membership (replace active members). One INSERT … SELECT,
-- so every matching contact is added (it used to go through the 500-row preview).
function Seg.sync_list(ns, list_id)
    local list = U.one("SELECT * FROM mkt_lists WHERE id = ? AND namespace_id = ?", list_id, ns)
    if not list then return nil, "not_found" end
    if list.list_type ~= "dynamic" then return nil, "not_dynamic" end
    local rule = U.json(list.segment_rule) or {}
    local args, needs = { ns, list_id, ns }, {}
    local where, err = compile(rule, args, needs)
    if not where then return nil, err end
    local join = needs.accounts
        and " LEFT JOIN crm_accounts a ON a.id = c.account_id AND a.namespace_id = c.namespace_id " or ""

    return U.tx(function()
        db.query("UPDATE mkt_list_members SET removed_at = NOW() WHERE namespace_id = ? AND list_id = ? AND removed_at IS NULL AND source = 'segment'",
            ns, list_id)
        local res = db.query([[
            INSERT INTO mkt_list_members (namespace_id, list_id, contact_uuid, source)
            SELECT ?, ?, c.uuid, 'segment'
            FROM crm_contacts c ]] .. join .. [[
            WHERE c.namespace_id = ? AND c.deleted_at IS NULL AND (]] .. where .. [[)
            ON CONFLICT (namespace_id, list_id, contact_uuid)
            DO UPDATE SET removed_at = NULL, source = 'segment', added_at = NOW()
        ]], unpack(args))
        db.query("UPDATE mkt_lists SET updated_at = NOW() WHERE id = ?", list_id)
        local n = res and res.affected_rows or 0
        return { synced = n, total = n }
    end)
end

return Seg
