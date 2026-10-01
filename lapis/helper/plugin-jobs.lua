--[[
    Plugin jobs
    ===========

    Scheduled work for plugins, one file per job (guide: PLUGINS.md):

        -- projects/helpdesk/jobs/close_stale.lua
        return {
            every = "1h",          -- a number and s/m/h/d; at least 1m
            -- at = "03:00",       -- with every in whole days: that time of day, UTC
            -- scope = "global",   -- once per deployment instead of once per workspace
            run = function(job)
                -- job = { name, namespace_id, settings, last_run_at }
            end,
        }

    A job runs once per workspace where its plugin is on (job.namespace_id,
    job.settings), or once per deployment with scope = "global".

    How it works
      * plugin_jobs holds one row per job and workspace: when it runs next
        and how the last run went. Worker 0 of each pod adds rows for
        workspaces that have the plugin on and drops the rest, every minute.
      * Every worker with jobs claims due rows FOR UPDATE SKIP LOCKED with a
        LEASE_SECONDS lease, so a run happens on one worker of one pod. If
        that worker dies, the run starts again when the lease ends.
      * A failed run (error raised, or `return false, "why"`) is recorded in
        last_error and the job waits for its next slot: no retries, like
        cron. Make runs safe to repeat.
      * `every` is the gap after a run finishes; `at` jobs keep their time of
        day. Runs missed while OpsAPI was down happen once, then the schedule
        continues. First runs of `every` jobs are spread over up to 5 minutes.
]]

local cjson = require("cjson")

local PluginJobs = {}

PluginJobs.LEASE_SECONDS = 900
local POLL_SECONDS = 10
local SEED_SECONDS = 60
local BATCH = 5
local DRAIN_SECONDS = 50
local UNITS = { s = 1, m = 60, h = 3600, d = 86400 }
local DAY = 86400

local function db()
    return require("lapis.db")
end

--- Check a jobs/*.lua table. @return the job definition, or nil + message
function PluginJobs.check(spec)
    if type(spec) ~= "table" then
        return nil, "must return a table like { every = \"1h\", run = function(job) ... end }"
    end
    if type(spec.run) ~= "function" then return nil, "needs run = function(job) ... end" end
    local n, unit = tostring(spec.every or ""):match("^(%d+)([smhd])$")
    local every = n and tonumber(n) * UNITS[unit]
    if not every or every < 60 then
        return nil, "every must look like \"5m\", \"1h\" or \"1d\" (at least 1m)"
    end
    local at
    if spec.at ~= nil then
        local h, m = tostring(spec.at):match("^(%d%d):(%d%d)$")
        h, m = tonumber(h), tonumber(m)
        if not h or h > 23 or m > 59 then return nil, "at must look like \"03:00\" (UTC)" end
        if every % DAY ~= 0 then return nil, "at needs every in whole days, e.g. every = \"1d\"" end
        at = h * 3600 + m * 60
    end
    local scope = spec.scope or "workspace"
    if scope ~= "workspace" and scope ~= "global" then
        return nil, "scope must be \"workspace\" or \"global\""
    end
    return { every = every, at = at, scope = scope, run = spec.run, every_text = spec.every, at_text = spec.at }
end

--- When a job runs next, after `now` (epoch seconds).
function PluginJobs.nextRun(def, now)
    if def.at then
        local t = math.floor(now / DAY) * DAY + def.at
        if t <= now then t = t + DAY end
        return t + def.every - DAY
    end
    return now + def.every
end

--- Load a plugin's jobs/*.lua files.
-- @return jobs { ["<code>.<file>"] = def }, errors { "jobs/<file>: message" }
function PluginJobs.loadJobs(manifest)
    local dir = manifest.path .. "/jobs"
    local jobs, errors = {}, {}
    for _, file in ipairs(require("helper.project-loader").listDir(dir)) do
        local name = file:match("^([%w_]+)%.lua$")
        if file:match("%.lua$") and not name then
            errors[#errors + 1] = "jobs/" .. file .. ": name it with letters, digits and _ only"
        elseif name then
            local chunk, err = loadfile(dir .. "/" .. file)
            local ok, spec = chunk ~= nil, err
            if chunk then ok, spec = pcall(chunk) end
            local def, why = nil, spec
            if ok then def, why = PluginJobs.check(spec) end
            if def then
                def.plugin, def.name = manifest.code, manifest.code .. "." .. name
                jobs[def.name] = def
            else
                errors[#errors + 1] = "jobs/" .. file .. ": " .. tostring(why)
            end
        end
    end
    return jobs, errors
end

-- ---------------------------------------------------------------------------
-- Schema + sync (helper.project-migrator, on every migrate)
-- ---------------------------------------------------------------------------

function PluginJobs.ensureSchema()
    local q = db().query
    q([[
        CREATE TABLE IF NOT EXISTS plugin_jobs (
            id BIGSERIAL PRIMARY KEY,
            job VARCHAR(200) NOT NULL,
            namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE,
            next_run_at TIMESTAMPTZ NOT NULL,
            locked_until TIMESTAMPTZ,
            last_run_at TIMESTAMPTZ,
            last_status VARCHAR(10),
            last_error TEXT,
            last_duration_ms INTEGER,
            failures INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    q("CREATE UNIQUE INDEX IF NOT EXISTS uq_plugin_jobs_job_ns ON plugin_jobs (job, (COALESCE(namespace_id, 0)))")
    q("CREATE INDEX IF NOT EXISTS idx_plugin_jobs_due ON plugin_jobs (next_run_at)")
end

--- Drop the rows of jobs a plugin no longer has. Raises on a broken jobs
-- file so the deploy stops, like a failed migration.
function PluginJobs.syncPlugin(manifest)
    local jobs, errors = PluginJobs.loadJobs(manifest)
    if #errors > 0 then error(manifest.code .. ": " .. table.concat(errors, "; "), 0) end
    local d = db()
    local keep = {}
    for name in pairs(jobs) do keep[#keep + 1] = d.escape_literal(name) end
    d.query("DELETE FROM plugin_jobs WHERE left(job, " .. (#manifest.code + 1) .. ") = "
        .. d.escape_literal(manifest.code .. ".")
        .. (#keep > 0 and (" AND job NOT IN (" .. table.concat(keep, ", ") .. ")") or ""))
end

-- ---------------------------------------------------------------------------
-- Scheduler (started per worker from nginx.conf init_worker_by_lua)
-- ---------------------------------------------------------------------------

local _jobs = {}       -- { [job name] = def }
local _manifests = {}  -- { [plugin code] = manifest } (job.settings)
local _failures = {}   -- { { code, errors } } jobs files that failed to load
local _busy, _last_seed = false, 0

--- jobs/*.lua files that failed to load in this worker (for /ready).
function PluginJobs.failures()
    return _failures
end

-- The first run of a new row: `at` jobs at their time, others spread over
-- up to 5 minutes so a deploy doesn't start every workspace at once.
local function first_run_sql(def)
    if def.at then return ("to_timestamp(%d)"):format(PluginJobs.nextRun(def, ngx.time())) end
    return ("NOW() + random() * interval '%d seconds'"):format(math.min(def.every, 300))
end

--- Make plugin_jobs match who has each job: a row per workspace with the
-- plugin on (or one row for a global job).
local function seed(def)
    local d = db()
    local job, code = d.escape_literal(def.name), d.escape_literal(def.plugin)
    if def.scope == "global" then
        d.query("INSERT INTO plugin_jobs (job, next_run_at) VALUES (" .. job .. ", " .. first_run_sql(def) .. ")"
            .. " ON CONFLICT (job, (COALESCE(namespace_id, 0))) DO NOTHING")
        d.query("DELETE FROM plugin_jobs WHERE job = " .. job .. " AND namespace_id IS NOT NULL")
        return
    end
    d.query("INSERT INTO plugin_jobs (job, namespace_id, next_run_at) SELECT " .. job .. ", n.id, "
        .. first_run_sql(def) .. " FROM namespaces n WHERE n.status = 'active'"
        .. " AND opsapi_plugin_enabled(" .. code .. ", n.id)"
        .. " ON CONFLICT (job, (COALESCE(namespace_id, 0))) DO NOTHING")
    d.query("DELETE FROM plugin_jobs j WHERE j.job = " .. job .. " AND (j.namespace_id IS NULL"
        .. " OR NOT opsapi_plugin_enabled(" .. code .. ", j.namespace_id)"
        .. " OR NOT EXISTS (SELECT 1 FROM namespaces n WHERE n.id = j.namespace_id AND n.status = 'active'))")
end

local function finish(id, ok, err, ms, next_at)
    db().query([[
        UPDATE plugin_jobs SET locked_until = NULL, last_run_at = NOW(), last_status = ?, last_error = ?,
            last_duration_ms = ?, failures = CASE WHEN ? THEN 0 ELSE failures + 1 END, next_run_at = to_timestamp(?)
        WHERE id = ?
    ]], ok and "ok" or "failed", ok and db().NULL or tostring(err):sub(1, 2000), ms, ok, next_at, id)
end

local function run_one(c)
    local def = _jobs[c.job]
    local d = db()
    local job = {
        name = c.job,
        namespace_id = c.namespace_id ~= d.NULL and tonumber(c.namespace_id) or nil,
        last_run_at = c.last_run_at ~= d.NULL and c.last_run_at or nil,
    }
    local manifest = _manifests[def.plugin]
    setmetatable(job, { __index = function(t, k)
        if k ~= "settings" then return nil end
        local v = require("helper.plugin-workspaces").settings(manifest, t.namespace_id)
        rawset(t, "settings", v)
        return v
    end })

    ngx.update_time()
    local started = ngx.now()
    local ok, result, message = pcall(def.run, job)
    if ok and result == false then ok, result = false, message or "run returned false" end
    ngx.update_time()
    if require("helper.plugin-events").resetTransaction() and ok then
        ok, result = false, "run left a transaction open; it was rolled back"
    end
    if not ok then
        ngx.log(ngx.WARN, "[plugin-jobs] ", c.job, " (namespace ", tostring(job.namespace_id), ") failed: ",
            tostring(result))
    end
    finish(c.id, ok, result, math.floor((ngx.now() - started) * 1000), PluginJobs.nextRun(def, ngx.time()))
end

local function claim()
    local d = db()
    local mine = {}
    for name in pairs(_jobs) do mine[#mine + 1] = d.escape_literal(name) end
    -- Inline literals only: no "?" placeholders in this statement.
    return d.query([[
        UPDATE plugin_jobs SET locked_until = NOW() + interval ']] .. PluginJobs.LEASE_SECONDS .. [[ seconds'
        WHERE id IN (
            SELECT id FROM plugin_jobs
            WHERE job IN (]] .. table.concat(mine, ", ") .. [[) AND next_run_at <= NOW()
              AND (locked_until IS NULL OR locked_until < NOW())
              AND (namespace_id IS NULL OR opsapi_plugin_enabled(split_part(job, '.', 1), namespace_id))
            ORDER BY next_run_at
            LIMIT ]] .. BATCH .. [[
            FOR UPDATE SKIP LOCKED
        )
        RETURNING id, job, namespace_id, last_run_at
    ]])
end

local function tick(premature)
    if premature or _busy then return end
    _busy = true
    local ok, err = pcall(function()
        if ngx.worker.id() == 0 and ngx.time() - _last_seed >= SEED_SECONDS then
            _last_seed = ngx.time()
            for _, def in pairs(_jobs) do seed(def) end
        end
        ngx.update_time()
        local stop = ngx.now() + DRAIN_SECONDS
        repeat
            local claimed = claim()
            for _, c in ipairs(claimed) do run_one(c) end
            ngx.update_time()
        until #claimed < BATCH or ngx.now() > stop
    end)
    require("helper.plugin-events").releaseConnection()
    _busy = false
    if not ok then ngx.log(ngx.ERR, "[plugin-jobs] scheduler failed: ", tostring(err)) end
end

--- Load every plugin's jobs/*.lua and start the scheduler (no-op without jobs).
function PluginJobs.start(projects_root)
    local ProjectLoader = require("helper.project-loader")
    for _, entry in ipairs(ProjectLoader.discover(projects_root)) do
        local manifest = ProjectLoader.loadManifest(entry.manifest_path, entry.path)
        if manifest and manifest.enabled and not ProjectLoader.isReservedCode(manifest.code) then
            _manifests[manifest.code] = manifest
            local jobs, errors = PluginJobs.loadJobs(manifest)
            for name, def in pairs(jobs) do _jobs[name] = def end
            if #errors > 0 then
                table.insert(_failures, { code = manifest.code, errors = errors })
                ngx.log(ngx.ERR, "[plugin-jobs] ", manifest.code, ": ", table.concat(errors, "; "))
            end
        end
    end
    if next(_jobs) then ngx.timer.every(POLL_SECONDS, tick) end
end

-- ---------------------------------------------------------------------------
-- Admin and workspace views
-- ---------------------------------------------------------------------------

local function ready()
    return require("helper.table-exists")("plugin_jobs")
end

local function schedule_of(def)
    return { every = def.every_text, at = def.at_text, scope = def.scope }
end

--- A plugin's jobs in this worker, sorted by name.
local function jobs_of(code)
    local list = {}
    for name, def in pairs(_jobs) do
        if def.plugin == code then list[#list + 1] = def end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

--- Platform admins: each job's schedule, how many workspaces run it, how
-- many last failed, and recent failures.
function PluginJobs.stats(code)
    local d = db()
    local out = {}
    for _, def in ipairs(jobs_of(code)) do
        local s = schedule_of(def)
        s.name = def.name
        if ready() then
            local r = d.query([[
                SELECT COUNT(*)::int AS rows, COUNT(*) FILTER (WHERE last_status = 'failed')::int AS failing,
                       MIN(next_run_at) AS next_run_at, MAX(last_run_at) AS last_run_at
                FROM plugin_jobs WHERE job = ?
            ]], def.name)[1]
            s.workspaces, s.failing = r.rows, r.failing
            s.next_run_at = r.next_run_at ~= d.NULL and r.next_run_at or nil
            s.last_run_at = r.last_run_at ~= d.NULL and r.last_run_at or nil
            s.recent_failures = setmetatable(d.query([[
                SELECT namespace_id, last_error, last_run_at, failures FROM plugin_jobs
                WHERE job = ? AND last_status = 'failed' ORDER BY last_run_at DESC LIMIT 10
            ]], def.name), cjson.array_mt)
        end
        out[#out + 1] = s
    end
    return setmetatable(out, cjson.array_mt)
end

--- A workspace's view of a plugin's (workspace-scoped) jobs: schedule and
-- last run. Errors stay with the platform admins (they're the plugin's).
function PluginJobs.forNamespace(code, namespace_id)
    local d = db()
    local out = {}
    for _, def in ipairs(jobs_of(code)) do
        if def.scope == "workspace" then
            local s = schedule_of(def)
            s.name = def.name
            local r = ready() and d.query([[
                SELECT next_run_at, last_run_at, last_status FROM plugin_jobs WHERE job = ? AND namespace_id = ?
            ]], def.name, namespace_id)[1]
            if r then
                s.next_run_at = r.next_run_at
                s.last_run_at = r.last_run_at ~= d.NULL and r.last_run_at or nil
                s.last_status = r.last_status ~= d.NULL and r.last_status or nil
            end
            out[#out + 1] = s
        end
    end
    return setmetatable(out, cjson.array_mt)
end

--- Run a job as soon as possible (every workspace, or one).
-- @return number of runs queued, or nil when the job doesn't exist
function PluginJobs.runNow(job_name, namespace_id)
    local def = _jobs[job_name]
    if not def or not ready() then return nil end
    seed(def)
    local d = db()
    return d.query("UPDATE plugin_jobs SET next_run_at = NOW() WHERE job = ?"
        .. (namespace_id and " AND namespace_id = ?" or ""), job_name, namespace_id).affected_rows or 0
end

return PluginJobs
