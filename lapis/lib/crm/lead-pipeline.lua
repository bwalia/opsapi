--[[
    Lead pipeline: the service layer (docs/plans/LEAD_TO_CASH_PIPELINE.md §4)
    =========================================================================

    Everything a lead goes through, independent of HTTP:

      after_created  a new lead (any source) gets its history, a duplicate
                     check, an owner, a first call due within the response
                     time, a notification, and an AI analysis queued.
                     Idempotent: the event outbox may deliver twice.
      move           stage changes with rules + history (lead-stages.lua)
      assign         owner changes; auto_assign = rules, then round-robin
      set_next_step  the one thing to do next, as a planned activity
      log_call       a call and its outcome; plans the next attempt
      list / board / funnel / my_steps / timeline   the read side

    Calls and meetings are crm_activities rows linked by lead_id, so they
    follow the lead onto its deal at conversion. Where the CRM tables don't
    exist the next step is kept on the lead itself.

    Errors: nil, { status, code, message, fields } (lib/crm/util.lua).
]]

local db = require("lapis.db")
local cjson = require("cjson")
local U = require("lib.crm.util")
local Stages = require("lib.crm.lead-stages")
local Settings = require("lib.crm.lead-settings")
local WH = require("lib.crm.working-hours")

local P = {}

P.CALL_OUTCOMES = {
    connected = "Spoke to them", no_answer = "No answer", voicemail = "Left a message",
    wrong_number = "Wrong number", callback = "Call back later", not_interested = "Not interested",
}
P.STEP_TYPES = { call = true, email = true, follow_up = true, meeting = true, task = true }

local OWNER_JOIN = [[
    LEFT JOIN users ou ON ou.uuid = l.owner_user_uuid
]]
local OWNER_COLS = [[
    NULLIF(TRIM(CONCAT(ou.first_name, ' ', ou.last_name)), '') AS owner_name, ou.email AS owner_email
]]

-- ---------------------------------------------------------------------------
-- Reading one lead
-- ---------------------------------------------------------------------------

function P.find(ns, uuid, opts)
    if type(uuid) ~= "string" or uuid == "" or #uuid > 64 then return nil end
    return U.one("SELECT * FROM crm_leads WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL"
        .. ((opts and opts.lock) and " FOR UPDATE" or ""), ns, uuid)
end

--- One lead for the API: owner, conversion links, latest analysis, labels.
function P.get(ns, uuid, settings)
    local sel = "SELECT l.*, " .. OWNER_COLS
    local joins = OWNER_JOIN
    if U.crm() then
        sel = sel .. [[, cc.uuid AS converted_contact_uuid, cd.uuid AS converted_deal_uuid, cd.name AS converted_deal_name,
            cd.value AS converted_deal_value, cd.currency AS converted_deal_currency]]
        joins = joins .. [[
            LEFT JOIN crm_contacts cc ON cc.id = l.converted_contact_id
            LEFT JOIN crm_deals cd ON cd.id = l.converted_deal_id
        ]]
    end
    local lead = U.one(sel .. " FROM crm_leads l " .. joins
        .. " WHERE l.namespace_id = ? AND l.uuid = ? AND l.deleted_at IS NULL", ns, uuid)
    if not lead then return nil end
    return P.present(lead, settings or Settings.get(ns))
end

--- Decorate a row for the API (labels, decoded JSON, the latest analysis).
function P.present(lead, settings, opts)
    local labels = Stages.labels(settings and settings.stage_labels)
    lead.stage = lead.status
    lead.stage_label = labels[lead.status] or lead.status
    lead.metadata = U.json(lead.metadata, {})
    if type(lead.metadata) ~= "table" or lead.metadata[1] ~= nil then lead.metadata = {} end
    lead.qualification = U.json(lead.qualification, {})
    if type(lead.qualification) ~= "table" or lead.qualification[1] ~= nil then lead.qualification = {} end
    lead.is_open = Stages.is_open(lead.status)
    if not (opts and opts.light) then
        local a = U.one([[
            SELECT uuid, status, trigger, result, error, provider_name, model, cost_usd, requested_by_uuid,
                   finished_at, created_at
            FROM crm_lead_analyses WHERE lead_id = ? ORDER BY created_at DESC LIMIT 1
        ]], lead.id)
        if a then a.result = U.json(a.result, cjson.null) end
        lead.analysis = a or cjson.null
    end
    return lead
end

-- ---------------------------------------------------------------------------
-- History, next steps
-- ---------------------------------------------------------------------------

local function history(ns, lead_id, from, to, actor, reason)
    db.query([[
        INSERT INTO crm_lead_stage_history (namespace_id, lead_id, from_status, to_status, changed_by_uuid, reason)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], ns, lead_id, from or db.NULL, to, actor or db.NULL, reason or db.NULL)
end

--- Re-point the lead's next step at its earliest planned activity (CRM), and
-- reset the overdue warnings when the due time changed.
function P.refresh_next_action(lead_id)
    if not U.crm() then return end
    db.query([[
        WITH nxt AS (
            SELECT a.activity_type, ]] .. U.ACTIVITY_AT .. [[ AS due, COALESCE(a.subject, '') AS note
            FROM crm_activities a
            WHERE a.lead_id = ? AND a.status = 'planned' AND a.deleted_at IS NULL
            ORDER BY a.activity_date ASC LIMIT 1
        )
        UPDATE crm_leads l SET
            next_action_type = (SELECT activity_type FROM nxt),
            next_action_at = (SELECT due FROM nxt),
            next_action_note = (SELECT note FROM nxt),
            next_action_warned_at = CASE WHEN l.next_action_at IS NOT DISTINCT FROM (SELECT due FROM nxt)
                THEN l.next_action_warned_at ELSE NULL END,
            next_action_escalated_at = CASE WHEN l.next_action_at IS NOT DISTINCT FROM (SELECT due FROM nxt)
                THEN l.next_action_escalated_at ELSE NULL END,
            updated_at = NOW()
        WHERE l.id = ?
    ]], lead_id, lead_id)
end

local function step_subject(kind, lead)
    local who = U.full_name(lead.first_name, lead.last_name) or U.nz(lead.email) or "the lead"
    local verbs = { call = "Call ", email = "Email ", follow_up = "Follow up with ", meeting = "Meeting with ",
        task = "Task for " }
    return (verbs[kind] or "Follow up with ") .. who
end

--- Plan the next step (a planned activity on the lead). Within a transaction
-- the caller already holds the lead row.
-- @param step { type, due_at (UTC ISO), note?, owner_user_uuid? }
function P.plan_step(ns, lead, actor, step)
    if not U.crm() then
        db.query([[UPDATE crm_leads SET next_action_type = ?, next_action_at = ?::timestamptz, next_action_note = ?,
            next_action_warned_at = NULL, next_action_escalated_at = NULL, updated_at = NOW() WHERE id = ?]],
            step.type, step.due_at, step.note or db.NULL, lead.id)
        return nil
    end
    local owner = step.owner_user_uuid or U.nz(lead.owner_user_uuid) or actor
    local row = db.query([[
        INSERT INTO crm_activities (uuid, namespace_id, lead_id, activity_type, subject, description, activity_date,
            owner_user_uuid, status, metadata, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ]] .. U.TO_ACTIVITY_DATE .. [[, ?, 'planned', ?::jsonb, NOW(), NOW())
        RETURNING *
    ]], require("helper.global").generateUUID(), ns, lead.id, step.type, step.subject or step_subject(step.type, lead),
        step.note or db.NULL, step.due_at, owner or db.NULL, U.enc({ planned_by = actor or "system",
            attempt = step.attempt }))[1]
    P.refresh_next_action(lead.id)
    return row
end

--- Cancel the lead's planned steps (lead lost / parked).
local function cancel_planned(lead_id, why)
    if not U.crm() then
        db.query([[UPDATE crm_leads SET next_action_type = NULL, next_action_at = NULL, next_action_note = NULL
            WHERE id = ?]], lead_id)
        return
    end
    db.query([[
        UPDATE crm_activities SET status = 'cancelled', cancelled_at = NOW(), updated_at = NOW(),
            metadata = (CASE WHEN jsonb_typeof(metadata) = 'object' THEN metadata ELSE '{}'::jsonb END) || jsonb_build_object('cancelled_because', ?::text)
        WHERE lead_id = ? AND status = 'planned' AND deleted_at IS NULL AND activity_type <> 'meeting'
    ]], why, lead_id)
    P.refresh_next_action(lead_id)
end

-- ---------------------------------------------------------------------------
-- Stage moves
-- ---------------------------------------------------------------------------

--- Move a lead to another stage.
-- @param opts { reason?, nurture_until? (YYYY-MM-DD), system? }
function P.move(ns, uuid, to, actor, opts)
    opts = opts or {}
    local target = Stages.normalise(to)
    if not target then return U.fail(422, "LEAD_STAGE_INVALID", "Unknown stage", { stage = "unknown stage" }) end
    local settings = Settings.get(ns)
    return U.tx(function()
        local lead = P.find(ns, uuid, { lock = true })
        if not lead then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        local ok, code, message = Stages.can_move(lead.status, target)
        if not ok then return U.fail(code == "same_stage" and 409 or 422, "LEAD_" .. code:upper(), message) end

        local set = { status = target, stage_changed_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }
        local reason = U.text(opts.reason, 200)
        if target == "lost" then
            if not reason then
                return U.fail(422, "LEAD_LOST_REASON", "Say why the lead was lost", { reason = "required" })
            end
            set.lost_reason, set.lost_at = reason, db.raw("NOW()")
        elseif target == "nurture" then
            local d = U.date(opts.nurture_until)
            if not d then
                return U.fail(422, "LEAD_NURTURE_DATE", "Pick the date to contact them again", { nurture_until = "YYYY-MM-DD" })
            end
            if not U.one("SELECT ?::date > CURRENT_DATE AS ok", d).ok then
                return U.fail(422, "LEAD_NURTURE_DATE", "Pick a date after today", { nurture_until = "after today" })
            end
            set.nurture_until = d
        end
        if Stages.is_open(target) then
            set.lost_reason, set.lost_at, set.nurture_until = db.NULL, db.NULL, db.NULL
        end
        db.update("crm_leads", set, { id = lead.id })
        history(ns, lead.id, lead.status, target, actor, reason)

        if target == "lost" or target == "nurture" then
            cancel_planned(lead.id, target)
        elseif Stages.PARKED[lead.status] and Stages.is_open(target) then
            -- Back from nurture/lost: someone should call them again.
            P.plan_step(ns, lead, actor, { type = "call",
                due_at = WH.due_at(settings.working_hours, settings.first_response_minutes) })
        end
        return P.find(ns, uuid)
    end)
end

-- ---------------------------------------------------------------------------
-- Owners
-- ---------------------------------------------------------------------------

--- Give the lead to `owner_uuid` (nil = back to the unassigned queue).
-- Planned steps follow the new owner.
function P.assign(ns, uuid, owner_uuid, actor, opts)
    local Access = require("lib.crm.lead-access")
    if owner_uuid ~= nil and not Access.worker(ns, owner_uuid) then
        return U.fail(422, "LEAD_OWNER_INVALID", "That person can't work leads in this workspace",
            { owner_user_uuid = "must be an active member who can work leads" })
    end
    local lead, err = U.tx(function()
        local lead = P.find(ns, uuid, { lock = true })
        if not lead then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        if U.nz(lead.owner_user_uuid) == owner_uuid then return lead end
        db.update("crm_leads", {
            owner_user_uuid = owner_uuid or db.NULL,
            assigned_at = owner_uuid and db.raw("NOW()") or db.NULL,
            updated_at = db.raw("NOW()"),
        }, { id = lead.id })
        if U.crm() and owner_uuid then
            db.query([[UPDATE crm_activities SET owner_user_uuid = ?, updated_at = NOW()
                WHERE lead_id = ? AND status = 'planned' AND deleted_at IS NULL]], owner_uuid, lead.id)
        end
        lead._previous_owner = U.nz(lead.owner_user_uuid)
        lead.owner_user_uuid = owner_uuid
        -- An open lead with nothing planned (e.g. from before the pipeline existed) gets a first call,
        -- so the new owner sees what to do next.
        if owner_uuid and Stages.is_open(lead.status) and U.null(lead.next_action_at) then
            local settings = Settings.get(ns)
            P.plan_step(ns, lead, actor, { type = "call", attempt = 1,
                due_at = WH.due_at(settings.working_hours, settings.first_response_minutes) })
        end
        return lead
    end)
    if not lead then return nil, err end
    if owner_uuid and owner_uuid ~= actor and not (opts and opts.quiet) then
        local name = U.full_name(lead.first_name, lead.last_name) or U.nz(lead.email) or "A lead"
        require("lib.crm.lead-notify").send(ns, { owner_uuid }, {
            kind = "assigned", lead_uuid = lead.uuid, title = "Lead assigned to you: " .. name,
            body = (U.nz(lead.company_name) and (lead.company_name .. " · ") or "") .. "Open it to see the next step.",
        })
    end
    return P.find(ns, uuid)
end

local function rule_matches(rule, lead)
    local c = U.json(rule.conditions, {})
    local function in_list(list, value)
        if type(list) ~= "table" or #list == 0 then return true end
        value = type(value) == "string" and value:lower() or ""
        for _, v in ipairs(list) do if type(v) == "string" and v:lower() == value then return true end end
        return false
    end
    if not in_list(c.sources, lead.source) then return false end
    if not in_list(c.channels, lead.channel) then return false end
    if not in_list(c.campaigns, lead.campaign) then return false end
    if type(c.keywords) == "table" and #c.keywords > 0 then
        local hay = table.concat({ U.nz(lead.notes) or "", U.nz(lead.company_name) or "", U.nz(lead.job_title) or "" },
            " "):lower()
        local hit = false
        for _, k in ipairs(c.keywords) do
            if type(k) == "string" and k ~= "" and hay:find(k:lower(), 1, true) then hit = true break end
        end
        if not hit then return false end
    end
    return true
end

-- Next person after `last` in `pool` (sorted, so the order is stable).
local function next_in(pool, last)
    table.sort(pool)
    for i, u in ipairs(pool) do
        if u == last then return pool[(i % #pool) + 1] end
    end
    return pool[1]
end

-- Only people who can still work leads stay in a pool.
local function eligible(ns, uuids)
    local out = {}
    for _, u in ipairs(uuids or {}) do
        if require("lib.crm.lead-access").worker(ns, u) then out[#out + 1] = u end
    end
    return out
end

--- Pick an owner for an unassigned lead: the first enabled rule that
-- matches (a person, or round-robin in its pool), else round-robin in the
-- workspace pool. @return owner uuid, how | nil
function P.pick_owner(ns, lead, settings)
    for _, rule in ipairs(db.query([[SELECT * FROM crm_lead_assignment_rules WHERE namespace_id = ? AND enabled
        ORDER BY position, id]], ns)) do
        if rule_matches(rule, lead) then
            local person = U.nz(rule.assignee_user_uuid)
            if person and require("lib.crm.lead-access").worker(ns, person) then return person, "rule:" .. rule.name end
            local pool = eligible(ns, U.json(rule.pool, {}))
            if #pool > 0 then
                local locked = U.one("SELECT rr_last_user_uuid FROM crm_lead_assignment_rules WHERE id = ? FOR UPDATE", rule.id)
                local pick = next_in(pool, locked and U.nz(locked.rr_last_user_uuid))
                db.query("UPDATE crm_lead_assignment_rules SET rr_last_user_uuid = ? WHERE id = ?", pick, rule.id)
                return pick, "rule:" .. rule.name
            end
        end
    end
    local pool = #settings.round_robin_user_uuids > 0 and eligible(ns, settings.round_robin_user_uuids) or {}
    if #pool == 0 then
        -- ponytail: everyone who can work leads, read per lead; cache per tick if workspaces get large.
        for _, w in ipairs(require("lib.crm.lead-access").workers(ns)) do pool[#pool + 1] = w.uuid end
    end
    if #pool == 0 then return nil end
    db.query("INSERT INTO crm_lead_settings (namespace_id) VALUES (?) ON CONFLICT DO NOTHING", ns)
    local row = U.one("SELECT rr_last_user_uuid FROM crm_lead_settings WHERE namespace_id = ? FOR UPDATE", ns)
    local pick = next_in(pool, row and U.nz(row.rr_last_user_uuid))
    db.query("UPDATE crm_lead_settings SET rr_last_user_uuid = ? WHERE namespace_id = ?", pick, ns)
    return pick, "round_robin"
end

-- ---------------------------------------------------------------------------
-- A new lead (any source): run once per lead from the event outbox
-- ---------------------------------------------------------------------------

function P.after_created(ns, uuid)
    local lead = P.find(ns, uuid)
    if not lead then return true end                          -- deleted before we got to it
    local meta = U.json(lead.metadata, {})
    if meta.pipeline_started then return true end
    if not Stages.is_open(lead.status) then return true end   -- created already converted/lost (imports)
    local settings = Settings.get(ns)

    local done = U.tx(function()
        lead = P.find(ns, uuid, { lock = true })
        if not lead then return false end
        if #db.query("SELECT 1 FROM crm_lead_stage_history WHERE lead_id = ? LIMIT 1", lead.id) == 0 then
            history(ns, lead.id, nil, lead.status, nil, "created")
        end
        -- Possible duplicate: another open lead with the same email or phone. Flagged, never merged.
        local dup = U.one([[
            SELECT uuid FROM crm_leads
            WHERE namespace_id = ? AND id <> ? AND deleted_at IS NULL AND status IN ('new','contacting','qualified','meeting','nurture')
              AND ((? <> '' AND lower(email) = lower(?)) OR (? <> '' AND phone = ?))
            ORDER BY created_at LIMIT 1
        ]], ns, lead.id, U.nz(lead.email) or "", U.nz(lead.email) or "", U.nz(lead.phone) or "", U.nz(lead.phone) or "")
        local patch = { pipeline_started = true }
        if dup then patch.duplicate_of = dup.uuid end
        if settings.auto_assign and not U.nz(lead.owner_user_uuid) then
            local owner, how = P.pick_owner(ns, lead, settings)
            if owner then
                db.update("crm_leads", { owner_user_uuid = owner, assigned_at = db.raw("NOW()") }, { id = lead.id })
                lead.owner_user_uuid = owner
                patch.assigned_by = how
            end
        elseif U.nz(lead.owner_user_uuid) and U.null(lead.assigned_at) then
            db.update("crm_leads", { assigned_at = db.raw("NOW()") }, { id = lead.id })
        end
        if lead.status == "new" and (not U.crm() or #db.query(
            "SELECT 1 FROM crm_activities WHERE lead_id = ? AND status = 'planned' AND deleted_at IS NULL LIMIT 1", lead.id) == 0) then
            P.plan_step(ns, lead, nil, { type = "call", attempt = 1,
                due_at = WH.due_at(settings.working_hours, settings.first_response_minutes) })
        end
        db.query("UPDATE crm_leads SET metadata = (CASE WHEN jsonb_typeof(metadata) = 'object' THEN metadata ELSE '{}'::jsonb END) || ?::jsonb, updated_at = NOW() WHERE id = ?",
            U.enc(patch), lead.id)
        return true
    end)
    if not done then return true end

    if settings.ai_enabled then
        local ok, err = pcall(require("lib.crm.lead-ai").enqueue, ns, lead.id, "created")
        if not ok then ngx.log(ngx.WARN, "[crm-leads] AI enqueue: ", tostring(err)) end
    end

    lead = P.find(ns, uuid) or lead
    local Notify = require("lib.crm.lead-notify")
    local name = U.full_name(lead.first_name, lead.last_name) or U.nz(lead.email) or "New lead"
    local from = U.nz(lead.source) and (" from " .. tostring(lead.source):gsub("_", " ")) or ""
    local due = ""
    if not U.null(lead.next_action_at) then
        local ok, row = pcall(U.one, "SELECT to_char(?::timestamptz AT TIME ZONE ?, 'Dy DD Mon HH24:MI') AS t",
            lead.next_action_at, settings.working_hours.timezone)
        if ok and row then due = " Call them by " .. row.t .. "." end
    end
    if U.nz(lead.owner_user_uuid) then
        Notify.send(ns, { lead.owner_user_uuid }, { kind = "new_lead", lead_uuid = lead.uuid,
            title = "New lead: " .. name, body = "A new lead" .. from .. " is yours." .. due })
    else
        Notify.send(ns, require("lib.crm.lead-access").managers(ns, settings), { kind = "new_lead_unassigned",
            lead_uuid = lead.uuid, title = "New lead waiting: " .. name,
            body = "Nobody has this lead yet" .. from .. ". Give it to someone or take it." .. due })
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------

--- Log a call and plan what comes next.
-- @param c { outcome, notes?, duration_minutes?, next_at? (callback / follow-up), lost_reason? }
-- @return { lead, activity, next_step?, suggestion? } | nil, err
function P.log_call(ns, uuid, actor, c)
    if not U.crm() then return U.fail(409, "LEAD_CRM_OFF", "Calls need the CRM module in this deployment") end
    local outcome = type(c.outcome) == "string" and c.outcome or ""
    if not P.CALL_OUTCOMES[outcome] then
        return U.fail(422, "LEAD_CALL_OUTCOME", "Pick how the call went", { outcome = "one of the listed outcomes" })
    end
    local notes = U.text(c.notes, 4000)
    local duration = c.duration_minutes ~= nil and tonumber(c.duration_minutes) or nil
    if duration and (duration < 0 or duration > 600) then
        return U.fail(422, "LEAD_CALL_DURATION", "Call length must be 0 to 600 minutes", { duration_minutes = "0 to 600" })
    end
    local next_at = c.next_at ~= nil and U.timestamp(c.next_at) or nil
    if c.next_at ~= nil and c.next_at ~= cjson.null and c.next_at ~= "" and not next_at then
        return U.fail(422, "LEAD_CALL_NEXT", "The next call time isn't a valid date and time", { next_at = "ISO date-time" })
    end
    if outcome == "callback" and not next_at then
        return U.fail(422, "LEAD_CALL_NEXT", "When should we call them back?", { next_at = "required for a call back" })
    end
    if next_at and not U.one("SELECT ?::timestamptz > NOW() AS ok", next_at).ok then
        return U.fail(422, "LEAD_CALL_NEXT", "The next call must be in the future", { next_at = "in the future" })
    end
    local settings = Settings.get(ns)
    local result, err = U.tx(function()
        local lead = P.find(ns, uuid, { lock = true })
        if not lead then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        if lead.status == "converted" then
            return U.fail(409, "LEAD_CONVERTED", "This lead is converted. Log calls on its deal.")
        end
        local label = P.CALL_OUTCOMES[outcome]
        local planned = U.one([[
            SELECT id FROM crm_activities WHERE lead_id = ? AND activity_type = 'call' AND status = 'planned'
              AND deleted_at IS NULL ORDER BY activity_date ASC LIMIT 1 FOR UPDATE
        ]], lead.id)
        local activity
        if planned then
            activity = db.query([[
                UPDATE crm_activities SET status = 'completed', completed_at = NOW(), outcome = ?,
                    description = CONCAT_WS(E'\n\n', NULLIF(description, ''), ?::text),
                    duration_minutes = COALESCE(?, duration_minutes), owner_user_uuid = COALESCE(?, owner_user_uuid),
                    updated_at = NOW()
                WHERE id = ? RETURNING *
            ]], outcome, notes or db.NULL, duration or db.NULL, actor or db.NULL, planned.id)[1]
        else
            activity = db.query([[
                INSERT INTO crm_activities (uuid, namespace_id, lead_id, activity_type, subject, description,
                    activity_date, duration_minutes, owner_user_uuid, status, completed_at, outcome, metadata,
                    created_at, updated_at)
                VALUES (?, ?, ?, 'call', ?, ?, (NOW() AT TIME ZONE 'UTC'), ?, ?, 'completed', NOW(), ?, '{}'::jsonb, NOW(), NOW())
                RETURNING *
            ]], require("helper.global").generateUUID(), ns, lead.id, step_subject("call", lead) .. " — " .. label,
                notes or db.NULL, duration or db.NULL, actor or db.NULL, outcome)[1]
        end

        db.query([[
            UPDATE crm_leads SET contact_attempts = contact_attempts + 1,
                first_contacted_at = COALESCE(first_contacted_at, NOW()), last_contacted_at = NOW(), updated_at = NOW()
            WHERE id = ?
        ]], lead.id)
        local attempts = (tonumber(lead.contact_attempts) or 0) + 1
        if lead.status == "new" then
            db.update("crm_leads", { status = "contacting", stage_changed_at = db.raw("NOW()") }, { id = lead.id })
            history(ns, lead.id, "new", "contacting", actor, "first call")
            lead.status = "contacting"
        end

        local next_step, suggestion
        if outcome == "not_interested" and lead.status ~= "lost" then
            local reason = U.text(c.lost_reason, 200) or "Not interested"
            db.update("crm_leads", { status = "lost", lost_reason = reason, lost_at = db.raw("NOW()"),
                stage_changed_at = db.raw("NOW()") }, { id = lead.id })
            history(ns, lead.id, lead.status, "lost", actor, reason)
            cancel_planned(lead.id, "lost")
        elseif next_at then
            next_step = P.plan_step(ns, lead, actor, { type = "call", due_at = next_at, attempt = attempts + 1 })
        elseif outcome == "no_answer" or outcome == "voicemail" then
            local plan = settings.attempt_plan_hours
            local delay = plan[attempts]
            if delay then
                next_step = P.plan_step(ns, lead, actor, { type = "call", attempt = attempts + 1,
                    due_at = WH.due_at(settings.working_hours, math.floor(delay * 60 + 0.5)) })
            else
                suggestion = { action = "nurture", message = "No answer after " .. attempts
                    .. " calls. Move them to Nurture, or email them instead." }
            end
        elseif outcome == "wrong_number" then
            db.query("UPDATE crm_leads SET metadata = (CASE WHEN jsonb_typeof(metadata) = 'object' THEN metadata ELSE '{}'::jsonb END) || '{\"wrong_number\":true}'::jsonb WHERE id = ?",
                lead.id)
            suggestion = { action = "email", message = "The number is wrong. Email them, or check the number." }
        elseif outcome == "connected" then
            suggestion = { action = "qualify", message = "Record what you learned (Qualify), or book a meeting." }
        end
        P.refresh_next_action(lead.id)
        return { activity = activity, next_step = next_step, suggestion = suggestion, lead_id = lead.id }
    end)
    if not result then return nil, err end
    if outcome == "connected" and notes and Settings.get(ns).ai_enabled then
        pcall(require("lib.crm.lead-ai").enqueue, ns, result.lead_id, "call", actor)
    end
    result.lead = P.get(ns, uuid, settings)
    result.lead_id = nil
    return result
end

--- Plan a follow-up by hand (replaces nothing: earlier planned steps stay).
function P.set_next_step(ns, uuid, actor, s)
    local kind = type(s.type) == "string" and s.type or "call"
    if not P.STEP_TYPES[kind] or kind == "meeting" then
        return U.fail(422, "LEAD_STEP_TYPE", "Pick call, email, follow up or task (book meetings with “Book meeting”)",
            { type = "call | email | follow_up | task" })
    end
    local due = U.timestamp(s.due_at)
    if not due then return U.fail(422, "LEAD_STEP_DUE", "Pick when it's due", { due_at = "ISO date-time" }) end
    return U.tx(function()
        local lead = P.find(ns, uuid, { lock = true })
        if not lead then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        if not Stages.is_open(lead.status) then
            return U.fail(409, "LEAD_NOT_OPEN", "Reopen the lead before planning a step")
        end
        local row = P.plan_step(ns, lead, actor, { type = kind, due_at = due, note = U.text(s.note, 2000),
            subject = U.text(s.subject, 200) })
        return row or true
    end)
end

--- Complete or cancel a planned step (not calls: log those with log_call).
function P.finish_step(ns, uuid, activity_uuid, actor, status, note)
    if not U.crm() then return U.fail(409, "LEAD_CRM_OFF", "Steps need the CRM module in this deployment") end
    if status ~= "completed" and status ~= "cancelled" then
        return U.fail(422, "LEAD_STEP_STATUS", "Mark the step done or cancel it", { status = "completed | cancelled" })
    end
    return U.tx(function()
        local lead = P.find(ns, uuid, { lock = true })
        if not lead then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        local a = U.one([[SELECT * FROM crm_activities WHERE uuid = ? AND lead_id = ? AND deleted_at IS NULL FOR UPDATE]],
            activity_uuid, lead.id)
        if not a then return U.fail(404, "LEAD_STEP_NOT_FOUND", "Step not found") end
        if a.status ~= "planned" then return U.fail(409, "LEAD_STEP_DONE", "This step is already closed") end
        if a.activity_type == "meeting" then
            return U.fail(409, "LEAD_STEP_MEETING", "Record the meeting's outcome, or cancel the meeting, instead")
        end
        db.query([[UPDATE crm_activities SET status = ?, completed_at = CASE WHEN ? = 'completed' THEN NOW() END,
            cancelled_at = CASE WHEN ? = 'cancelled' THEN NOW() END,
            description = CONCAT_WS(E'\n\n', NULLIF(description, ''), ?::text), updated_at = NOW() WHERE id = ?]],
            status, status, status, U.text(note, 2000) or db.NULL, a.id)
        if status == "completed" and (a.activity_type == "email" or a.activity_type == "follow_up") then
            db.query([[UPDATE crm_leads SET last_contacted_at = NOW(), first_contacted_at = COALESCE(first_contacted_at, NOW())
                WHERE id = ?]], lead.id)
        end
        P.refresh_next_action(lead.id)
        return true
    end)
end

-- ---------------------------------------------------------------------------
-- Qualification, money estimate
-- ---------------------------------------------------------------------------

--- Save answers to the workspace's qualification questions and the money
-- estimate; `move` = true also moves an open lead to Qualified.
function P.qualify(ns, uuid, actor, q)
    local settings = Settings.get(ns)
    local known = {}
    for _, item in ipairs(settings.qualification_questions) do known[item.key] = true end
    local answers = {}
    if q.answers ~= nil then
        if type(q.answers) ~= "table" then return U.fail(422, "LEAD_QUALIFY", "answers must be an object", { answers = "object" }) end
        for k, v in pairs(q.answers) do
            if not known[k] then return U.fail(422, "LEAD_QUALIFY", "Unknown question " .. tostring(k), { answers = "unknown " .. tostring(k) }) end
            if v ~= cjson.null and type(v) ~= "string" then
                return U.fail(422, "LEAD_QUALIFY", "Answers are text", { ["answers." .. k] = "text" })
            end
            answers[k] = v == cjson.null and cjson.null or (U.text(v, 1000) or cjson.null)
        end
    end
    local value = q.estimated_value
    if value ~= nil and value ~= cjson.null then
        value = U.money(value)
        if not value then return U.fail(422, "LEAD_VALUE", "The value must be a positive amount", { estimated_value = "amount" }) end
    end
    local currency = q.currency ~= nil and tostring(q.currency):upper() or nil
    if currency and not currency:match("^%u%u%u$") then
        return U.fail(422, "LEAD_CURRENCY", "Use a 3-letter currency code", { currency = "e.g. GBP" })
    end
    local close = q.expected_close_date
    if close ~= nil and close ~= cjson.null then
        close = U.date(close)
        if not close then return U.fail(422, "LEAD_CLOSE_DATE", "Expected close must be a date", { expected_close_date = "YYYY-MM-DD" }) end
    end
    return U.tx(function()
        local lead = P.find(ns, uuid, { lock = true })
        if not lead then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        if lead.status == "converted" then return U.fail(409, "LEAD_CONVERTED", "This lead is converted. Edit its deal.") end
        local merged = U.json(lead.qualification, {})
        for k, v in pairs(answers) do merged[k] = v ~= cjson.null and v or nil end
        local set = { qualification = U.enc(merged), updated_at = db.raw("NOW()") }
        if q.estimated_value ~= nil then
            set.estimated_value = value == cjson.null and db.NULL or value
            -- A person's value: later AI runs never replace it (lib/crm/lead-ai.lua).
            local meta = U.json(lead.metadata, {})
            meta.value_from = "person"
            set.metadata = U.enc(meta)
        end
        if currency then set.currency = currency end
        if q.expected_close_date ~= nil then set.expected_close_date = close == cjson.null and db.NULL or close end
        db.update("crm_leads", set, { id = lead.id })
        if q.move == true and Stages.rank(lead.status) > 0 and Stages.rank(lead.status) < Stages.rank("qualified") then
            db.update("crm_leads", { status = "qualified", stage_changed_at = db.raw("NOW()") }, { id = lead.id })
            history(ns, lead.id, lead.status, "qualified", actor, "qualified")
        end
        return true
    end)
end

-- ---------------------------------------------------------------------------
-- Read side
-- ---------------------------------------------------------------------------

local SORTS = {
    next_action = "l.next_action_at ASC NULLS LAST, l.created_at DESC",
    newest = "l.created_at DESC",
    oldest = "l.created_at ASC",
    score = "l.ai_score DESC NULLS LAST, l.created_at DESC",
    value = "l.estimated_value DESC NULLS LAST, l.created_at DESC",
    stage_changed = "l.stage_changed_at DESC NULLS LAST",
}

--- Filtered, scoped, paginated list.
-- @param scope { sql, params } from lead-access.scope
-- @param q { stage, owner (me|unassigned|uuid), due (overdue|today), hot, source, search, sort, page, per_page }
function P.list(ns, scope, me, q, settings)
    local Global = require("helper.global")
    local page = Global.pageParam(q.page)
    local per_page = Global.perPageParam(q.per_page, 25, 200)
    local where, args = { "l.namespace_id = ?", "l.deleted_at IS NULL", scope.sql }, { ns }
    for _, p in ipairs(scope.params) do args[#args + 1] = p end

    if U.nz(q.stage) then
        local list = {}
        for s in tostring(q.stage):gmatch("[^,]+") do
            local st = Stages.normalise(s)
            if st then list[#list + 1] = st end
        end
        if #list > 0 then
            where[#where + 1] = "l.status IN ?"
            args[#args + 1] = db.list(list)
        end
    end
    if q.owner == "me" then
        where[#where + 1] = "l.owner_user_uuid = ?"; args[#args + 1] = me
    elseif q.owner == "unassigned" then
        where[#where + 1] = "l.owner_user_uuid IS NULL"
    elseif U.is_uuid(q.owner) or (type(q.owner) == "string" and #q.owner <= 64 and q.owner:match("^[%w%-]+$")) then
        where[#where + 1] = "l.owner_user_uuid = ?"; args[#args + 1] = q.owner
    end
    if q.due == "overdue" then
        where[#where + 1] = "l.next_action_at < NOW()"
    elseif q.due == "today" then
        where[#where + 1] = "l.next_action_at < date_trunc('day', NOW()) + interval '1 day'"
    end
    if q.hot == true or q.hot == "true" or q.hot == "1" then
        where[#where + 1] = "l.ai_score >= ?"; args[#args + 1] = settings.ai_hot_score
    end
    if U.nz(q.source) then where[#where + 1] = "l.source = ?"; args[#args + 1] = U.text(q.source, 64) end
    if U.nz(q.search) then
        local s = "%" .. U.text(q.search, 100):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(l.first_name ILIKE ? OR l.last_name ILIKE ? OR l.email ILIKE ? OR l.company_name ILIKE ? OR l.phone ILIKE ?)"
        for _ = 1, 5 do args[#args + 1] = s end
    end
    local where_sql = table.concat(where, " AND ")
    local total = tonumber(db.query("SELECT COUNT(*) AS n FROM crm_leads l WHERE " .. where_sql, unpack(args))[1].n) or 0
    local order = SORTS[q.sort] or SORTS.next_action
    local data_args = { unpack(args) }
    data_args[#data_args + 1] = per_page
    data_args[#data_args + 1] = (page - 1) * per_page
    local rows = db.query("SELECT l.*, " .. OWNER_COLS .. " FROM crm_leads l " .. OWNER_JOIN
        .. " WHERE " .. where_sql .. " ORDER BY " .. order .. " LIMIT ? OFFSET ?", unpack(data_args))
    for i, r in ipairs(rows) do rows[i] = P.present(r, settings, { light = true }) end
    return { items = U.array(rows), meta = { total = total, page = page, per_page = per_page,
        total_pages = math.max(1, math.ceil(total / per_page)) } }
end

--- The pipeline board: per stage, the count, estimated value and the first
-- `per_stage` cards. Converted and lost show the last `recent_days` only.
function P.board(ns, scope, settings, opts)
    opts = opts or {}
    local per_stage = math.min(math.max(tonumber(opts.per_stage) or 30, 1), 100)
    local recent = math.min(math.max(tonumber(opts.recent_days) or 30, 1), 365)
    local base_args = { ns }
    for _, p in ipairs(scope.params) do base_args[#base_args + 1] = p end
    local filter = "l.namespace_id = ? AND l.deleted_at IS NULL AND " .. scope.sql
        .. " AND (l.status NOT IN ('converted','lost') OR l.stage_changed_at > NOW() - make_interval(days => " .. recent .. "))"
    if opts.owner == "me" and opts.me then
        filter = filter .. " AND l.owner_user_uuid = " .. db.escape_literal(opts.me)
    end
    local totals = {}
    for _, r in ipairs(db.query([[
        SELECT l.status, COUNT(*) AS n, COALESCE(SUM(l.estimated_value), 0) AS value,
               COUNT(*) FILTER (WHERE l.next_action_at < NOW()) AS overdue
        FROM crm_leads l WHERE ]] .. filter .. " GROUP BY l.status", unpack(base_args))) do
        totals[r.status] = r
    end
    local args = { unpack(base_args) }
    args[#args + 1] = per_stage
    local cards = db.query([[
        SELECT * FROM (
            SELECT l.id, l.uuid, l.first_name, l.last_name, l.email, l.phone, l.company_name, l.source, l.status,
                   l.owner_user_uuid, l.estimated_value, l.currency, l.ai_score, l.ai_summary, l.ai_status,
                   l.next_action_type, l.next_action_at, l.stage_changed_at, l.created_at, l.contact_attempts,
                   l.priority, ]] .. OWNER_COLS .. [[,
                   ROW_NUMBER() OVER (PARTITION BY l.status ORDER BY l.next_action_at ASC NULLS LAST, l.created_at DESC) AS rn
            FROM crm_leads l ]] .. OWNER_JOIN .. [[ WHERE ]] .. filter .. [[
        ) x WHERE rn <= ? ORDER BY rn
    ]], unpack(args))
    local by_stage = {}
    for _, c in ipairs(cards) do
        c.rn, c.id = nil, nil
        by_stage[c.status] = by_stage[c.status] or {}
        table.insert(by_stage[c.status], c)
    end
    local labels = Stages.labels(settings.stage_labels)
    local columns = {}
    for _, s in ipairs(Stages.ORDER) do
        local t = totals[s] or {}
        columns[#columns + 1] = {
            key = s, label = labels[s], count = tonumber(t.n) or 0, value = tonumber(t.value) or 0,
            overdue = tonumber(t.overdue) or 0, open = Stages.is_open(s), leads = U.array(by_stage[s] or {}),
        }
    end
    return { stages = U.array(columns), currency = settings.currency, recent_days = recent }
end

local RANK_SQL = [[CASE %s WHEN 'new' THEN 1 WHEN 'contacting' THEN 2 WHEN 'qualified' THEN 3
    WHEN 'meeting' THEN 4 WHEN 'converted' THEN 5 ELSE 0 END]]

--- Funnel and timing for leads created between `from` and `to` (dates).
function P.funnel(ns, scope, settings, from, to)
    local args = { ns, from, to }
    for _, p in ipairs(scope.params) do args[#args + 1] = p end
    local base = [[
        WITH leads AS (
            SELECT l.id, l.status, l.source, l.created_at, l.first_contacted_at, l.estimated_value, l.lost_reason,
                   l.converted_deal_id
            FROM crm_leads l
            WHERE l.namespace_id = ? AND l.deleted_at IS NULL AND l.created_at >= ?::date AND l.created_at < ?::date + 1
              AND ]] .. scope.sql .. [[
        ),
        reach AS (
            SELECT ld.id, GREATEST(]] .. RANK_SQL:format("ld.status") .. [[,
                COALESCE((SELECT MAX(]] .. RANK_SQL:format("h.to_status") .. [[) FROM crm_lead_stage_history h
                          WHERE h.lead_id = ld.id), 0)) AS max_rank
            FROM leads ld
        )
    ]]
    local counts = db.query(base .. [[
        SELECT COUNT(*) AS total,
               COUNT(*) FILTER (WHERE r.max_rank >= 2) AS contacting,
               COUNT(*) FILTER (WHERE r.max_rank >= 3) AS qualified,
               COUNT(*) FILTER (WHERE r.max_rank >= 4) AS meeting,
               COUNT(*) FILTER (WHERE r.max_rank >= 5) AS converted,
               COUNT(*) FILTER (WHERE ld.status = 'lost') AS lost,
               COUNT(*) FILTER (WHERE ld.status = 'nurture') AS nurture,
               COUNT(*) FILTER (WHERE ld.status IN ('new','contacting','qualified','meeting')) AS open,
               COALESCE(SUM(ld.estimated_value) FILTER (WHERE ld.status IN ('new','contacting','qualified','meeting')), 0) AS open_value,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM ld.first_contacted_at - ld.created_at) / 60)
                   FILTER (WHERE ld.first_contacted_at IS NOT NULL) AS median_first_contact_minutes,
               COUNT(*) FILTER (WHERE ld.first_contacted_at IS NOT NULL) AS contacted_count,
               COUNT(*) FILTER (WHERE ld.first_contacted_at IS NOT NULL
                   AND ld.first_contacted_at - ld.created_at <= make_interval(mins => ]] .. settings.first_response_minutes .. [[)) AS contacted_in_time
        FROM leads ld JOIN reach r ON r.id = ld.id
    ]], unpack(args))[1]

    -- Median minutes from creation to first entering each stage.
    local timing = {}
    for _, r in ipairs(db.query(base .. [[
        SELECT h.to_status, percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM h.first_at - ld.created_at) / 60) AS minutes
        FROM leads ld
        JOIN (SELECT lead_id, to_status, MIN(created_at) AS first_at FROM crm_lead_stage_history GROUP BY lead_id, to_status) h
          ON h.lead_id = ld.id
        WHERE h.to_status IN ('contacting','qualified','meeting','converted')
        GROUP BY h.to_status
    ]], unpack(args))) do
        timing[r.to_status] = r.minutes and math.floor(tonumber(r.minutes) + 0.5) or cjson.null
    end

    local by_source = db.query(base .. [[
        SELECT COALESCE(NULLIF(ld.source, ''), 'unknown') AS source, COUNT(*) AS leads,
               COUNT(*) FILTER (WHERE r.max_rank >= 5) AS converted,
               COUNT(*) FILTER (WHERE ld.status = 'lost') AS lost
        FROM leads ld JOIN reach r ON r.id = ld.id GROUP BY 1 ORDER BY 2 DESC LIMIT 20
    ]], unpack(args))
    local lost_reasons = db.query(base .. [[
        SELECT COALESCE(NULLIF(ld.lost_reason, ''), 'No reason') AS reason, COUNT(*) AS leads
        FROM leads ld WHERE ld.status = 'lost' GROUP BY 1 ORDER BY 2 DESC LIMIT 10
    ]], unpack(args))
    local money = { open_value = tonumber(counts.open_value) or 0, deal_value = 0, won_value = 0 }
    if U.crm() then
        local m = db.query(base .. [[
            SELECT COALESCE(SUM(d.value), 0) AS deal_value,
                   COALESCE(SUM(d.value) FILTER (WHERE d.status = 'won'), 0) AS won_value
            FROM leads ld JOIN crm_deals d ON d.id = ld.converted_deal_id AND d.deleted_at IS NULL
        ]], unpack(args))[1]
        money.deal_value, money.won_value = tonumber(m.deal_value) or 0, tonumber(m.won_value) or 0
    end

    local labels = Stages.labels(settings.stage_labels)
    local total = tonumber(counts.total) or 0
    local steps, prev = {}, nil
    for _, s in ipairs(Stages.FUNNEL) do
        local n = s == "new" and total or tonumber(counts[s]) or 0
        steps[#steps + 1] = { key = s, label = labels[s], reached = n,
            pct_of_total = total > 0 and math.floor(n * 1000 / total + 0.5) / 10 or 0,
            pct_of_previous = (prev and prev > 0) and math.floor(n * 1000 / prev + 0.5) / 10 or cjson.null,
            median_minutes_from_created = timing[s] or cjson.null }
        prev = n
    end
    local contacted = tonumber(counts.contacted_count) or 0
    return {
        from = from, to = to, total = total, steps = U.array(steps),
        open = tonumber(counts.open) or 0, lost = tonumber(counts.lost) or 0, nurture = tonumber(counts.nurture) or 0,
        speed_to_lead = {
            median_minutes = counts.median_first_contact_minutes ~= db.NULL and counts.median_first_contact_minutes
                and math.floor(tonumber(counts.median_first_contact_minutes) + 0.5) or cjson.null,
            target_minutes = settings.first_response_minutes,
            within_target_pct = contacted > 0 and math.floor((tonumber(counts.contacted_in_time) or 0) * 1000 / contacted + 0.5) / 10 or cjson.null,
            contacted = contacted,
        },
        by_source = U.array(by_source), lost_reasons = U.array(lost_reasons), money = money,
        currency = settings.currency,
    }
end

--- What this person should do now: overdue and today's steps, today's
-- meetings, and how many unassigned leads are waiting.
function P.my_steps(ns, me, is_manager)
    local out = { overdue = {}, today = {}, meetings = {}, unassigned = 0 }
    local leads = db.query([[
        SELECT l.uuid, l.first_name, l.last_name, l.company_name, l.status, l.next_action_type, l.next_action_at,
               l.next_action_note, l.ai_score, l.phone, l.email,
               CASE WHEN l.next_action_at < NOW() THEN 'overdue' ELSE 'today' END AS bucket
        FROM crm_leads l
        WHERE l.namespace_id = ? AND l.deleted_at IS NULL AND l.owner_user_uuid = ?
          AND l.next_action_at IS NOT NULL AND l.next_action_at < date_trunc('day', NOW()) + interval '1 day'
        ORDER BY l.next_action_at ASC LIMIT 100
    ]], ns, me)
    for _, l in ipairs(leads) do table.insert(out[l.bucket], l) end
    if U.crm() then
        out.meetings = db.query([[
            SELECT a.uuid, a.subject, ]] .. U.ACTIVITY_AT .. [[ AS starts_at, a.ends_at, a.location, a.meeting_url,
                   l.uuid AS lead_uuid, l.first_name, l.last_name, l.company_name
            FROM crm_activities a JOIN crm_leads l ON l.id = a.lead_id
            WHERE a.namespace_id = ? AND a.activity_type = 'meeting' AND a.status = 'planned' AND a.deleted_at IS NULL
              AND a.owner_user_uuid = ?
              AND ]] .. U.ACTIVITY_AT .. [[ >= date_trunc('day', NOW())
              AND ]] .. U.ACTIVITY_AT .. [[ < date_trunc('day', NOW()) + interval '1 day'
            ORDER BY a.activity_date LIMIT 50
        ]], ns, me)
    end
    out.unassigned = tonumber(U.one([[SELECT COUNT(*) AS n FROM crm_leads WHERE namespace_id = ? AND deleted_at IS NULL
        AND owner_user_uuid IS NULL AND status IN ('new','contacting','qualified','meeting')]], ns).n) or 0
    out.overdue, out.today, out.meetings = U.array(out.overdue), U.array(out.today), U.array(out.meetings)
    out.can_take_unassigned = true
    out.is_manager = is_manager == true
    return out
end

--- Everything that happened to a lead, newest first.
function P.timeline(ns, lead)
    local items = {}
    local function add(t) items[#items + 1] = t end
    -- created_at / converted_at are old zone-less columns; ::timestamptz gives them back with their zone.
    local at = U.one("SELECT created_at::timestamptz AS created_at, converted_at::timestamptz AS converted_at FROM crm_leads WHERE id = ?",
        lead.id) or lead
    add({ kind = "created", at = at.created_at, title = "Lead created",
        detail = U.nz(lead.source) and ("Source: " .. tostring(lead.source)) or cjson.null })
    for _, h in ipairs(db.query([[
        SELECT h.from_status, h.to_status, h.reason, h.created_at, h.changed_by_uuid,
               NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), '') AS by_name
        FROM crm_lead_stage_history h LEFT JOIN users u ON u.uuid = h.changed_by_uuid
        WHERE h.lead_id = ? AND h.from_status IS NOT NULL ORDER BY h.created_at
    ]], lead.id)) do
        add({ kind = "stage", at = h.created_at, title = "Moved to " .. (Stages.LABELS[h.to_status] or h.to_status),
            from = h.from_status, to = h.to_status, detail = U.nz(h.reason) or cjson.null, by = h.by_name or cjson.null })
    end
    if U.crm() then
        for _, a in ipairs(db.query([[
            SELECT a.uuid, a.activity_type, a.subject, a.description, a.status, a.outcome, ]] .. U.ACTIVITY_AT .. [[ AS at,
                   a.ends_at, a.completed_at::timestamptz AS completed_at, a.cancelled_at, a.duration_minutes, a.location, a.meeting_url,
                   NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), '') AS by_name
            FROM crm_activities a LEFT JOIN users u ON u.uuid = a.owner_user_uuid
            WHERE a.lead_id = ? AND a.deleted_at IS NULL ORDER BY a.activity_date
        ]], lead.id)) do
            local when = a.status == "completed" and not U.null(a.completed_at) and a.completed_at or a.at
            add({ kind = "activity", at = when, activity_uuid = a.uuid, type = a.activity_type, status = a.status,
                title = a.subject or a.activity_type, outcome = a.outcome or cjson.null,
                outcome_label = a.outcome and P.CALL_OUTCOMES[a.outcome] or cjson.null,
                detail = U.nz(a.description) or cjson.null, due_at = a.at, by = a.by_name or cjson.null,
                location = a.location or cjson.null, meeting_url = a.meeting_url or cjson.null })
        end
    end
    for _, r in ipairs(db.query([[SELECT uuid, status, trigger, error, finished_at, created_at FROM crm_lead_analyses
        WHERE lead_id = ? AND status IN ('done','failed') ORDER BY created_at]], lead.id)) do
        add({ kind = "analysis", at = r.finished_at or r.created_at, title = r.status == "done" and "AI analysed the lead"
            or "AI analysis failed", detail = r.status == "failed" and (r.error or cjson.null) or cjson.null,
            analysis_uuid = r.uuid })
    end
    if U.has_table("crm_deal_referrals") then
        for _, r in ipairs(db.query([[
            SELECT r.uuid, r.status, r.created_at, r.sent_at, a.name AS partner_name
            FROM crm_deal_referrals r JOIN crm_accounts a ON a.id = r.partner_account_id
            WHERE r.lead_id = ? ORDER BY r.created_at
        ]], lead.id)) do
            add({ kind = "referral", at = r.sent_at or r.created_at, title = "Passed to " .. r.partner_name,
                detail = "Referral " .. r.status, referral_uuid = r.uuid })
        end
    end
    if not U.null(at.converted_at) then
        add({ kind = "converted", at = at.converted_at, title = "Converted to a deal" })
    end
    table.sort(items, function(a, b) return tostring(a.at) > tostring(b.at) end)
    return U.array(items)
end

return P
