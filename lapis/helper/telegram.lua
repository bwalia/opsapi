--[[
    Telegram helper — send HTML messages via the Telegram Bot API.

    Mirrors the Bot API contract used by the monitoring-go beacon notifier:
    POST https://api.telegram.org/bot<TOKEN>/sendMessage
      { chat_id, text, parse_mode: "HTML", disable_web_page_preview: true }

    Per-namespace credentials (a bot token + chat id) are configured by the
    namespace owner (see crm_lead_notification_settings). Non-throwing: returns
    (ok, err) so callers can surface a helpful message (bad token / wrong chat id)
    to the owner during "send test", and swallow failures during live capture.
]]

local cjson = require("cjson")

local Telegram = {}

local function http_client()
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(10000)
    return httpc, nil
end

--- HTML-escape a value for safe insertion into a Telegram HTML message.
function Telegram.esc(s)
    if s == nil then return "" end
    s = tostring(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- Send an HTML message.
-- @param bot_token string  Bot token from @BotFather
-- @param chat_id string     Target chat id (user, group, or channel)
-- @param text string        HTML body (use Telegram.esc on dynamic values)
-- @return boolean ok, string|nil err
function Telegram.send(bot_token, chat_id, text)
    if not bot_token or bot_token == "" then return false, "Telegram bot token is not configured" end
    if not chat_id or chat_id == "" then return false, "Telegram chat id is not configured" end

    local httpc, err = http_client()
    if not httpc then return false, err end

    local body = cjson.encode({
        chat_id = chat_id,
        text = text,
        parse_mode = "HTML",
        disable_web_page_preview = true,
    })

    local res, rerr = httpc:request_uri(
        "https://api.telegram.org/bot" .. bot_token .. "/sendMessage",
        {
            method = "POST",
            body = body,
            headers = { ["Content-Type"] = "application/json" },
            ssl_verify = true,
        }
    )

    if not res then
        return false, "Telegram request failed: " .. tostring(rerr)
    end
    if res.status ~= 200 then
        -- Telegram returns { ok=false, description="..." } on errors.
        local desc
        local ok, decoded = pcall(cjson.decode, res.body or "")
        if ok and type(decoded) == "table" then desc = decoded.description end
        return false, "Telegram API error: " .. (desc or ("HTTP " .. tostring(res.status)))
    end
    return true, nil
end

return Telegram
