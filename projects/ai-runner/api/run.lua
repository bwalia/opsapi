-- Run-token API (docs/AI_RUNNER.md §23.2): what the agent itself may do, through the run's MCP server
-- (promptpilot run-mcp). No user session: under public/, authenticated by the run token
-- ("Authorization: Bearer oprt_<48 hex>", minted at claim, stored as a SHA-256 hash). It reaches its own run's task
-- and nothing else, and only while the run is open; plugin off in the workspace -> 404.
--   GET  /public/run/task       the task and its 20 latest comments
--   POST /public/run/comments   { text <= 4000 } -> a comment on the task as the requester, prefixed "[AI run] "
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")

-- Lookup by hash, like the runner token. @return run, task
local function auth()
    local h = ngx.req.get_headers()["authorization"]
    if type(h) == "table" then h = h[1] end
    local raw = type(h) == "string" and h:match("^%s*[Bb]earer%s+(oprt_%x+)%s*$")
    if not raw or #raw ~= 53 then U.fail(401, "Unauthorized") end
    local run = U.one([[SELECT r.id, r.uuid, r.namespace_id, r.task_uuid, r.requested_by, n.status AS ns_status
        FROM ar_runs r JOIN namespaces n ON n.id = r.namespace_id
        WHERE r.run_token_hash = ? AND r.status IN ]] .. R.OPEN_SQL, U.sha256(raw))
    if not run then U.fail(401, "Unauthorized") end
    R.require_plugin(run.ns_status, run.namespace_id)
    local task = R.task(run.namespace_id, run.task_uuid)
    if not task then U.fail(404, "Task not found") end
    return run, task
end

return function(app)
    app:get("/public/run/task", sdk.handler({ namespace = false }, U.guard(function()
        local _, task = auth()
        local comments = db.query([[
            SELECT c.content AS text, c.created_at AS at, ]] .. R.name_sql("u") .. [[ AS author_name
            FROM kanban_task_comments c LEFT JOIN users u ON u.uuid = c.user_uuid
            WHERE c.task_id = ? AND c.deleted_at IS NULL ORDER BY c.created_at DESC, c.id DESC LIMIT 20
        ]], task.id)
        local oldest_first = {}
        for i = #comments, 1, -1 do
            local c = comments[i]
            oldest_first[#oldest_first + 1] = { author_name = U.null(c.author_name), text = U.null(c.text), at = c.at }
        end
        return sdk.ok({
            uuid = task.uuid, task_number = U.null(task.task_number), title = task.title,
            description = U.null(task.description), checklist = R.checklist(task.id), status = U.null(task.status),
            priority = U.null(task.priority), url = R.task_url(task.project_uuid, task.uuid),
            project = { uuid = task.project_uuid, name = task.project_name }, comments = U.array(oldest_first),
        })
    end)))

    app:post("/public/run/comments", sdk.handler({ namespace = false }, U.guard(function(self)
        local run, task = auth()
        local b, err = sdk.body(self)
        if not b then U.fail(400, err) end
        local d, errors = sdk.validate(b, { text = { type = "text", required = true, max = 4000 } })
        if not d then U.invalid(errors) end
        local c = require("queries.KanbanTaskQueries").addComment({ task_id = task.id, user_uuid = run.requested_by,
            content = "[AI run] " .. U.redact(U.clean(d.text)) })
        return sdk.created({ uuid = c.uuid, text = c.content, at = c.created_at })
    end)))
end
