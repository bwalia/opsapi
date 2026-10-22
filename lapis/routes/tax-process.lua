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

local function getUserId(user)
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user.uuid or user.id)
    return rows and rows[1] and rows[1].id
end

local function set_status(id, status)
    db.update("tax_statements", { processing_status = status, updated_at = db.raw("NOW()") }, { id = id })
end

-- Authenticated internal call to an existing tax endpoint, AS the user.
local function internal(method, path, body, auth, port)
    local httpc = http.new()
    httpc:set_timeout(300000) -- classify runs the LLM per transaction
    local res = httpc:request_uri("http://127.0.0.1:" .. (port or 80) .. path, {
        method = method,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded", ["Authorization"] = auth },
        body = body,
    })
    return res
end

-- Background worker: process each statement in turn (extract then classify).
local function process_all(premature, job)
    if premature then return end
    for _, s in ipairs(job.statements) do
        local ok, err = pcall(function()
            ngx.log(ngx.INFO, "[tax-process] extracting ", s.uuid)
            set_status(s.id, "EXTRACTING")
            local r1 = internal("POST", "/api/v2/tax/extract", "statement_id=" .. s.uuid, job.auth, job.port)
            if not r1 or r1.status >= 400 then error("extract HTTP " .. tostring(r1 and r1.status)) end
            ngx.log(ngx.INFO, "[tax-process] classifying ", s.uuid, " (extract HTTP ", r1.status, ")")
            set_status(s.id, "CLASSIFYING")
            local r2 = internal("POST", "/api/v2/tax/classify", "statement_id=" .. s.uuid, job.auth, job.port)
            if not r2 or r2.status >= 400 then error("classify HTTP " .. tostring(r2 and r2.status)) end
            ngx.log(ngx.INFO, "[tax-process] completed ", s.uuid, " (classify HTTP ", r2.status, ")")
            set_status(s.id, "COMPLETED")
        end)
        if not ok then
            ngx.log(ngx.ERR, "[tax-process] statement ", s.uuid, " failed: ", tostring(err))
            set_status(s.id, "ERROR")
        end
    end
end

return function(app)
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

        local statements = {}
        for _, ident in ipairs(ids) do
            local rows = db.query(
                "SELECT id, uuid FROM tax_statements WHERE (uuid = ? OR id::text = ?) AND user_id = ? LIMIT 1",
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

        local ok = ngx.timer.at(0, process_all, {
            statements = statements,
            auth = self.req.headers["authorization"],
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
