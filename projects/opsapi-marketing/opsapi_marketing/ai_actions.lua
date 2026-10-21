-- Audit log for AI marketing proposals. Execution always requires a human path.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("opsapi_marketing.util")

local A = {}

function A.record(ns, opts)
    opts = opts or {}
    local row = db.query([[
        INSERT INTO mkt_ai_actions
            (namespace_id, user_uuid, agent, action, status, input_summary, output_summary,
             campaign_uuid, contact_uuid, requires_approval)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING *
    ]], ns, opts.user_uuid, opts.agent or "marketing", opts.action or "propose",
        opts.status or "proposed",
        opts.input_summary and tostring(opts.input_summary):sub(1, 2000) or nil,
        opts.output_summary and tostring(opts.output_summary):sub(1, 4000) or nil,
        opts.campaign_uuid, opts.contact_uuid,
        opts.requires_approval ~= false)[1]
    return row
end

function A.list(ns, limit)
    return db.query([[
        SELECT * FROM mkt_ai_actions WHERE namespace_id = ?
        ORDER BY created_at DESC LIMIT ?
    ]], ns, math.min(tonumber(limit) or 50, 200))
end

function A.summarise(obj)
    local ok, s = pcall(cjson.encode, obj)
    return ok and s or tostring(obj)
end

return A
