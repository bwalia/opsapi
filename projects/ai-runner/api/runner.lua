-- Runner API (docs/AI_RUNNER.md §22.2, §23.2). No user session: under public/, authenticated by the runner token
-- ("Authorization: Bearer oprn_<48 hex>", stored as a SHA-256 hash and bound to one workspace).
--   POST /public/runner/heartbeat              capabilities, repos, inventory -> runs to cancel; renews leases
--   POST /public/runner/claim                  long-poll (wait_s <= 25) -> 200 { run } (+ run_token) or 204
--   POST /public/runner/runs/:uuid/status      { seq, status, question?, ... } compare-and-set; stale seq ignored
--   POST /public/runner/runs/:uuid/events      { events: [{ seq, type, text?, data? }] } idempotent on (run, seq)
--   POST /public/runner/runs/:uuid/permissions              ask a person; idempotent on request_id
--   POST /public/runner/runs/:uuid/permissions/:req/wait    long-poll for the decision
--   POST /public/runner/runs/:uuid/turns                    an agent turn + its usage; idempotent on turn
--   POST /public/runner/runs/:uuid/turns/next               long-poll for people's messages
-- Revoked token -> 401; plugin off in the workspace -> 404; paused runner: heartbeat works, claim gives 204.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson")
local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")

local MAX_EVENTS, MAX_EVENT_TEXT, MAX_EVENT_DATA = 200, 4096, 8192
local MAX_INPUT, MAX_TURN_TEXT, INT_MAX = 8192, 8192, 2147483647
local EVENT_TYPES = { log = true, progress = true, tool = true, usage = true }
local BRANCH = "^[%w%._/%-]+$"

-- Lookup by hash: the comparison never touches the secret itself, so its timing tells nothing about it.
local function auth()
    local h = ngx.req.get_headers()["authorization"]
    if type(h) == "table" then h = h[1] end
    local raw = type(h) == "string" and h:match("^%s*[Bb]earer%s+(oprn_%x+)%s*$")
    if not raw or #raw ~= 53 then U.fail(401, "Unauthorized") end
    local r = U.one("SELECT " .. R.RUNNER_COLS .. [[, n.status AS ns_status FROM ar_runners r
        JOIN namespaces n ON n.id = r.namespace_id WHERE r.token_hash = ?]], U.sha256(raw))
    if not r or r.status == "revoked" then U.fail(401, "Unauthorized") end
    R.require_plugin(r.ns_status, r.namespace_id)
    return r
end

local function body(self)
    local b, err = sdk.body(self)
    if not b then U.fail(400, err) end
    return b
end

local function str(v, max)
    if type(v) == "string" then return U.clean(v, max) end
end

-- Redact before cutting, so a cut never leaves half a key in clear.
local function safe_text(v, max)
    if type(v) == "string" then return U.clean(U.redact(U.clean(v)), max) end
end

-- A run this runner claimed: 404 when it isn't its own or not claimed yet, 409 once it ended.
local function claimed_run(runner, uuid)
    local run = U.is_uuid(uuid) and U.one([[SELECT * FROM ar_runs WHERE uuid = ? AND namespace_id = ?
        AND runner_uuid = ?]], uuid, runner.namespace_id, runner.uuid)
    if not run or not (R.IS_ACTIVE[run.status] or R.TERMINAL[run.status]) then U.fail(404, "Run not found") end
    if R.TERMINAL[run.status] then U.fail(409, "This run has ended (" .. run.status .. ")", { status = run.status }) end
    return run
end

-- Has the run been cancelled (or ended) under the runner? Long polls return early on it.
local function stopping(run)
    local st = U.one("SELECT status FROM ar_runs WHERE id = ?", run.id).status
    return st == "cancelling" or R.TERMINAL[st] == true
end

-- What a person sees for a permission request: the command, the file, the URL; else the input as JSON.
local function input_summary(input)
    local s = input.command or input.file_path or input.notebook_path or input.url or input.path or input.pattern
    if type(s) ~= "string" then
        local ok, enc = pcall(cjson.encode, input)
        s = ok and enc or ""
    end
    return safe_text(s, 2000)
end

local function num(v)
    v = tonumber(v)
    if v and v == v and v ~= math.huge and v ~= -math.huge then return v end
end

-- The profile's plan usage window, as the agent reported it (Claude's rate_limit_event), for the Runners page.
local function rate_limit(v)
    if type(v) ~= "table" then return nil end
    return { status = str(v.status, 40) or cjson.null, type = str(v.type, 40) or cjson.null,
        resets_at = num(v.resets_at) or str(v.resets_at, 64) or cjson.null,
        utilization = num(v.utilization) or cjson.null }
end

local function capabilities(c)
    if type(c) ~= "table" then return nil end
    local profiles = {}
    for _, p in ipairs(type(c.profiles) == "table" and c.profiles or {}) do
        local key = type(p) == "table" and str(p.key, 80)
        if key and key ~= "" and #profiles < 50 then
            local models = {}
            for _, m in ipairs(type(p.models) == "table" and p.models or {}) do
                if type(m) == "string" and #models < 50 then models[#models + 1] = U.clean(m, 120) end
            end
            profiles[#profiles + 1] = { key = key, label = str(p.label, 120) or key, models = U.array(models),
                approval = (p.approval == "bridge" or p.approval == "unsupported") and p.approval or "none",
                rate_limit = rate_limit(p.rate_limit) }
        end
    end
    local n = tonumber(c.max_concurrency)
    n = n and n == n and math.max(1, math.min(64, math.floor(n))) or 1
    return { max_concurrency = n, profiles = U.array(profiles) }
end

local function repos(list)
    if type(list) ~= "table" then return nil end
    local out, seen = {}, {}
    for _, r in ipairs(list) do
        local p = type(r) == "table" and U.path(str(r.path))
        if p and not seen[p] and #out < 1000 then
            seen[p] = true
            out[#out + 1] = { path = p, remote = str(r.remote, 1024), branch = str(r.branch, 255),
                dirty = r.dirty == true }
        end
    end
    return U.array(out)
end

-- Up to 20 string labels per session (opsapi_run, opsapi_task, ...), redacted.
local function labels(t)
    if type(t) ~= "table" then return nil end
    local out, n = {}, 0
    for k, v in pairs(t) do
        if type(k) == "string" and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") and n < 20 then
            out[U.clean(k, 64)] = type(v) == "string" and U.redact(U.clean(v, 200)) or v
            n = n + 1
        end
    end
    return n > 0 and out or nil
end

local function inventory(list)
    local out, seen = {}, {}
    for _, s in ipairs(type(list) == "table" and list or {}) do
        local key = type(s) == "table" and str(s.key, 255)
        if key and key ~= "" and not seen[key] and #out < 500 then
            seen[key] = true
            local l = labels(s.labels)
            -- A managed session names its run: the opsapi_run label, or the Claude session id (= the run uuid).
            local run = l and l.opsapi_run
            if not U.is_uuid(run) then run = U.is_uuid(s.session_id) and s.session_id or nil end
            out[#out + 1] = { key = key, tool = str(s.tool, 40), status = str(s.status, 40),
                cwd = U.path(str(s.cwd)), branch = str(s.branch, 255), session_id = str(s.session_id, 255),
                started_at = str(s.started_at, 64), updated_at = str(s.updated_at, 64),
                prompt_preview = U.redact(str(s.prompt_preview, 200)), labels = l, run = run }
        end
    end
    return out
end

local STATUS_RULES = {
    seq = { type = "integer", required = true, min = 1 },
    status = { required = true, enum = { "starting", "running", "waiting_permission", "needs_input", "succeeded",
        "failed", "cancelled" } },
    question = { type = "text" },
    pid = { type = "integer", min = 0 },
    agent_session_id = { max = 255 },
    exit_code = { type = "integer" },
    error_category = { max = 40 },
    error = { type = "text" },
    summary = { type = "text" },
    commit_sha = { min = 7, max = 64 },
    pr_url = { type = "url", max = 1000 },
    work_branch = { max = 255 },
    previous_branch = { max = 255 },
}

return function(app)
    app:post("/public/runner/heartbeat", sdk.handler({ namespace = false }, U.guard(function(self)
        local runner = auth()
        local b = body(self)
        local set = { last_heartbeat_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }
        for k, max in pairs({ version = 100, host = 255, os = 100 }) do
            local v = str(b[k], max)
            if v then set[k] = v end
        end
        local caps, rp = capabilities(b.capabilities), repos(b.repos)
        if caps then set.capabilities = cjson.encode(caps) end
        if rp then set.repos = cjson.encode(rp) end
        local inv = b.inventory ~= nil and inventory(b.inventory) or nil

        U.tx(function()
            -- Inline literals only (no "?" placeholders: lapis would also replace any "?" inside them).
            db.query("UPDATE ar_runners SET " .. db.encode_assigns(set) .. " WHERE id = "
                .. db.escape_literal(runner.id))
            db.query("UPDATE ar_runs SET heartbeat_at = NOW(), lease_until = NOW() + interval '" .. R.LEASE_S
                .. " seconds' WHERE runner_uuid = ? AND namespace_id = ? AND status IN " .. R.ACTIVE_SQL,
                runner.uuid, runner.namespace_id)
            if inv then
                db.query("DELETE FROM ar_sessions WHERE runner_uuid = ? AND namespace_id = ?", runner.uuid,
                    runner.namespace_id)
                if #inv > 0 then
                    db.query([[
                        INSERT INTO ar_sessions (runner_uuid, namespace_id, session_key, tool, status, cwd, branch,
                            session_id, started_at, updated_at, prompt_preview, labels, run_uuid, managed, seen_at)
                        SELECT ?, ?, x.key, x.tool, x.status, x.cwd, x.branch, x.session_id, ai_runner_ts(x.started_at),
                            ai_runner_ts(x.updated_at), x.prompt_preview, COALESCE(x.labels, '{}'::jsonb), r.uuid,
                            r.uuid IS NOT NULL, NOW()
                        FROM jsonb_to_recordset(?::jsonb) AS x(key text, tool text, status text, cwd text, branch text,
                            session_id text, started_at text, updated_at text, prompt_preview text, labels jsonb,
                            run uuid)
                        LEFT JOIN ar_runs r ON r.uuid = x.run AND r.runner_uuid = ? AND r.namespace_id = ?
                        ON CONFLICT (runner_uuid, session_key) DO NOTHING
                    ]], runner.uuid, runner.namespace_id, cjson.encode(inv), runner.uuid, runner.namespace_id)
                end
            end
        end)

        local cancel = {}
        for _, r in ipairs(db.query("SELECT uuid FROM ar_runs WHERE runner_uuid = ? AND namespace_id = ? AND "
            .. "status = 'cancelling' ORDER BY id", runner.uuid, runner.namespace_id)) do
            cancel[#cancel + 1] = r.uuid
        end
        return sdk.ok({ runner_uuid = runner.uuid, status = runner.status, cancel = U.array(cancel),
            config = { heartbeat_s = R.HEARTBEAT_S, claim_wait_s = R.CLAIM_WAIT_S, lease_s = R.LEASE_S } })
    end)))

    app:post("/public/runner/claim", sdk.handler({ namespace = false }, U.guard(function(self)
        local runner = auth()
        local run = R.claim(runner, R.wait_s(body(self).wait_s))
        if not run then return { status = 204, layout = false, "" } end
        return sdk.ok({ run = R.payload(run) })
    end)))

    app:post("/public/runner/runs/:uuid/status", sdk.handler({ namespace = false }, U.guard(function(self)
        local runner = auth()
        if not U.is_uuid(self.params.uuid) then U.fail(404, "Run not found") end
        local d, errors = sdk.validate(body(self), STATUS_RULES)
        if not d then U.invalid(errors) end
        for k, v in pairs(d) do
            if v == db.NULL then d[k] = nil elseif type(v) == "string" then d[k] = U.clean(v) end
        end
        if d.commit_sha and not d.commit_sha:match("^%x+$") then U.invalid({ commit_sha = "must be a git sha" }) end
        for _, k in ipairs({ "work_branch", "previous_branch" }) do
            if d[k] and not d[k]:match(BRANCH) then U.invalid({ [k] = "must be a branch name" }) end
        end
        if d.error then d.error = U.clean(U.redact(d.error), 2000) end
        if d.summary then d.summary = U.clean(U.redact(d.summary), 8000) end
        if d.question then d.question = U.clean(U.redact(d.question), 4000) end
        return sdk.ok(R.report(runner, self.params.uuid, d))
    end)))

    app:post("/public/runner/runs/:uuid/events", sdk.handler({ namespace = false }, U.guard(function(self)
        local runner = auth()
        local b = body(self)
        local run = U.is_uuid(self.params.uuid) and U.one([[SELECT uuid, status FROM ar_runs
            WHERE uuid = ? AND namespace_id = ? AND runner_uuid = ?]], self.params.uuid, runner.namespace_id,
            runner.uuid)
        if not run or run.status == "queued" or run.status == "pending_approval" then U.fail(404, "Run not found") end
        local list = b.events
        if type(list) ~= "table" or (next(list) ~= nil and list[1] == nil) then
            U.invalid({ events = "must be a list" })
        end
        if #list > MAX_EVENTS then U.invalid({ events = "at most " .. MAX_EVENTS .. " per call" }) end
        local rows = {}
        for i, e in ipairs(list) do
            local at = "events[" .. i .. "]"
            local seq = type(e) == "table" and tonumber(e.seq)
            if not seq or seq ~= math.floor(seq) or seq < 0 or seq > 2147483647 then
                U.invalid({ [at .. ".seq"] = "must be a whole number" })
            end
            if not EVENT_TYPES[e.type] then U.invalid({ [at .. ".type"] = "must be log, progress, tool or usage" }) end
            if e.text ~= nil and e.text ~= cjson.null and type(e.text) ~= "string" then
                U.invalid({ [at .. ".text"] = "must be a string" })
            end
            local data
            if type(e.data) == "table" then
                data = U.redact_value(e.data)
                if #cjson.encode(data) > MAX_EVENT_DATA then data = { truncated = true } end
            end
            rows[#rows + 1] = { seq = seq, type = e.type, data = data, text = safe_text(e.text, MAX_EVENT_TEXT) }
        end
        if #rows == 0 then return sdk.ok({ stored = 0 }) end
        -- ponytail: no cap on events per run yet; add one (or MinIO chunks, §5) when long runs make the table heavy.
        local res = db.query([[
            INSERT INTO ar_run_events (run_uuid, namespace_id, seq, type, text, data)
            SELECT ?, ?, x.seq, x.type, x.text, x.data
            FROM jsonb_to_recordset(?::jsonb) AS x(seq int, type text, text text, data jsonb)
            ON CONFLICT (run_uuid, seq) DO NOTHING
        ]], run.uuid, runner.namespace_id, cjson.encode(rows))
        return sdk.ok({ stored = res.affected_rows or 0 })
    end)))

    -- The permission bridge (§23.2): the runner is Claude's permission host and asks a person through OpsAPI.
    app:post("/public/runner/runs/:uuid/permissions", sdk.handler({ namespace = false }, U.guard(function(self)
        local runner = auth()
        local run = claimed_run(runner, self.params.uuid)
        local b = body(self)
        local d, errors = sdk.validate(b, { request_id = { required = true, max = 255 },
            tool = { required = true, max = 120 }, tool_use_id = { max = 255 }, description = { type = "text" },
            blocked_path = { type = "text", max = 4096 }, rule_key = { max = 255 } })
        if not d then U.invalid(errors) end
        if type(b.input) ~= "table" or (next(b.input) ~= nil and b.input[1] ~= nil) then
            U.invalid({ input = "must be an object" })
        end
        for k, v in pairs(d) do if v == db.NULL or v == "" then d[k] = nil end end
        local input = U.redact_value(b.input)
        local ok, enc = pcall(cjson.encode, input)
        if not ok or #enc > MAX_INPUT then enc = cjson.encode({ truncated = true }) end

        local function existing()
            return U.one("SELECT uuid, status, reason FROM ar_run_requests WHERE run_uuid = ? AND request_id = ?",
                run.uuid, d.request_id)
        end
        local found = existing()
        if found then
            return sdk.ok({ request = { uuid = found.uuid, status = found.status, reason = U.null(found.reason) } })
        end
        -- "Allow for this run" covers later requests of the same kind (same rule_key) at once.
        local earlier = d.rule_key and U.one([[SELECT decided_by FROM ar_run_requests WHERE run_uuid = ?
            AND rule_key = ? AND status = 'allowed' AND remember ORDER BY decided_at DESC LIMIT 1]], run.uuid,
            d.rule_key)
        local minutes = R.policy(run.namespace_id).permission_timeout_s / 60
        local row = U.one([[
            INSERT INTO ar_run_requests (run_uuid, namespace_id, kind, request_id, tool, input_summary, input,
                description, blocked_path, rule_key, tool_use_id, status, decided_by, decided_at, reason, expires_at)
            VALUES (?, ?, 'permission', ?, ?, ?, ?::jsonb, ?, ?, ?, ?, ?, ?, ?, ?, NOW() + make_interval(mins => ?))
            ON CONFLICT (run_uuid, request_id) DO NOTHING
            RETURNING uuid, status, reason
        ]], run.uuid, run.namespace_id, d.request_id, U.clean(d.tool), input_summary(b.input), enc,
            safe_text(d.description, 2000) or db.NULL, d.blocked_path and U.clean(d.blocked_path) or db.NULL,
            d.rule_key and U.clean(d.rule_key) or db.NULL, d.tool_use_id or db.NULL,
            earlier and "allowed" or "pending", earlier and earlier.decided_by or db.NULL,
            earlier and db.raw("NOW()") or db.NULL, earlier and "Allowed earlier in this run" or db.NULL, minutes)
        if not row then -- the same request_id raced in
            found = existing()
            return sdk.ok({ request = { uuid = found.uuid, status = found.status, reason = U.null(found.reason) } })
        end
        R.notify(run)
        return sdk.created({ request = { uuid = row.uuid, status = row.status, reason = U.null(row.reason) } })
    end)))

    app:post("/public/runner/runs/:uuid/permissions/:req_uuid/wait", sdk.handler({ namespace = false },
        U.guard(function(self)
            local runner = auth()
            local run = claimed_run(runner, self.params.uuid)
            local req = U.is_uuid(self.params.req_uuid) and U.one([[SELECT id FROM ar_run_requests
                WHERE uuid = ? AND run_uuid = ? AND namespace_id = ?]], self.params.req_uuid, run.uuid,
                run.namespace_id)
            if not req then U.fail(404, "Request not found") end
            local function state(last)
                R.expire_requests(req.id)
                local q = U.one(R.REQUEST_SQL .. " WHERE q.id = ?", req.id)
                local cancel = stopping(run)
                if last or cancel or q.status ~= "pending" then
                    return { status = q.status, reason = U.null(q.reason), decided_by_name = U.null(q.decided_by_name),
                        cancel = cancel }
                end
            end
            return sdk.ok(R.long_poll(R.wait_s(body(self).wait_s), state) or state(true))
        end)))

    -- One agent turn (a stream-json `result`) with its usage: stored, added to the run's totals and metered.
    app:post("/public/runner/runs/:uuid/turns", sdk.handler({ namespace = false }, U.guard(function(self)
        local runner = auth()
        local run = claimed_run(runner, self.params.uuid)
        local b = body(self)
        local d, errors = sdk.validate(b, { turn = { type = "integer", required = true, min = 1 },
            text = { type = "text" }, model = { max = 120 },
            cost_estimate = { type = "number", min = 0, max = 99999999 },
            num_turns = { type = "integer", min = 0 }, duration_ms = { type = "integer", min = 0 },
            needs_input = { type = "boolean" } })
        if not d then U.invalid(errors) end
        for k, v in pairs(d) do if v == db.NULL then d[k] = nil end end
        if b.usage ~= nil and (type(b.usage) ~= "table" or b.usage[1] ~= nil) then
            U.invalid({ usage = "must be an object" })
        end
        local usage = {}
        for key, col in pairs({ input_tokens = "tokens_in", output_tokens = "tokens_out",
            cache_read_tokens = "cache_read", cache_write_tokens = "cache_write" }) do
            local v = (b.usage or {})[key]
            local n = v == nil and 0 or num(v)
            if not n or n < 0 or n > 1e12 then U.invalid({ ["usage." .. key] = "must be a token count" }) end
            usage[col] = math.floor(n)
        end
        local model = d.model and U.clean(d.model) or run.model or run.profile

        local stored = U.tx(function()
            U.one("SELECT id FROM ar_runs WHERE id = ? FOR UPDATE", run.id) -- a replayed turn waits for the first
            if U.one([[SELECT 1 AS x FROM ar_run_turns WHERE run_uuid = ? AND role = 'assistant'
                AND runner_turn = ?]], run.uuid, d.turn) then return 0 end
            R.insert_turn(run, { role = "assistant", status = "delivered", runner_turn = d.turn,
                text = safe_text(d.text, MAX_TURN_TEXT) or db.NULL, model = model, tokens_in = usage.tokens_in,
                tokens_out = usage.tokens_out, cache_read = usage.cache_read, cache_write = usage.cache_write,
                cost_estimate = d.cost_estimate or db.NULL, num_turns = d.num_turns or db.NULL,
                duration_ms = d.duration_ms or db.NULL, needs_input = d.needs_input == true })
            db.query([[UPDATE ar_runs SET tokens_in = tokens_in + ?, tokens_out = tokens_out + ?,
                cache_read = cache_read + ?, cache_write = cache_write + ?, cost_estimate = cost_estimate + ?,
                turns = turns + 1, updated_at = NOW() WHERE id = ?]], usage.tokens_in, usage.tokens_out,
                usage.cache_read, usage.cache_write, d.cost_estimate or 0, run.id)
            -- Metered like every other model call (lib/agent/llm.lua): the AI usage page and limits see it. A lost
            -- usage row is logged, never a failed turn (the savepoint keeps the turn).
            local ok, err = pcall(U.tx, function()
                db.insert("ai_usage", { namespace_id = run.namespace_id, user_uuid = run.requested_by,
                    feature = "agent_run", scope = run.profile:sub(1, 60), run_uuid = run.uuid,
                    provider = run.profile:sub(1, 20), model = model,
                    input_tokens = math.min(usage.tokens_in, INT_MAX),
                    output_tokens = math.min(usage.tokens_out, INT_MAX),
                    cached_input_tokens = math.min(usage.cache_read, INT_MAX), latency_ms = d.duration_ms or 0,
                    ok = true })
            end)
            if not ok then ngx.log(ngx.ERR, "[ai_runner] usage not recorded: ", tostring(err)) end
            return 1
        end)
        return sdk.ok({ stored = stored })
    end)))

    -- People's follow-ups and needs_input answers, handed over once (marked delivered).
    app:post("/public/runner/runs/:uuid/turns/next", sdk.handler({ namespace = false }, U.guard(function(self)
        local runner = auth()
        local run = claimed_run(runner, self.params.uuid)
        local function next_turns(last)
            if stopping(run) then return { turns = U.array(), cancel = true } end
            local rows = db.query([[
                WITH d AS (UPDATE ar_run_turns SET status = 'delivered'
                           WHERE run_uuid = ? AND role = 'user' AND status = 'queued'
                           RETURNING uuid, seq, text, author_user_uuid)
                SELECT d.uuid, d.text, ]] .. R.name_sql("au") .. [[ AS author_name
                FROM d LEFT JOIN users au ON au.uuid = d.author_user_uuid ORDER BY d.seq
            ]], run.uuid)
            if #rows > 0 or last then
                for i, t in ipairs(rows) do
                    rows[i] = { uuid = t.uuid, text = U.null(t.text), author_name = U.null(t.author_name) }
                end
                return { turns = U.array(rows), cancel = false }
            end
        end
        return sdk.ok(R.long_poll(R.wait_s(body(self).wait_s), next_turns) or next_turns(true))
    end)))
end
