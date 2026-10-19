-- Web terminal (workstation-terminal / sshweb) linked to a kanban task.
-- Launch posts a comment with terminal + repo + PR links; webhook updates session status.
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)
local db = require("lapis.db")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")
local V = require("ai_runner.vault_pr")

local T = {}

T.DEFAULT_URL = "https://dev.workstation.co.uk"

function T.base_url()
    local u = os.getenv("WORKSTATION_TERMINAL_URL")
    if type(u) == "string" and u:match("^https?://") then
        return u:gsub("%s+", ""):gsub("/+$", "")
    end
    return T.DEFAULT_URL
end

function T.webhook_secret()
    local s = os.getenv("WORKSTATION_TERMINAL_WEBHOOK_SECRET")
    if type(s) == "string" and s ~= "" then return s end
end

local function to_hex(bytes)
    local t = {}
    for i = 1, #bytes do t[i] = string.format("%02x", string.byte(bytes, i)) end
    return table.concat(t)
end

--- HMAC-SHA256 hex of body with the shared webhook secret.
function T.sign(body)
    local secret = T.webhook_secret()
    if not secret then return nil, "WORKSTATION_TERMINAL_WEBHOOK_SECRET is not set" end
    -- Prefer resty.hmac (works in more contexts); fall back to openssl.
    local ok_rh, resty_hmac = pcall(require, "resty.hmac")
    if ok_rh and resty_hmac then
        local h = resty_hmac:new(secret, resty_hmac.ALGOS.SHA256)
        if h and h:update(body) then
            local dig = h:final()
            if dig then return to_hex(dig) end
        end
    end
    local ok, hmac = pcall(require, "resty.openssl.hmac")
    if not ok or not hmac then return nil, "hmac unavailable" end
    local h, err = hmac.new(secret, "sha256")
    if not h then return nil, err or "hmac init failed" end
    if not h:update(body) then return nil, "hmac update failed" end
    local dig = h:final()
    if not dig then return nil, "hmac final failed" end
    return to_hex(dig)
end

function T.verify_signature(body, header)
    if type(header) ~= "string" or header == "" then return false end
    local got = header:match("^[Ss]ha256=(%x+)$") or header:match("^(%x+)$")
    if not got then return false end
    local expect, err = T.sign(body)
    if not expect then
        ngx.log(ngx.WARN, "[ai_runner] terminal webhook sign: ", tostring(err))
        return false
    end
    if #got ~= #expect then return false end
    -- Byte-wise compare (webhook secret; constant-time not required).
    for i = 1, #expect do
        if string.byte(expect, i) ~= string.byte(got, i) then return false end
    end
    return true
end

local function repo_for_task(ns, task)
    local W = require("ai_runner.task_work")
    local latest = W.latest(ns, task.uuid)
    local snap = latest and U.json(latest.context_snapshot) or {}
    if type(snap) == "table" and type(snap.target_repo_url) == "string" and snap.target_repo_url ~= "" then
        return snap.target_repo_url
    end
    local ps = R.project_settings(ns, task.project_uuid)
    if type(ps.target_repo_url) == "string" and ps.target_repo_url ~= "" then
        return ps.target_repo_url
    end
end

local function build_deep_link(task, ns_slug, repo_url)
    local base = T.base_url()
    local q = {
        "opsapi_task=" .. ngx.escape_uri(task.uuid),
        "opsapi_ns=" .. ngx.escape_uri(tostring(ns_slug or "")),
        "return=" .. ngx.escape_uri(R.task_url(task.project_uuid, task.uuid)),
    }
    if repo_url and repo_url ~= "" then
        q[#q + 1] = "repo=" .. ngx.escape_uri(repo_url)
    end
    return base .. "/?" .. table.concat(q, "&")
end

local function comment_links(task, terminal_url, repo_url, prs)
    local lines = {
        "Web terminal opened for this task:",
        terminal_url,
        "",
        "Back to task: " .. R.task_url(task.project_uuid, task.uuid),
    }
    if repo_url and repo_url ~= "" then
        lines[#lines + 1] = "Repo: " .. repo_url
    end
    if type(prs) == "table" and #prs > 0 then
        lines[#lines + 1] = "Pull requests:"
        for _, p in ipairs(prs) do
            if p.pr_url then lines[#lines + 1] = "- " .. p.pr_url end
        end
    end
    return table.concat(lines, "\n")
end

--- Launch: insert row, comment, return view.
function T.launch(ns, task, user_uuid, ns_slug)
    local repo_url = repo_for_task(ns, task)
    local terminal_url = build_deep_link(task, ns_slug, repo_url)
    local row = db.insert("ar_terminal_sessions", {
        namespace_id = ns,
        task_uuid = task.uuid,
        project_uuid = task.project_uuid,
        opened_by = user_uuid or db.NULL,
        terminal_url = terminal_url,
        repo_url = repo_url or db.NULL,
        status = "launched",
    }, { returning = "*" })[1]
    local prs = V.list_for_task(ns, task.uuid)
    pcall(function()
        require("queries.KanbanTaskQueries").addComment({
            task_id = task.id, user_uuid = user_uuid,
            content = comment_links(task, terminal_url, repo_url, prs),
        })
    end)
    T.ensure_poll_timer()
    return row
end

function T.list_for_task(ns, task_uuid)
    return db.query([[SELECT * FROM ar_terminal_sessions WHERE namespace_id = ? AND task_uuid = ?
        ORDER BY created_at DESC, id DESC LIMIT 50]], ns, task_uuid)
end

function T.view(s)
    if not s then return nil end
    return {
        uuid = s.uuid, task_uuid = s.task_uuid, project_uuid = s.project_uuid,
        opened_by = U.null(s.opened_by), terminal_url = s.terminal_url,
        session_id = U.null(s.session_id), repo_url = U.null(s.repo_url),
        status = s.status, started_at = U.null(s.started_at), ended_at = U.null(s.ended_at),
        created_at = s.created_at, updated_at = s.updated_at,
    }
end

local function resume_url(session_id)
    local base = T.base_url()
    if session_id and session_id ~= "" then
        return base .. "/?session=" .. ngx.escape_uri(session_id)
    end
    return base
end

--- Webhook from sshweb: session_start | session_end.
function T.apply_webhook(payload)
    local event = payload.event
    local session_id = type(payload.session_id) == "string" and payload.session_id or nil
    local task_uuid = type(payload.opsapi_task) == "string" and payload.opsapi_task or nil
    if not session_id or not U.is_uuid(task_uuid or "") then
        return nil, "session_id and opsapi_task (uuid) required"
    end
    if event ~= "session_start" and event ~= "session_end" then
        return nil, "unknown event"
    end
    local row = U.one([[SELECT s.*, t.id AS task_id FROM ar_terminal_sessions s
        JOIN kanban_tasks t ON t.uuid = s.task_uuid
        WHERE s.task_uuid = ? ORDER BY s.created_at DESC, s.id DESC LIMIT 1]], task_uuid)
    if not row then
        -- Create a row if the developer opened the deep link without clicking OpsAPI first.
        local task = U.one([[
            SELECT t.id, t.uuid, p.uuid AS project_uuid, p.namespace_id
            FROM kanban_tasks t
            JOIN kanban_boards b ON b.id = t.board_id
            JOIN kanban_projects p ON p.id = b.project_id
            WHERE t.uuid = ? AND t.deleted_at IS NULL
        ]], task_uuid)
        if not task then return nil, "task not found" end
        row = db.insert("ar_terminal_sessions", {
            namespace_id = task.namespace_id,
            task_uuid = task.uuid,
            project_uuid = task.project_uuid,
            terminal_url = resume_url(session_id),
            session_id = session_id,
            status = event == "session_end" and "ended" or "active",
            started_at = db.raw("NOW()"),
            ended_at = event == "session_end" and db.raw("NOW()") or db.NULL,
        }, { returning = "*" })[1]
        row.task_id = task.id
    else
        local task_id = row.task_id
        if event == "session_start" then
            row = U.one([[UPDATE ar_terminal_sessions SET session_id = ?, status = 'active',
                started_at = COALESCE(started_at, NOW()), updated_at = NOW()
                WHERE id = ? RETURNING *]], session_id, row.id)
        else
            row = U.one([[UPDATE ar_terminal_sessions SET session_id = COALESCE(session_id, ?),
                status = 'ended', ended_at = NOW(), updated_at = NOW()
                WHERE id = ? RETURNING *]], session_id, row.id)
        end
        row.task_id = task_id
    end

    local link = resume_url(session_id)
    local text = event == "session_start"
        and ("Terminal session active: " .. link)
        or ("Terminal session ended: " .. link)
    if row.task_id then
        pcall(function()
            require("queries.KanbanTaskQueries").addComment({
                task_id = row.task_id, user_uuid = row.opened_by,
                content = text,
            })
        end)
    end
    return row
end

local poll_started = false
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
