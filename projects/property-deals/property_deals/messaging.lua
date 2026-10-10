-- Instant alerts to staff (the "call this hot lead now" alert) over free / open-source channels,
-- each a workspace connector (Settings → Data connectors):
--   ntfy         self-hosted or ntfy.sh push (open source). config { base_url?, topic_prefix }, secret = access token?
--                Each person subscribes to their topic in the ntfy app: their own (notification prefs ntfy_topic)
--                or <topic_prefix>-<first 12 of their user uuid>.
--   telegram     a Telegram bot (free Bot API). secret = bot token, config { base_url? }. Each person puts their
--                chat id in notification prefs (telegram_chat_id) after messaging the bot.
--   sms_gateway  Android SMS Gateway (open source, sms-gate.app): texts from your own phone + SIM.
--                config { base_url, username }, secret = password. To the person's users.phone_no.
-- No paid SMS/WhatsApp APIs. Nothing is sent to leads from here: messages to leads are drafts a person approves.
-- A gateway on your own network needs OPSAPI_AI_ALLOW_PRIVATE=true (the outbound SSRF rule blocks private IPs).
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local H = require("property_deals.http")
local C = require("property_deals.connectors")

local M = {}

M.CHANNELS = { ntfy = "ntfy", telegram = "telegram", sms = "sms_gateway" }

local function null(v) return v == nil or v == db.NULL end

local function e164(phone)
    if type(phone) ~= "string" then return nil end
    local p = phone:gsub("[%s%-%(%)%.]", "")
    if p:match("^00%d+$") then p = "+" .. p:sub(3) end
    if p:match("^0%d%d%d%d%d%d%d%d%d%d?$") then p = "+44" .. p:sub(2) end -- UK national format
    return p:match("^%+%d%d%d%d%d%d%d+$") and p or nil
end
M.e164 = e164

local function base(conn, default)
    local cfg = U.json(conn.config) or {}
    local b = (type(cfg.base_url) == "string" and cfg.base_url ~= "" and cfg.base_url) or default
    return b and b:gsub("/+$", "") or nil
end

--- The connector for a channel (sms|ntfy|telegram), when it is set up.
function M.connector(ns, channel)
    local kind = M.CHANNELS[channel]
    return kind and C.of_kind(ns, kind) or nil
end

function M.available(ns, channel)
    return M.connector(ns, channel) ~= nil
end

--- Where `user_uuid` gets `channel`: { to } or nil (no number / topic / chat id).
local function address(ns, channel, user_uuid, conn)
    if channel == "sms" then
        local row = U.one([[
            SELECT u.phone_no FROM users u JOIN namespace_members m ON m.user_id = u.id AND m.status = 'active'
            WHERE u.uuid = ? AND m.namespace_id = ?
        ]], user_uuid, ns)
        return row and not null(row.phone_no) and e164(row.phone_no) or nil
    end
    local prefs = require("property_deals.notify").prefs(ns, user_uuid)
    if channel == "telegram" then
        return type(prefs.telegram_chat_id) == "string" and prefs.telegram_chat_id ~= "" and prefs.telegram_chat_id or nil
    end
    if channel == "ntfy" then
        if type(prefs.ntfy_topic) == "string" and prefs.ntfy_topic ~= "" then return prefs.ntfy_topic end
        local cfg = U.json(conn.config) or {}
        local prefix = type(cfg.topic_prefix) == "string" and cfg.topic_prefix ~= "" and cfg.topic_prefix or nil
        return prefix and (prefix .. "-" .. tostring(user_uuid):gsub("%-", ""):sub(1, 12)) or nil
    end
end

--- Send one alert. msg = { title, body, url? }. @return true | nil, error
function M.send(ns, channel, to, msg)
    local conn = M.connector(ns, channel)
    if not conn then return nil, "no " .. tostring(channel) .. " connector" end
    local secret, cfg = C.secret(conn), U.json(conn.config) or {}
    local text = tostring(msg.body or ""):sub(1, 1500)
    local _, err
    if channel == "ntfy" then
        local headers = { Title = tostring(msg.title or "OpsAPI"):sub(1, 200), Priority = "urgent", Tags = "telephone_receiver" }
        if msg.url then headers.Click = msg.url end
        if secret then headers.Authorization = "Bearer " .. secret end
        _, err = H.json(base(conn, "https://ntfy.sh") .. "/" .. ngx.escape_uri(to), { method = "POST", headers = headers,
            body = text })
    elseif channel == "telegram" then
        if not secret then return nil, "the Telegram connector has no bot token" end
        _, err = H.json(base(conn, "https://api.telegram.org") .. "/bot" .. secret .. "/sendMessage", { method = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body = cjson.encode({ chat_id = to, text = (msg.title and (msg.title .. "\n") or "") .. text,
                disable_web_page_preview = true }) })
    elseif channel == "sms" then
        local url = base(conn, nil)
        if not url then return nil, "the SMS gateway connector needs base_url" end
        _, err = H.json(url .. "/message", { method = "POST",
            headers = { ["Content-Type"] = "application/json", Authorization = H.basic(cfg.username, secret) },
            body = cjson.encode({ message = (msg.title and (msg.title .. ": ") or "") .. text, phoneNumbers = { to } }) })
    else
        return nil, "unknown channel"
    end
    if err then
        -- The error can carry provider details; it stays in the log.
        ngx.log(ngx.WARN, "[property_deals] ", channel, " alert failed: ", tostring(err))
        return nil, err
    end
    return true
end

--- Send to workspace users (by uuid) who have an address on that channel. @return number sent
function M.to_users(ns, channel, user_uuids, msg)
    local conn = M.connector(ns, channel)
    if not conn then return 0 end
    local sent = 0
    for _, u in ipairs(user_uuids or {}) do
        local to = address(ns, channel, u, conn)
        if to and M.send(ns, channel, to, msg) then sent = sent + 1 end
    end
    return sent
end

return M
