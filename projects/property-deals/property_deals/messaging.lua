-- Instant alerts to staff (the "call this hot lead now" alert) over free / open-source channels,
-- each a workspace connector (Settings → Data connectors):
--   ntfy         self-hosted or ntfy.sh push (open source). config { base_url? }, secret = access token?
--                Anyone who knows a topic can read it, so only people who set their own topic get alerts
--                (notification prefs ntfy_topic; "generate" makes a random one) and the text says only that
--                something is waiting in OpsAPI.
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

--- Where `user_uuid` gets `channel`, or nil (not an active member here, or no number / topic / chat id).
local function address(ns, channel, user_uuid)
    local N = require("property_deals.notify")
    local member = N.member(ns, user_uuid)
    if not member then return nil end
    if channel == "sms" then
        return not null(member.phone_no) and e164(member.phone_no) or nil
    end
    local key = ({ telegram = "telegram_chat_id", ntfy = "ntfy_topic" })[channel]
    local v = key and N.prefs(ns, user_uuid)[key]
    return type(v) == "string" and v ~= "" and v or nil
end

--- Send one alert. msg = { title, body, public?, url? }: ntfy gets only `public` (no names, numbers or
-- message text: a topic is readable by anyone who knows it). @return true | nil, error
function M.send(ns, channel, to, msg)
    local conn = M.connector(ns, channel)
    if not conn then return nil, "no " .. tostring(channel) .. " connector" end
    local secret, cfg = C.secret(conn), U.json(conn.config) or {}
    local text = tostring(msg.body or ""):sub(1, 1500)
    local _, err
    if channel == "ntfy" then
        text = tostring(msg.public or "Something needs you: open OpsAPI"):sub(1, 200)
        local headers = { Title = "OpsAPI", Priority = "urgent", Tags = "telephone_receiver" }
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
        local to = address(ns, channel, u)
        if to and M.send(ns, channel, to, msg) then sent = sent + 1 end
    end
    return sent
end

return M
