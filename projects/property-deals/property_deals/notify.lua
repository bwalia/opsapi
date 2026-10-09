-- Notifications for Property Deals: in-app (core notifications table), push
-- (FCM or APNs per device, helper.push-notification) and, for digests, email.
-- Push payload contract (docs/property-deals/api-requests/ios-apns-device-tokens.md):
--   { namespace_id, route = task|approval|deal|digest, uuid, event, thread_id = deal uuid }
-- Alert text carries no personal data beyond a deal's short name.
local db = require("lapis.db")
local U = require("property_deals.util")

local N = {}

local function has_table(name)
    return U.one("SELECT to_regclass(?) IS NOT NULL AS ok", name).ok
end

--- n = { kind, title, body, route, uuid, deal_uuid?, event? }
-- @return number of users notified in-app
function N.send(ns, user_uuids, n)
    local seen, users = {}, {}
    for _, u in ipairs(user_uuids or {}) do
        if u and u ~= db.NULL and not seen[u] then seen[u] = true; users[#users + 1] = u end
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
            -- Only members of this workspace hear about its deals.
            local member = U.one([[
                SELECT u.id FROM users u JOIN namespace_members m ON m.user_id = u.id AND m.status = 'active'
                WHERE u.uuid = ? AND m.namespace_id = ?
            ]], u, ns)
            if member then
                local ok, err = pcall(Helper.create, member.id, "property_deals." .. n.kind, n.title, n.body, data)
                if ok then count = count + 1 else ngx.log(ngx.WARN, "[property_deals] in-app notification: ", tostring(err)) end
            end
        end
    end
    if has_table("device_tokens") then
        local push = {}
        for k, v in pairs(data) do push[k] = tostring(v) end
        push.thread_id = n.deal_uuid and tostring(n.deal_uuid) or nil
        local ok, err = pcall(function()
            require("helper.push-notification").sendToUsers(users, { title = n.title, body = n.body }, push)
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
