-- Poll GitHub for ar_task_prs state (open / merged / closed) and comment on change.
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)
local db = require("lapis.db")
local U = require("ai_runner.util")
local V = require("ai_runner.vault_pr")
local R = require("ai_runner.runs")

local P = {}

P.THROTTLE_S = 60

local function map_gh_state(data)
    if type(data) ~= "table" then return nil end
    if data.merged == true or data.merged_at then return "merged" end
    if data.state == "closed" then return "closed" end
    if data.state == "open" then return "open" end
end

local function token_for_pr(ns, pr)
    local ps = R.project_settings(ns, pr.project_uuid)
    if ps and ps.vault_configured ~= false then
        local tok, err = V.fetch_github_token(ps)
        if tok then return tok end
        if err then ngx.log(ngx.DEBUG, "[ai_runner] pr_poll vault: ", tostring(err)) end
    end
end

local function comment_state(task_id, user_uuid, pr, new_state)
    local label = new_state == "merged" and "merged"
        or new_state == "closed" and "closed"
        or new_state
    pcall(function()
        require("queries.KanbanTaskQueries").addComment({
            task_id = task_id, user_uuid = user_uuid,
            content = "PR #" .. tostring(pr.pr_number or "?") .. " is now " .. label
                .. " on GitHub.\n" .. tostring(pr.pr_url),
        })
    end)
end

--- Refresh one PR row. @return updated row or nil, err
function P.refresh_one(pr)
    if not pr or not pr.pr_number or not pr.repo or pr.repo == "" then return nil, "incomplete pr" end
    if pr.state == "merged" or pr.state == "closed" then return pr end
    local tok = token_for_pr(pr.namespace_id, pr)
    if not tok then return nil, "no github token" end
    local client = V.repo_with_token(pr.repo, tok)
    local data, status, err = client:call("GET", "/pulls/" .. tostring(pr.pr_number))
    if not data then return nil, err or ("github " .. tostring(status)) end
    local new_state = map_gh_state(data)
    if not new_state then return nil, "unrecognised github state" end
    db.query([[UPDATE ar_task_prs SET github_state_checked_at = NOW(), updated_at = NOW()
        WHERE id = ?]], pr.id)
    if new_state == pr.state then return pr end
    local row = U.one([[UPDATE ar_task_prs SET state = ?, github_state_checked_at = NOW(),
        updated_at = NOW() WHERE id = ? RETURNING *]], new_state, pr.id)
    local task = U.one("SELECT id FROM kanban_tasks WHERE uuid = ?", pr.task_uuid)
    if task then
        comment_state(task.id, pr.reviewed_by or nil, row or pr, new_state)
    end
    return row or pr
end

--- Throttled refresh for every open PR on a task (used by GET .../work).
function P.refresh_task(ns, task_uuid)
    local cache = ngx.shared and ngx.shared.cache
    local key = "ar:pr_poll:" .. tostring(ns) .. ":" .. tostring(task_uuid)
    if cache and cache:get(key) then return end
    if cache then cache:set(key, true, P.THROTTLE_S) end
    local rows = db.query([[SELECT * FROM ar_task_prs WHERE namespace_id = ? AND task_uuid = ?
        AND state NOT IN ('merged', 'closed') ORDER BY id ASC LIMIT 20]], ns, task_uuid)
    for _, pr in ipairs(rows) do
        local ok, err = pcall(P.refresh_one, pr)
        if not ok then ngx.log(ngx.WARN, "[ai_runner] pr_poll task: ", tostring(err)) end
    end
end

--- Background tick: a batch of open PRs across workspaces.
function P.tick()
    local rows = db.query([[SELECT * FROM ar_task_prs
        WHERE state NOT IN ('merged', 'closed')
          AND (github_state_checked_at IS NULL OR github_state_checked_at < NOW() - INTERVAL '3 minutes')
        ORDER BY COALESCE(github_state_checked_at, '1970-01-01') ASC, id ASC
        LIMIT 25]])
    for _, pr in ipairs(rows) do
        local ok, err = pcall(P.refresh_one, pr)
        if not ok then ngx.log(ngx.WARN, "[ai_runner] pr_poll tick: ", tostring(err)) end
    end
end

return P
