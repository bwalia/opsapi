-- JobShout executor for AI Runner: launch a remote JobShout workflow with the rendered
-- prompt + skills context, then poll / record the run id on ar_runs.
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)
local db = require("lapis.db")
local U = require("ai_runner.util")

local J = {}

local function provider_row(ns, provider_uuid)
    if not U.is_uuid(provider_uuid) then return nil end
    return U.one([[SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?
        AND provider_type = 'jobshout' AND enabled = true]], ns, provider_uuid)
end

--- First enabled JobShout provider in the workspace (when no uuid given).
function J.default_provider(ns)
    return U.one([[SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND provider_type = 'jobshout'
        AND enabled = true ORDER BY updated_at DESC NULLS LAST, id DESC LIMIT 1]], ns)
end

--- Start a JobShout run for an AI Runner run that is queued with executor_kind=jobshout.
function J.start(run)
    local ns = run.namespace_id
    local row = provider_row(ns, run.provider_uuid) or J.default_provider(ns)
    if not row then
        db.query([[UPDATE ar_runs SET status = 'failed', finished_at = NOW(), error_category = 'config',
            error = ?, updated_at = NOW() WHERE id = ?]],
            "No JobShout AI provider is configured for this workspace", run.id)
        return nil, "no jobshout provider"
    end
    local snap = U.json(run.context_snapshot) or {}
    local skill_slugs = {}
    for _, s in ipairs(type(snap.skills_git_urls) == "table" and snap.skills_git_urls or {}) do
        if type(s.label) == "string" and s.label ~= "" then
            skill_slugs[#skill_slugs + 1] = s.label
        end
    end
    local JobShout = require("lib.jobshout-client")
    -- Prefer run_task when a JobShout task id was stored as profile; else launch.
    local agent_id = run.profile
    local data, err
    if run.model and tostring(run.model):match("^%d+$") then
        data, err = JobShout.run_task(ns, row, tonumber(run.model), {
            agent_id = agent_id, prompt = run.prompt,
            context = { task_uuid = run.task_uuid, run_uuid = run.uuid, skills = snap.skills_git_urls,
                md_refs = snap.md_refs, target_repo = snap.target_repo_url },
            skill_slugs = skill_slugs,
        })
    else
        data, err = JobShout.launch(ns, row, {
            agent_id = agent_id,
            values = {
                prompt = run.prompt, opsapi_run_uuid = run.uuid, opsapi_task_uuid = run.task_uuid,
                skills = cjson.encode(snap.skills_git_urls or {}),
                target_repo = snap.target_repo_url or "",
            },
        })
    end
    if not data then
        db.query([[UPDATE ar_runs SET status = 'failed', finished_at = NOW(), error_category = 'executor',
            error = ?, updated_at = NOW() WHERE id = ?]],
            U.clean(tostring(err or "JobShout launch failed"), 1000), run.id)
        return nil, err
    end
    local jid = data.id or data.run_id or (type(data.run) == "table" and data.run.id)
        or (type(data.data) == "table" and (data.data.id or data.data.run_id))
    db.query([[UPDATE ar_runs SET status = 'running', started_at = COALESCE(started_at, NOW()),
        claimed_at = COALESCE(claimed_at, NOW()), provider_uuid = ?, jobshout_run_id = ?,
        updated_at = NOW() WHERE id = ?]], row.uuid, jid and tostring(jid) or db.NULL, run.id)
    return true
end

--- Poll one JobShout-backed run; on terminal status sync summary and try vault PR attach.
function J.poll(run)
    if not run.jobshout_run_id then return end
    local ns = run.namespace_id
    local row = provider_row(ns, run.provider_uuid) or J.default_provider(ns)
    if not row then return end
    local data, err = require("lib.jobshout-client").run(ns, row, run.jobshout_run_id)
    if not data then
        ngx.log(ngx.WARN, "[ai_runner] jobshout poll ", run.uuid, ": ", tostring(err))
        return
    end
    local status = tostring(data.status or (data.run and data.run.status) or ""):lower()
    local summary = data.summary or data.result or (data.run and data.run.summary)
    local pr_url = data.pr_url or (data.run and data.run.pr_url)
    if status == "succeeded" or status == "completed" or status == "success" then
        local R = require("ai_runner.runs")
        db.query([[UPDATE ar_runs SET status = 'succeeded', finished_at = COALESCE(finished_at, NOW()),
            summary = COALESCE(?, summary), pr_url = COALESCE(?, pr_url), updated_at = NOW() WHERE id = ?]],
            summary and U.clean(tostring(summary), 8000) or db.NULL,
            type(pr_url) == "string" and pr_url or db.NULL, run.id)
        local updated = U.one("SELECT * FROM ar_runs WHERE id = ?", run.id)
        R.automate(updated, "on_success")
        require("ai_runner.task_work").sync_run(updated, {
            conversation_summary = require("ai_runner.task_work").summarize_turns(ns, updated.uuid),
        })
        pcall(require("ai_runner.vault_pr").open_or_attach, updated, { pr_url = updated.pr_url })
        R.notify(updated)
    elseif status == "failed" or status == "error" or status == "cancelled" then
        db.query([[UPDATE ar_runs SET status = ?, finished_at = COALESCE(finished_at, NOW()),
            error_category = 'executor', error = ?, updated_at = NOW() WHERE id = ?]],
            status == "cancelled" and "cancelled" or "failed",
            U.clean(tostring(data.error or data.message or status), 1000), run.id)
        local updated = U.one("SELECT * FROM ar_runs WHERE id = ?", run.id)
        require("ai_runner.task_work").sync_run(updated)
        require("ai_runner.runs").notify(updated)
    end
end

--- Kick queued JobShout runs (called from on_queued / a light job).
function J.kick(ns)
    local rows = db.query([[SELECT * FROM ar_runs WHERE namespace_id = ? AND executor_kind = 'jobshout'
        AND status = 'queued' ORDER BY created_at ASC LIMIT 5]], ns)
    for _, run in ipairs(rows) do
        local ok, err = pcall(J.start, run)
        if not ok then ngx.log(ngx.ERR, "[ai_runner] jobshout start: ", tostring(err)) end
    end
    local running = db.query([[SELECT * FROM ar_runs WHERE namespace_id = ? AND executor_kind = 'jobshout'
        AND status = 'running' AND jobshout_run_id IS NOT NULL ORDER BY updated_at ASC LIMIT 10]], ns)
    for _, run in ipairs(running) do
        local ok, err = pcall(J.poll, run)
        if not ok then ngx.log(ngx.ERR, "[ai_runner] jobshout poll: ", tostring(err)) end
    end
end

return J
