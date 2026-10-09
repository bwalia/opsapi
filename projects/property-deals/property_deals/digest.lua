-- Daily digest (SPEC §3.3): per person, rules-based. Sent once per local day at
-- the workspace's digest_time (default 07:30, workspace time zone) by
-- jobs/daily_digest.lua: in-app + push, and email when mail is configured.
-- GET /digest shows the live version. When the workspace has a model, the
-- "digest writer" agent turns it into a few sentences (d.prose); these lists
-- stay the source of truth and the plain summary is the fallback.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local Days = require("property_deals.workdays")
local Notify = require("property_deals.notify")

local D = {}

local TASK_COLS = [[
    d.task_uuid, t.title, d.pd_status, d.due_at, d.urgency_score, d.blocking, d.compliance,
    d.deal_uuid, cd.name AS deal_name
]]
local TASK_FROM = [[
    FROM property_deals_task_details d
    JOIN kanban_tasks t ON t.uuid = d.task_uuid
    LEFT JOIN property_deals_deals dl ON dl.uuid = d.deal_uuid
    LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
]]

--- Is this user a Property Deals manager (or workspace owner) here?
local function is_manager(ns, user_uuid)
    for _, u in ipairs(require("property_deals.engine").managers(ns)) do
        if u == user_uuid then return true end
    end
    return false
end

--- The digest for one person on the workspace's current local day.
function D.build(ns, user_uuid, settings)
    local cal = Days.calendar(ns, settings)
    local today = Days.today(cal)
    local manager = is_manager(ns, user_uuid)
    local day_end = Days.at(cal, Days.add(cal, today, 1), "00:00")

    local overdue = db.query("SELECT " .. TASK_COLS .. TASK_FROM .. [[
        WHERE d.namespace_id = ? AND d.owner_user_uuid = ? AND d.pd_status NOT IN ('done', 'cancelled')
          AND d.due_at < NOW() ORDER BY d.urgency_score DESC, d.due_at LIMIT 50
    ]], ns, user_uuid)
    local due_today = db.query("SELECT " .. TASK_COLS .. TASK_FROM .. [[
        WHERE d.namespace_id = ? AND d.owner_user_uuid = ? AND d.pd_status NOT IN ('done', 'cancelled')
          AND d.due_at >= NOW() AND d.due_at < ?::timestamptz ORDER BY d.due_at LIMIT 50
    ]], ns, user_uuid, day_end)

    -- Deals at risk: my deals (owner, or I have open tasks on them); managers see all.
    local mine = manager and "TRUE" or ([[(cd.owner_user_uuid = ]] .. db.escape_literal(user_uuid) .. [[ OR EXISTS (
        SELECT 1 FROM property_deals_task_details x WHERE x.deal_uuid = dl.uuid AND x.owner_user_uuid = ]]
        .. db.escape_literal(user_uuid) .. [[ AND x.pd_status NOT IN ('done', 'cancelled')))]])
    local deals = db.query([[
        SELECT dl.uuid, cd.name, dl.stage_key, dl.health, dl.health_reasons, dl.money_at_risk,
               dl.target_completion_date, dl.predicted_completion_date
        FROM property_deals_deals dl JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
        WHERE dl.namespace_id = ? AND dl.status = 'active' AND dl.health IN ('red', 'amber') AND ]] .. mine .. [[
        ORDER BY (dl.health = 'red') DESC, dl.money_at_risk DESC, dl.target_completion_date NULLS LAST LIMIT 50
    ]], ns)

    local within = tonumber(settings and settings.expiring_within_days) or 14
    local compliance = db.query([[
        SELECT c.uuid, c.check_type, c.subject_type, c.party_role, c.status, c.expires_at, c.deal_uuid, cd.name AS deal_name
        FROM property_deals_compliance_checks c
        LEFT JOIN property_deals_deals dl ON dl.uuid = c.deal_uuid
        LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
        WHERE c.namespace_id = ? AND (
            (c.status = 'passed' AND c.expires_at IS NOT NULL AND c.expires_at < NOW() + make_interval(days => ?))
            OR c.status = 'expired')
        ORDER BY c.expires_at NULLS FIRST LIMIT 50
    ]], ns, within)
    local pof = db.query([[
        SELECT b.uuid, b.pof_status, b.pof_expires_on, COALESCE(c.first_name || ' ' || COALESCE(c.last_name, ''), a.name) AS buyer
        FROM property_deals_buyer_profiles b
        LEFT JOIN crm_contacts c ON c.uuid = b.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = b.account_uuid
        WHERE b.namespace_id = ? AND b.active AND b.pof_expires_on IS NOT NULL
          AND b.pof_expires_on < CURRENT_DATE + ? ORDER BY b.pof_expires_on LIMIT 50
    ]], ns, within)

    -- Approvals I can decide: manager rules only for managers; never my own request.
    local approvals = db.query([[
        SELECT uuid, title, subject_type, rule, deal_uuid, created_at FROM property_deals_approvals
        WHERE namespace_id = ? AND status = 'pending' AND (rule <> 'manager' OR ?)
          AND (requested_by_user_uuid IS DISTINCT FROM ?)
          AND NOT (decisions @> ?::jsonb)
        ORDER BY created_at LIMIT 50
    ]], ns, manager, user_uuid, cjson.encode({ { user_uuid = user_uuid } }))

    local money = 0
    for _, d in ipairs(deals) do money = money + (tonumber(d.money_at_risk) or 0) end
    return {
        date = today, user_uuid = user_uuid, manager = manager,
        overdue = U.array(overdue), due_today = U.array(due_today), deals_at_risk = U.array(deals),
        compliance_expiring = U.array(compliance), proof_of_funds_expiring = U.array(pof),
        approvals_waiting = U.array(approvals),
        totals = {
            overdue = #overdue, due_today = #due_today, deals_at_risk = #deals, money_at_risk = money,
            compliance_expiring = #compliance + #pof, approvals_waiting = #approvals,
        },
    }
end

function D.is_empty(d)
    local t = d.totals
    return t.overdue + t.due_today + t.deals_at_risk + t.compliance_expiring + t.approvals_waiting == 0
end

--- One-line summary used as the notification body.
function D.summary(d)
    local t, bits = d.totals, {}
    if t.overdue > 0 then bits[#bits + 1] = t.overdue .. " overdue" end
    if t.due_today > 0 then bits[#bits + 1] = t.due_today .. " due today" end
    if t.deals_at_risk > 0 then
        bits[#bits + 1] = t.deals_at_risk .. " deal(s) at risk" .. (t.money_at_risk > 0 and string.format(" (£%.0f)", t.money_at_risk) or "")
    end
    if t.compliance_expiring > 0 then bits[#bits + 1] = t.compliance_expiring .. " compliance item(s) expiring" end
    if t.approvals_waiting > 0 then bits[#bits + 1] = t.approvals_waiting .. " approval(s) waiting" end
    return table.concat(bits, " · ")
end

local function esc(s) return (tostring(s or ""):gsub("[<>&\"]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" })) end

local function html(d)
    local out = { "<h2>Your day — " .. esc(d.date) .. "</h2><p>" .. esc(d.prose or D.summary(d)) .. "</p>" }
    local function list(title, rows, fmt)
        if #rows == 0 then return end
        out[#out + 1] = "<h3>" .. title .. "</h3><ul>"
        for _, r in ipairs(rows) do out[#out + 1] = "<li>" .. fmt(r) .. "</li>" end
        out[#out + 1] = "</ul>"
    end
    list("Deals at risk", d.deals_at_risk, function(r)
        return esc(r.name) .. " — " .. esc(r.health) .. (tonumber(r.money_at_risk) > 0 and string.format(", £%.0f at risk", r.money_at_risk) or "")
    end)
    list("Overdue", d.overdue, function(r) return esc(r.title) .. (r.deal_name and (" — " .. esc(r.deal_name)) or "") end)
    list("Due today", d.due_today, function(r) return esc(r.title) .. (r.deal_name and (" — " .. esc(r.deal_name)) or "") end)
    list("Compliance expiring", d.compliance_expiring, function(r) return esc(r.check_type) .. " " .. esc(r.expires_at) end)
    list("Approvals waiting", d.approvals_waiting, function(r) return esc(r.title) end)
    return table.concat(out)
end

--- Who gets a digest: owners of open tasks, deal owners, managers and compliance officers.
local function recipients(ns)
    local set, out = {}, {}
    local function add(u) if u and not set[u] then set[u] = true; out[#out + 1] = u end end
    for _, r in ipairs(db.query([[
        SELECT DISTINCT owner_user_uuid AS u FROM property_deals_task_details
        WHERE namespace_id = ? AND owner_user_uuid IS NOT NULL AND pd_status NOT IN ('done', 'cancelled')
        UNION SELECT DISTINCT cd.owner_user_uuid FROM property_deals_deals dl JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
        WHERE dl.namespace_id = ? AND dl.status = 'active'
    ]], ns, ns)) do add(r.u) end
    local E = require("property_deals.engine")
    for _, u in ipairs(E.managers(ns)) do add(u) end
    for _, u in ipairs(E.members_with_role(ns, "pd_compliance")) do add(u) end
    return out
end

--- Send today's digests once the workspace's local digest time has passed.
-- `force` skips the time check (tests, "send now").
function D.run(ns, settings, force)
    local cal = Days.calendar(ns, settings)
    local time = tostring(settings and settings.digest_time or "07:30")
    if not time:match("^%d%d:%d%d$") then time = "07:30" end
    local now_local = db.query("SELECT to_char(NOW() AT TIME ZONE ?, 'HH24:MI') AS t", cal.tz)[1].t
    if not force and now_local < time then return 0 end
    local today = Days.today(cal)
    local sent = 0
    for _, user in ipairs(recipients(ns)) do
        local d = D.build(ns, user, settings)
        local logged = db.query([[
            INSERT INTO property_deals_digest_log (namespace_id, user_uuid, local_date, payload, empty)
            VALUES (?, ?, ?, ?::jsonb, ?) ON CONFLICT (namespace_id, user_uuid, local_date) DO NOTHING RETURNING id
        ]], ns, user, today, cjson.encode(d), D.is_empty(d))[1]
        if logged and not D.is_empty(d) then
            -- The digest writer agent may turn the lists into prose; the lists stay as they are.
            local ok, prose = pcall(require("property_deals.ai.runner").write_digest, ns, user, d)
            if not ok then ngx.log(ngx.WARN, "[property_deals] digest writer: ", tostring(prose)); prose = nil end
            if prose then
                d.prose = prose
                db.query("UPDATE property_deals_digest_log SET payload = ?::jsonb WHERE id = ?", cjson.encode(d), logged.id)
            end
            Notify.send(ns, { user }, { kind = "daily_digest", event = "property_deals.digest.daily", route = "digest",
                uuid = today, title = "Your day", body = prose or D.summary(d) })
            local u = U.one("SELECT email FROM users WHERE uuid = ?", user)
            if (settings == nil or settings.digest_email ~= false) and Notify.allowed(ns, user, "daily_digest", "email") then
                Notify.email(u and u.email, "Your property deals today — " .. today, html(d), prose or D.summary(d))
            end
            sent = sent + 1
        end
    end
    return sent
end

return D
