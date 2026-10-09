--[[
    Form responses: list, read, export, delete, spam and retry
    ==========================================================

    Every function takes a form row already loaded for the caller's namespace
    (FormQueries.load), so a response can only be reached through its own
    workspace's form. Lists are keyset-paged (created_at, id), never OFFSET,
    and each page loads its links and linked records in a few batched queries.
]]

local db = require("lapis.db")
local cjson = require("lib.forms.json")
local Fields = require("lib.forms.fields")
local Submit = require("lib.forms.submit")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143

local FormSubmissionQueries = {}

local PAGE = 50
local decode = Submit.decode
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function nonnull(v)
    if v == nil or v == db.NULL or v == cjson.null then return nil end
    return v
end

local function arr(t)
    return setmetatable(t or {}, cjson.array_mt)
end

-- ---------------------------------------------------------------------------
-- Columns: every answer key across the form's versions, newest label first
-- ---------------------------------------------------------------------------

--- The response table's columns: input fields of every published version
-- (and the draft, for a form not published yet), latest label wins.
function FormSubmissionQueries.columns(form)
    local cols, seen = {}, {}
    local schemas = {}
    for _, v in ipairs(db.query("SELECT schema FROM form_versions WHERE form_id = ? ORDER BY version DESC LIMIT 100",
        form.id)) do
        schemas[#schemas + 1] = decode(v.schema, { fields = {} })
    end
    if #schemas == 0 then schemas[1] = decode(form.draft_schema, { fields = {} }) end
    for _, schema in ipairs(schemas) do
        for _, f in ipairs(schema.fields or {}) do
            local def = Fields.TYPES[f.type]
            if def and def.input ~= false and not seen[f.key] then
                seen[f.key] = f
                cols[#cols + 1] = { key = f.key, label = f.label, type = f.type, options = f.options,
                    scale = f.scale }
            end
        end
    end
    return arr(cols), seen
end

-- ---------------------------------------------------------------------------
-- Links + the records they point at, batched
-- ---------------------------------------------------------------------------

local ENTITY_SQL = {
    customer = [[SELECT uuid, first_name, last_name, email FROM customers WHERE namespace_id = ? AND uuid IN ?]],
    lead = [[SELECT uuid, first_name, last_name, email, status FROM crm_leads WHERE namespace_id = ? AND uuid IN ?]],
    user = [[SELECT u.uuid, u.first_name, u.last_name, u.email FROM users u
             JOIN namespace_members m ON m.user_id = u.id AND m.namespace_id = ? WHERE u.uuid IN ?]],
    invitation = [[SELECT uuid, email, status, expires_at FROM namespace_invitations
                   WHERE namespace_id = ? AND uuid IN ?]],
}

local function attach_links(rows, namespace_id)
    if #rows == 0 then return end
    local ids, by_id = {}, {}
    for _, r in ipairs(rows) do
        ids[#ids + 1] = tonumber(r.id)
        by_id[tonumber(r.id)] = r
        r.links = arr({})
    end
    local links = db.query("SELECT * FROM form_submission_links WHERE submission_id IN ("
        .. table.concat(ids, ",") .. ") ORDER BY target")
    local wanted = {}
    for _, l in ipairs(links) do
        local et, eu = nonnull(l.entity_type), nonnull(l.entity_uuid)
        if et and eu and ENTITY_SQL[et] then
            wanted[et] = wanted[et] or {}
            wanted[et][#wanted[et] + 1] = eu
        end
    end
    local records = {}
    for et, uuids in pairs(wanted) do
        records[et] = {}
        local ok, found = pcall(db.query, ENTITY_SQL[et], namespace_id, db.list(uuids))
        for _, e in ipairs(ok and found or {}) do
            local name = ((nonnull(e.first_name) or "") .. " " .. (nonnull(e.last_name) or "")):match("^%s*(.-)%s*$")
            records[et][e.uuid] = { name = name ~= "" and name or nil, email = nonnull(e.email),
                status = nonnull(e.status), expires_at = nonnull(e.expires_at) }
        end
    end
    for _, l in ipairs(links) do
        local et, eu = nonnull(l.entity_type), nonnull(l.entity_uuid)
        local rec = et and eu and records[et] and records[et][eu]
        local row = by_id[tonumber(l.submission_id)]
        row.links[#row.links + 1] = {
            target = l.target,
            outcome = l.outcome,
            entity_type = et,
            entity_uuid = eu,
            error_code = nonnull(l.error_code),
            record = rec or nil,
            missing = (eu and not rec) or nil, -- deleted since
        }
    end
end

local function present(r)
    local meta = decode(r.meta, {})
    return {
        uuid = r.uuid,
        status = r.status,
        respondent_email = nonnull(r.respondent_email),
        answers = decode(r.data, {}),
        version = tonumber(r.version),
        links = r.links or arr({}),
        utm = meta.utm,
        referrer = meta.referrer,
        page_url = meta.page_url,
        spam_reason = meta.spam_reason,
        duration_ms = meta.duration_ms,
        created_at = r.created_at,
        processed_at = nonnull(r.processed_at),
    }
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

local function filters(form, params)
    local where, args = { "s.form_id = ?" }, { form.id }
    local status = params.status
    if status == nil or status == "" then
        where[#where + 1] = "s.status <> 'spam'"
    elseif status ~= "all" then
        if status ~= "complete" and status ~= "needs_attention" and status ~= "spam" then
            return nil, "status must be complete, needs_attention, spam or all"
        end
        where[#where + 1] = "s.status = ?"
        args[#args + 1] = status
    end
    for _, k in ipairs({ "from", "to" }) do
        local v = params[k]
        if v ~= nil and v ~= "" then
            if type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d") or #v > 40 then
                return nil, k .. " must be a date (YYYY-MM-DD)"
            end
            where[#where + 1] = k == "from" and "s.created_at >= ?::timestamptz" or "s.created_at < ?::timestamptz"
            args[#args + 1] = v
        end
    end
    if type(params.q) == "string" and params.q ~= "" then
        local like = "%" .. params.q:sub(1, 100):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(s.respondent_email ILIKE ? OR s.data::text ILIKE ?)"
        args[#args + 1] = like
        args[#args + 1] = like
    end
    return where, args
end

--- A page of a form's responses, newest first. ?cursor = the last uuid seen.
-- @return items, meta | nil, err
function FormSubmissionQueries.list(form, params)
    params = params or {}
    local where, args = filters(form, params)
    if not where then return nil, args end
    if type(params.cursor) == "string" and params.cursor:match(UUID) then
        where[#where + 1] = [[(s.created_at, s.id) < (SELECT created_at, id FROM form_submissions
            WHERE uuid = ? AND form_id = ?)]]
        args[#args + 1] = params.cursor
        args[#args + 1] = form.id
    end
    local limit = math.min(math.max(math.floor(tonumber(params.limit) or PAGE), 1), 200)
    args[#args + 1] = limit + 1
    local rows = db.query([[
        SELECT s.id, s.uuid, s.status, s.respondent_email, s.data, s.meta, s.created_at, s.processed_at,
               v.version
        FROM form_submissions s JOIN form_versions v ON v.id = s.version_id
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY s.created_at DESC, s.id DESC LIMIT ?
    ]], unpack(args))
    local page = {}
    for i = 1, math.min(#rows, limit) do page[i] = rows[i] end
    attach_links(page, form.namespace_id)
    local items = {}
    for i, r in ipairs(page) do items[i] = present(r) end
    return arr(items), { next_cursor = #rows > limit and rows[limit].uuid or nil }
end

local function load(form, uuid)
    if type(uuid) ~= "string" or not uuid:match(UUID) then return nil end
    return db.query([[
        SELECT s.*, v.version, v.schema AS version_schema, v.targets AS version_targets,
               v.published_by_uuid AS version_published_by_uuid
        FROM form_submissions s JOIN form_versions v ON v.id = s.version_id
        WHERE s.form_id = ? AND s.uuid = ?
    ]], form.id, uuid)[1]
end

--- One response with the fields of the version it answered.
function FormSubmissionQueries.get(form, uuid)
    local row = load(form, uuid)
    if not row then return nil end
    attach_links({ row }, form.namespace_id)
    local out = present(row)
    local schema = decode(row.version_schema, { fields = {} })
    out.fields = arr(schema.fields or {})
    return out
end

-- ---------------------------------------------------------------------------
-- Writes
-- ---------------------------------------------------------------------------

function FormSubmissionQueries.delete(form, uuid)
    local row = load(form, uuid)
    if not row then return nil, "Response not found", 404 end
    db.query("BEGIN")
    local ok, err = pcall(function()
        db.query("DELETE FROM form_submissions WHERE id = ?", row.id)
        if row.status ~= "spam" then
            db.query("UPDATE forms SET submission_count = GREATEST(submission_count - 1, 0) WHERE id = ?", form.id)
        end
    end)
    if not ok then
        pcall(db.query, "ROLLBACK")
        error(err, 0)
    end
    db.query("COMMIT")
    return true
end

local function namespace_of(form)
    return db.query("SELECT id, name, max_users FROM namespaces WHERE id = ?", form.namespace_id)[1]
end

-- Re-run the targets that failed or never ran (a spam response, a fixed role
-- or a freed seat). The version's publisher stays the authority.
local function process(form, row)
    local version = {
        schema = row.version_schema, targets = row.version_targets,
        published_by_uuid = row.version_published_by_uuid,
    }
    local answers = decode(row.data, {})
    local schema = decode(row.version_schema, { fields = {} })
    -- Spam was stored unvalidated: it must fit the form before records are made.
    local clean, errors = Fields.validate(schema, answers)
    if not clean then return nil, "this response doesn't fit the form, so no records can be created from it", 422,
        errors end
    local done = {}
    for _, l in ipairs(db.query([[SELECT target FROM form_submission_links
        WHERE submission_id = ? AND outcome <> 'failed']], row.id)) do
        done[l.target] = true
    end
    local pending = {}
    for _, t in ipairs(decode(version.targets, {})) do
        if not done[t.type] then pending[#pending + 1] = t end
    end
    version.targets = pending
    local hooks = {}
    local contact = Fields.contact(schema, clean)
    db.query("BEGIN")
    local ok, err = pcall(function()
        db.query("SELECT id FROM form_submissions WHERE id = ? FOR UPDATE", row.id)
        local links, failed = Submit.run_targets(form, version, clean, row.uuid, decode(row.meta, {}),
            namespace_of(form), function(fn) hooks[#hooks + 1] = fn end)
        Submit.save_links(row.id, form.namespace_id, links)
        if row.status == "spam" then
            db.query("UPDATE forms SET submission_count = submission_count + 1 WHERE id = ?", form.id)
        end
        local still_failed = failed or db.query([[SELECT 1 FROM form_submission_links
            WHERE submission_id = ? AND outcome = 'failed']], row.id)[1] ~= nil
        db.query([[UPDATE form_submissions SET status = ?, data = ?::jsonb, respondent_email = ?,
            processed_at = NOW(), updated_at = NOW() WHERE id = ?]],
            still_failed and "needs_attention" or "complete", cjson.encode(clean),
            contact.email and contact.email:lower() or db.NULL, row.id)
    end)
    if not ok then
        pcall(db.query, "ROLLBACK")
        error(err, 0)
    end
    db.query("COMMIT")
    for _, fn in ipairs(hooks) do pcall(fn) end
    return FormSubmissionQueries.get(form, row.uuid)
end

--- Retry failed targets. @return response | nil, err, status
function FormSubmissionQueries.retry(form, uuid)
    local row = load(form, uuid)
    if not row then return nil, "Response not found", 404 end
    if row.status == "spam" then return nil, "mark it as not spam first", 409 end
    return process(form, row)
end

--- Mark a response as spam, or not spam (which runs its targets).
function FormSubmissionQueries.setStatus(form, uuid, status)
    local row = load(form, uuid)
    if not row then return nil, "Response not found", 404 end
    if status == "spam" then
        if row.status ~= "spam" then
            db.query("BEGIN")
            local ok, err = pcall(function()
                db.query("UPDATE form_submissions SET status = 'spam', updated_at = NOW() WHERE id = ?", row.id)
                db.query("UPDATE forms SET submission_count = GREATEST(submission_count - 1, 0) WHERE id = ?", form.id)
            end)
            if not ok then
                pcall(db.query, "ROLLBACK")
                error(err, 0)
            end
            db.query("COMMIT")
        end
        return FormSubmissionQueries.get(form, uuid)
    elseif status == "complete" then
        if row.status ~= "spam" then return FormSubmissionQueries.get(form, uuid) end
        return process(form, row)
    end
    return nil, "status must be spam or complete"
end

-- ---------------------------------------------------------------------------
-- CSV export (streamed)
-- ---------------------------------------------------------------------------

local cell = Fields.csv_cell

--- Write the form's responses as CSV through `write(chunk)`, 1,000 rows at a time.
function FormSubmissionQueries.export(form, params, write)
    local cols, by_key = FormSubmissionQueries.columns(form)
    local header = { "Submitted at (UTC)", "Status" }
    for _, c in ipairs(cols) do header[#header + 1] = cell(c.label) end
    header[#header + 1] = "Records"
    write(table.concat(header, ",") .. "\r\n")

    local where, args = filters(form, params or {})
    if not where then return nil, args end
    local after
    repeat
        local w, a = { unpack(where) }, { unpack(args) }
        if after then
            w[#w + 1] = "(s.created_at, s.id) < (?::timestamptz, ?)"
            a[#a + 1] = after.created_at
            a[#a + 1] = after.id
        end
        local rows = db.query([[
            SELECT s.id, s.status, s.data, s.created_at,
                   to_char(s.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS created_utc
            FROM form_submissions s WHERE ]] .. table.concat(w, " AND ") .. [[
            ORDER BY s.created_at DESC, s.id DESC LIMIT 1000
        ]], unpack(a))
        attach_links(rows, form.namespace_id)
        local out = {}
        for _, r in ipairs(rows) do
            local answers = decode(r.data, {})
            local line = { cell(r.created_utc), cell(r.status) }
            for _, c in ipairs(cols) do line[#line + 1] = cell(Fields.show(by_key[c.key], answers[c.key])) end
            local recs = {}
            for _, l in ipairs(r.links or {}) do recs[#recs + 1] = l.target .. ": " .. l.outcome end
            line[#line + 1] = cell(table.concat(recs, "; "))
            out[#out + 1] = table.concat(line, ",")
        end
        if #out > 0 then write(table.concat(out, "\r\n") .. "\r\n") end
        after = rows[#rows]
    until #rows < 1000
    return true
end

return FormSubmissionQueries
