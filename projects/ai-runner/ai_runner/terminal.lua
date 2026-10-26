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
T.AUTOLOGIN_TTL = 120              -- a link that signs someone in works for 2 minutes (§8)
T.STEPUP_TTL = 43200               -- an emailed-code step-up is remembered for 12 hours (§8)
T.REPORT_TTL = 7 * 86400           -- an agent may report its pull request for a week after the launch (§9)
T.AUTOLOGIN_PERMISSION = { "ai_terminal_autologin", "create" }
T.DEFAULT_AGENTS = {
    { id = "claude", label = "Claude Code" },
    { id = "claude_auto", label = "Claude Code (unattended)" },
    { id = "codex", label = "Codex" },
    { id = "cursor", label = "Cursor" },
    { id = "shell", label = "Just a terminal" },
}
-- What the terminal's config runs for each default agent (shown in the config block; the terminal decides).
T.RUN_LINES = {
    claude = 'claude "$OPSAPI_TASK_PROMPT"',
    -- Never stops to ask: acceptable only because the terminal runs under its own macOS account (W1).
    claude_auto = 'claude --dangerously-skip-permissions "$OPSAPI_TASK_PROMPT"',
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
        is_active = row.is_active == true, autologin = row.autologin == true, secret_hint = U.null(row.secret_hint),
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
-- `autologin`: this person may be signed in there by the link (the terminal allows it, and they hold
-- ai_terminal_autologin or a live key on it; who = { user_uuid, can_autologin }).
function T.offer(ns, task, ps, who)
    who = who or {}
    local out = {}
    for i, t in ipairs(T.list(ns, true)) do
        local paths = T.paths(ns, task.project_uuid, t.uuid, ps)
        local auto = t.autologin == true and (who.can_autologin == true
            or (who.user_uuid ~= nil and T.live_key(ns, who.user_uuid, t.id) ~= nil))
        out[i] = { uuid = t.uuid, name = t.name, url = t.url, agents = U.array(agents(t)),
            autologin = auto, default_path = U.null(paths[1]), recent_paths = U.array(paths) }
    end
    return U.array(out)
end

local TERMINAL_OUTPUT = "commit your work on that branch, push it and open a pull request to the base branch "
    .. "(never merge). Then report the pull request to OpsAPI so the task moves on (only if OPSAPI_REPORT_URL is "
    .. "set): curl -fsS -X POST \"$OPSAPI_REPORT_URL\" -H \"Authorization: Bearer $OPSAPI_REPORT_TOKEN\" "
    .. "-H 'Content-Type: application/json' -d '{\"pr_url\":\"<the pull request URL>\",\"note\":\"<one line on "
    .. "what you did>\"}'. The person who opened this terminal may be watching: tell them when you are done."

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

-- ---------------------------------------------------------------------------
-- Auto sign-in step-up (§8)
-- ---------------------------------------------------------------------------

--- The person's live step-up in this workspace: { verified_at (unix), expires_at (unix) } or nil. It holds only for
-- the email the code went to: if the account's email changes, the person confirms a code again.
function T.stepup(ns, user_uuid)
    return U.one([[SELECT EXTRACT(EPOCH FROM s.verified_at)::bigint AS verified_at,
        EXTRACT(EPOCH FROM s.expires_at)::bigint AS expires_at FROM ar_terminal_stepups s
        JOIN users u ON u.uuid = s.user_uuid AND lower(u.email) = s.email
        WHERE s.namespace_id = ? AND s.user_uuid = ? AND s.expires_at > NOW()]], ns, user_uuid)
end

local function account(user_uuid)
    return U.one("SELECT id, uuid, email, first_name FROM users WHERE uuid = ?", user_uuid)
end

--- Email the person a sign-in code for the step-up. @return true | nil, http status, message
function T.send_stepup_code(user_uuid)
    local u = account(user_uuid)
    if not u or not u.email or u.email == "" then return nil, 422, "Your account has no email address" end
    local ok, err = require("helper.otp").sendToEmail({ id = u.id, email = u.email, first_name = u.first_name },
        { app_name = "OpsAPI web terminal" })
    if err == "rate_limited" then return nil, 429, "Too many codes requested. Try again in a few minutes." end
    if not ok then return nil, 502, "The code could not be sent. Try again." end
    return true
end

--- Check the emailed code and remember the step-up. @return stepup | nil, http status, message
function T.verify_stepup(ns, user_uuid, code)
    local u = account(user_uuid)
    if not u then return nil, 404, "User not found" end
    local ok, err = require("helper.otp").verify(u.id, tostring(code or ""))
    if not ok then return nil, 401, err or "Invalid code" end
    db.query([[INSERT INTO ar_terminal_stepups (namespace_id, user_uuid, email, verified_at, expires_at)
        VALUES (?, ?, lower(?), NOW(), NOW() + interval ']] .. T.STEPUP_TTL .. [[ seconds')
        ON CONFLICT (namespace_id, user_uuid) DO UPDATE
        SET email = EXCLUDED.email, verified_at = EXCLUDED.verified_at, expires_at = EXCLUDED.expires_at]],
        ns, user_uuid, u.email)
    return T.stepup(ns, user_uuid)
end

function T.forget_stepup(ns, user_uuid)
    db.query("DELETE FROM ar_terminal_stepups WHERE namespace_id = ? AND user_uuid = ?", ns, user_uuid)
end

-- ---------------------------------------------------------------------------
-- Keys issued by managers (§10)
-- ---------------------------------------------------------------------------

T.KEY_TTL = 90 * 86400             -- a key works for 90 days, then the manager issues a new one
T.KEY_REMIND = 14 * 86400          -- the manager who issued it is reminded this long before it expires

-- A key counts only while it isn't blocked or expired and its person is an active user and member of the workspace:
-- removing someone from the workspace, or deactivating them, blocks their keys with nothing else to do.
local LIVE_KEY = [[k.revoked_at IS NULL AND k.expires_at > NOW() AND EXISTS (SELECT 1 FROM users ku
    JOIN namespace_members km ON km.user_id = ku.id AND km.namespace_id = k.namespace_id
    WHERE ku.uuid = k.user_uuid AND ku.active = true AND km.status = 'active')]]

--- An OpenSSH ed25519 public key line -> "ssh-ed25519 <base64>" (no comment) and its SHA256 fingerprint, or nil.
function T.parse_public_key(line)
    if type(line) ~= "string" or #line > 1000 then return nil end
    local b64 = line:match("^%s*ssh%-ed25519%s+([%w+/]+=*)[^\r\n]*$")
    local blob = b64 and ngx.decode_base64(b64)
    -- string "ssh-ed25519", string <32-byte key>
    if not blob or #blob ~= 51 or blob:sub(1, 19) ~= "\0\0\0\11ssh-ed25519\0\0\0\32" then return nil end
    local h = require("resty.sha256"):new()
    h:update(blob)
    return "ssh-ed25519 " .. b64, "SHA256:" .. ngx.encode_base64(h:final()):gsub("=+$", "")
end

-- Keys of people who left the workspace (or were deactivated) are blocked for good, so coming back later doesn't
-- bring an old key back: a manager issues a new one.
local function retire_leavers(terminal_id)
    db.query([[UPDATE ar_terminal_keys k SET revoked_at = NOW(), revoked_reason = 'left'
        WHERE k.terminal_id = ? AND k.revoked_at IS NULL AND NOT EXISTS (SELECT 1 FROM users ku
            JOIN namespace_members km ON km.user_id = ku.id AND km.namespace_id = k.namespace_id
            WHERE ku.uuid = k.user_uuid AND ku.active = true AND km.status = 'active')]], terminal_id)
end

--- The person's live key on a terminal (any terminal of the workspace when terminal_id is nil), or nil.
function T.live_key(ns, user_uuid, terminal_id)
    return U.one("SELECT k.* FROM ar_terminal_keys k WHERE k.namespace_id = ? AND k.user_uuid = ?"
        .. (terminal_id and " AND k.terminal_id = " .. tonumber(terminal_id) or "") .. " AND " .. LIVE_KEY
        .. " LIMIT 1", ns, user_uuid)
end

--- The terminal user a person signs in as: the one they had on this terminal before, else their email's local part
-- (a terminal user name: [a-z_][a-z0-9_.-]*), numbered when someone else already had it. Names are never reused for
-- another person, so a new starter can't inherit a leaver's saved tabs.
local function terminal_user_for(terminal_id, user_uuid, email)
    local prev = U.one([[SELECT terminal_user FROM ar_terminal_keys WHERE terminal_id = ? AND user_uuid = ?
        ORDER BY id DESC LIMIT 1]], terminal_id, user_uuid)
    if prev then return prev.terminal_user end
    local base = (tostring(email or ""):match("^([^@]+)") or ""):lower():gsub("[^a-z0-9_.-]", "."):gsub("^[^a-z_]+", "")
    base = base ~= "" and base:sub(1, 28) or "user"
    for i = 1, 99 do
        local name = i == 1 and base or (base .. i)
        if not U.one("SELECT 1 AS x FROM ar_terminal_keys WHERE terminal_id = ? AND terminal_user = ?", terminal_id,
            name) then return name end
    end
end

--- Issue a person a key for a terminal. The manager's browser made the key pair; only the public half comes here.
-- Their earlier key on this terminal is blocked. @return key row | nil, http status, message
function T.issue_key(ns, term, user_uuid, public_key, by)
    local person = U.one([[SELECT u.uuid, u.email FROM users u JOIN namespace_members m ON m.user_id = u.id
        WHERE m.namespace_id = ? AND u.uuid = ? AND m.status = 'active' AND u.active = true]], ns, user_uuid)
    if not person then return nil, 422, "Pick someone who is an active member of this workspace" end
    local line, fp = T.parse_public_key(public_key)
    if not line then return nil, 422, "public_key must be an ssh-ed25519 public key" end
    if U.one("SELECT 1 AS x FROM ar_terminal_keys WHERE terminal_id = ? AND fingerprint = ?", term.id, fp) then
        return nil, 409, "This key was used before. Make a new one."
    end
    local name = terminal_user_for(term.id, person.uuid, person.email)
    if not name then return nil, 409, "No free terminal user name for this person" end
    db.query([[UPDATE ar_terminal_keys SET revoked_at = NOW(), revoked_by = ?, revoked_reason = 'replaced'
        WHERE terminal_id = ? AND user_uuid = ? AND revoked_at IS NULL]], by, term.id, person.uuid)
    return U.one([[INSERT INTO ar_terminal_keys (namespace_id, terminal_id, user_uuid, terminal_user, public_key,
        fingerprint, created_by, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, NOW() + interval ']] .. T.KEY_TTL
        .. [[ seconds') RETURNING *]], ns, term.id, person.uuid, name, line, fp, by)
end

--- Block a key now (the terminal drops it at its next fetch and closes its sessions). @return row | nil
function T.block_key(ns, term, key_uuid, by)
    if not U.is_uuid(key_uuid) then return nil end
    return U.one([[UPDATE ar_terminal_keys SET revoked_at = NOW(), revoked_by = ?, revoked_reason = 'blocked'
        WHERE namespace_id = ? AND terminal_id = ? AND uuid = ? AND revoked_at IS NULL RETURNING *]],
        by, ns, term.id, key_uuid:lower())
end

--- A terminal's keys for its managers, newest live ones first: who, terminal user, fingerprint, issued, expires, and
-- status active | expired | blocked | replaced | left (left the workspace or was deactivated).
function T.keys(ns, term)
    retire_leavers(term.id)
    local rows = db.query([[SELECT k.uuid, k.user_uuid, k.terminal_user, k.fingerprint, k.created_at, k.expires_at,
            k.revoked_at, k.revoked_reason, ]] .. R.name_sql("u") .. [[ AS person_name, u.email AS person_email,
            ]] .. R.name_sql("cb") .. [[ AS created_by_name, ]] .. R.name_sql("rb") .. [[ AS revoked_by_name,
            (]] .. LIVE_KEY .. [[) AS live, (k.expires_at <= NOW()) AS expired
        FROM ar_terminal_keys k LEFT JOIN users u ON u.uuid = k.user_uuid
        LEFT JOIN users cb ON cb.uuid = k.created_by LEFT JOIN users rb ON rb.uuid = k.revoked_by
        WHERE k.namespace_id = ? AND k.terminal_id = ?
        ORDER BY (k.revoked_at IS NULL) DESC, k.created_at DESC LIMIT 200]], ns, term.id)
    local out = {}
    for i, k in ipairs(rows) do
        local status = k.live and "active" or k.revoked_reason == "replaced" and "replaced"
            or k.revoked_reason == "left" and "left" or k.revoked_reason == "blocked" and "blocked" or "expired"
        out[i] = { uuid = k.uuid, user_uuid = k.user_uuid, person_name = U.null(k.person_name),
            person_email = U.null(k.person_email), terminal_user = k.terminal_user, fingerprint = k.fingerprint,
            created_at = k.created_at, created_by_name = U.null(k.created_by_name), expires_at = k.expires_at,
            revoked_at = U.null(k.revoked_at), revoked_by_name = U.null(k.revoked_by_name), status = status }
    end
    return U.array(out)
end

--- Active members a key can be issued to.
function T.key_candidates(ns)
    return U.array(db.query([[SELECT u.uuid, ]] .. R.name_sql("u") .. [[ AS name, u.email FROM namespace_members m
        JOIN users u ON u.id = m.user_id WHERE m.namespace_id = ? AND m.status = 'active' AND u.active = true
        ORDER BY lower(]] .. R.name_sql("u") .. [[) LIMIT 500]], ns))
end

-- Tell whoever issued a key that it expires soon (once per key; runs when the terminal fetches its keys).
local function remind_expiring(term)
    local due = db.query([[UPDATE ar_terminal_keys k SET reminded_at = NOW() WHERE k.terminal_id = ?
        AND k.reminded_at IS NULL AND k.created_by IS NOT NULL AND k.expires_at < NOW() + interval ']] .. T.KEY_REMIND
        .. [[ seconds' AND ]] .. LIVE_KEY .. [[ RETURNING k.namespace_id, k.user_uuid, k.created_by,
        to_char(k.expires_at, 'DD Mon YYYY') AS expires_on]], term.id)
    for _, k in ipairs(due) do
        local who = U.one("SELECT " .. R.name_sql("u") .. " AS name FROM users u WHERE u.uuid = ?", k.user_uuid)
        pcall(require("queries.KanbanNotificationQueries").create, {
            namespace_id = k.namespace_id, recipient_user_uuid = k.created_by, type = "general", priority = "normal",
            title = "A web terminal key expires soon",
            message = ((who and who.name) or "Someone") .. "'s key for " .. tostring(term.name) .. " stops working on "
                .. k.expires_on .. ". Issue a new one under Machines → Web terminals → People.",
            action_url = "/dashboard/ai-runner/machines",
        })
    end
end

--- What the terminal fetches (§10): its live keys, signed so it can trust them. The request is signed too:
-- X-Opsapi-Signature: sha256=hex(HMAC(secret, "keys\n<terminal uuid>\n<X-Opsapi-Timestamp>")).
-- A terminal switched off in OpsAPI gets an empty list. @return body, signature hex | nil, http status, message
function T.keys_for_terminal(terminal_uuid, ts, signature)
    local term = U.is_uuid(terminal_uuid) and U.one("SELECT * FROM ar_terminals WHERE uuid = ?", terminal_uuid:lower())
    if not term then return nil, 401, "Unauthorized" end
    local secret = secret_of(term)
    ts = type(ts) == "string" and ts:match("^%d+$")
    local got = type(signature) == "string" and (signature:match("^[Ss][Hh][Aa]256=(%x+)$") or "") or ""
    if not secret or not ts or not equal(got:lower(), T.hmac_hex(secret, "keys\n" .. term.uuid .. "\n" .. ts)) then
        return nil, 401, "Unauthorized"
    end
    if math.abs(tonumber(ts) - ngx.time()) > T.CLOCK_SKEW then return nil, 400, "Timestamp too far from now" end
    local keys = {}
    retire_leavers(term.id)
    if term.is_active then
        pcall(remind_expiring, term)
        for i, k in ipairs(db.query([[SELECT k.terminal_user AS user, k.public_key,
                EXTRACT(EPOCH FROM k.expires_at)::bigint AS expires_unix, lower(pu.email) AS email
            FROM ar_terminal_keys k JOIN users pu ON pu.uuid = k.user_uuid
            WHERE k.terminal_id = ? AND ]] .. LIVE_KEY .. " ORDER BY k.id", term.id)) do
            keys[i] = { user = k.user, public_key = k.public_key, expires_unix = tonumber(k.expires_unix),
                email = U.null(k.email) }
        end
    end
    local body = cjson.encode({ terminal = term.uuid, generated_at = ngx.time(), keys = U.array(keys) })
    return body, T.hmac_hex(secret, body)
end

-- ---------------------------------------------------------------------------
-- Launch
-- ---------------------------------------------------------------------------

local function sha256_hex(s)
    local h = require("resty.sha256"):new()
    h:update(s)
    return require("resty.string").to_hex(h:final())
end
T.sha256_hex = sha256_hex

--- A report token: 32 random bytes as base64url (43 characters). @return plain, sha256 hex
local function report_token()
    local bytes = require("resty.random").bytes(32, true)
    if not bytes then error("ai_runner: no secure random bytes available") end
    local plain = b64url(bytes)
    return plain, sha256_hex(plain)
end

--- Record a launch and mint its link. inp = { terminal, path, agent (an entry of the terminal's agents), prompt,
-- by (display name), ws (workspace name), login ({ email, stepup } to sign the person in, §8),
-- report_url (§9; nil: the agent can't report) }. @return session row, launch_url
function T.launch(ns, task, user_uuid, inp)
    local secret = secret_of(inp.terminal)
    if not secret then
        U.fail(503, "This terminal's secret can't be read. Make a new one under Machines → Web terminals.")
    end
    local now = ngx.time()
    local ttl = inp.login and T.AUTOLOGIN_TTL or T.LINK_TTL
    local token, token_hash
    if inp.report_url then token, token_hash = report_token() end
    local row = db.insert("ar_terminal_sessions", {
        namespace_id = ns, task_uuid = task.uuid, project_uuid = task.project_uuid, opened_by = user_uuid,
        terminal_url = inp.terminal.url, terminal_uuid = inp.terminal.uuid, path = inp.path,
        agent = inp.agent.id, agent_label = inp.agent.label, status = "launched",
        autologin = inp.login ~= nil, report_token_hash = token_hash or db.NULL,
        expires_at = db.raw("NOW() + interval '" .. ttl .. " seconds'"),
    }, { returning = "*" })[1]
    remember_path(ns, task.project_uuid, inp.terminal.uuid, inp.path)
    local claims = {
        v = 1, id = row.uuid, iat = now, exp = now + ttl, task = task.uuid,
        num = tonumber(task.task_number), title = U.cut(U.clean(tostring(task.title or "")):gsub("[%c]+", " "), 200),
        path = inp.path, agent = inp.agent.id, prompt = inp.prompt, by = U.cut(inp.by or "", 120),
        ws = U.cut(inp.ws or "", 120), ["return"] = return_url(task),
        login = inp.login and { email = inp.login.email, user = user_uuid, stepup = inp.login.stepup } or nil,
        report = token and { url = inp.report_url, token = token } or nil,
    }
    return row, inp.terminal.url .. "/#launch=" .. T.ticket(secret, claims)
end

--- Where agents report (§9): OPSAPI_PUBLIC_URL, else the address this request came in on (its Host; the scheme may
-- come from X-Forwarded-Proto). https only (or http on this machine, for development). @return url | nil
function T.report_url()
    local base = (os.getenv("OPSAPI_PUBLIC_URL") or ""):gsub("/+$", "")
    if base == "" then
        local h = ngx.req.get_headers()
        local proto = h["x-forwarded-proto"]
        if type(proto) == "table" then proto = proto[1] end
        proto = type(proto) == "string" and proto:match("^%s*(https?)") or ngx.var.scheme
        local host = ngx.var.http_host or ngx.var.host
        if type(host) ~= "string" or not host:match("^[%w%.%-]+:?%d*$") then return nil end
        base = proto .. "://" .. host
    end
    if not (base:match("^https://") or base:match("^http://localhost[:/]?") or base:match("^http://127%.0%.0%.1[:/]?"))
    then return nil end
    return base .. "/api/v2/ai-runner/public/terminal/report"
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
        session_id = U.null(s.session_id), repo_url = U.null(s.repo_url), autologin = s.autologin == true,
        reported_at = U.null(s.reported_at),
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
                .. tostring(s.path or "their folder")
                .. (s.autologin == true and " (signed in to the terminal by OpsAPI)." or "."))
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

-- ---------------------------------------------------------------------------
-- Agent reports (§9)
-- ---------------------------------------------------------------------------

--- owner/repo and the number of a GitHub pull request URL (or GitLab merge request: no repo, no number polled).
local function pr_parts(url)
    local owner, repo, num = url:match("^https://github%.com/([%w%.%-_]+)/([%w%.%-_]+)/pull/(%d+)/?$")
    if owner then return owner .. "/" .. repo, tonumber(num) end
    if url:match("^https://[%w%.%-]+/.+/%-/merge_requests/%d+/?$") then return "", nil end
end

--- Apply an agent's report: body = { pr_url?, note? }. @return { task_uuid, pr? } | nil, http status, message
function T.report(token, body)
    if type(token) ~= "string" or not token:match("^[%w_%-]+$") or #token < 32 or #token > 128 then
        return nil, 401, "Unauthorized"
    end
    local s = U.one([[SELECT * FROM ar_terminal_sessions WHERE report_token_hash = ?
        AND created_at > NOW() - interval ']] .. T.REPORT_TTL .. [[ seconds']], sha256_hex(token))
    if not s then return nil, 401, "Unauthorized" end
    if type(body) ~= "table" then return nil, 400, "Invalid JSON" end
    local pr_url = body.pr_url
    if pr_url ~= nil and pr_url ~= cjson.null then
        if type(pr_url) ~= "string" or #pr_url > 500 or not pr_parts(pr_url) then
            return nil, 422, "pr_url must be a GitHub pull request (or GitLab merge request) URL"
        end
        pr_url = pr_url:gsub("/$", "")
    else
        pr_url = nil
    end
    local note = type(body.note) == "string" and U.clean(body.note, 1000) or nil
    if note == "" then note = nil end
    if not pr_url and not note then return nil, 422, "Send pr_url, note or both" end

    local who = s.agent_label or s.agent or "The agent"
    local out = { task_uuid = s.task_uuid }
    if pr_url then
        local repo, num = pr_parts(pr_url)
        local row = U.one([[INSERT INTO ar_task_prs (namespace_id, task_uuid, project_uuid, repo, pr_url, pr_number, state)
            VALUES (?, ?, ?, ?, ?, ?, 'open')
            ON CONFLICT (namespace_id, task_uuid, pr_url) WHERE run_uuid IS NULL DO NOTHING RETURNING *]],
            s.namespace_id, s.task_uuid, s.project_uuid, repo, pr_url, num or db.NULL)
        if row then
            comment(s.task_uuid, s.namespace_id, s.opened_by, who .. " opened a pull request from the web terminal: "
                .. pr_url .. (note and ("\n" .. note) or "")
                .. "\nManagers: approve or request changes on the task's AI work panel.")
            R.automate_task(s.namespace_id, s.task_uuid, "on_pr_open")
        else
            row = U.one([[SELECT * FROM ar_task_prs WHERE namespace_id = ? AND task_uuid = ? AND pr_url = ?
                AND run_uuid IS NULL]], s.namespace_id, s.task_uuid, pr_url)
            if note then comment(s.task_uuid, s.namespace_id, s.opened_by, who .. ": " .. note) end
        end
        out.pr = row and require("ai_runner.vault_pr").view(row) or nil
    else
        comment(s.task_uuid, s.namespace_id, s.opened_by, who .. ": " .. note)
    end
    db.query("UPDATE ar_terminal_sessions SET reported_at = NOW(), updated_at = NOW() WHERE id = ?", s.id)
    return out
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
