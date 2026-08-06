--[[
    Domain Pipeline Run Queries
    ===========================

    CRUD + step-state helpers for domain_pipeline_runs. The orchestrator
    (helper/domain-pipeline.lua) mutates a run's steps as it advances.
]]

local DomainPipelineRunModel = require("models.DomainPipelineRunModel")
local Global = require("helper.global")
local cjson = require("cjson")
local db = require("lapis.db")

local DomainPipelineRunQueries = {}

-- Decode the steps jsonb into a Lua array (defensive).
local function decode_steps(row)
    if not row then return row end
    if type(row.steps) == "string" then
        local ok, decoded = pcall(cjson.decode, row.steps)
        row.steps = ok and decoded or {}
    end
    return row
end
DomainPipelineRunQueries.decode_steps = decode_steps

function DomainPipelineRunQueries.create(params)
    params.uuid = params.uuid or Global.generateUUID()
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")
    if type(params.steps) == "table" then
        params.steps = cjson.encode(params.steps)
    end
    return DomainPipelineRunModel:create(params, { returning = "*" })
end

function DomainPipelineRunQueries.get(uuid)
    local rows = db.query("SELECT * FROM domain_pipeline_runs WHERE uuid = ? LIMIT 1", uuid)
    return decode_steps(rows and rows[1] or nil)
end

function DomainPipelineRunQueries.list(namespace_id, limit)
    local rows = db.query([[
        SELECT * FROM domain_pipeline_runs
        WHERE namespace_id = ?
        ORDER BY created_at DESC
        LIMIT ?
    ]], namespace_id, tonumber(limit) or 20)
    for _, r in ipairs(rows or {}) do decode_steps(r) end
    return rows or {}
end

-- Full update by uuid. `patch` may include steps (Lua table → encoded).
function DomainPipelineRunQueries.update(uuid, patch)
    local run = DomainPipelineRunModel:find({ uuid = uuid })
    if not run then return nil end
    if type(patch.steps) == "table" then
        patch.steps = cjson.encode(patch.steps)
    end
    patch.updated_at = db.raw("NOW()")
    return run:update(patch, { returning = "*" })
end

return DomainPipelineRunQueries
