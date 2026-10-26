-- Work log (docs/AI_RUNNER_WEB_TERMINAL.md §11): what the terminal reports about every tab (who, when, how long),
-- what the AI did in it (prompts, requests with tokens and cost, tool actions) and its screen recording.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")
local T = require("ai_runner.terminal")

local W = {}

W.PERMISSION = { "ai_terminal_worklogs", "read" } -- see everyone's; without it, only your own
W.TEXT_DAYS = 90                                  -- prompt and command text is blanked after this
W.RECORDING_DAYS = 30                             -- recordings are deleted after this
W.STALE_HOURS = 12                                -- an open tab with no news this long is closed (terminal lost it)
W.STALE_REASON = "the terminal stopped reporting"
W.MAX_TABS, W.MAX_EVENTS = 500, 2000              -- per activity request
W.MAX_PART = 4 * 1024 * 1024                      -- bytes per recording part

local EVENT_TYPES = { user_prompt = true, api_request = true, api_error = true, tool_result = true,
    tool_decision = true, metric = true }

local function str(v, max)
    if type(v) == "number" then v = tostring(v) end
    if type(v) ~= "string" or v == "" then return nil end
    return U.cut(v, max)
end

local function num(v)
    v = tonumber(v)
    if v and v == v and v > -1e15 and v < 1e15 then return v end
end

local function int(v)
    v = num(v)
    return v and math.floor(v) or nil
end

-- A unix time (seconds, may have a fraction) the terminal sent, as SQL; NULL when missing or absurd.
local function ts(v)
    v = num(v)
    if not v or v < 1e9 or v > 4e9 then return db.NULL end
    return db.raw(string.format("to_timestamp(%.3f)", v))
end

-- Who a tab belongs to: the opener of its launch, else the holder of the OpsAPI key it signed in with.
local function owner(term, tab)
    if U.is_uuid(tab.launch) then
        local s = U.one([[SELECT uuid, opened_by, task_uuid FROM ar_terminal_sessions
            WHERE uuid = ? AND namespace_id = ? AND terminal_uuid = ?]],
            tab.launch:lower(), term.namespace_id, term.uuid)
        if s then return s.opened_by, s.task_uuid, s.uuid end
    end
    if type(tab.key) == "string" and tab.key ~= "" then
        local k = U.one("SELECT user_uuid FROM ar_terminal_keys WHERE terminal_id = ? AND fingerprint = ?", term.id,
            tab.key)
        if k then return k.user_uuid end
    end
end

local function upsert_tab(term, tab)
    local id = str(tab.id, 64)
    if not id or not id:match("^[%w_%-]+$") then return nil end
    local user_uuid, task_uuid, session_uuid = owner(term, tab)
    return U.one([[INSERT INTO ar_terminal_tabs (namespace_id, terminal_id, tab_id, session_uuid, task_uuid, user_uuid,
            terminal_user, key_fingerprint, via, ip, kind, cwd, agent, opened_at, closed_at, end_reason, exit_code,
            active_secs, input_bytes, output_bytes)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (terminal_id, tab_id) DO UPDATE SET
            session_uuid = COALESCE(ar_terminal_tabs.session_uuid, EXCLUDED.session_uuid),
            task_uuid = COALESCE(ar_terminal_tabs.task_uuid, EXCLUDED.task_uuid),
            user_uuid = COALESCE(ar_terminal_tabs.user_uuid, EXCLUDED.user_uuid),
            terminal_user = COALESCE(EXCLUDED.terminal_user, ar_terminal_tabs.terminal_user),
            key_fingerprint = COALESCE(EXCLUDED.key_fingerprint, ar_terminal_tabs.key_fingerprint),
            via = COALESCE(EXCLUDED.via, ar_terminal_tabs.via), ip = COALESCE(EXCLUDED.ip, ar_terminal_tabs.ip),
            kind = COALESCE(EXCLUDED.kind, ar_terminal_tabs.kind), cwd = COALESCE(EXCLUDED.cwd, ar_terminal_tabs.cwd),
            agent = COALESCE(EXCLUDED.agent, ar_terminal_tabs.agent),
            opened_at = COALESCE(ar_terminal_tabs.opened_at, EXCLUDED.opened_at),
            -- A tab the sweep closed for lack of news (W.STALE_REASON) reopens if the terminal reports it open.
            closed_at = CASE WHEN EXCLUDED.closed_at IS NULL AND ar_terminal_tabs.end_reason = ']] .. W.STALE_REASON
                .. [[' THEN NULL ELSE COALESCE(EXCLUDED.closed_at, ar_terminal_tabs.closed_at) END,
            end_reason = CASE WHEN EXCLUDED.closed_at IS NULL AND ar_terminal_tabs.end_reason = ']] .. W.STALE_REASON
                .. [[' THEN NULL ELSE COALESCE(EXCLUDED.end_reason, ar_terminal_tabs.end_reason) END,
            exit_code = COALESCE(EXCLUDED.exit_code, ar_terminal_tabs.exit_code),
            active_secs = GREATEST(ar_terminal_tabs.active_secs, EXCLUDED.active_secs),
            input_bytes = GREATEST(ar_terminal_tabs.input_bytes, EXCLUDED.input_bytes),
            output_bytes = GREATEST(ar_terminal_tabs.output_bytes, EXCLUDED.output_bytes),
            updated_at = NOW()
        RETURNING id, user_uuid]],
        term.namespace_id, term.id, id, session_uuid or db.NULL, task_uuid or db.NULL, user_uuid or db.NULL,
        str(tab.user, 64) or db.NULL, str(tab.key, 80) or db.NULL, str(tab.via, 32) or db.NULL,
        str(tab.ip, 64) or db.NULL, str(tab.kind, 16) or db.NULL, str(tab.cwd, 1024) or db.NULL,
        str(tab.agent, 64) or db.NULL, ts(tab.opened_at), ts(tab.closed_at), str(tab.end_reason, 200) or db.NULL,
        int(tab.exit_code) or db.NULL, math.max(int(tab.active_secs) or 0, 0), math.max(int(tab.input_bytes) or 0, 0),
        math.max(int(tab.output_bytes) or 0, 0))
end

-- A tab an event names but no tab entry described yet (or ever: a tab the terminal lost): a bare row.
local function tab_for(term, tab_id, cache)
    if type(tab_id) ~= "string" or not tab_id:match("^[%w_%-]+$") or #tab_id > 64 then return nil end
    if cache[tab_id] == nil then
        cache[tab_id] = U.one("SELECT id, user_uuid FROM ar_terminal_tabs WHERE terminal_id = ? AND tab_id = ?",
            term.id, tab_id) or upsert_tab(term, { id = tab_id }) or false
    end
    return cache[tab_id] or nil
end

-- Roll an event up into its tab's totals and, for model requests, into ai_usage (the AI usage page).
local function roll_up(term, tab, e, a)
    if not tab then return end
    local set
    if e.type == "user_prompt" then
        set = "prompts = prompts + 1"
    elseif e.type == "api_request" then
        set = string.format([[requests = requests + 1, input_tokens = input_tokens + %d,
            output_tokens = output_tokens + %d, cache_read_tokens = cache_read_tokens + %d,
            cache_write_tokens = cache_write_tokens + %d, cost_usd = cost_usd + %.6f]],
            e.input_tokens or 0, e.output_tokens or 0, e.cache_read_tokens or 0, e.cache_write_tokens or 0,
            e.cost_usd or 0)
        if tab.user_uuid then
            pcall(db.insert, "ai_usage", {
                created_at = e.at, namespace_id = term.namespace_id, user_uuid = tab.user_uuid,
                feature = "web_terminal", scope = "terminal", provider = "anthropic", model = e.model or "unknown",
                -- As Llm.chat records Claude: input counts cache writes and reads; cached = the reads.
                input_tokens = (e.input_tokens or 0) + (e.cache_write_tokens or 0) + (e.cache_read_tokens or 0),
                output_tokens = e.output_tokens or 0, cached_input_tokens = e.cache_read_tokens or 0,
                latency_ms = e.duration_ms or 0, ok = true,
            })
        end
    elseif e.type == "tool_result" then
        set = "tool_calls = tool_calls + 1"
    elseif e.type == "metric" then
        local v = math.max(int(a.value) or 0, 0)
        local column = ({ ["claude_code.commit.count"] = "commits",
            ["claude_code.pull_request.count"] = "pull_requests" })[a.name]
        if a.name == "claude_code.lines_of_code.count" then
            column = a.type == "removed" and "lines_removed" or a.type == "added" and "lines_added" or nil
        end
        if column and v > 0 then set = string.format("%s = %s + %d", column, column, v) end
    end
    if set then db.query("UPDATE ar_terminal_tabs SET " .. set .. ", updated_at = NOW() WHERE id = ?", tab.id) end
end

local DROP_ATTRS = { ["user.email"] = true, ["user.account_uuid"] = true, ["organization.id"] = true,
    prompt = true, tool_parameters = true, tool_input = true, error = true }

local function store_event(term, ev, cache)
    if type(ev) ~= "table" or not EVENT_TYPES[ev.type] then return false end
    local event_id = str(ev.id, 128)
    if not event_id then return false end
    local a = type(ev.attrs) == "table" and ev.attrs or {}
    local tab = tab_for(term, ev.tab, cache)
    local e = { type = ev.type, at = ts(ev.at) }
    if e.at == db.NULL then e.at = db.raw("NOW()") end
    e.model, e.tool_name = str(a.model, 100), str(a.tool_name, 100)
    e.input_tokens, e.output_tokens = int(a.input_tokens), int(a.output_tokens)
    e.cache_read_tokens, e.cache_write_tokens = int(a.cache_read_tokens), int(a.cache_creation_tokens)
    e.cost_usd, e.duration_ms = num(a.cost_usd), int(a.duration_ms)
    local success = a.success
    if type(success) == "string" then success = success == "true" end
    -- The words: what was asked, which command or file, what failed. Secrets are masked before storing.
    local text = ev.type == "user_prompt" and a.prompt
        or ev.type == "tool_result" and (a.tool_parameters or a.tool_input)
        or ev.type == "api_error" and a.error or nil
    if type(text) == "table" then text = cjson.encode(text) end
    text = type(text) == "string" and text ~= "" and U.redact(U.cut(text, 16384)) or nil
    local keep = {}
    for k, v in pairs(a) do
        if not DROP_ATTRS[k] and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
            keep[k] = type(v) == "string" and U.cut(v, 500) or v
        end
    end
    local row = U.one([[INSERT INTO ar_terminal_events (namespace_id, terminal_id, tab_ref, event_id, at, type,
            claude_session, prompt_id, model, tool_name, success, input_tokens, output_tokens, cache_read_tokens,
            cache_write_tokens, cost_usd, duration_ms, text, attrs)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb)
        ON CONFLICT (terminal_id, event_id) DO NOTHING RETURNING id]],
        term.namespace_id, term.id, tab and tab.id or db.NULL, event_id, e.at, ev.type, str(ev.session, 64) or db.NULL,
        str(ev.prompt_id, 64) or db.NULL, e.model or db.NULL, e.tool_name or db.NULL,
        type(success) == "boolean" and success or db.NULL, e.input_tokens or db.NULL, e.output_tokens or db.NULL,
        e.cache_read_tokens or db.NULL, e.cache_write_tokens or db.NULL, e.cost_usd or db.NULL,
        e.duration_ms or db.NULL, text or db.NULL, next(keep) and cjson.encode(keep) or "{}")
    if row then roll_up(term, tab, e, a) end
    return row ~= nil
end

--- Take a terminal's activity report (§11.2): tab states and events.
-- @return { tabs = n, events = n } | nil, status, msg
function W.ingest(term, body)
    if type(body) ~= "table" or (body.terminal ~= nil and tostring(body.terminal):lower() ~= term.uuid) then
        return nil, 400, "Invalid body"
    end
    local tabs = type(body.tabs) == "table" and body.tabs or {}
    local events = type(body.events) == "table" and body.events or {}
    if #tabs > W.MAX_TABS or #events > W.MAX_EVENTS then return nil, 413, "Too many tabs or events in one request" end
    ngx.ctx.ar_ns = term.namespace_id -- the workspace's own redaction patterns
    local cache, n_tabs, n_events = {}, 0, 0
    for _, tab in ipairs(tabs) do
        if type(tab) == "table" then
            local row = upsert_tab(term, tab)
            if row then
                n_tabs = n_tabs + 1
                cache[tab.id] = row
            end
        end
    end
    for _, ev in ipairs(events) do
        if store_event(term, ev, cache) then n_events = n_events + 1 end
    end
    return { tabs = n_tabs, events = n_events }
end

--- Store one recording part (§11.2). @return { stored = bool } | nil, status, msg
function W.store_recording(term, tab_id, part, final, bytes)
    part = int(part)
    if not part or part < 0 or part > 100000 then return nil, 400, "Invalid part" end
    if #bytes == 0 or #bytes > W.MAX_PART then return nil, 413, "A part must be 1 byte to 4 MiB" end
    if bytes:sub(1, 2) ~= "\31\139" then return nil, 400, "A part must be gzipped" end
    local tab = tab_for(term, tab_id, {})
    if not tab then return nil, 400, "Invalid tab" end
    if U.one("SELECT 1 AS x FROM ar_terminal_recordings WHERE tab_ref = ? AND part = ?", tab.id, part) then
        return { stored = false }
    end
    local t = U.one("SELECT uuid FROM ar_terminal_tabs WHERE id = ?", tab.id)
    local key = ("terminal-recordings/%d/%s/%s/%06d.cast.gz"):format(term.namespace_id, term.uuid, t.uuid, part)
    local Minio = require("helper.minio").getDefault()
    local _, err, meta = Minio:upload({ filename = ("%06d.cast.gz"):format(part), content = bytes,
        content_type = "application/gzip" }, { object_key = key, validate_type = false, max_size = W.MAX_PART })
    if not meta then
        ngx.log(ngx.ERR, "[ai_runner] recording upload: ", tostring(err))
        return nil, 503, "Could not store the recording"
    end
    local row = U.one([[INSERT INTO ar_terminal_recordings
            (namespace_id, tab_ref, part, final, object_key, bucket, bytes)
        VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (tab_ref, part) DO NOTHING RETURNING id]],
        term.namespace_id, tab.id, part, final == true, meta.key, meta.bucket, #bytes)
    if row then
        db.query([[UPDATE ar_terminal_tabs SET recording_parts = recording_parts + 1,
            recording_bytes = recording_bytes + ?, updated_at = NOW() WHERE id = ?]], #bytes, tab.id)
    end
    return { stored = row ~= nil }
end

--- Blank old text, close tabs the terminal lost and delete old recordings (W.TEXT_DAYS, W.STALE_HOURS,
-- W.RECORDING_DAYS). Safe to run in several workers at once: each recording row is claimed by the DELETE returning it.
function W.sweep()
    db.query([[UPDATE ar_terminal_events SET text = NULL WHERE text IS NOT NULL
        AND created_at < NOW() - interval ']] .. W.TEXT_DAYS .. [[ days']])
    -- The terminal's own idle limits close real tabs long before this: no news means it lost them (a crash).
    db.query([[UPDATE ar_terminal_tabs SET closed_at = updated_at, end_reason = ?, updated_at = NOW()
        WHERE closed_at IS NULL AND updated_at < NOW() - interval ']] .. W.STALE_HOURS .. [[ hours']], W.STALE_REASON)
    local gone = db.query([[DELETE FROM ar_terminal_recordings WHERE created_at < NOW() - interval ']]
        .. W.RECORDING_DAYS .. [[ days' RETURNING tab_ref, object_key, bucket, bytes]])
    if #gone == 0 then return 0 end
    local Minio = require("helper.minio").getDefault()
    for _, r in ipairs(gone) do
        pcall(Minio.delete, Minio, r.object_key, r.bucket)
        db.query([[UPDATE ar_terminal_tabs SET recording_parts = GREATEST(recording_parts - 1, 0),
            recording_bytes = GREATEST(recording_bytes - ?, 0) WHERE id = ?]], r.bytes, r.tab_ref)
    end
    return #gone
end

-- ---------------------------------------------------------------------------
-- Reading (the dashboard)
-- ---------------------------------------------------------------------------

local TAB_SQL = [[SELECT t.*, ]] .. R.name_sql("u") .. [[ AS person_name, u.email AS person_email,
        term.name AS terminal_name, kt.task_number, kt.title AS task_title,
        EXTRACT(EPOCH FROM (COALESCE(t.closed_at, t.updated_at) - t.opened_at))::bigint AS duration_secs
    FROM ar_terminal_tabs t
    LEFT JOIN ar_terminals term ON term.id = t.terminal_id
    LEFT JOIN users u ON u.uuid = t.user_uuid
    LEFT JOIN kanban_tasks kt ON kt.uuid = t.task_uuid]]

function W.tab_view(t)
    local cost = tonumber(t.cost_usd) or 0
    return {
        uuid = t.uuid, tab_id = t.tab_id, terminal_name = U.null(t.terminal_name), user_uuid = U.null(t.user_uuid),
        person_name = U.null(t.person_name), person_email = U.null(t.person_email),
        terminal_user = U.null(t.terminal_user), via = U.null(t.via), ip = U.null(t.ip), kind = U.null(t.kind),
        cwd = U.null(t.cwd), agent = U.null(t.agent), session_uuid = U.null(t.session_uuid),
        task_uuid = U.null(t.task_uuid), task_number = U.null(tonumber(t.task_number)),
        task_title = U.null(t.task_title), opened_at = U.null(t.opened_at), closed_at = U.null(t.closed_at),
        open = t.closed_at == nil, end_reason = U.null(t.end_reason), exit_code = U.null(t.exit_code),
        duration_secs = math.max(tonumber(t.duration_secs) or 0, 0),
        -- Counted in 10-second steps by the terminal: never more than the time the tab was open.
        active_secs = math.min(tonumber(t.active_secs) or 0, math.max(tonumber(t.duration_secs) or 0, 0)),
        input_bytes = tonumber(t.input_bytes) or 0, output_bytes = tonumber(t.output_bytes) or 0,
        prompts = t.prompts, requests = t.requests, tool_calls = t.tool_calls,
        input_tokens = tonumber(t.input_tokens) or 0, output_tokens = tonumber(t.output_tokens) or 0,
        cache_read_tokens = tonumber(t.cache_read_tokens) or 0,
        cache_write_tokens = tonumber(t.cache_write_tokens) or 0,
        cost_usd = cost, lines_added = t.lines_added, lines_removed = t.lines_removed, commits = t.commits,
        pull_requests = t.pull_requests, recording_parts = t.recording_parts,
        recording_bytes = tonumber(t.recording_bytes) or 0,
    }
end

-- WHERE clauses shared by the list and the per-person summary. f = { user_uuid, task_uuid, from, to }
local function filters(ns, f)
    local where, args = { "t.namespace_id = ?" }, { ns }
    if U.is_uuid(f.user_uuid) then where[#where + 1] = "t.user_uuid = ?"; args[#args + 1] = f.user_uuid:lower() end
    if U.is_uuid(f.task_uuid) then where[#where + 1] = "t.task_uuid = ?"; args[#args + 1] = f.task_uuid:lower() end
    if type(f.from) == "string" and f.from:match("^%d%d%d%d%-%d%d%-%d%d$") then
        where[#where + 1] = "t.opened_at >= ?::date"; args[#args + 1] = f.from
    end
    if type(f.to) == "string" and f.to:match("^%d%d%d%d%-%d%d%-%d%d$") then
        where[#where + 1] = "t.opened_at < ?::date + 1"; args[#args + 1] = f.to
    end
    return table.concat(where, " AND "), args
end

function W.list(ns, f, page, per_page)
    local where, args = filters(ns, f)
    local total = tonumber(U.one("SELECT COUNT(*) AS n FROM ar_terminal_tabs t WHERE " .. where, unpack(args)).n)
    args[#args + 1] = per_page
    args[#args + 1] = (page - 1) * per_page
    local out = {}
    for i, t in ipairs(db.query(TAB_SQL .. " WHERE " .. where
        .. " ORDER BY t.opened_at DESC NULLS LAST, t.id DESC LIMIT ? OFFSET ?", unpack(args))) do
        out[i] = W.tab_view(t)
    end
    return U.array(out), { page = page, per_page = per_page, total = total, total_pages = math.ceil(total / per_page) }
end

function W.people(ns, f)
    local where, args = filters(ns, f)
    local out = {}
    for i, p in ipairs(db.query([[SELECT t.user_uuid, MAX(]] .. R.name_sql("u") .. [[) AS person_name,
            MAX(u.email) AS person_email, MAX(t.terminal_user) AS terminal_user, COUNT(*) AS tabs,
            SUM(LEAST(t.active_secs, GREATEST(EXTRACT(EPOCH FROM (COALESCE(t.closed_at, t.updated_at)
                - t.opened_at)), 0))) AS active_secs, SUM(t.prompts) AS prompts, SUM(t.requests) AS requests,
            SUM(t.tool_calls) AS tool_calls,
            SUM(t.input_tokens + t.cache_read_tokens + t.cache_write_tokens) AS input_tokens,
            SUM(t.output_tokens) AS output_tokens, SUM(t.cost_usd) AS cost_usd, SUM(t.lines_added) AS lines_added,
            SUM(t.lines_removed) AS lines_removed, SUM(t.commits) AS commits, SUM(t.pull_requests) AS pull_requests,
            MAX(COALESCE(t.closed_at, t.updated_at)) AS last_seen
        FROM ar_terminal_tabs t LEFT JOIN users u ON u.uuid = t.user_uuid
        WHERE ]] .. where .. [[ GROUP BY t.user_uuid ORDER BY 6 DESC LIMIT 500]], unpack(args))) do
        out[i] = { user_uuid = U.null(p.user_uuid), person_name = U.null(p.person_name),
            person_email = U.null(p.person_email), terminal_user = U.null(p.terminal_user),
            tabs = tonumber(p.tabs), active_secs = tonumber(p.active_secs) or 0, prompts = tonumber(p.prompts) or 0,
            requests = tonumber(p.requests) or 0, tool_calls = tonumber(p.tool_calls) or 0,
            input_tokens = tonumber(p.input_tokens) or 0, output_tokens = tonumber(p.output_tokens) or 0,
            cost_usd = tonumber(p.cost_usd) or 0, lines_added = tonumber(p.lines_added) or 0,
            lines_removed = tonumber(p.lines_removed) or 0, commits = tonumber(p.commits) or 0,
            pull_requests = tonumber(p.pull_requests) or 0, last_seen = U.null(p.last_seen) }
    end
    return U.array(out)
end

function W.find(ns, uuid)
    if not U.is_uuid(uuid) then return nil end
    return U.one(TAB_SQL .. " WHERE t.namespace_id = ? AND t.uuid = ?", ns, uuid:lower())
end

--- A tab with its timeline (events, oldest first) and recording parts.
function W.detail(t)
    local events = {}
    for i, e in ipairs(db.query([[SELECT event_id, at, type, claude_session, prompt_id, model, tool_name, success,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd, duration_ms, text, attrs
        FROM ar_terminal_events WHERE tab_ref = ? ORDER BY at, id LIMIT 5000]], t.id)) do
        events[i] = { id = e.event_id, at = e.at, type = e.type, session = U.null(e.claude_session),
            prompt_id = U.null(e.prompt_id), model = U.null(e.model), tool_name = U.null(e.tool_name),
            success = U.null(e.success), input_tokens = U.null(e.input_tokens), output_tokens = U.null(e.output_tokens),
            cache_read_tokens = U.null(e.cache_read_tokens), cache_write_tokens = U.null(e.cache_write_tokens),
            cost_usd = U.null(tonumber(e.cost_usd)), duration_ms = U.null(e.duration_ms), text = U.null(e.text),
            attrs = U.json(e.attrs) or {} }
    end
    local parts = db.query([[SELECT part, final, bytes, created_at FROM ar_terminal_recordings WHERE tab_ref = ?
        ORDER BY part]], t.id)
    local view = W.tab_view(t)
    view.events = U.array(events)
    view.recording = U.array(parts)
    view.text_days, view.recording_days = W.TEXT_DAYS, W.RECORDING_DAYS
    return view
end

--- The bytes of one recording part (gzipped asciicast). @return bytes | nil
function W.recording_part(t, part)
    local row = U.one("SELECT object_key, bucket FROM ar_terminal_recordings WHERE tab_ref = ? AND part = ?", t.id,
        tonumber(part))
    if not row then return nil end
    local Minio = require("helper.minio").getDefault()
    local url = Minio:getPresignedUrl(row.object_key, 300, row.bucket, false, "GET")
    if not url then return nil end
    local res = require("resty.http").new():request_uri(url:gsub("^https?://[^/]+", Minio:_resolved_endpoint(), 1), {
        method = "GET", headers = { Host = Minio.host }, ssl_verify = false,
    })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "[ai_runner] recording read: ", res and res.status or "no response")
        return nil
    end
    return res.body
end

return W
