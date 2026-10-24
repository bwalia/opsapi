-- Web terminals (workstation-terminal / sshweb) for task work: docs/AI_RUNNER_WEB_TERMINAL.md.
-- A workspace connects terminals (address + a sealed shared secret + the agents people may pick). A launch records a
-- row and hands the browser a signed, short-lived ticket in the terminal URL's fragment; the terminal opens the
-- folder, starts the agent and reports session_start / session_end on the webhook, signed with the same secret.
local bit = require("bit")
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")

local T = {}

T.PURPOSE = "ai_runner_terminal"   -- secret-box purpose of the shared secret
T.LINK_TTL = 900                   -- a launch link works for 15 minutes (the contract allows up to 3600)
T.MAX_PROMPT = 8000                -- bytes, so the ticket stays well inside the terminal's 32 KiB body limit
T.CLOCK_SKEW = 300                 -- webhook `ts` may be this far from now
T.DEFAULT_AGENTS = {
    { id = "claude", label = "Claude Code" },
    { id = "codex", label = "Codex" },
    { id = "cursor", label = "Cursor" },
    { id = "shell", label = "Just a terminal" },
}
-- What the terminal's config runs for each default agent (shown in the config block; the terminal decides).
T.RUN_LINES = {
    claude = 'claude "$OPSAPI_TASK_PROMPT"',
    codex = 'codex "$OPSAPI_TASK_PROMPT"',
    cursor = 'cursor-agent "$OPSAPI_TASK_PROMPT"',
}

-- ---------------------------------------------------------------------------
-- Signing
-- ---------------------------------------------------------------------------

--- Lowercase hex HMAC-SHA256.
function T.hmac_hex(secret, msg)
    local h = require("resty.openssl.hmac").new(secret, "sha256")
    if not h then error("ai_runner: hmac unavailable") end
    return require("resty.string").to_hex(h:final(msg))
end

local function equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i))) end
    return diff == 0
end
T.equal = equal

local function b64url(s)
    return (ngx.encode_base64(s, true):gsub("+", "-"):gsub("/", "_"))
end

--- The ticket the terminal verifies: base64url(compact JSON) .. "." .. hex HMAC-SHA256(secret, that payload).
function T.ticket(secret, claims)
    local payload = b64url(cjson.encode(claims))
    return payload .. "." .. T.hmac_hex(secret, payload)
end

-- ---------------------------------------------------------------------------
-- Terminals
-- ---------------------------------------------------------------------------

--- Agents as given: 1 to 20 of { id = [a-z0-9_-]{1,32}, label = 1..60 }, ids unique. 422 otherwise.
function T.agents_of(v)
    if v == nil or v == cjson.null then return nil end
    if type(v) ~= "table" or v[1] == nil or #v > 20 then U.invalid({ agents = "must be a list of 1 to 20 agents" }) end
    local out, seen = {}, {}
    for i, a in ipairs(v) do
        local id = type(a) == "table" and a.id
        local label = type(a) == "table" and type(a.label) == "string" and U.clean(a.label:match("^%s*(.-)%s*$")) or ""
        if type(id) ~= "string" or not id:match("^[a-z0-9_%-]+$") or #id > 32 then
            U.invalid({ agents = "each id is 1 to 32 of a-z, 0-9, _ and -" })
        end
        if seen[id] then U.invalid({ agents = "ids must be different" }) end
        if label == "" or #label > 60 then U.invalid({ agents = "each label is 1 to 60 characters" }) end
        seen[id] = true
        out[i] = { id = id, label = label }
    end
    return U.array(out)
end

local function agents(row)
    local list = U.json(row.agents)
    return type(list) == "table" and list[1] ~= nil and list or T.DEFAULT_AGENTS
end
T.agents = agents

function T.view(row)
    return {
        uuid = row.uuid, name = row.name, url = row.url, agents = U.array(agents(row)),
        is_active = row.is_active == true, secret_hint = U.null(row.secret_hint),
        created_by = U.null(row.created_by), created_at = row.created_at, updated_at = row.updated_at,
    }
end

function T.find(ns, uuid)
    if not U.is_uuid(uuid) then return nil end
    return U.one("SELECT * FROM ar_terminals WHERE namespace_id = ? AND uuid = ?", ns, uuid:lower())
end

function T.list(ns, active_only)
    return db.query("SELECT * FROM ar_terminals WHERE namespace_id = ?" .. (active_only and " AND is_active" or "")
        .. " ORDER BY lower(name), id LIMIT 50", ns)
end

--- A new shared secret: 64 hex characters (32 bytes from the OS CSPRNG). @return plain, sealed, hint
function T.new_secret()
    local bytes = require("resty.random").bytes(32, true)
    if not bytes then error("ai_runner: no secure random bytes available") end
    local plain = require("resty.string").to_hex(bytes)
    return plain, require("helper.secret-box").seal(plain, T.PURPOSE), "…" .. plain:sub(-4)
end

local function secret_of(row)
    local plain, err = require("helper.secret-box").open(row.secret_sealed, T.PURPOSE)
    if not plain then ngx.log(ngx.ERR, "[ai_runner] terminal secret not opened: ", tostring(err)) end
    return plain
end

-- ---------------------------------------------------------------------------
-- Launches
-- ---------------------------------------------------------------------------

--- Folders used before for a project on a terminal: the remembered one first, then the latest distinct ones.
function T.paths(ns, project_uuid, terminal_uuid, ps)
    local out, seen = {}, {}
    local function add(p)
        if type(p) == "string" and p ~= "" and not seen[p] then seen[p] = true; out[#out + 1] = p end
    end
    add(ps.default_repo_paths[terminal_uuid])
    for _, r in ipairs(db.query([[SELECT path FROM ar_terminal_sessions WHERE namespace_id = ? AND project_uuid = ?
        AND terminal_uuid = ? AND path IS NOT NULL GROUP BY path ORDER BY MAX(created_at) DESC LIMIT 5]],
        ns, project_uuid, terminal_uuid)) do add(r.path) end
    return out
end

--- What the Start dialog offers: each active terminal with its agents and folders for this task's project.
function T.offer(ns, task, ps)
    local out = {}
    for i, t in ipairs(T.list(ns, true)) do
        local paths = T.paths(ns, task.project_uuid, t.uuid, ps)
        out[i] = { uuid = t.uuid, name = t.name, url = t.url, agents = U.array(agents(t)),
            default_path = U.null(paths[1]), recent_paths = U.array(paths) }
    end
    return U.array(out)
end

local TERMINAL_OUTPUT = "commit your work on that branch, push it and open a pull request to the base branch "
    .. "(never merge). The person who opened this terminal is watching: tell them when you are done."

--- The task prompt for an agent in a terminal: the workspace template. `{{repo_path}}` is left in: the dialog shows
-- the folder being typed there, and the launch fills in the folder actually chosen (T.with_folder).
function T.prompt(ns, task)
    local defaults = R.defaults(ns, task)
    local ps = defaults.project_settings
    local snap = require("ai_runner.context").snapshot(ps, {})
    return U.clean(R.render(R.template(ns).body, task, {
        repo_path = "{{repo_path}}", base_branch = defaults.base_branch,
        target_repo = type(ps.target_repo_url) == "string" and ps.target_repo_url or nil,
        output_text = TERMINAL_OUTPUT, context_snapshot = snap,
    }), T.MAX_PROMPT)
end

function T.with_folder(prompt, path)
    return (prompt:gsub("{{%s*repo_path%s*}}", function() return path end))
end

local function remember_path(ns, project_uuid, terminal_uuid, path)
    db.query([[INSERT INTO ar_project_settings (namespace_id, project_uuid, default_repo_paths, updated_at)
        VALUES (?, ?, jsonb_build_object(?::text, ?::text), NOW())
        ON CONFLICT (namespace_id, project_uuid) DO UPDATE
        SET default_repo_paths = COALESCE(ar_project_settings.default_repo_paths, '{}'::jsonb)
            || jsonb_build_object(?::text, ?::text), updated_at = NOW()]],
        ns, project_uuid, terminal_uuid, path, terminal_uuid, path)
end

-- The task page link the terminal shows ("Back to task"): https, or http on this machine (development).
local function return_url(task)
    local u = R.task_url(task.project_uuid, task.uuid)
    if u:match("^https://") or u:match("^http://localhost[:/]") or u:match("^http://127%.0%.0%.1[:/]") then return u end
end

--- Record a launch and mint its link. inp = { terminal, path, agent (an entry of the terminal's agents), prompt,
-- by (display name), ws (workspace name) }. @return session row, launch_url
function T.launch(ns, task, user_uuid, inp)
    local secret = secret_of(inp.terminal)
    if not secret then
        U.fail(503, "This terminal's secret can't be read. Make a new one under Machines → Web terminals.")
    end
    local now = ngx.time()
    local row = db.insert("ar_terminal_sessions", {
        namespace_id = ns, task_uuid = task.uuid, project_uuid = task.project_uuid, opened_by = user_uuid,
        terminal_url = inp.terminal.url, terminal_uuid = inp.terminal.uuid, path = inp.path,
        agent = inp.agent.id, agent_label = inp.agent.label, status = "launched",
        expires_at = db.raw("NOW() + interval '" .. T.LINK_TTL .. " seconds'"),
    }, { returning = "*" })[1]
    remember_path(ns, task.project_uuid, inp.terminal.uuid, inp.path)
    local claims = {
        v = 1, id = row.uuid, iat = now, exp = now + T.LINK_TTL, task = task.uuid,
        num = tonumber(task.task_number), title = U.cut(U.clean(tostring(task.title or "")):gsub("[%c]+", " "), 200),
        path = inp.path, agent = inp.agent.id, prompt = inp.prompt, by = U.cut(inp.by or "", 120),
        ws = U.cut(inp.ws or "", 120), ["return"] = return_url(task),
    }
    return row, inp.terminal.url .. "/#launch=" .. T.ticket(secret, claims)
end

local SESSION_SQL = [[SELECT s.*, ]] .. R.name_sql("u") .. [[ AS opened_by_name, t.name AS terminal_name,
        (s.status = 'launched' AND s.expires_at < NOW()) AS link_expired
    FROM ar_terminal_sessions s
    LEFT JOIN users u ON u.uuid = s.opened_by
    LEFT JOIN ar_terminals t ON t.uuid = s.terminal_uuid]]

function T.list_for_task(ns, task_uuid)
    return db.query(SESSION_SQL .. [[ WHERE s.namespace_id = ? AND s.task_uuid = ?
        ORDER BY s.created_at DESC, s.id DESC LIMIT 50]], ns, task_uuid)
end

function T.session(ns, uuid)
    return U.one(SESSION_SQL .. " WHERE s.namespace_id = ? AND s.uuid = ?", ns, uuid)
end

function T.session_view(s)
    if not s then return nil end
    return {
        uuid = s.uuid, task_uuid = s.task_uuid, project_uuid = s.project_uuid,
        opened_by = U.null(s.opened_by), opened_by_name = U.null(s.opened_by_name),
        terminal_uuid = U.null(s.terminal_uuid), terminal_name = U.null(s.terminal_name),
        terminal_url = s.terminal_url, path = U.null(s.path), agent = U.null(s.agent),
        agent_label = U.null(s.agent_label), terminal_user = U.null(s.terminal_user),
        session_id = U.null(s.session_id), repo_url = U.null(s.repo_url),
        status = s.link_expired == true and "expired" or s.status,
        started_at = U.null(s.started_at), ended_at = U.null(s.ended_at), exit_code = U.null(s.exit_code),
        ended_reason = U.null(s.ended_reason), expires_at = U.null(s.expires_at),
        created_at = s.created_at, updated_at = s.updated_at,
    }
end

-- ---------------------------------------------------------------------------
-- Webhook (contract §4)
-- ---------------------------------------------------------------------------

local function comment(task_uuid, ns, user_uuid, text)
    local task = R.task(ns, task_uuid)
    if not task then return end
    local ok, err = pcall(function()
        require("queries.KanbanTaskQueries").addComment({ task_id = task.id, user_uuid = user_uuid, content = text })
    end)
    if not ok then ngx.log(ngx.ERR, "[ai_runner] terminal comment not posted: ", tostring(err)) end
end

local function minutes(seconds)
    local m = math.floor((tonumber(seconds) or 0) / 60 + 0.5)
    if m < 1 then return "less than a minute" end
    if m < 60 then return m .. (m == 1 and " minute" or " minutes") end
    local h = math.floor(m / 60)
    return h .. (h == 1 and " hour" or " hours") .. (m % 60 > 0 and (" " .. (m % 60) .. " min") or "")
end

--- Apply a signed webhook. @return session view | nil, http status, message
function T.webhook(raw, signature)
    local payload = require("cjson.safe").decode(raw)
    if type(payload) ~= "table" then return nil, 400, "Invalid JSON" end
    local launch = payload.launch
    if not U.is_uuid(launch) then return nil, 400, "launch (uuid) is required" end
    local s = U.one(SESSION_SQL .. " WHERE s.uuid = ?", launch:lower())
    local term = s and s.terminal_uuid and U.one("SELECT * FROM ar_terminals WHERE uuid = ? AND namespace_id = ?",
        s.terminal_uuid, s.namespace_id)
    if not term then return nil, 404, "Unknown launch" end
    local secret = secret_of(term)
    local got = type(signature) == "string" and (signature:match("^[Ss][Hh][Aa]256=(%x+)$") or "") or ""
    if not secret or not equal(got:lower(), T.hmac_hex(secret, raw)) then return nil, 401, "Invalid signature" end
    local ts = tonumber(payload.ts)
    if not ts or math.abs(ts - ngx.time()) > T.CLOCK_SKEW then return nil, 400, "ts is missing or too far from now" end
    local event = payload.event
    if event ~= "session_start" and event ~= "session_end" then return nil, 400, "Unknown event" end
    local sid = type(payload.session_id) == "string" and payload.session_id:match("^%x+$") and #payload.session_id <= 64
        and payload.session_id or nil
    local who = type(payload.user) == "string" and U.cut(U.clean(payload.user), 64) or nil
    local agent = s.agent_label or s.agent or "an agent"

    if event == "session_start" then
        local row = U.one([[UPDATE ar_terminal_sessions SET status = 'active', session_id = COALESCE(?, session_id),
            terminal_user = COALESCE(?, terminal_user), started_at = NOW(), last_event_at = NOW(), updated_at = NOW()
            WHERE id = ? AND status = 'launched' RETURNING id]], sid or db.NULL, who or db.NULL, s.id)
        if row then
            local where = s.terminal_name and (" (" .. s.terminal_name .. ")") or ""
            comment(s.task_uuid, s.namespace_id, s.opened_by, (s.opened_by_name or "Someone")
                .. " started working on this in the web terminal" .. where .. ": " .. agent .. " in "
                .. tostring(s.path or "their folder") .. ".")
        end
    else
        local code = tonumber(payload.exit_code)
        local reason = type(payload.reason) == "string" and U.cut(U.clean(payload.reason), 200) or nil
        local row = U.one([[UPDATE ar_terminal_sessions SET status = 'ended', ended_at = NOW(), last_event_at = NOW(),
            session_id = COALESCE(session_id, ?), exit_code = ?, ended_reason = ?, updated_at = NOW()
            WHERE id = ? AND status IN ('launched', 'active')
            RETURNING EXTRACT(EPOCH FROM (NOW() - COALESCE(started_at, created_at)))::int AS secs]],
            sid or db.NULL, code and math.floor(code) or db.NULL, reason or db.NULL, s.id)
        if row then
            comment(s.task_uuid, s.namespace_id, s.opened_by, "The web terminal session for this task ended after "
                .. minutes(row.secs) .. " (" .. agent .. " in " .. tostring(s.path or "their folder") .. ").")
        end
    end
    return T.session_view(T.session(s.namespace_id, s.uuid))
end

local poll_started = false
--- The pull-request poll timer (§29.7), started on first use in a worker.
function T.ensure_poll_timer()
    if poll_started then return end
    local ok = pcall(function()
        ngx.timer.every(180, function(premature)
            if premature then return end
            pcall(function() require("ai_runner.pr_poll").tick() end)
        end)
    end)
    if ok then poll_started = true end
end

return T
