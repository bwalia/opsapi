--[[
    Lead pipeline settings (crm_lead_settings.settings JSONB)
    =========================================================

    One row per workspace; anything not saved takes the default below, so a
    new setting reaches every workspace without a migration. `save` merges a
    partial patch and validates the whole result: an invalid value is
    refused with a per-field message, never silently dropped.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local WH = require("lib.crm.working-hours")
local Stages = require("lib.crm.lead-stages")

local Settings = {}

Settings.DEFAULTS = {
    -- First call due this many WORKING minutes after a lead arrives.
    first_response_minutes = 60,
    working_hours = { timezone = "Europe/London", start = "09:00", ["end"] = "17:30", days = { 1, 2, 3, 4, 5 } },
    -- After an unanswered call, the next attempt is due this many working
    -- hours later; one entry per further attempt (the first call is attempt 1).
    attempt_plan_hours = { 4, 24, 72 },
    -- Overdue next steps are escalated to the managers this long after they were due.
    escalate_after_minutes = 60,
    auto_assign = true,
    -- Round-robin pool when no rule matches; empty = everyone who can work leads.
    round_robin_user_uuids = {},
    -- Who hears about escalations; empty = everyone with crm_leads "manage".
    manager_user_uuids = {},
    ai_enabled = true,
    ai_provider_uuid = cjson.null,      -- null = any enabled provider, self-hosted first
    ai_daily_cost_usd = 5,
    ai_hot_score = 70,
    currency = "GBP",
    qualification_questions = {
        { key = "budget", label = "Budget" },
        { key = "need", label = "What they need" },
        { key = "timeline", label = "When they want it" },
        { key = "decision_maker", label = "Who decides" },
    },
    lost_reasons = { "Not interested", "No budget", "Couldn't reach them", "Went elsewhere", "Spam", "Duplicate", "Other" },
    stage_labels = {},
    meeting = {
        default_minutes = 30,
        default_link = "",
        send_invites = true,
        lead_reminder_hours = 24,
        staff_reminder_minutes = 60,
    },
}

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return setmetatable(out, getmetatable(v))
end

-- Deep merge: objects merge key by key, arrays and scalars replace.
local function is_array(t)
    if type(t) ~= "table" then return false end
    if getmetatable(t) == cjson.array_mt then return true end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n > 0 and #t == n
end

local function merge(base, patch)
    if type(patch) ~= "table" or is_array(patch) or type(base) ~= "table" or is_array(base) then
        return copy(patch)
    end
    local out = copy(base)
    for k, v in pairs(patch) do
        if v ~= cjson.null and type(v) == "table" and not is_array(v) and type(out[k]) == "table" and not is_array(out[k]) then
            out[k] = merge(out[k], v)
        else
            out[k] = copy(v)
        end
    end
    return out
end

local function decode(raw)
    if type(raw) == "table" then return raw end
    if raw == nil or raw == db.NULL or raw == "" then return {} end
    local ok, t = pcall(cjson.decode, raw)
    return ok and type(t) == "table" and t or {}
end

local function is_uuid(v)
    return type(v) == "string" and v:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function int_in(v, lo, hi)
    local n = tonumber(v)
    return n ~= nil and n == math.floor(n) and n >= lo and n <= hi and n or nil
end

local function num_in(v, lo, hi)
    local n = tonumber(v)
    return n ~= nil and n >= lo and n <= hi and n or nil
end

local function uuid_list(v, field, errors)
    if type(v) ~= "table" then errors[field] = "a list of user ids"; return {} end
    local out, seen = {}, {}
    for _, u in ipairs(v) do
        if not is_uuid(u) then errors[field] = "every item must be a user id"; return {} end
        if not seen[u] then seen[u] = true; out[#out + 1] = u end
    end
    if #out > 200 then errors[field] = "at most 200 people" end
    return setmetatable(out, cjson.array_mt)
end

--- Validate a full settings object. @return clean | nil, { field = message }
function Settings.validate(s)
    local e, out = {}, {}

    out.first_response_minutes = int_in(s.first_response_minutes, 1, 10080)
    if not out.first_response_minutes then e.first_response_minutes = "1 to 10080 minutes" end

    local hours, herr = WH.normalise(s.working_hours)
    if not hours then
        e.working_hours = herr
    else
        local tz_ok = pcall(db.query, "SELECT NOW() AT TIME ZONE ?", hours.timezone)
        if not tz_ok then e.working_hours = "unknown time zone " .. tostring(hours.timezone) end
        out.working_hours = { timezone = hours.timezone, start = hours.start, ["end"] = hours["end"],
            days = setmetatable(hours.days, cjson.array_mt) }
    end

    out.attempt_plan_hours = setmetatable({}, cjson.array_mt)
    if type(s.attempt_plan_hours) ~= "table" or #s.attempt_plan_hours > 10 then
        e.attempt_plan_hours = "a list of up to 10 delays in hours"
    else
        for i, v in ipairs(s.attempt_plan_hours) do
            local n = num_in(v, 0.25, 720)
            if not n then e.attempt_plan_hours = "item " .. i .. " must be 0.25 to 720 hours"; break end
            out.attempt_plan_hours[i] = n
        end
    end

    out.escalate_after_minutes = int_in(s.escalate_after_minutes, 5, 10080)
    if not out.escalate_after_minutes then e.escalate_after_minutes = "5 to 10080 minutes" end

    out.auto_assign = s.auto_assign == true
    out.round_robin_user_uuids = uuid_list(s.round_robin_user_uuids or {}, "round_robin_user_uuids", e)
    out.manager_user_uuids = uuid_list(s.manager_user_uuids or {}, "manager_user_uuids", e)

    out.ai_enabled = s.ai_enabled == true
    if s.ai_provider_uuid == nil or s.ai_provider_uuid == cjson.null or s.ai_provider_uuid == "" then
        out.ai_provider_uuid = cjson.null
    elseif is_uuid(s.ai_provider_uuid) then
        out.ai_provider_uuid = s.ai_provider_uuid
    else
        e.ai_provider_uuid = "an AI provider id, or empty for any"
    end
    out.ai_daily_cost_usd = num_in(s.ai_daily_cost_usd, 0, 10000)
    if not out.ai_daily_cost_usd then e.ai_daily_cost_usd = "0 to 10000 US dollars" end
    out.ai_hot_score = int_in(s.ai_hot_score, 1, 100)
    if not out.ai_hot_score then e.ai_hot_score = "1 to 100" end

    out.currency = type(s.currency) == "string" and s.currency:upper() or ""
    if not out.currency:match("^%u%u%u$") then e.currency = "a 3-letter currency code, e.g. GBP" end

    out.qualification_questions = setmetatable({}, cjson.array_mt)
    if type(s.qualification_questions) ~= "table" or #s.qualification_questions > 20 then
        e.qualification_questions = "a list of up to 20 questions"
    else
        local keys = {}
        for i, q in ipairs(s.qualification_questions) do
            local label = type(q) == "table" and type(q.label) == "string" and q.label:match("^%s*(.-)%s*$") or ""
            local key = type(q) == "table" and type(q.key) == "string" and q.key or ""
            if key == "" then key = label:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "") end
            if label == "" or #label > 120 or not key:match("^[%w_]+$") or #key > 40 then
                e.qualification_questions = "question " .. i .. " needs a label (up to 120 characters)"
                break
            end
            if keys[key] then e.qualification_questions = "question " .. i .. " repeats " .. key; break end
            keys[key] = true
            out.qualification_questions[i] = { key = key, label = label }
        end
    end

    out.lost_reasons = setmetatable({}, cjson.array_mt)
    if type(s.lost_reasons) ~= "table" or #s.lost_reasons == 0 or #s.lost_reasons > 30 then
        e.lost_reasons = "1 to 30 reasons"
    else
        for i, r in ipairs(s.lost_reasons) do
            if type(r) ~= "string" or not r:match("%S") or #r > 80 then
                e.lost_reasons = "reason " .. i .. " must be 1 to 80 characters"; break
            end
            out.lost_reasons[i] = r:match("^%s*(.-)%s*$")
        end
    end

    out.stage_labels = {}
    if type(s.stage_labels) == "table" then
        for k, v in pairs(s.stage_labels) do
            if not Stages.valid(k) then e.stage_labels = "unknown stage " .. tostring(k); break end
            if v ~= cjson.null and v ~= "" then
                if type(v) ~= "string" or #v > 40 then e.stage_labels = k .. ": up to 40 characters"; break end
                out.stage_labels[k] = v
            end
        end
    end

    local m = type(s.meeting) == "table" and s.meeting or {}
    out.meeting = {}
    out.meeting.default_minutes = int_in(m.default_minutes, 5, 480)
    if not out.meeting.default_minutes then e["meeting.default_minutes"] = "5 to 480 minutes" end
    out.meeting.default_link = type(m.default_link) == "string" and m.default_link or ""
    if out.meeting.default_link ~= "" and not out.meeting.default_link:match("^https://[%w%-%.]+") then
        e["meeting.default_link"] = "an https:// link"
    end
    out.meeting.send_invites = m.send_invites ~= false
    out.meeting.lead_reminder_hours = int_in(m.lead_reminder_hours, 0, 168)
    if not out.meeting.lead_reminder_hours then e["meeting.lead_reminder_hours"] = "0 to 168 hours (0 = no reminder)" end
    out.meeting.staff_reminder_minutes = int_in(m.staff_reminder_minutes, 0, 1440)
    if not out.meeting.staff_reminder_minutes then e["meeting.staff_reminder_minutes"] = "0 to 1440 minutes (0 = no reminder)" end

    if next(e) then return nil, e end
    return out
end

--- The workspace's settings, defaults filled in (never fails: a corrupt row
-- falls back to the defaults and is logged).
function Settings.get(ns)
    local row = db.query("SELECT settings FROM crm_lead_settings WHERE namespace_id = ?", ns)[1]
    local merged = merge(Settings.DEFAULTS, row and decode(row.settings) or {})
    local clean, errs = Settings.validate(merged)
    if clean then return clean end
    ngx.log(ngx.WARN, "[crm-leads] namespace ", ns, " has invalid lead settings, using defaults: ", cjson.encode(errs))
    return assert(Settings.validate(copy(Settings.DEFAULTS)))
end

--- Merge `patch` into the saved settings and store it. Provider and people
-- ids must belong to this workspace.
-- @return settings | nil, { field = message }
function Settings.save(ns, actor_uuid, patch)
    if type(patch) ~= "table" or is_array(patch) then return nil, { settings = "an object" } end
    for k in pairs(patch) do
        if Settings.DEFAULTS[k] == nil then return nil, { [k] = "unknown setting" } end
    end
    local row = db.query("SELECT settings FROM crm_lead_settings WHERE namespace_id = ?", ns)[1]
    local merged = merge(merge(Settings.DEFAULTS, row and decode(row.settings) or {}), patch)
    local clean, errs = Settings.validate(merged)
    if not clean then return nil, errs end
    if clean.ai_provider_uuid ~= cjson.null and #db.query(
        "SELECT 1 FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?", ns, clean.ai_provider_uuid) == 0 then
        return nil, { ai_provider_uuid = "not an AI provider of this workspace" }
    end
    for _, field in ipairs({ "round_robin_user_uuids", "manager_user_uuids" }) do
        if #clean[field] > 0 then
            local found = db.query([[
                SELECT COUNT(DISTINCT u.uuid) AS n FROM users u
                JOIN namespace_members m ON m.user_id = u.id AND m.namespace_id = ? AND m.status = 'active'
                WHERE u.uuid IN ?
            ]], ns, db.list(clean[field]))[1]
            if tonumber(found.n) ~= #clean[field] then
                return nil, { [field] = "everyone must be an active member of this workspace" }
            end
        end
    end
    db.query([[
        INSERT INTO crm_lead_settings (namespace_id, settings, updated_by_uuid, updated_at)
        VALUES (?, ?::jsonb, ?, NOW())
        ON CONFLICT (namespace_id) DO UPDATE SET settings = EXCLUDED.settings,
            updated_by_uuid = EXCLUDED.updated_by_uuid, updated_at = NOW()
    ]], ns, cjson.encode(clean), actor_uuid or db.NULL)
    return clean
end

return Settings
