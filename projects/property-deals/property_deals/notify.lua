-- Notifications for Property Deals: in-app (core notifications table), push
-- (FCM or APNs per device, helper.push-notification) and, for digests, email.
-- Push payload contract (docs/property-deals/api-requests/ios-apns-device-tokens.md):
--   { namespace_id, route = task|approval|deal|digest, uuid, event, thread_id = deal uuid }
-- Alert text carries no personal data beyond a deal's short name.
local db = require("lapis.db")
local U = require("property_deals.util")

local N = {}

-- Per-user preferences (ios-notification-preferences): push / email per
-- category, plus quiet hours (workspace time zone) that hold back push. In-app
-- notifications always arrive. No saved row = everything on.
N.CATEGORIES = { "sla_warning", "overdue", "escalated", "approval_requested", "digest", "compliance_expiring",
    "agent_update", "deal_scout", "hot_lead" }
local CATEGORY_OF = { sla_warning = "sla_warning", task_overdue = "overdue", task_escalated = "escalated",
    approval_requested = "approval_requested", daily_digest = "digest", compliance_expiring = "compliance_expiring",
    agent_update = "agent_update", scout_alert = "deal_scout", hot_lead = "hot_lead" }
-- ntfy, Telegram and SMS (free / open-source connectors, property_deals.messaging) are off unless a
-- category turns them on; a hot lead ("call them now") has them on by default.
N.CHANNELS = { "push", "email", "ntfy", "telegram", "sms" }
local TEXT_ON = { hot_lead = true }

local function defaults()
    local p = {}
    for _, c in ipairs(N.CATEGORIES) do
        local on = TEXT_ON[c] == true
        p[c] = { push = true, email = true, ntfy = on, telegram = on, sms = on }
    end
    return p
end

--- A user's preferences in this workspace, defaults filled in.
function N.prefs(ns, user_uuid)
    local p = defaults()
    local row = U.one("SELECT prefs FROM property_deals_notification_prefs WHERE namespace_id = ? AND user_uuid = ?", ns, user_uuid)
    local saved = row and U.json(row.prefs) or {}
    for _, c in ipairs(N.CATEGORIES) do
        if type(saved[c]) == "table" then
            for _, ch in ipairs(N.CHANNELS) do
                if saved[c][ch] ~= nil then p[c][ch] = saved[c][ch] == true end
            end
        end
    end
    if type(saved.quiet_hours) == "table" then p.quiet_hours = saved.quiet_hours end
    -- Where this person gets ntfy / Telegram alerts.
    for _, k in ipairs({ "ntfy_topic", "telegram_chat_id" }) do
        if type(saved[k]) == "string" and saved[k] ~= "" then p[k] = saved[k] end
    end
    return p
end

local HHMM = "^[012]%d:[0-5]%d$"

--- Merge `input` into the saved preferences (only fields sent change).
function N.save_prefs(ns, user_uuid, input)
    local current = N.prefs(ns, user_uuid)
    local errors = {}
    for k, v in pairs(input) do
        if type(current[k]) == "table" and k ~= "quiet_hours" then
            if type(v) ~= "table" then errors[k] = "{ push?, email?, ntfy?, telegram?, sms? }"
            else
                for _, ch in ipairs(N.CHANNELS) do
                    if v[ch] ~= nil then
                        if type(v[ch]) ~= "boolean" then errors[k] = ch .. " must be true or false"
                        else current[k][ch] = v[ch] end
                    end
                end
            end
        elseif k == "ntfy_topic" and v == "generate" then
            -- Anyone who knows an ntfy topic can read it: a fresh one with 128 random bits.
            current[k] = "opsapi-" .. require("resty.string").to_hex(require("resty.random").bytes(16, true))
        elseif k == "ntfy_topic" or k == "telegram_chat_id" then
            if v == require("cjson").null or v == false or v == "" then current[k] = nil
            elseif type(v) ~= "string" or #v > 120 or not v:match("^[%w%-_@%.]+$") then
                errors[k] = "letters, digits, - _ @ . (max 120)"
            else current[k] = v end
        elseif k == "quiet_hours" then
            if v == require("cjson").null or v == false then current.quiet_hours = nil
            elseif type(v) ~= "table" or type(v.from) ~= "string" or type(v.to) ~= "string"
                or not v.from:match(HHMM) or not v.to:match(HHMM) then
                errors.quiet_hours = "{ from: \"HH:MM\", to: \"HH:MM\" } or null"
            else current.quiet_hours = { from = v.from, to = v.to } end
        else
            errors[k] = "unknown preference"
        end
    end
    if next(errors) then return nil, errors end
    db.query([[
        INSERT INTO property_deals_notification_prefs (namespace_id, user_uuid, prefs) VALUES (?, ?, ?::jsonb)
        ON CONFLICT (namespace_id, user_uuid) DO UPDATE SET prefs = EXCLUDED.prefs, updated_at = NOW()
    ]], ns, user_uuid, require("cjson").encode(current))
    return N.prefs(ns, user_uuid)
end

local function quiet_now(ns, q)
    if type(q) ~= "table" or not q.from or not q.to then return false end
    local s = require("helper.plugin-sdk").settings("property_deals", ns) or {}
    local tz = s.timezone or "Europe/London"
    local ok, r = pcall(U.one, "SELECT to_char(NOW() AT TIME ZONE ?, 'HH24:MI') AS t", tz)
    local now = ok and r and r.t or "12:00"
    if q.from < q.to then return now >= q.from and now < q.to end
    return now >= q.from or now < q.to -- over midnight, e.g. 21:00-07:00
end

--- May this user get `channel` (push|email|ntfy|telegram|sms) for notification kind `kind` now?
function N.allowed(ns, user_uuid, kind, channel)
    local cat = CATEGORY_OF[kind]
    if not cat then return channel == "push" or channel == "email" end
    local p = N.prefs(ns, user_uuid)
    if p[cat] and p[cat][channel] ~= true then
        -- A workspace may make escalations to managers impossible to mute.
        local s = require("helper.plugin-sdk").settings("property_deals", ns) or {}
        if not (cat == "escalated" and s.escalations_always_notify == true) then return false end
    end
    if channel ~= "email" and cat ~= "digest" and quiet_now(ns, p.quiet_hours) then return false end
    return true
end

local function has_table(name)
    return U.one("SELECT to_regclass(?) IS NOT NULL AS ok", name).ok
end

--- The user ({ id, email, phone_no }) while they are an active member of this workspace, else nil.
-- Every channel asks this first: someone removed from the workspace hears nothing more about it.
function N.member(ns, user_uuid)
    if user_uuid == nil or user_uuid == db.NULL then return nil end
    return U.one([[
        SELECT u.id, u.email, u.phone_no FROM users u
        JOIN namespace_members m ON m.user_id = u.id AND m.status = 'active'
        WHERE u.uuid = ? AND m.namespace_id = ?
    ]], user_uuid, ns)
end

--- n = { kind, title, body, route, uuid, deal_uuid?, event? }
-- @return number of users notified in-app
function N.send(ns, user_uuids, n)
    local seen, users, members = {}, {}, {}
    for _, u in ipairs(user_uuids or {}) do
        if u and u ~= db.NULL and not seen[u] then
            seen[u] = true
            members[u] = N.member(ns, u)
            if members[u] then users[#users + 1] = u end
        end
    end
    if #users == 0 then return 0 end
    local ns_row = U.one("SELECT uuid FROM namespaces WHERE id = ?", ns)
    local data = {
        namespace_id = ns_row and ns_row.uuid, route = n.route, uuid = n.uuid, event = n.event,
        deal_uuid = n.deal_uuid, plugin = "property_deals",
    }
    local count = 0
    if has_table("notifications") then
        local Helper = require("helper.notification-helper")
        for _, u in ipairs(users) do
            local ok, err = pcall(Helper.create, members[u].id, "property_deals." .. n.kind, n.title, n.body, data)
            if ok then count = count + 1
            else ngx.log(ngx.WARN, "[property_deals] in-app notification: ", tostring(err)) end
        end
    end
    local push_users = {}
    for _, u in ipairs(users) do
        local ok, yes = pcall(N.allowed, ns, u, n.kind, "push")
        if not ok or yes then push_users[#push_users + 1] = u end
    end
    if has_table("device_tokens") and #push_users > 0 then
        local push = {}
        for k, v in pairs(data) do push[k] = tostring(v) end
        push.thread_id = n.deal_uuid and tostring(n.deal_uuid) or nil
        local ok, err = pcall(function()
            require("helper.push-notification").sendToUsers(push_users, { title = n.title, body = n.body }, push)
        end)
        if not ok then ngx.log(ngx.WARN, "[property_deals] push: ", tostring(err)) end
    end
    return count
end

--- Email, when the deployment has mail configured. Never raises.
function N.email(to, subject, html, text)
    local ok, Mail = pcall(require, "helper.mail")
    if not ok or not Mail.isConfigured() or not to then return false end
    local sent, err = pcall(Mail.send, { to = to, subject = subject, html = html, text = text })
    if not sent then ngx.log(ngx.WARN, "[property_deals] email: ", tostring(err)) end
    return sent
end

return N
