-- Runner API (docs/AI_RUNNER.md §22.2). No user session: under public/, authenticated by the runner token
-- ("Authorization: Bearer oprn_<48 hex>", stored as a SHA-256 hash and bound to one workspace).
--   POST /public/runner/heartbeat              capabilities, repos, inventory -> runs to cancel; renews leases
--   POST /public/runner/claim                  long-poll (wait_s <= 25) -> 200 { run } or 204
--   POST /public/runner/runs/:uuid/status      { seq, status, ... } compare-and-set; stale seq ignored
--   POST /public/runner/runs/:uuid/events      { events: [{ seq, type, text?, data? }] } idempotent on (run, seq)
-- Revoked token -> 401; plugin off in the workspace -> 404; paused runner: heartbeat works, claim gives 204.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson")
local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")

local MAX_EVENTS, MAX_EVENT_TEXT, MAX_EVENT_DATA = 200, 4096, 8192
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
    if r.ns_status ~= "active" or not require("helper.plugin-workspaces").isEnabled("ai_runner", r.namespace_id) then
        U.fail(404, "AI Runs is turned off for this workspace", { code = "PLUGIN_DISABLED" })
    end
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
                approval = (p.approval == "bridge" or p.approval == "unsupported") and p.approval or "none" }
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
    status = { required = true, enum = { "starting", "running", "succeeded", "failed", "cancelled" } },
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
        local wait = tonumber(body(self).wait_s)
        wait = wait and wait == wait and math.max(0, math.min(R.CLAIM_WAIT_S, wait)) or R.CLAIM_WAIT_S
        local run = R.claim(runner, wait)
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
        return sdk.ok(R.report(runner, self.params.uuid, d))
    end)))

    app:post("/public/runner/runs/:uuid/events", sdk.handler({ namespace = false }, U.guard(function(self)
        local runner = auth()
        local b = body(self)
        local run = U.is_uuid(self.params.uuid) and U.one([[SELECT uuid, status FROM ar_runs
            WHERE uuid = ? AND namespace_id = ? AND runner_uuid = ?]], self.params.uuid, runner.namespace_id,
            runner.uuid)
        if not run or run.status == "queued" then U.fail(404, "Run not found") end
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
            -- Redact before cutting, so a cut never leaves half a key in clear.
            rows[#rows + 1] = { seq = seq, type = e.type, data = data,
                text = type(e.text) == "string" and U.clean(U.redact(U.clean(e.text)), MAX_EVENT_TEXT) or nil }
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
end
