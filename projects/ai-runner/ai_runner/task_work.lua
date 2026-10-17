-- Durable AI work record on a kanban task: prompt, context, executor, conversation summary,
-- linked run. Written on every Start (even pending_approval / queued with no machine online).
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)
local db = require("lapis.db")
local U = require("ai_runner.util")

local W = {}

local STATUS_MAP = {
    pending_approval = "pending_approval",
    queued = "queued",
    claimed = "running",
    running = "running",
    needs_input = "needs_input",
    cancelling = "running",
    succeeded = "succeeded",
    failed = "failed",
    cancelled = "cancelled",
    lost = "lost",
}

function W.from_run_status(s)
    return STATUS_MAP[s] or s or "started"
end

--- Upsert the latest work row for this task (keeps history: new row per start).
function W.record(ns, task, run, snap, opts)
    opts = opts or {}
    local summary = opts.conversation_summary
    local row = db.insert("ar_task_work", {
        namespace_id = ns,
        task_uuid = task.uuid,
        project_uuid = task.project_uuid,
        run_uuid = run.uuid,
        status = W.from_run_status(run.status),
        executor_kind = run.executor_kind or opts.executor_kind or "machine",
        provider_uuid = run.provider_uuid or opts.provider_uuid or db.NULL,
        prompt = run.prompt or "",
        prompt_sha256 = run.prompt_sha256 or U.sha256(run.prompt or ""),
        context_snapshot = type(snap) == "string" and snap or cjson.encode(snap or {}),
        conversation_summary = summary or db.NULL,
        summary = run.summary or db.NULL,
        requested_by = run.requested_by or db.NULL,
    }, { returning = "*" })[1]
    return row
end

--- Mirror run status / summary / conversation onto the matching work row.
function W.sync_run(run, extras)
    extras = extras or {}
    local set = {
        status = W.from_run_status(run.status),
        summary = run.summary or db.NULL,
        updated_at = db.raw("NOW()"),
    }
    if extras.conversation_summary ~= nil then
        set.conversation_summary = extras.conversation_summary
    end
    if run.executor_kind then set.executor_kind = run.executor_kind end
    db.query("UPDATE ar_task_work SET " .. db.encode_assigns(set) .. " WHERE run_uuid = "
        .. db.escape_literal(run.uuid))
end

--- Build a short conversation summary from recent turns (for the task panel).
function W.summarize_turns(ns, run_uuid, limit)
    limit = limit or 12
    local turns = db.query([[
        SELECT role, left(text, 400) AS text FROM ar_run_turns
        WHERE namespace_id = ? AND run_uuid = ? ORDER BY seq DESC LIMIT ?
    ]], ns, run_uuid, limit)
    if #turns == 0 then return nil end
    local lines = {}
    for i = #turns, 1, -1 do
        local t = turns[i]
        lines[#lines + 1] = (t.role == "user" and "User: " or "Agent: ") .. tostring(t.text or "")
    end
    return table.concat(lines, "\n\n"):sub(1, 8000)
end

function W.latest(ns, task_uuid)
    return U.one([[SELECT * FROM ar_task_work WHERE namespace_id = ? AND task_uuid = ?
        ORDER BY created_at DESC, id DESC LIMIT 1]], ns, task_uuid)
end

function W.list(ns, task_uuid)
    return db.query([[SELECT * FROM ar_task_work WHERE namespace_id = ? AND task_uuid = ?
        ORDER BY created_at DESC, id DESC LIMIT 20]], ns, task_uuid)
end

function W.view(w)
    if not w then return nil end
    return {
        uuid = w.uuid, task_uuid = w.task_uuid, project_uuid = w.project_uuid,
        run_uuid = U.null(w.run_uuid), status = w.status, executor_kind = w.executor_kind,
        provider_uuid = U.null(w.provider_uuid), prompt = w.prompt,
        prompt_sha256 = U.null(w.prompt_sha256),
        context_snapshot = U.json(w.context_snapshot) or {},
        conversation_summary = U.null(w.conversation_summary),
        summary = U.null(w.summary), requested_by = U.null(w.requested_by),
        created_at = w.created_at, updated_at = w.updated_at,
    }
end

return W
