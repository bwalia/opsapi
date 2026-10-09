-- Data retention (SPEC §4): per-workspace settings, run nightly (jobs/nightly.lua).
local db = require("lapis.db")

local Ret = {}

local function days(v, default) return math.max(30, math.floor(tonumber(v) or default)) end

function Ret.run(ns, settings)
    settings = settings or {}
    local inbound = db.query([[
        UPDATE property_deals_inbound_messages SET body_text = NULL
        WHERE namespace_id = ? AND body_text IS NOT NULL AND received_at < NOW() - make_interval(days => ?) RETURNING id
    ]], ns, days(settings.retention_inbound_days, 365))
    local runs = db.query([[
        UPDATE property_deals_agent_runs SET input_snapshot = '{}', steps = '[]', output = NULL, output_draft = NULL
        WHERE namespace_id = ? AND created_at < NOW() - make_interval(days => ?)
          AND (output_draft IS NOT NULL OR output IS NOT NULL OR steps <> '[]'::jsonb) RETURNING id
    ]], ns, days(settings.retention_agent_run_days, 365))
    local market = db.query([[
        DELETE FROM property_deals_market_records m
        WHERE m.namespace_id = ? AND m.fetched_at < NOW() - make_interval(days => ?)
          AND NOT EXISTS (SELECT 1 FROM property_deals_scout_alerts a WHERE a.market_record_uuid = m.uuid AND a.seen_at IS NULL)
        RETURNING m.id
    ]], ns, math.max(90, math.floor(tonumber(settings.retention_market_days) or 730)))
    return { inbound = #inbound, agent_runs = #runs, market = #market }
end

return Ret
