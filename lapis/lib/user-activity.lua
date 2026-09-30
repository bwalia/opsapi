--[[
    User activity & login tracking
    ==============================

    Two streams, both stored in Postgres. Per-user data never goes to /metrics:
    user ids as Prometheus labels explode series cardinality and would publish
    personal data to every scraper.

      auth_events    sign-ins (success / failure), 2FA, token refresh, logout,
                     password reset/change, account deactivation. Written
                     synchronously (low volume, security relevant) and rolled
                     up into user_login_stats (last login / last seen / counts —
                     a separate 1:1 table, so existing `users` payloads, which
                     are whole rows minus secrets, never start carrying IPs).

      user_activity  what signed-in users do. Captured in nginx's log phase —
                     after the response has gone out — buffered per worker and
                     written in batches by a timer, so it never adds latency to
                     a request and never fails one. Every change (POST / PUT /
                     PATCH / DELETE) is its own row; repeated identical reads
                     (same user, route, record, status) are merged per minute
                     into one row with `hits`. Monthly partitions; old ones are
                     dropped by retention. If the database is unavailable,
                     entries are retried a few times, then dropped and counted
                     (opsapi_activity_dropped_total) rather than growing memory.

    Aggregates go to Prometheus: opsapi_auth_events_total, opsapi_active_users,
    and pipeline health. Grafana reads per-user data through the
    opsapi_reporting views (migrations/user-activity.lua).

    Config: OPSAPI_ACTIVITY_ENABLED (default true),
            OPSAPI_ACTIVITY_RETENTION_DAYS (default 90),
            OPSAPI_AUTH_EVENTS_RETENTION_DAYS (default 365),
            OPSAPI_ACTIVITY_EXCLUDE (extra comma-separated Lua URI patterns).
]]

local ClientIP = require("helper.client-ip")

local UserActivity = {}

local FLUSH_SECONDS = 2
local BATCH_ROWS = 500
local MAX_BUFFERED = 20000        -- per worker; beyond this new entries are dropped
local MAX_TRIES = 3               -- write attempts before a batch is dropped
local SEEN_EVERY = 60             -- seconds between last_seen_at pushes per user
local MAINTENANCE_SECONDS = 3600
local PARTITIONS_AHEAD = 2

local VERB = { GET = "read", HEAD = "read", POST = "create", PUT = "update", PATCH = "update", DELETE = "delete" }

local DEFAULT_EXCLUDE = {
    "^/health", "^/ready$", "^/live$", "^/metrics", "^/swagger", "^/openapi", "^/api%-docs",
    "^/auth/", -- covered by auth_events
}

local function env_number(name, default, min)
    local n = tonumber(os.getenv(name) or "")
    if not n or n < (min or 1) then return default end
    return math.floor(n)
end

local ENABLED = os.getenv("OPSAPI_ACTIVITY_ENABLED") ~= "false"
UserActivity.ACTIVITY_RETENTION_DAYS = env_number("OPSAPI_ACTIVITY_RETENTION_DAYS", 90, 7)
UserActivity.AUTH_RETENTION_DAYS = env_number("OPSAPI_AUTH_EVENTS_RETENTION_DAYS", 365, 30)

local EXCLUDE = {}
for _, p in ipairs(DEFAULT_EXCLUDE) do EXCLUDE[#EXCLUDE + 1] = p end
for p in (os.getenv("OPSAPI_ACTIVITY_EXCLUDE") or ""):gmatch("[^,]+") do
    EXCLUDE[#EXCLUDE + 1] = p:match("^%s*(.-)%s*$")
end

local function metric(name)
    local ok, metrics = pcall(require, "lib.prometheus_metrics")
    return ok and metrics.metric and metrics.metric(name) or nil
end

local function inc(name, labels, by)
    local m = metric(name)
    if m then pcall(m.inc, m, by or 1, labels) end
end

local function db()
    return require("lapis.db")
end

local function lit(v)
    if v == nil then return "NULL" end
    return db().escape_literal(v)
end

local function user_agent()
    local ua = ngx.var.http_user_agent
    return ua and ua:sub(1, 255) or nil
end

-- Timers don't run lapis' after-dispatch hook: hand the connection back to
-- the pool ourselves, rolling back anything left open first.
local function release_connection()
    pcall(function()
        local d = db()
        if d.query("SELECT now() <> statement_timestamp() AS open")[1].open then d.query("ROLLBACK") end
    end)
    pcall(require("lapis.nginx.context").run_after_dispatch)
end

-- ---------------------------------------------------------------------------
-- Routes → "what did they do"
-- ---------------------------------------------------------------------------

local function is_id(seg)
    return seg:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
        or seg:match("^%d+$") ~= nil
        or (seg:match("^[%w_%-%.]+$") ~= nil and (
            (#seg >= 16 and seg:match("%d") ~= nil)                -- tokens, hashes
            or (#seg >= 6 and select(2, seg:gsub("%d", "")) >= 3))) -- INV-2026-000123, ORD00042
end

--- "/api/v2/crm/accounts/5f0e…/contacts" →
--  route "/api/v2/crm/accounts/:id/contacts", entity "5f0e…", resource "crm.accounts.contacts"
function UserActivity.normalize(uri)
    local parts, resource, entity = {}, {}, nil
    local index = 0
    for seg in uri:gmatch("[^/]+") do
        index = index + 1
        if index > 12 then break end
        if is_id(seg) then
            parts[#parts + 1] = ":id"
            entity = seg
        else
            parts[#parts + 1] = seg
            if not (index <= 2 and (seg == "api" or seg:match("^v%d+$"))) then
                resource[#resource + 1] = seg
            end
        end
    end
    local route = "/" .. table.concat(parts, "/")
    local res = #resource > 0 and table.concat(resource, ".") or "root"
    return route:sub(1, 255), entity and entity:sub(1, 64) or nil, res:sub(1, 100)
end

-- ---------------------------------------------------------------------------
-- Auth events (synchronous)
-- ---------------------------------------------------------------------------

--- Record an authentication event. Never raises.
-- opts: result ("success" | "failure" | "rate_limited"), method ("password" |
-- "google" | "oauth" | "refresh" | …), user (table with uuid[, email]),
-- email (identifier tried, when the user is unknown), namespace_id, reason,
-- metric_only (count it, don't store a row — e.g. rate-limited floods).
function UserActivity.auth(event, opts)
    opts = opts or {}
    local result = opts.result or "success"
    local method = opts.method or "none"
    inc("auth_events", { event, result, method })
    ngx.ctx.auth_event_recorded = true
    if opts.metric_only or not ENABLED then return end

    local ok, err = pcall(function()
        local d = db()
        local user = opts.user
        local user_uuid = user and (user.uuid or user.user_uuid) or nil
        local email = opts.email or (user and user.email) or nil
        if email then email = tostring(email):lower():sub(1, 255) end
        local ip, ua = ClientIP.get(), user_agent()

        -- An identifier we know (failed login, reset request): attribute it.
        if not user_uuid and email then
            local row = d.query("SELECT uuid FROM users WHERE lower(email) = ? OR lower(username) = ? LIMIT 1",
                email, email)[1]
            user_uuid = row and row.uuid or nil
        end

        d.query([[
            INSERT INTO auth_events (event, result, method, user_uuid, email, namespace_id, ip, user_agent,
                                     reason, request_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], event, result, method, user_uuid or d.NULL, email or d.NULL, opts.namespace_id or d.NULL,
            ip or d.NULL, ua or d.NULL, opts.reason and tostring(opts.reason):sub(1, 64) or d.NULL,
            ngx.var.request_id or d.NULL)

        if not user_uuid then return end
        if event == "login" and result == "success" then
            d.query([[
                INSERT INTO user_login_stats (user_uuid, last_login_at, last_login_ip, last_login_method,
                                              last_login_user_agent, login_count, failed_login_count, last_seen_at)
                VALUES (?, NOW(), ?, ?, ?, 1, 0, NOW())
                ON CONFLICT (user_uuid) DO UPDATE SET
                    last_login_at = NOW(), last_login_ip = EXCLUDED.last_login_ip,
                    last_login_method = EXCLUDED.last_login_method,
                    last_login_user_agent = EXCLUDED.last_login_user_agent,
                    login_count = user_login_stats.login_count + 1, failed_login_count = 0,
                    last_seen_at = NOW(), updated_at = NOW()
            ]], user_uuid, ip or d.NULL, method, ua or d.NULL)
        elseif event == "login" and result == "failure" then
            d.query([[
                INSERT INTO user_login_stats (user_uuid, last_failed_login_at, failed_login_count)
                VALUES (?, NOW(), 1)
                ON CONFLICT (user_uuid) DO UPDATE SET last_failed_login_at = NOW(),
                    failed_login_count = user_login_stats.failed_login_count + 1, updated_at = NOW()
            ]], user_uuid)
        elseif event == "token_refresh" and result == "success" then
            d.query([[
                INSERT INTO user_login_stats (user_uuid, last_seen_at) VALUES (?, NOW())
                ON CONFLICT (user_uuid) DO UPDATE SET last_seen_at = NOW(), updated_at = NOW()
                WHERE user_login_stats.last_seen_at IS NULL
                   OR user_login_stats.last_seen_at < NOW() - interval '1 minute'
            ]], user_uuid)
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "[user-activity] auth event ", event, " not recorded: ", tostring(err))
    end
end

local function reason_of(res)
    local j = res.json
    if type(j) == "table" then
        local e = j.error
        if type(e) == "table" then return tostring(e.code or e.title or "error") end
        if type(e) == "string" then return e end
    end
    return "http_" .. tostring(res.status)
end

--- Wrap an auth route so any failed response (4xx/5xx, or a redirect with
-- ?error=) is recorded as `event` failure — unless the handler already
-- recorded something itself. Put it OUTSIDE RateLimit.wrap so rate-limited
-- attempts are counted (metrics only: no row per flood request).
-- identify(self) → the identifier tried (e.g. the login email), optional.
function UserActivity.guardAuth(event, method, handler, identify)
    return function(self)
        ngx.ctx.auth_event_recorded = nil
        local res = handler(self)
        if not ngx.ctx.auth_event_recorded and type(res) == "table" then
            local status = tonumber(res.status) or 200
            local redirect_error = type(res.redirect_to) == "string" and res.redirect_to:match("[?&]error=([%w_%-]+)")
            if status >= 400 or redirect_error then
                local email
                if identify then
                    local ok, v = pcall(identify, self)
                    email = ok and type(v) == "string" and v or nil
                end
                UserActivity.auth(event, {
                    result = status == 429 and "rate_limited" or "failure",
                    method = method,
                    email = email,
                    reason = redirect_error or reason_of(res),
                    metric_only = status == 429,
                })
            end
        end
        return res
    end
end

-- ---------------------------------------------------------------------------
-- Request activity (log phase → per-worker buffer → batched writes)
-- ---------------------------------------------------------------------------

local writes = {}      -- change rows, in order
local reads = {}       -- merged reads: key → row
local buffered = 0
local pending = {}     -- rows whose write failed, retried next flush
local seen = {}        -- user_uuid → last activity time (for user_login_stats.last_seen_at)
local seen_pushed      -- lrucache: user_uuid → last time pushed

--- Called from nginx.conf log_by_lua for every request. Cheap, never raises.
function UserActivity.capture()
    if not ENABLED then return end
    local user = ngx.ctx.user
    if type(user) ~= "table" or not user.uuid then return end -- anonymous
    local status = ngx.status
    if status == 101 then return end                            -- websocket upgrade
    local method = ngx.req.get_method()
    local verb = VERB[method]
    if not verb then return end                                 -- OPTIONS etc.
    local uri = ngx.var.uri or ""
    for _, pattern in ipairs(EXCLUDE) do
        if uri:find(pattern) then return end
    end

    local now = ngx.now()
    local ms = math.floor((tonumber(ngx.var.request_time) or 0) * 1000)
    local route, entity, resource = UserActivity.normalize(uri)
    local ns = ngx.ctx.namespace_id or user.namespace_id
        or ngx.var.http_x_namespace_id or ngx.var.http_x_namespace_slug
        or (type(user.namespace) == "table" and (user.namespace.id or user.namespace.uuid)) or nil

    if verb == "read" then
        local key = table.concat({ user.uuid, tostring(ns), method, route, entity or "", status,
            math.floor(now / 60) }, "|")
        local row = reads[key]
        if row then
            row.hits = row.hits + 1
            row.total_ms = row.total_ms + ms
        else
            if buffered >= MAX_BUFFERED then return inc("activity_dropped", { "buffer_full" }) end
            buffered = buffered + 1
            reads[key] = {
                at = now, user_uuid = user.uuid, ns = ns, api_key = user.api_key and user.key_uuid or nil,
                method = method, route = route, action = resource .. ".read", entity = entity, status = status,
                hits = 1, total_ms = ms, ip = ClientIP.get(), ua = user_agent(), request_id = ngx.var.request_id,
            }
        end
    else
        if buffered >= MAX_BUFFERED then return inc("activity_dropped", { "buffer_full" }) end
        buffered = buffered + 1
        writes[#writes + 1] = {
            at = now, user_uuid = user.uuid, ns = ns, api_key = user.api_key and user.key_uuid or nil,
            method = method, route = route, action = resource .. "." .. verb, entity = entity, status = status,
            hits = 1, total_ms = ms, ip = ClientIP.get(), ua = user_agent(), request_id = ngx.var.request_id,
        }
    end

    if not user.api_key then seen[user.uuid] = now end
end

-- Namespace hints are numeric ids or uuid/slug strings; resolve the strings.
local ns_cache
local function resolve_namespaces(rows)
    if not ns_cache then ns_cache = require("resty.lrucache").new(2000) end
    local wanted, list = {}, {}
    for _, r in ipairs(rows) do
        local hint = r.ns
        if hint ~= nil and not tonumber(hint) and ns_cache:get(tostring(hint)) == nil and not wanted[hint] then
            wanted[hint] = true
            list[#list + 1] = lit(tostring(hint))
        end
    end
    if #list > 0 then
        local set = table.concat(list, ",")
        for _, n in ipairs(db().query("SELECT id, uuid::text AS uuid, slug FROM namespaces WHERE uuid::text IN ("
            .. set .. ") OR slug IN (" .. set .. ")")) do
            ns_cache:set(n.uuid, n.id, 300)
            ns_cache:set(n.slug, n.id, 300)
        end
        for hint in pairs(wanted) do
            if ns_cache:get(hint) == nil then ns_cache:set(hint, false, 300) end -- unknown: don't re-query
        end
    end
    for _, r in ipairs(rows) do
        if r.ns_id == nil then
            local n = tonumber(r.ns)
            if not n and r.ns ~= nil then n = ns_cache:get(tostring(r.ns)) or nil end
            r.ns_id = n or false
        end
    end
end

local function values_sql(r)
    return "(" .. table.concat({
        ("to_timestamp(%.3f)"):format(r.at),
        lit(r.user_uuid),
        r.ns_id and tostring(r.ns_id) or "NULL",
        lit(r.api_key and "api_key" or "jwt"),
        lit(r.api_key),
        lit(r.method),
        lit(r.route),
        lit(r.action),
        lit(r.entity),
        tostring(r.status),
        tostring(r.hits),
        tostring(math.floor(r.total_ms / r.hits)),
        lit(r.ip),
        lit(r.ua),
        lit(r.request_id),
    }, ", ") .. ")"
end

local INSERT = "INSERT INTO user_activity (occurred_at, user_uuid, namespace_id, via, api_key_uuid, method, route, "
    .. "action, entity_id, status, hits, duration_ms, ip, user_agent, request_id) VALUES "

local function write_batch(batch)
    local sql = {}
    for i, r in ipairs(batch) do sql[i] = values_sql(r) end
    local ok, err = pcall(db().query, INSERT .. table.concat(sql, ",\n"))
    if not ok and tostring(err):find("no partition of relation", 1, true) then
        pcall(UserActivity.ensurePartitions)
        ok, err = pcall(db().query, INSERT .. table.concat(sql, ",\n"))
    end
    return ok, err
end

local function flush_activity()
    local rows = pending
    pending = {}
    for _, r in ipairs(writes) do rows[#rows + 1] = r end
    for _, r in pairs(reads) do rows[#rows + 1] = r end
    writes, reads, buffered = {}, {}, 0
    if #rows == 0 then return end

    local started = ngx.now()
    pcall(resolve_namespaces, rows)
    local written = 0
    for i = 1, #rows, BATCH_ROWS do
        local batch = { unpack(rows, i, math.min(i + BATCH_ROWS - 1, #rows)) }
        local ok, err = write_batch(batch)
        if ok then
            written = written + #batch
        else
            ngx.log(ngx.ERR, "[user-activity] write failed (", #batch, " rows): ", tostring(err))
            for _, r in ipairs(batch) do
                r.tries = (r.tries or 0) + 1
                if r.tries < MAX_TRIES and #pending < MAX_BUFFERED then
                    pending[#pending + 1] = r
                else
                    inc("activity_dropped", { "write_failed" })
                end
            end
        end
    end
    if written > 0 then inc("activity_rows", nil, written) end
    local h = metric("activity_flush")
    if h then pcall(h.observe, h, ngx.now() - started) end
end

local function flush_seen()
    if not seen_pushed then seen_pushed = require("resty.lrucache").new(10000) end
    local list = {}
    for uuid, at in pairs(seen) do
        local last = seen_pushed:get(uuid)
        if not last or at - last >= SEEN_EVERY then
            list[#list + 1] = ("(%s, to_timestamp(%.3f))"):format(lit(uuid), at)
            seen_pushed:set(uuid, at, SEEN_EVERY * 10)
        end
    end
    seen = {}
    if #list == 0 then return end
    db().query([[
        INSERT INTO user_login_stats (user_uuid, last_seen_at)
        SELECT v.uuid, v.at FROM (VALUES ]] .. table.concat(list, ",") .. [[) AS v(uuid, at)
        JOIN users u ON u.uuid = v.uuid
        ON CONFLICT (user_uuid) DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at, updated_at = NOW()
        WHERE user_login_stats.last_seen_at IS NULL OR user_login_stats.last_seen_at < EXCLUDED.last_seen_at
    ]])
end

local flushing = false
local function flush(premature)
    if flushing then return end
    flushing = true
    local ok, err = pcall(function()
        flush_activity()
        flush_seen()
    end)
    release_connection()
    flushing = false
    if not ok then ngx.log(ngx.ERR, "[user-activity] flush failed: ", tostring(err)) end
    if premature then return end
end

-- ---------------------------------------------------------------------------
-- Partitions, retention, gauges
-- ---------------------------------------------------------------------------

local function add_months(year, month, k)
    local t = year * 12 + (month - 1) + k
    return math.floor(t / 12), t % 12 + 1
end

--- Monthly partitions for this month and PARTITIONS_AHEAD months ahead.
function UserActivity.ensurePartitions()
    local now = os.date("!*t")
    for k = 0, PARTITIONS_AHEAD do
        local y, m = add_months(now.year, now.month, k)
        local y2, m2 = add_months(now.year, now.month, k + 1)
        db().query(("CREATE TABLE IF NOT EXISTS user_activity_p%04d%02d PARTITION OF user_activity "
            .. "FOR VALUES FROM ('%04d-%02d-01 00:00:00+00') TO ('%04d-%02d-01 00:00:00+00')")
            :format(y, m, y, m, y2, m2))
    end
end

--- Drop activity partitions entirely older than the retention window, and
-- delete auth events past theirs. @return partitions dropped, auth rows deleted
function UserActivity.applyRetention()
    local d = db()
    local cutoff = os.date("!*t", os.time() - UserActivity.ACTIVITY_RETENTION_DAYS * 86400)
    local cutoff_key = cutoff.year * 100 + cutoff.month
    local dropped = 0
    for _, p in ipairs(d.query([[
        SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'user_activity'::regclass
    ]])) do
        local y, m = p.relname:match("^user_activity_p(%d%d%d%d)(%d%d)$")
        if y then
            local ey, em = add_months(tonumber(y), tonumber(m), 1) -- the partition's (exclusive) end
            if ey * 100 + em <= cutoff_key then
                d.query("DROP TABLE IF EXISTS " .. d.escape_identifier(p.relname))
                dropped = dropped + 1
            end
        end
    end
    local deleted = 0
    for _ = 1, 50 do
        local res = d.query(([[
            DELETE FROM auth_events WHERE id IN (
                SELECT id FROM auth_events WHERE occurred_at < NOW() - interval '%d days' LIMIT 5000)
        ]]):format(UserActivity.AUTH_RETENTION_DAYS))
        deleted = deleted + (res.affected_rows or 0)
        if (res.affected_rows or 0) < 5000 then break end
    end
    return dropped, deleted
end

local function maintenance(premature)
    if premature then return end
    local ok, err = pcall(function()
        local d = db()
        d.query("BEGIN")
        -- One pod at a time; the lock ends with the transaction even on error.
        local ok_run, run_err = pcall(function()
            if d.query("SELECT pg_try_advisory_xact_lock(hashtext('opsapi.user_activity.maintenance')) AS l")[1].l then
                UserActivity.ensurePartitions()
                local dropped, deleted = UserActivity.applyRetention()
                if dropped > 0 or deleted > 0 then
                    ngx.log(ngx.NOTICE, "[user-activity] retention: dropped ", dropped, " partition(s), deleted ",
                        deleted, " auth event(s)")
                end
            end
        end)
        d.query(ok_run and "COMMIT" or "ROLLBACK")
        if not ok_run then error(run_err, 0) end
    end)
    release_connection()
    if not ok then ngx.log(ngx.ERR, "[user-activity] maintenance failed: ", tostring(err)) end
end

-- Same value on every pod (read from the database): graph with max(), not sum().
local function active_users(premature)
    if premature then return end
    local ok, err = pcall(function()
        local r = db().query([[
            SELECT COUNT(*) FILTER (WHERE last_seen_at > NOW() - interval '5 minutes')::int AS m5,
                   COUNT(*) FILTER (WHERE last_seen_at > NOW() - interval '1 hour')::int AS h1,
                   COUNT(*)::int AS d1
            FROM user_login_stats WHERE last_seen_at > NOW() - interval '24 hours'
        ]])[1]
        local g = metric("active_users")
        if g then
            g:set(r.m5, { "5m" })
            g:set(r.h1, { "1h" })
            g:set(r.d1, { "24h" })
        end
    end)
    release_connection()
    if not ok then ngx.log(ngx.ERR, "[user-activity] active users gauge failed: ", tostring(err)) end
end

--- Start the per-worker timers (nginx.conf init_worker_by_lua).
function UserActivity.start()
    if not ENABLED then return end
    ngx.timer.every(FLUSH_SECONDS, flush)
    if ngx.worker.id() == 0 then
        ngx.timer.at(5, maintenance)
        ngx.timer.every(MAINTENANCE_SECONDS, maintenance)
        ngx.timer.at(10, active_users)
        ngx.timer.every(60, active_users)
    end
end

return UserActivity
