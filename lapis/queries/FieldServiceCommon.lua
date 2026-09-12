--[[
    Field Service — shared query helpers
    ====================================

    Small utilities shared by FieldServiceConfigQueries, FieldServiceJobQueries
    and FieldServiceVisitQueries: value coercion, tenant-scoped uuid -> id
    resolution, the job activity log, and a nest-safe transaction wrapper.

    Timestamps: every fs_* TIMESTAMP column holds UTC wall-clock time. The
    dashboard sends ISO-8601 UTC strings (Postgres drops the "Z" when casting
    to TIMESTAMP) and appends "Z" when parsing values back.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local Common = {}

-- Tables resolve_id may look up. The name is interpolated into SQL, so it must
-- come from this allow-list, never from request input.
local RESOLVABLE = {
    crm_accounts = true,
    crm_contacts = true,
    fs_job_types = true,
    fs_phase_templates = true,
    fs_sites = true,
    fs_jobs = true,
    fs_job_phases = true,
    fs_visits = true,
    fs_job_items = true,
}

-- SQL expression for a user's display name (users alias `u`).
Common.USER_NAME_SQL = [[COALESCE(
    NULLIF(TRIM(COALESCE(%s.first_name, '') || ' ' || COALESCE(%s.last_name, '')), ''), %s.email)]]

function Common.user_name_sql(alias)
    return string.format(Common.USER_NAME_SQL, alias, alias, alias)
end

function Common.uuid()
    return Global.generateUUID()
end

-- Treat empty strings (and cjson.null) as NULL so DATE/NUMERIC columns don't choke.
function Common.nilify(v)
    if v == nil or v == "" or v == cjson.null then return nil end
    return v
end

-- Value for an UPDATE: explicit empty/null clears the column.
function Common.nullable(v)
    if v == nil or v == "" or v == cjson.null then return db.NULL end
    return v
end

function Common.to_bool(v, default_value)
    if v == nil or v == "" or v == cjson.null then return default_value end
    if type(v) == "boolean" then return v end
    v = tostring(v):lower()
    return v == "true" or v == "1" or v == "yes" or v == "on"
end

function Common.to_number(v)
    if v == nil or v == "" or v == cjson.null then return nil end
    return tonumber(v)
end

function Common.round2(n)
    return math.floor((tonumber(n) or 0) * 100 + 0.5) / 100
end

-- Mark a Lua table as a JSON array so an empty result encodes as [] not {}.
function Common.arr(t)
    t = t or {}
    if cjson.array_mt then
        setmetatable(t, cjson.array_mt)
    elseif next(t) == nil then
        return cjson.empty_array
    end
    return t
end

-- Decode a JSON column/value into a Lua table (pgmoon already decodes jsonb).
function Common.decode(v, fallback)
    if type(v) == "table" then return v end
    if type(v) == "string" and v ~= "" then
        local ok, decoded = pcall(cjson.decode, v)
        if ok and type(decoded) == "table" then return decoded end
    end
    return fallback
end

--- Normalise a phase-template checklist into an array of label strings.
-- Accepts a JSON string, an array of strings, or an array of { label = ... }.
function Common.template_checklist(input)
    local list = Common.decode(input, {})
    local out = {}
    for _, item in ipairs(list) do
        local label = type(item) == "table" and item.label or item
        label = label and tostring(label):match("^%s*(.-)%s*$")
        if label and label ~= "" then table.insert(out, label) end
    end
    return out
end

--- Normalise a job-phase checklist into an array of { label, done, done_at, done_by }.
-- Plain strings become unticked items.
function Common.phase_checklist(input)
    local list = Common.decode(input, {})
    local out = {}
    for _, item in ipairs(list) do
        if type(item) == "table" then
            local label = item.label and tostring(item.label):match("^%s*(.-)%s*$")
            if label and label ~= "" then
                table.insert(out, {
                    label = label,
                    done = Common.to_bool(item.done, false),
                    done_at = Common.nilify(item.done_at),
                    done_by = Common.nilify(item.done_by),
                })
            end
        elseif item and tostring(item) ~= "" then
            table.insert(out, { label = tostring(item), done = false })
        end
    end
    return out
end

function Common.encode_array(t)
    if not t or next(t) == nil then return "[]" end
    return cjson.encode(t)
end

--- Resolve a uuid to its internal id, scoped to the tenant. Returns nil when
-- the row does not exist, is soft-deleted, or belongs to another namespace.
function Common.resolve_id(tbl, namespace_id, uuid)
    assert(RESOLVABLE[tbl], "resolve_id: table not allowed: " .. tostring(tbl))
    uuid = Common.nilify(uuid)
    if not uuid then return nil end
    local rows = db.query(
        "SELECT id FROM " .. tbl .. " WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1",
        tostring(uuid), namespace_id
    )
    return rows and rows[1] and rows[1].id or nil
end

--- Is this user an active member of the namespace?
function Common.is_member(namespace_id, user_uuid)
    user_uuid = Common.nilify(user_uuid)
    if not user_uuid then return false end
    local rows = db.query([[
        SELECT 1 FROM namespace_members nm
        JOIN users u ON u.id = nm.user_id
        WHERE nm.namespace_id = ? AND u.uuid = ? AND nm.status = 'active'
        LIMIT 1
    ]], namespace_id, tostring(user_uuid))
    return rows and rows[1] ~= nil
end

--- Is this user assigned to any (non-deleted) visit on the job?
function Common.is_engineer_on_job(job_id, user_uuid)
    if not job_id or not user_uuid then return false end
    local rows = db.query([[
        SELECT 1 FROM fs_visits
        WHERE job_id = ? AND engineer_user_uuid = ? AND deleted_at IS NULL
        LIMIT 1
    ]], job_id, tostring(user_uuid))
    return rows and rows[1] ~= nil
end

--- Append a row to the job's activity log. Never fails the caller.
function Common.log_activity(namespace_id, job_id, actor_uuid, action, message, metadata)
    pcall(function()
        db.query([[
            INSERT INTO fs_job_activity (uuid, namespace_id, job_id, actor_uuid, action, message, metadata, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?::jsonb, NOW())
        ]], Common.uuid(), namespace_id, job_id, actor_uuid or db.NULL, action, message or db.NULL,
            metadata and cjson.encode(metadata) or "{}")
    end)
end

--- Run fn inside a transaction. Nest-safe per request: an inner call joins the
-- outer transaction instead of issuing its own BEGIN/COMMIT.
-- @return the values returned by fn, or nil + error message on failure
function Common.transaction(fn)
    local ctx = ngx and ngx.ctx or {}
    local depth = ctx.fs_tx_depth or 0
    if depth > 0 then
        return fn()
    end

    db.query("BEGIN")
    ctx.fs_tx_depth = 1
    local results = { pcall(fn) }
    ctx.fs_tx_depth = 0

    if not results[1] then
        pcall(db.query, "ROLLBACK")
        -- Raised errors carry SQL/stack detail: log it, return a generic message.
        ngx.log(ngx.ERR, "[FieldService] transaction rolled back: ", tostring(results[2]))
        return nil, "Operation failed"
    end
    -- fn signalled a handled failure (nil, err): roll back, pass it through.
    if results[2] == nil and results[3] ~= nil then
        pcall(db.query, "ROLLBACK")
        return nil, results[3]
    end
    db.query("COMMIT")
    return unpack(results, 2, table.maxn(results))
end

--- Build a pagination meta block.
function Common.meta(total, page, per_page)
    total = tonumber(total) or 0
    return {
        total = total,
        page = page,
        per_page = per_page,
        total_pages = per_page > 0 and math.ceil(total / per_page) or 0,
    }
end

function Common.paging(params)
    local page = math.max(tonumber(params.page) or 1, 1)
    local per_page = math.min(math.max(tonumber(params.per_page) or 20, 1), 200)
    return page, per_page, (page - 1) * per_page
end

return Common
