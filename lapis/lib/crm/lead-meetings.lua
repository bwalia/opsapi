--[[
    Meetings with leads (docs/plans/LEAD_TO_CASH_PIPELINE.md §4.5)
    ==============================================================

    A meeting is a crm_activities row (activity_type 'meeting') on the lead,
    with a calendar invite: a fixed UID (ics_uid) and a SEQUENCE (ics_sequence)
    that goes up on every change, so calendars update the event they have.

    Invites are sent from the event outbox (lib/crm/lead-jobs.lua on
    crm.activity.*), so a failed email is retried and a change never sends
    twice: reminders_sent.invited_seq records the last SEQUENCE delivered.
    Email goes through the workspace's own SMTP (templates crm.meeting_*,
    editable in Settings → Email).

    Reminders and the "how did it go?" prompt run from the pipeline timer.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local U = require("lib.crm.util")
local Settings = require("lib.crm.lead-settings")
local Stages = require("lib.crm.lead-stages")

local M = {}

M.TYPES = { video = "Video call", phone = "Phone call", in_person = "In person", viewing = "Viewing" }
M.OUTCOMES = { held = "It happened", no_show = "They didn't come", rescheduled = "Moved to another time" }

local function email_ok(v)
    return type(v) == "string" and #v <= 254 and v:match("^[^%s@<>]+@[^%s@<>]+%.[^%s@<>]+$") ~= nil
end

local function domain()
    local host = (os.getenv("FRONTEND_URL") or os.getenv("API_URL") or ""):match("^https?://([^/:]+)")
    return host or "opsapi.local"
end

local function load(ns, activity_uuid, lock)
    if type(activity_uuid) ~= "string" or #activity_uuid > 64 then return nil end
    return U.one([[SELECT a.*, ]] .. U.ACTIVITY_AT .. [[ AS starts_at FROM crm_activities a
        WHERE a.namespace_id = ? AND a.uuid = ? AND a.activity_type = 'meeting' AND a.deleted_at IS NULL]]
        .. (lock and " FOR UPDATE" or ""), ns, activity_uuid)
end

--- Validate meeting fields from a client. @return clean | nil, err
local function fields(settings, p, existing)
    local out = {}
    local starts = p.starts_at ~= nil and U.timestamp(p.starts_at) or (existing and existing.starts_utc)
    if not starts then return U.fail(422, "MEETING_TIME", "Pick the meeting's date and time", { starts_at = "ISO date-time" }) end
    if not U.one("SELECT ?::timestamptz > NOW() AS ok", starts).ok then
        return U.fail(422, "MEETING_TIME", "The meeting must be in the future", { starts_at = "in the future" })
    end
    out.starts_at = starts
    local minutes = p.duration_minutes ~= nil and tonumber(p.duration_minutes)
        or (existing and tonumber(existing.duration_minutes)) or settings.meeting.default_minutes
    if not minutes or minutes < 5 or minutes > 480 or minutes ~= math.floor(minutes) then
        return U.fail(422, "MEETING_LENGTH", "A meeting is 5 to 480 minutes", { duration_minutes = "5 to 480" })
    end
    out.duration_minutes = minutes
    local kind = p.type or (existing and U.json(existing.metadata, {}).meeting_type) or "video"
    if not M.TYPES[kind] then return U.fail(422, "MEETING_TYPE", "Pick the kind of meeting", { type = "video | phone | in_person | viewing" }) end
    out.type = kind
    out.location = p.location ~= nil and U.text(p.location, 300) or (existing and U.nz(existing.location)) or nil
    local url = p.meeting_url
    if url == nil then url = existing and U.nz(existing.meeting_url) or (kind == "video" and settings.meeting.default_link or nil) end
    url = U.text(url, 1000)
    if url and not url:match("^https://[%w%-%.]+") then
        return U.fail(422, "MEETING_LINK", "The meeting link must start with https://", { meeting_url = "https:// link" })
    end
    out.meeting_url = url
    if kind == "in_person" or kind == "viewing" then
        if not out.location then return U.fail(422, "MEETING_PLACE", "Where is the meeting?", { location = "required" }) end
    end
    out.title = p.title ~= nil and U.text(p.title, 200) or (existing and U.nz(existing.subject)) or nil
    out.notes = p.notes ~= nil and U.text(p.notes, 2000) or (existing and U.nz(existing.description)) or nil
    local guests = {}
    if p.guests ~= nil then
        if type(p.guests) ~= "table" or #p.guests > 10 then
            return U.fail(422, "MEETING_GUESTS", "Up to 10 extra guests", { guests = "list of up to 10 emails" })
        end
        for i, g in ipairs(p.guests) do
            local email = type(g) == "table" and g.email or g
            if not email_ok(email) then
                return U.fail(422, "MEETING_GUESTS", "Guest " .. i .. " needs a valid email", { guests = "guest " .. i })
            end
            guests[#guests + 1] = { email = email:lower(), name = type(g) == "table" and U.text(g.name, 120) or nil, role = "guest" }
        end
    end
    out.guests = guests
    out.send_invite = p.send_invite ~= false and settings.meeting.send_invites
    return out
end

local function attendees(ns, lead, owner_uuid, guests)
    local list = {}
    if U.nz(lead.email) and email_ok(lead.email) then
        list[#list + 1] = { email = lead.email:lower(), name = U.full_name(lead.first_name, lead.last_name), role = "lead" }
    end
    local owner = owner_uuid and U.one("SELECT email, first_name, last_name FROM users WHERE uuid = ?", owner_uuid)
    if owner and email_ok(owner.email) then
        list[#list + 1] = { email = owner.email:lower(), name = U.full_name(owner.first_name, owner.last_name), role = "staff" }
    end
    local seen = {}
    for _, a in ipairs(list) do seen[a.email] = true end
    for _, g in ipairs(guests or {}) do
        if not seen[g.email] then seen[g.email] = true; list[#list + 1] = g end
    end
    return U.array(list)
end

--- Book a meeting with a lead. Moves an earlier-stage lead to Meeting.
function M.book(ns, lead_uuid, actor, p)
    if not U.crm() then return U.fail(409, "LEAD_CRM_OFF", "Meetings need the CRM module in this deployment") end
    local settings = Settings.get(ns)
    local f, err = fields(settings, p or {})
    if not f then return nil, err end
    local Pipeline = require("lib.crm.lead-pipeline")
    local activity, terr = U.tx(function()
        local lead = Pipeline.find(ns, lead_uuid, { lock = true })
        if not lead then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        if lead.status == "converted" or lead.status == "lost" then
            return U.fail(409, "LEAD_NOT_OPEN", "Reopen the lead before booking a meeting")
        end
        local owner = U.nz(lead.owner_user_uuid) or actor
        local who = U.full_name(lead.first_name, lead.last_name) or U.nz(lead.company_name) or "lead"
        local row = db.query([[
            INSERT INTO crm_activities (uuid, namespace_id, lead_id, activity_type, subject, description, activity_date,
                ends_at, duration_minutes, location, meeting_url, attendees, owner_user_uuid, status, ics_uid, ics_sequence,
                metadata, created_at, updated_at)
            VALUES (?, ?, ?, 'meeting', ?, ?, ]] .. U.TO_ACTIVITY_DATE .. [[, ?::timestamptz + make_interval(mins => ?), ?, ?, ?,
                ?::jsonb, ?, 'planned', ?, 0, ?::jsonb, NOW(), NOW())
            RETURNING *
        ]], require("helper.global").generateUUID(), ns, lead.id, f.title or (M.TYPES[f.type] .. " with " .. who),
            f.notes or db.NULL, f.starts_at, f.starts_at, f.duration_minutes, f.duration_minutes, f.location or db.NULL,
            f.meeting_url or db.NULL, U.enc(attendees(ns, lead, owner, f.guests)), owner or db.NULL,
            require("helper.global").generateUUID() .. "@" .. domain(),
            U.enc({ meeting_type = f.type, send_invite = f.send_invite, booked_by = actor }))[1]
        if Stages.is_open(lead.status) and Stages.rank(lead.status) < Stages.rank("meeting") or lead.status == "nurture" then
            db.update("crm_leads", { status = "meeting", stage_changed_at = db.raw("NOW()"), nurture_until = db.NULL,
                updated_at = db.raw("NOW()") }, { id = lead.id })
            db.query([[INSERT INTO crm_lead_stage_history (namespace_id, lead_id, from_status, to_status, changed_by_uuid, reason)
                VALUES (?, ?, ?, 'meeting', ?, 'meeting booked')]], ns, lead.id, lead.status, actor or db.NULL)
        end
        Pipeline.refresh_next_action(lead.id)
        return row
    end)
    if not activity then return nil, terr end
    return M.get(ns, activity.uuid)
end

--- Move a meeting (time, length, place, link, notes). Sends an updated invite.
function M.update(ns, activity_uuid, actor, p)
    local settings = Settings.get(ns)
    local ok, err = U.tx(function()
        local a = load(ns, activity_uuid, true)
        if not a then return U.fail(404, "MEETING_NOT_FOUND", "Meeting not found") end
        if a.status ~= "planned" then return U.fail(409, "MEETING_CLOSED", "This meeting is already closed") end
        local existing = { starts_utc = U.one([[SELECT to_char(?::timestamptz AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t]],
            a.starts_at).t, duration_minutes = a.duration_minutes, metadata = a.metadata, location = a.location,
            meeting_url = a.meeting_url, subject = a.subject, description = a.description }
        local f, err = fields(settings, p or {}, existing)
        if not f then return nil, err end
        local meta = U.json(a.metadata, {})
        meta.meeting_type = f.type
        local reminders = U.json(a.reminders_sent, {})
        local kept = { invited_seq = reminders.invited_seq }
        db.query([[
            UPDATE crm_activities SET activity_date = ]] .. U.TO_ACTIVITY_DATE .. [[,
                ends_at = ?::timestamptz + make_interval(mins => ?), duration_minutes = ?, location = ?, meeting_url = ?,
                subject = COALESCE(?, subject), description = ?, ics_sequence = ics_sequence + 1, metadata = ?::jsonb,
                reminders_sent = ?::jsonb, outcome_prompted_at = NULL, updated_at = NOW()
            WHERE id = ?
        ]], f.starts_at, f.starts_at, f.duration_minutes, f.duration_minutes, f.location or db.NULL, f.meeting_url or db.NULL,
            p and p.title ~= nil and f.title or db.NULL, f.notes or db.NULL, U.enc(meta), U.enc(kept), a.id)
        if a.lead_id then require("lib.crm.lead-pipeline").refresh_next_action(a.lead_id) end
        return true
    end)
    if not ok then return nil, err end
    return M.get(ns, activity_uuid)
end

--- Cancel a meeting. Sends a cancellation to everyone invited.
function M.cancel(ns, activity_uuid, actor, reason)
    local ok, err = U.tx(function()
        local a = load(ns, activity_uuid, true)
        if not a then return U.fail(404, "MEETING_NOT_FOUND", "Meeting not found") end
        if a.status ~= "planned" then return U.fail(409, "MEETING_CLOSED", "This meeting is already closed") end
        db.query([[
            UPDATE crm_activities SET status = 'cancelled', cancelled_at = NOW(), ics_sequence = ics_sequence + 1,
                description = CONCAT_WS(E'\n\n', NULLIF(description, ''), ?::text), updated_at = NOW()
            WHERE id = ?
        ]], U.text(reason, 500) and ("Cancelled: " .. U.text(reason, 500)) or db.NULL, a.id)
        if a.lead_id then require("lib.crm.lead-pipeline").refresh_next_action(a.lead_id) end
        return true
    end)
    if not ok then return nil, err end
    return M.get(ns, activity_uuid)
end

--- Record how the meeting went. A held meeting re-runs the AI analysis with
-- the notes; a no-show plans a call to rebook.
function M.outcome(ns, activity_uuid, actor, p)
    local outcome = type(p.outcome) == "string" and p.outcome or ""
    if not M.OUTCOMES[outcome] then
        return U.fail(422, "MEETING_OUTCOME", "Say how the meeting went", { outcome = "held | no_show | rescheduled" })
    end
    if outcome == "rescheduled" then
        return U.fail(422, "MEETING_OUTCOME", "To move a meeting, change its time instead", { outcome = "use update" })
    end
    local notes = U.text(p.notes, 4000)
    local settings = Settings.get(ns)
    local lead_id
    local ok, err = U.tx(function()
        local a = load(ns, activity_uuid, true)
        if not a then return U.fail(404, "MEETING_NOT_FOUND", "Meeting not found") end
        if a.status ~= "planned" then return U.fail(409, "MEETING_CLOSED", "This meeting already has an outcome") end
        if not U.one("SELECT ?::timestamptz <= NOW() + interval '15 minutes' AS ok", a.starts_at).ok then
            return U.fail(409, "MEETING_NOT_YET", "The meeting hasn't started yet")
        end
        db.query([[
            UPDATE crm_activities SET status = 'completed', completed_at = NOW(), outcome = ?,
                description = CONCAT_WS(E'\n\n', NULLIF(description, ''), ?::text), updated_at = NOW()
            WHERE id = ?
        ]], outcome, notes or db.NULL, a.id)
        lead_id = a.lead_id
        if lead_id then
            if outcome == "held" then
                db.query("UPDATE crm_leads SET last_contacted_at = NOW(), first_contacted_at = COALESCE(first_contacted_at, NOW()) WHERE id = ?",
                    lead_id)
            elseif outcome == "no_show" then
                local lead = U.one("SELECT * FROM crm_leads WHERE id = ?", lead_id)
                if lead and Stages.is_open(lead.status) then
                    require("lib.crm.lead-pipeline").plan_step(ns, lead, actor, { type = "call",
                        subject = "Call " .. (U.full_name(lead.first_name, lead.last_name) or "the lead") .. " to rebook the meeting",
                        due_at = require("lib.crm.working-hours").due_at(settings.working_hours, 60) })
                end
            end
            require("lib.crm.lead-pipeline").refresh_next_action(lead_id)
        end
        return true
    end)
    if not ok then return nil, err end
    if outcome == "held" and lead_id and settings.ai_enabled then
        pcall(require("lib.crm.lead-ai").enqueue, ns, lead_id, "meeting", actor)
    end
    return M.get(ns, activity_uuid)
end

--- One meeting for the API.
function M.get(ns, activity_uuid)
    local a = U.one([[
        SELECT a.uuid, a.subject, a.description, a.status, a.outcome, ]] .. U.ACTIVITY_AT .. [[ AS starts_at, a.ends_at,
               a.duration_minutes, a.location, a.meeting_url, a.attendees, a.owner_user_uuid, a.ics_sequence, a.metadata,
               a.reminders_sent, a.completed_at, a.cancelled_at, l.uuid AS lead_uuid
        FROM crm_activities a LEFT JOIN crm_leads l ON l.id = a.lead_id
        WHERE a.namespace_id = ? AND a.uuid = ? AND a.activity_type = 'meeting' AND a.deleted_at IS NULL
    ]], ns, activity_uuid)
    if not a then return nil end
    a.attendees = U.array(U.json(a.attendees, {}))
    local meta = U.json(a.metadata, {})
    local sent = U.json(a.reminders_sent, {})
    a.type = meta.meeting_type or "video"
    a.type_label = M.TYPES[a.type] or a.type
    a.invite = { enabled = meta.send_invite ~= false, sent_sequence = sent.invited_seq or cjson.null,
        up_to_date = sent.invited_seq == tonumber(a.ics_sequence), error = sent.invite_error or cjson.null }
    a.metadata, a.reminders_sent = nil, nil
    return a
end

--- Meetings of a lead (planned first).
function M.for_lead(ns, lead_id)
    if not U.crm() then return U.array({}) end
    local out = {}
    for _, r in ipairs(db.query([[
        SELECT a.uuid FROM crm_activities a WHERE a.namespace_id = ? AND a.lead_id = ? AND a.activity_type = 'meeting'
          AND a.deleted_at IS NULL
        ORDER BY (a.status = 'planned') DESC, a.activity_date DESC LIMIT 50
    ]], ns, lead_id)) do
        out[#out + 1] = M.get(ns, r.uuid)
    end
    return U.array(out)
end

-- ---------------------------------------------------------------------------
-- Delivery (outbox) and reminders (timer)
-- ---------------------------------------------------------------------------

local function when_text(starts_at, minutes, tz)
    local ok, row = pcall(U.one, [[SELECT to_char(?::timestamptz AT TIME ZONE ?, 'FMDay FMDD FMMonth YYYY, HH24:MI') AS t]],
        starts_at, tz)
    return (ok and row and row.t or tostring(starts_at)) .. " (" .. tz .. ", " .. tostring(minutes) .. " minutes)"
end

local function send_one(ns, key, to, data, ics, method)
    local NamespaceMail = require("helper.namespace-mail")
    return NamespaceMail.send(ns, key, to, data, nil, ics and {
        attachments = { { filename = "invite.ics", content_type = "text/calendar; charset=UTF-8; method=" .. method,
            content_b64 = ngx.encode_base64(ics) } },
    } or nil)
end

--- Send (or re-send) the invite for the meeting's current SEQUENCE, or the
-- cancellation. Idempotent: does nothing when that SEQUENCE was delivered.
-- @return true (done / nothing to do) | false, reason (retry)
function M.deliver(ns, activity_uuid)
    local a = U.one([[
        SELECT a.*, ]] .. U.ACTIVITY_AT .. [[ AS starts_at FROM crm_activities a
        WHERE a.namespace_id = ? AND a.uuid = ? AND a.activity_type = 'meeting' AND a.deleted_at IS NULL
    ]], ns, activity_uuid)
    if not a or not U.nz(a.ics_uid) then return true end
    local meta, sent = U.json(a.metadata, {}), U.json(a.reminders_sent, {})
    local seq = tonumber(a.ics_sequence) or 0
    if meta.send_invite == false or sent.invited_seq == seq then return true end
    if a.status == "completed" then return true end
    -- Never invited and already cancelled: nothing to tell anyone.
    if a.status == "cancelled" and sent.invited_seq == nil then return true end
    local settings = Settings.get(ns)
    local tz = settings.working_hours.timezone
    local list = U.json(a.attendees, {})
    if #list == 0 then return true end
    local owner = U.nz(a.owner_user_uuid) and U.one("SELECT email, first_name, last_name FROM users WHERE uuid = ?", a.owner_user_uuid)
    local smtp = require("helper.namespace-mail").smtp(ns)
    local organizer = { email = smtp and smtp.from_email or (owner and owner.email) or os.getenv("SMTP_FROM_EMAIL") or "noreply@opsapi.com",
        name = smtp and smtp.from_name or (owner and U.full_name(owner.first_name, owner.last_name)) }
    local stamp = U.one([[SELECT to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t]]).t
    local starts = U.one([[SELECT to_char(?::timestamptz AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS s,
        to_char(?::timestamptz AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS e]], a.starts_at, a.ends_at)
    local cancelled = a.status == "cancelled"
    local method = cancelled and "CANCEL" or "REQUEST"
    local ics = require("lib.crm.ics").build({
        uid = a.ics_uid, sequence = seq, method = method, starts_utc = starts.s, ends_utc = starts.e, stamp_utc = stamp,
        summary = a.subject, description = table.concat({ U.nz(a.description) or "", U.nz(a.meeting_url) and ("Join: " .. a.meeting_url) or "" }, "\n"),
        location = U.nz(a.location) or U.nz(a.meeting_url), url = U.nz(a.meeting_url), organizer = organizer,
        attendees = list,
    })
    local data = {
        meeting_title = a.subject, when = when_text(a.starts_at, a.duration_minutes, tz),
        location = U.nz(a.location) or "", meeting_url = U.nz(a.meeting_url) or "",
        organiser_name = organizer.name or "", notes = U.nz(a.description) or "",
        updated = seq > 0 and not cancelled and "yes" or "",
    }
    local failures = {}
    for _, person in ipairs(list) do
        data.recipient_name = person.name or ""
        local ok, err = send_one(ns, cancelled and "crm.meeting_cancelled" or "crm.meeting_invite", person.email, data, ics, method)
        if not ok then failures[#failures + 1] = tostring(err) end
    end
    if #failures > 0 and #failures == #list then
        db.query([[UPDATE crm_activities SET reminders_sent = (CASE WHEN jsonb_typeof(reminders_sent) = 'object' THEN reminders_sent ELSE '{}'::jsonb END)
            || jsonb_build_object('invite_error', ?::text) WHERE id = ?]], failures[1]:sub(1, 300), a.id)
        return false, "invite not sent: " .. failures[1]
    end
    db.query([[UPDATE crm_activities SET reminders_sent = ((CASE WHEN jsonb_typeof(reminders_sent) = 'object' THEN reminders_sent ELSE '{}'::jsonb END) - 'invite_error')
        || jsonb_build_object('invited_seq', ?::int) WHERE id = ?]], seq, a.id)
    return true
end

--- Reminders before meetings and the "how did it go?" prompt after them.
-- Each reminder is recorded on the meeting so it is sent once.
function M.tick()
    local Notify = require("lib.crm.lead-notify")
    -- Up to a day ahead covers every reminder setting below 24 h; longer lead
    -- reminders are picked up as their window opens.
    local rows = db.query([[
        SELECT a.id, a.uuid, a.namespace_id, a.subject, a.owner_user_uuid, a.attendees, a.reminders_sent, a.metadata,
               a.location, a.meeting_url, a.duration_minutes, a.ends_at, a.outcome_prompted_at, ]] .. U.ACTIVITY_AT .. [[ AS starts_at,
               EXTRACT(EPOCH FROM ]] .. U.ACTIVITY_AT .. [[ - NOW()) / 60 AS minutes_to_start,
               EXTRACT(EPOCH FROM NOW() - a.ends_at) / 60 AS minutes_since_end, l.uuid AS lead_uuid
        FROM crm_activities a LEFT JOIN crm_leads l ON l.id = a.lead_id
        WHERE a.activity_type = 'meeting' AND a.status = 'planned' AND a.deleted_at IS NULL AND a.lead_id IS NOT NULL
          AND ]] .. U.ACTIVITY_AT .. [[ < NOW() + interval '7 days' AND a.ends_at > NOW() - interval '3 days'
        ORDER BY a.activity_date LIMIT 500
    ]])
    local settings_cache = {}
    for _, a in ipairs(rows) do
        local ns = tonumber(a.namespace_id)
        settings_cache[ns] = settings_cache[ns] or Settings.get(ns)
        local s = settings_cache[ns]
        local sent = U.json(a.reminders_sent, {})
        local meta = U.json(a.metadata, {})
        local to_start, since_end = tonumber(a.minutes_to_start) or 0, tonumber(a.minutes_since_end) or 0
        -- Claim first (several pods run this): only the pod that sets the flag sends.
        local function claim(key)
            return #db.query([[UPDATE crm_activities SET reminders_sent = (CASE WHEN jsonb_typeof(reminders_sent) = 'object' THEN reminders_sent ELSE '{}'::jsonb END)
                || jsonb_build_object(?::text, true) WHERE id = ? AND ((CASE WHEN jsonb_typeof(reminders_sent) = 'object' THEN reminders_sent ELSE '{}'::jsonb END) ->> ?) IS NULL
                RETURNING id]], key, a.id, key) > 0
        end
        local function release(key)
            db.query("UPDATE crm_activities SET reminders_sent = reminders_sent - ? WHERE id = ?", key, a.id)
        end
        -- The lead: an email reminder.
        local lead_h = s.meeting.lead_reminder_hours
        if lead_h > 0 and meta.send_invite ~= false and not sent.lead_reminder and to_start > 0 and to_start <= lead_h * 60
            and claim("lead_reminder") then
            local lead_att
            for _, p in ipairs(U.json(a.attendees, {})) do if p.role == "lead" then lead_att = p end end
            if lead_att then
                local ok, sent_ok = pcall(send_one, ns, "crm.meeting_reminder", lead_att.email, {
                    meeting_title = a.subject, when = when_text(a.starts_at, a.duration_minutes, s.working_hours.timezone),
                    location = U.nz(a.location) or "", meeting_url = U.nz(a.meeting_url) or "",
                    recipient_name = lead_att.name or "" })
                if not (ok and sent_ok) then release("lead_reminder") end
            end
        end
        -- Staff: in-app + push (no email: the invite is already in their calendar).
        local staff_m = s.meeting.staff_reminder_minutes
        if staff_m > 0 and not sent.staff_reminder and to_start > 0 and to_start <= staff_m and U.nz(a.owner_user_uuid)
            and claim("staff_reminder") then
            Notify.send(ns, { a.owner_user_uuid }, { kind = "meeting_soon", lead_uuid = a.lead_uuid, email = false,
                title = "Meeting in " .. math.max(1, math.floor(to_start + 0.5)) .. " min: " .. tostring(a.subject),
                body = U.nz(a.meeting_url) and ("Join: " .. a.meeting_url) or (U.nz(a.location) or "") })
        end
        -- After it ended: ask the owner how it went (once).
        if since_end >= 15 and U.null(a.outcome_prompted_at) and U.nz(a.owner_user_uuid)
            and #db.query("UPDATE crm_activities SET outcome_prompted_at = NOW() WHERE id = ? AND outcome_prompted_at IS NULL RETURNING id",
                a.id) > 0 then
            Notify.send(ns, { a.owner_user_uuid }, { kind = "meeting_outcome", lead_uuid = a.lead_uuid,
                title = "How did the meeting go? " .. tostring(a.subject),
                body = "Record whether it happened and what you agreed, so the lead moves on.",
                action_label = "Record the outcome" })
        end
    end
    return #rows
end

return M
