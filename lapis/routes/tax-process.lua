--[[
    Background statement processing for the tax agent.

    The chat uploads statements, then calls POST /statements/process which runs
    extract + classify for each one in a SERVER-SIDE background worker (ngx.timer),
    so it keeps going if the user reloads, navigates away or closes the tab. The UI
    polls GET /statements/process-status to show live per-statement progress.

    Reuses the existing (tested) /tax/extract and /tax/classify endpoints via
    authenticated internal calls, rather than re-implementing the pipeline.

    processing_status lifecycle: QUEUED -> EXTRACTING -> CLASSIFYING -> COMPLETED | ERROR.
    ponytail: ngx.timer is fine for a handful of statements per user; move to a job
    queue if this ever needs to survive nginx reloads or run at scale.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local http = require("resty.http")
local AuthMiddleware = require("middleware.auth")
local JWTHelper = require("helper.jwt-helper")

local function getUserId(user)
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user.uuid or user.id)
    return rows and rows[1] and rows[1].id
end

local function set_status(id, status)
    db.update("tax_statements", { processing_status = status, updated_at = db.raw("NOW()") }, { id = id })
end

-- Add a line to the tax-agent chat this upload came from, so it survives a reload
-- (and the model sees that statements were uploaded / processed). Best-effort.
local function session_note(session, role, content, quick_replies)
    if not session then return end
    pcall(db.query, [[INSERT INTO tax_agent_messages
        (uuid, session_id, namespace_id, user_id, role, content, quick_replies)
        VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?)]],
        session.id, session.namespace_id, session.user_id, role, content,
        quick_replies and db.raw(db.escape_literal(cjson.encode(quick_replies)) .. "::jsonb") or db.NULL)
    pcall(db.query, "UPDATE tax_agent_sessions SET updated_at = NOW() WHERE id = ?", session.id)
end

local function plural(n) return n == 1 and "" or "s" end

-- The Authorization header for one internal call. A job for a year of statements can
-- run for hours on a slow model, far past the user's 1-hour access token, so a JWT
-- caller gets a fresh 15-minute token re-signed from the identity verified when the
-- job started. API keys (opsk_...) don't expire and are passed through unchanged.
local function auth_for(job)
    if job.jwt_payload then
        local tok = JWTHelper.reissue(job.jwt_payload, 900)
        if tok then return "Bearer " .. tok end
    end
    return job.auth
end

-- Authenticated internal call to an existing tax endpoint, AS the user.
local function internal(method, path, body, auth, port)
    local httpc = http.new()
    -- classify runs the model per transaction; nobody waits on this background job, so the
    -- budget follows the model speed (TAX_PROCESS_TIMEOUT_MS, default 30 min per statement step).
    httpc:set_timeout(tonumber(os.getenv("TAX_PROCESS_TIMEOUT_MS") or "") or 1800000)
    local res = httpc:request_uri("http://127.0.0.1:" .. (port or 80) .. path, {
        method = method,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded", ["Authorization"] = auth },
        body = body,
    })
    return res
end

-- Property income keys (the chat's uk_property and My Income's rental/overseas types).
local PROPERTY_TYPES = { uk_property = true, rental = true, overseas_property = true, foreign_property = true }

--- The classifier profile to use for this upload, or nil to leave it to the classifier.
-- The classifier falls back to "sole_trader" when the user has no saved profile, which
-- files a landlord's rents as other income and their repairs as equipment repairs. When
-- the File My Tax chat already knows the income is property only, classify as a
-- landlord. A profile the user saved themselves always wins, so we only fill the gap.
-- @param session table|nil  tax_agent_sessions row with income_types
-- @param user_id number
local function classify_profile(session, user_id)
    if not session then return nil end
    local types = session.income_types
    if type(types) == "string" then
        local ok, t = pcall(cjson.decode, types)
        types = ok and t or nil
    end
    if type(types) ~= "table" or #types == 0 then return nil end
    for _, t in ipairs(types) do
        if not PROPERTY_TYPES[tostring(t)] then return nil end
    end
    local ok, rows = pcall(db.select,
        "default_profile_key FROM tax_user_profiles WHERE user_id = ? LIMIT 1", user_id)
    if ok and rows and rows[1] and rows[1].default_profile_key and rows[1].default_profile_key ~= "" then
        return nil
    end
    return "landlord"
end

-- Background worker: process each statement in turn (extract then classify).
local function process_all(premature, job)
    if premature then return end
    local failed = 0
    for _, s in ipairs(job.statements) do
        local ok, err = pcall(function()
            ngx.log(ngx.INFO, "[tax-process] extracting ", s.uuid)
            set_status(s.id, "EXTRACTING")
            local r1 = internal("POST", "/api/v2/tax/extract", "statement_id=" .. s.uuid, auth_for(job), job.port)
            if not r1 or r1.status >= 400 then error("extract HTTP " .. tostring(r1 and r1.status)) end
            ngx.log(ngx.INFO, "[tax-process] classifying ", s.uuid, " (extract HTTP ", r1.status, ")")
            set_status(s.id, "CLASSIFYING")
            local body = "statement_id=" .. s.uuid
            if job.profile_type then body = body .. "&profile_type=" .. job.profile_type end
            local r2 = internal("POST", "/api/v2/tax/classify", body, auth_for(job), job.port)
            if not r2 or r2.status >= 400 then error("classify HTTP " .. tostring(r2 and r2.status)) end
            ngx.log(ngx.INFO, "[tax-process] completed ", s.uuid, " (classify HTTP ", r2.status, ")")
            set_status(s.id, "COMPLETED")
        end)
        if not ok then
            ngx.log(ngx.ERR, "[tax-process] statement ", s.uuid, " failed: ", tostring(err))
            set_status(s.id, "ERROR")
            failed = failed + 1
        end
    end
    local n = #job.statements
    if failed == 0 then
        session_note(job.session, "assistant",
            "✅ Your statement" .. plural(n) .. (n == 1 and " is" or " are")
            .. " processed and categorised. Want to see your tax estimate?", { "Show my estimate" })
    else
        session_note(job.session, "assistant", ("⚠️ I processed %d of %d statement%s — %d couldn't be read. "
            .. "Try uploading %s again, or use Tax → Statements."):format(n - failed, n, plural(n), failed,
            failed == 1 and "it" or "them"))
    end
end

local M = setmetatable({ _classify_profile = classify_profile }, {
    __call = function(_, app) return M.register(app) end,
})

function M.register(app)
    local function parse_body()
        local ok, result = pcall(function()
            ngx.req.read_body()
            local b = ngx.req.get_body_data()
            if not b or b == "" then return {} end
            return cjson.decode(b)
        end)
        return (ok and type(result) == "table") and result or {}
    end

    -- Kick off background processing for a set of uploaded statements.
    app:post("/api/v2/tax/statements/process", AuthMiddleware.requireAuth(function(self)
        local user_id = getUserId(self.current_user)
        if not user_id then return { status = 401, json = { error = "User not found" } } end

        local data = parse_body()
        local raw = data.statement_ids or self.params.statement_ids or ""
        local ids = {}
        if type(raw) == "table" then
            for _, v in ipairs(raw) do ids[#ids + 1] = tostring(v) end
        else
            for v in tostring(raw):gmatch("[^,]+") do ids[#ids + 1] = (v:gsub("^%s+", ""):gsub("%s+$", "")) end
        end
        if #ids == 0 then return { status = 400, json = { error = "statement_ids is required" } } end

        -- Stamp the filing year onto these statements so the tax tools (which scope by
        -- tax_year) see them. Only a well-formed YYYY-YY, only when not already set.
        local tax_year = tostring(data.tax_year or self.params.tax_year or "")
        if not tax_year:match("^%d%d%d%d%-%d%d$") then tax_year = nil end

        -- The tax-agent chat this upload came from (optional; must be the caller's own).
        local session
        local sid = tostring(data.session_id or self.params.session_id or "")
        if sid ~= "" then
            session = db.query([[SELECT id, namespace_id, user_id, income_types FROM tax_agent_sessions
                WHERE uuid = ? AND user_id = ? LIMIT 1]], sid, user_id)[1]
        end

        local statements = {}
        for _, ident in ipairs(ids) do
            local rows = db.query(
                "SELECT id, uuid, file_name FROM tax_statements WHERE (uuid = ? OR id::text = ?) AND user_id = ? LIMIT 1",
                ident, ident, user_id)
            if rows and rows[1] then
                statements[#statements + 1] = rows[1]
                set_status(rows[1].id, "QUEUED")
                if tax_year then
                    db.query([[UPDATE tax_statements SET tax_year = ?
                        WHERE id = ? AND (tax_year IS NULL OR tax_year = '')]], tax_year, rows[1].id)
                end
            end
        end
        if #statements == 0 then return { status = 404, json = { error = "No matching statements for this user" } } end

        if session then
            local names = {}
            for _, s in ipairs(statements) do names[#names + 1] = s.file_name or "statement" end
            local n = #statements
            session_note(session, "user", ("📎 Uploaded %d statement%s: %s"):format(n, plural(n), table.concat(names, ", ")))
            session_note(session, "assistant", ("Got %d statement%s. I'm reading and categorising the transactions "
                .. "now — this keeps running in the background, so you can reload or leave this page and come back.")
                :format(n, plural(n)))
        end

        -- Keep the verified identity so the worker can mint fresh tokens (see auth_for).
        local auth = self.req.headers["authorization"]
        local raw = type(auth) == "string" and auth:match("^[Bb]earer%s+(.+)$")
        local jwt_payload
        if raw and not raw:match("^opsk_") then
            local v = JWTHelper.verifyToken(raw)
            if v.valid then jwt_payload = v.payload end
        end
        local ok = ngx.timer.at(0, process_all, {
            statements = statements,
            session = session,
            auth = auth,
            jwt_payload = jwt_payload,
            profile_type = classify_profile(session, user_id),
            port = tonumber(ngx.var.server_port) or 80,
        })
        if not ok then
            for _, s in ipairs(statements) do set_status(s.id, "ERROR") end
            return { status = 503, json = { error = "Could not start processing. Please try again." } }
        end
        return { status = 202, json = { success = true, data = { queued = #statements } } }
    end))

    -- Live status of the user's in-progress statements (for the UI progress card).
    app:get("/api/v2/tax/statements/process-status", AuthMiddleware.requireAuth(function(self)
        local user_id = getUserId(self.current_user)
        if not user_id then return { status = 401, json = { error = "User not found" } } end
        local rows = db.query([[
            SELECT s.uuid, s.file_name, s.processing_status,
                   (SELECT count(*) FROM tax_transactions t WHERE t.statement_id = s.id) AS transaction_count,
                   (SELECT count(*) FROM tax_transactions t WHERE t.statement_id = s.id
                        AND t.classification_status <> 'PENDING') AS classified_count
            FROM tax_statements s
            WHERE s.user_id = ? AND s.processing_status IN ('QUEUED','EXTRACTING','CLASSIFYING','PROCESSING')
            ORDER BY s.id ASC]], user_id)
        return { status = 200, json = { success = true, data = rows or {} } }
    end))
end

return M
