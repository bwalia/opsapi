-- Personal follow-ups (step 2). A follow-up is a task on the lead worked by the `lead_followup` agent: it
-- reads the lead's newest news (Companies House, a captured post) and recent replies and drafts ONE short,
-- personal message (email, WhatsApp or SMS). The draft is an approval: nothing reaches the lead until a
-- person approves it (executor: send_lead_followup). Leads who opted out are never drafted to.
--   * on demand: POST /leads/{id}/follow-up { channel?, signal_uuid?, note? }
--   * automatic: when the Companies House watch finds news for a lead with an owner (setting
--     followup_auto_on_news, default on, needs an AI provider), at most one open follow-up per lead.
local db = require("lapis.db")
local U = require("property_deals.util")

local F = {}

F.CHANNELS = { email = true, whatsapp = true, sms = true }

local function null(v) return v == nil or v == db.NULL end

local function lead_row(ns, lead_uuid)
    return U.one([[
        SELECT l.uuid, l.first_name, l.last_name, l.company_name, l.email, l.phone, l.owner_user_uuid,
               d.vulnerability_flag, d.opted_out_at
        FROM crm_leads l LEFT JOIN property_deals_lead_details d ON d.lead_uuid = l.uuid
        WHERE l.namespace_id = ? AND l.uuid = ? AND l.deleted_at IS NULL
    ]], ns, lead_uuid)
end

local function open_followup(ns, lead_uuid)
    return U.one([[
        SELECT task_uuid, pd_status FROM property_deals_task_details
        WHERE namespace_id = ? AND lead_uuid = ? AND agent_key = 'lead_followup'
          AND pd_status NOT IN ('done', 'cancelled') LIMIT 1
    ]], ns, lead_uuid)
end

--- Start a follow-up draft. @return { task_uuid, run_uuid?, status } | nil, error, http status
function F.start(ns, lead_uuid, opts)
    opts = opts or {}
    local lead = lead_row(ns, lead_uuid)
    if not lead then return nil, "Lead not found", 404 end
    if not null(lead.opted_out_at) then return nil, "This lead asked not to be contacted", 409 end
    local channel = opts.channel or "email"
    if not F.CHANNELS[channel] then return nil, "channel must be email, whatsapp or sms", 422 end
    if channel == "email" and null(lead.email) then return nil, "The lead has no email address", 422 end
    if channel ~= "email" and null(lead.phone) then return nil, "The lead has no phone number", 422 end
    if opts.signal_uuid and not U.one([[SELECT 1 FROM property_deals_lead_signals
            WHERE namespace_id = ? AND lead_uuid = ? AND uuid = ?]], ns, lead.uuid, opts.signal_uuid) then
        return nil, "That news item isn't on this lead", 422
    end
    local Tasks = require("property_deals.tasks")
    local existing = open_followup(ns, lead.uuid)
    local task_uuid
    if existing then
        if existing.pd_status == "agent_running" or existing.pd_status == "awaiting_approval" then
            return nil, "A follow-up for this lead is already being drafted or waiting for approval", 409
        end
        task_uuid = existing.task_uuid
        db.query([[UPDATE property_deals_task_details SET metadata = metadata || ?::jsonb, updated_at = NOW()
            WHERE namespace_id = ? AND task_uuid = ?]], require("cjson").encode({ channel = channel,
            signal_uuid = opts.signal_uuid, note = opts.note }), ns, task_uuid)
    else
        local owner = not null(lead.owner_user_uuid) and lead.owner_user_uuid or opts.actor
            or require("property_deals.engine").managers(ns)[1]
        local name = ((null(lead.first_name) and "" or lead.first_name) .. " " .. (null(lead.last_name) and "" or lead.last_name))
            :gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then name = not null(lead.company_name) and lead.company_name or "lead" end
        local task = U.tx(function()
            require("property_deals.workspace").ensure(ns, owner, opts.settings)
            return Tasks.create(ns, {
                title = "Follow up " .. name .. " (" .. channel .. ")", lead_uuid = lead.uuid, owner_user_uuid = owner,
                priority = "medium", agent_eligible = true, agent_key = "lead_followup",
                -- Vulnerable people: a manager reads every word first.
                approval_rule = lead.vulnerability_flag == true and "manager" or "any_operator",
                metadata = { kind = "lead_followup", channel = channel, signal_uuid = opts.signal_uuid, note = opts.note },
            }, opts.actor or owner)
        end)
        task_uuid = task.task_uuid
    end
    local run, err, status = require("property_deals.ai.runner").start(ns, task_uuid,
        { trigger = opts.trigger or "manual", actor = opts.actor, sync = opts.sync })
    if not run then return { task_uuid = task_uuid, status = "todo", error = err }, nil, status end
    return { task_uuid = task_uuid, run_uuid = run.uuid, status = run.status }
end

--- Leads with fresh news -> a follow-up draft each (no open follow-up, not opted out, has an owner).
function F.auto(ns, lead_uuids, settings)
    settings = settings or require("helper.plugin-sdk").settings("property_deals", ns) or {}
    if settings.followup_auto_on_news == false then return 0 end
    -- No model, no drafts: don't leave empty follow-up tasks behind.
    if #require("property_deals.ai.config").route(ns, "draft").chain == 0 then return 0 end
    local started = 0
    for _, lead_uuid in ipairs(lead_uuids or {}) do
        local lead = lead_row(ns, lead_uuid)
        if lead and null(lead.opted_out_at) and not null(lead.owner_user_uuid) and not open_followup(ns, lead_uuid) then
            local channel = not null(lead.email) and "email" or (not null(lead.phone) and "whatsapp") or nil
            if channel then
                local ok, r = pcall(F.start, ns, lead_uuid, { channel = channel, trigger = "news", settings = settings })
                if ok and r and r.run_uuid then started = started + 1 end
            end
        end
    end
    return started
end

--- Opt-out: cancel follow-ups still waiting (drafting or awaiting approval).
function F.cancel_pending(ns, lead_uuid, why)
    local tasks = db.query([[
        SELECT task_uuid FROM property_deals_task_details WHERE namespace_id = ? AND lead_uuid = ?
          AND agent_key = 'lead_followup' AND pd_status NOT IN ('done', 'cancelled')
    ]], ns, lead_uuid)
    for _, t in ipairs(tasks) do
        db.query([[UPDATE property_deals_approvals SET status = 'cancelled', updated_at = NOW()
            WHERE namespace_id = ? AND task_uuid = ? AND status = 'pending']], ns, t.task_uuid)
        require("property_deals.tasks").update(ns, t.task_uuid, { pd_status = "cancelled" }, nil)
        require("property_deals.approvals").comment(ns, t.task_uuid, why, nil)
    end
    return #tasks
end

return F
