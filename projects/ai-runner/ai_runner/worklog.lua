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
W.LOST_SECS = 600                                 -- …or this long, from a terminal that reports open tabs each minute
W.LIVE_SECS = 180                                 -- "working now": the terminal reported the open tab this recently
W.STALE_REASON = "the terminal stopped reporting"
W.MAX_TABS, W.MAX_EVENTS = 500, 2000              -- per activity request
W.COUNT_CAP = 1000                                -- the list counts matching tabs up to this many ("1000+")
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

-- A tab entry from the terminal (state = true: it described the tab; seen_at becomes now, §11.2) or a bare row for
-- a tab an event names. last_input_at (unix seconds or null) and attached (a browser shows it) are optional.
local function upsert_tab(term, tab, state)
    local id = str(tab.id, 64)
    if not id or not id:match("^[%w_%-]+$") then return nil end
    local user_uuid, task_uuid, session_uuid = owner(term, tab)
    return U.one([[INSERT INTO ar_terminal_tabs (namespace_id, terminal_id, tab_id, session_uuid, task_uuid, user_uuid,
            terminal_user, key_fingerprint, via, ip, kind, cwd, agent, opened_at, closed_at, end_reason, exit_code,
            active_secs, input_bytes, output_bytes, last_input_at, seen_at, attached)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            last_input_at = GREATEST(ar_terminal_tabs.last_input_at, EXCLUDED.last_input_at),
            seen_at = COALESCE(EXCLUDED.seen_at, ar_terminal_tabs.seen_at),
            attached = COALESCE(EXCLUDED.attached, ar_terminal_tabs.attached),
            updated_at = NOW()
        RETURNING id, user_uuid]],
        term.namespace_id, term.id, id, session_uuid or db.NULL, task_uuid or db.NULL, user_uuid or db.NULL,
        str(tab.user, 64) or db.NULL, str(tab.key, 80) or db.NULL, str(tab.via, 32) or db.NULL,
        str(tab.ip, 64) or db.NULL, str(tab.kind, 16) or db.NULL, str(tab.cwd, 1024) or db.NULL,
        str(tab.agent, 64) or db.NULL, ts(tab.opened_at), ts(tab.closed_at), str(tab.end_reason, 200) or db.NULL,
        int(tab.exit_code) or db.NULL, math.max(int(tab.active_secs) or 0, 0), math.max(int(tab.input_bytes) or 0, 0),
        math.max(int(tab.output_bytes) or 0, 0), ts(tab.last_input_at), state and db.raw("NOW()") or db.NULL,
        type(tab.attached) == "boolean" and tab.attached or db.NULL)
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
            local row = upsert_tab(term, tab, true)
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

--- Close the open tabs a terminal stopped reporting (it lost them: a crash, a restart). A terminal that reports
-- every open tab at least once a minute (it sends `attached`) after W.LOST_SECS without news; an older one, which
-- reports only changes, after W.STALE_HOURS (its own idle limits close real tabs long before). Cheap: open tabs only
-- (partial indexes). A tab reported open again reopens (upsert_tab).
function W.close_stale()
    db.query([[UPDATE ar_terminal_tabs SET closed_at = GREATEST(seen_at, updated_at), end_reason = ?,
            updated_at = NOW()
        WHERE closed_at IS NULL AND ((attached IS NOT NULL AND seen_at < NOW() - interval ']] .. W.LOST_SECS
        .. [[ seconds') OR updated_at < NOW() - interval ']] .. W.STALE_HOURS .. [[ hours')]], W.STALE_REASON)
end

--- Blank old text, close tabs the terminal lost and delete old recordings (W.TEXT_DAYS, W.close_stale,
-- W.RECORDING_DAYS). Safe to run in several workers at once: each recording row is claimed by the DELETE returning it.
function W.sweep()
    db.query([[UPDATE ar_terminal_events SET text = NULL WHERE text IS NOT NULL
        AND created_at < NOW() - interval ']] .. W.TEXT_DAYS .. [[ days']])
    W.close_stale()
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
        -- §11.2: when someone last typed, when the terminal last reported the tab, whether a browser shows it.
        last_input_at = U.null(t.last_input_at), seen_at = U.null(t.seen_at), attached = U.null(t.attached),
    }
end

-- A search as an ILIKE pattern: its own %, _ and \ match themselves.
local function like(q)
    return "%" .. q:gsub("[%%_\\]", "\\%0") .. "%"
end

-- WHERE clauses shared by the list and the per-person summary; every value is a parameter.
-- f = { user_uuid, task_uuid, from, to, terminal_uuid, state = open|closed, agent, q }. q (person name or email,
-- terminal user, folder, task title) needs the users u and kanban_tasks kt joins: the third result says so.
local function filters(ns, f)
    local where, args = { "t.namespace_id = ?" }, { ns }
    local function add(sql, ...)
        where[#where + 1] = sql
        for _, v in ipairs({ ... }) do args[#args + 1] = v end
    end
    if U.is_uuid(f.user_uuid) then add("t.user_uuid = ?", f.user_uuid:lower()) end
    if U.is_uuid(f.task_uuid) then add("t.task_uuid = ?", f.task_uuid:lower()) end
    local function day(v) return type(v) == "string" and v:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil end
    if day(f.from) then add("t.opened_at >= ?::date", f.from) end
    if day(f.to) then add("t.opened_at < ?::date + 1", f.to) end
    if U.is_uuid(f.terminal_uuid) then
        add("t.terminal_id = (SELECT id FROM ar_terminals WHERE namespace_id = ? AND uuid = ?)", ns,
            f.terminal_uuid:lower())
    end
    if f.state == "open" then
        add("t.closed_at IS NULL")
    elseif f.state == "closed" then
        add("t.closed_at IS NOT NULL")
    end
    if type(f.agent) == "string" and f.agent ~= "" and #f.agent <= 64 then add("t.agent = ?", f.agent) end
    local q = type(f.q) == "string" and U.clean(f.q:match("^%s*(.-)%s*$"), 100) or ""
    if q ~= "" then
        local p = like(q)
        add("(" .. R.name_sql("u") .. " ILIKE ? OR u.email ILIKE ? OR t.terminal_user ILIKE ? OR t.cwd ILIKE ? "
            .. "OR kt.title ILIKE ?)", p, p, p, p, p)
    end
    return table.concat(where, " AND "), args, q ~= ""
end

--- A page of tabs, newest first. Counting stops at W.COUNT_CAP + 1 matches, so no page pays for counting a long
-- history: meta.total_capped says there are more than total, and has_more whether a next page exists.
function W.list(ns, f, page, per_page)
    local where, args, joins = filters(ns, f)
    local from = joins and [[ FROM ar_terminal_tabs t LEFT JOIN users u ON u.uuid = t.user_uuid
        LEFT JOIN kanban_tasks kt ON kt.uuid = t.task_uuid]] or " FROM ar_terminal_tabs t"
    local n = tonumber(U.one("SELECT COUNT(*) AS n FROM (SELECT 1" .. from .. " WHERE " .. where .. " LIMIT "
        .. (W.COUNT_CAP + 1) .. ") c", unpack(args)).n)
    local capped = n > W.COUNT_CAP
    local total = capped and W.COUNT_CAP or n
    args[#args + 1] = per_page + 1
    args[#args + 1] = (page - 1) * per_page
    local rows = db.query(TAB_SQL .. " WHERE " .. where
        .. " ORDER BY t.opened_at DESC NULLS LAST, t.id DESC LIMIT ? OFFSET ?", unpack(args))
    local out = {}
    for i = 1, math.min(#rows, per_page) do out[i] = W.tab_view(rows[i]) end
    local has_more = #rows > per_page
    local pages = math.ceil(total / per_page)
    if has_more then pages = math.max(pages, page + 1) end
    return U.array(out), { page = page, per_page = per_page, total = total, total_pages = pages,
        total_capped = capped, has_more = has_more }
end

--- What the work log's filters offer: the workspace's terminals and the agents they list.
function W.options(ns)
    local terminals, agents, seen = {}, {}, {}
    for i, t in ipairs(T.list(ns)) do
        terminals[i] = { uuid = t.uuid, name = t.name }
        for _, a in ipairs(T.agents(t)) do
            if not seen[a.id] then
                seen[a.id] = true
                agents[#agents + 1] = { id = a.id, label = a.label }
            end
        end
    end
    return { terminals = U.array(terminals), agents = U.array(agents) }
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

--- Who is working right now (§11.4): open tabs the terminal reported in the last W.LIVE_SECS, by person.
-- user_uuid: only that person's (callers without ai_terminal_worklogs.read). with_keys: add the person's live key
-- on that terminal (key_uuid), for Suspend.
function W.live(ns, user_uuid, with_keys)
    local args, mine = { ns }, ""
    if user_uuid then mine, args[2] = " AND t.user_uuid = ?", user_uuid end
    local rows = db.query([[SELECT t.uuid, t.user_uuid, t.terminal_user, t.cwd, t.agent, t.via, t.opened_at,
            t.last_input_at, t.seen_at, t.attached, t.task_uuid, ]] .. R.name_sql("u") .. [[ AS person_name,
            u.email AS person_email, term.uuid AS terminal_uuid, term.name AS terminal_name, kt.task_number,
            kt.title AS task_title, kp.uuid AS project_uuid, lk.uuid AS key_uuid,
            GREATEST(EXTRACT(EPOCH FROM (NOW() - t.last_input_at)), 0)::bigint AS idle_secs
        FROM ar_terminal_tabs t
        LEFT JOIN ar_terminals term ON term.id = t.terminal_id
        LEFT JOIN users u ON u.uuid = t.user_uuid
        LEFT JOIN kanban_tasks kt ON kt.uuid = t.task_uuid
        LEFT JOIN kanban_boards kb ON kb.id = kt.board_id
        LEFT JOIN kanban_projects kp ON kp.id = kb.project_id AND kp.namespace_id = t.namespace_id
        LEFT JOIN LATERAL (SELECT k.uuid FROM ar_terminal_keys k WHERE k.namespace_id = t.namespace_id
            AND k.terminal_id = t.terminal_id AND k.user_uuid = t.user_uuid AND k.revoked_at IS NULL
            AND k.suspended_at IS NULL AND k.expires_at > NOW() ORDER BY k.id DESC LIMIT 1) lk ON TRUE
        WHERE t.namespace_id = ? AND t.closed_at IS NULL
            AND t.seen_at > NOW() - interval ']] .. W.LIVE_SECS .. [[ seconds']] .. mine .. [[
        ORDER BY lower(COALESCE(]] .. R.name_sql("u") .. [[, t.terminal_user, '')), t.opened_at DESC, t.id DESC
        LIMIT 500]], unpack(args))
    local out = {}
    for i, t in ipairs(rows) do
        out[i] = { uuid = t.uuid, user_uuid = U.null(t.user_uuid), person_name = U.null(t.person_name),
            person_email = U.null(t.person_email), terminal_user = U.null(t.terminal_user),
            terminal_uuid = U.null(t.terminal_uuid), terminal_name = U.null(t.terminal_name),
            task_uuid = U.null(t.task_uuid), task_number = U.null(tonumber(t.task_number)),
            task_title = U.null(t.task_title), project_uuid = U.null(t.project_uuid), cwd = U.null(t.cwd),
            agent = U.null(t.agent), via = U.null(t.via), opened_at = U.null(t.opened_at),
            last_input_at = U.null(t.last_input_at), idle_secs = U.null(tonumber(t.idle_secs)),
            seen_at = U.null(t.seen_at), attached = U.null(t.attached),
            key_uuid = with_keys and U.null(t.key_uuid) or nil }
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
