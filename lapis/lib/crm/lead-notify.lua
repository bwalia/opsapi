--[[
    Tell people about leads: in-app (core notifications), phone push and email
    ==========================================================================

    Every channel first checks the person is still an active member of the
    workspace: someone removed hears nothing more about its leads. Push and
    email failures are logged, never raised — a notification must not undo
    the change it reports. Email goes through the workspace's own SMTP when
    it has one (helper/namespace-mail.lua), else the platform's.
]]

local db = require("lapis.db")

local Notify = {}

local function frontend()
    local o = os.getenv("FRONTEND_URL") or os.getenv("DASHBOARD_URL") or ""
    return (o:gsub("/+$", ""))
end

function Notify.lead_url(lead_uuid)
    local base = frontend()
    if base == "" then return nil end
    return base .. "/dashboard/leads/" .. tostring(lead_uuid)
end

local function has_table(name)
    return db.query("SELECT to_regclass(?) IS NOT NULL AS ok", name)[1].ok
end

local function members(ns, uuids)
    local seen, list = {}, {}
    for _, u in ipairs(uuids or {}) do
        if type(u) == "string" and u ~= "" and not seen[u] then
            seen[u] = true
            list[#list + 1] = u
        end
    end
    if #list == 0 then return {} end
    return db.query([[
        SELECT u.id, u.uuid, u.email FROM users u
        JOIN namespace_members m ON m.user_id = u.id AND m.status = 'active' AND m.namespace_id = ?
        WHERE u.uuid IN ?
    ]], ns, db.list(list))
end

--- n = { kind, title, body, lead_uuid, email = true|false, action_label? }
-- @return number of people notified
function Notify.send(ns, user_uuids, n)
    local people = members(ns, user_uuids)
    if #people == 0 then return 0 end
    local ns_row = db.query("SELECT uuid, name FROM namespaces WHERE id = ?", ns)[1] or {}
    local url = n.lead_uuid and Notify.lead_url(n.lead_uuid)
    local data = { namespace_id = ns_row.uuid, route = "lead", uuid = n.lead_uuid, event = n.kind,
        entity_type = "crm_lead", entity_id = n.lead_uuid, url = url }

    if has_table("notifications") then
        local Helper = require("helper.notification-helper")
        for _, p in ipairs(people) do
            local ok, err = pcall(Helper.create, p.id, "crm_leads." .. tostring(n.kind), n.title, n.body, data)
            if not ok then ngx.log(ngx.WARN, "[crm-leads] in-app notification: ", tostring(err)) end
        end
    end

    if has_table("device_tokens") then
        local uuids, push = {}, {}
        for _, p in ipairs(people) do uuids[#uuids + 1] = p.uuid end
        for k, v in pairs(data) do push[k] = tostring(v) end
        local ok, err = pcall(function()
            require("helper.push-notification").sendToUsers(uuids, { title = n.title, body = n.body }, push)
        end)
        if not ok then ngx.log(ngx.WARN, "[crm-leads] push: ", tostring(err)) end
    end

    if n.email ~= false then
        local Mail = require("helper.mail")
        local smtp = require("helper.namespace-mail").smtp(ns)
        if smtp or Mail.isConfigured() then
            for _, p in ipairs(people) do
                if p.email and p.email ~= db.NULL and p.email ~= "" then
                    local ok, err = pcall(Mail.send, {
                        to = p.email, subject = n.title, template = "notification", smtp = smtp,
                        from_email = smtp and smtp.from_email or nil, from_name = smtp and smtp.from_name or nil,
                        data = { title = n.title, message = n.body, action_url = url,
                            action_label = n.action_label or "Open the lead", app_name = ns_row.name or "OpsAPI" },
                    })
                    if not ok then ngx.log(ngx.WARN, "[crm-leads] email: ", tostring(err)) end
                end
            end
        end
    end
    return #people
end

return Notify
