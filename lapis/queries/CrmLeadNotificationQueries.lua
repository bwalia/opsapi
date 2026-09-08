--[[
    CrmLeadNotificationQueries

    Per-namespace lead notification settings + the dispatch that fires when a
    lead is captured. Three channels:
      1. confirmation email to the person who submitted the lead
      2. "you got a lead" email to the namespace owner/admin
      3. Telegram alert (owner-configured bot token + chat id)

    Settings default to sensible on-by-default behaviour when no row exists:
    confirmation + admin email ON, Telegram OFF. The Telegram bot token is a
    secret — getForApi() never returns it (only a masked hint), and upsert()
    only overwrites it when a fresh value is supplied.
]]

local db = require("lapis.db")
local Global = require("helper.global")

local CrmLeadNotificationQueries = {}

local DEFAULTS = {
    notify_admin = true,
    admin_email = nil,
    send_confirmation = true,
    telegram_enabled = false,
    telegram_chat_id = nil,
}

--- Raw settings row for a namespace, or nil.
function CrmLeadNotificationQueries.get(namespace_id)
    local rows = db.select("* FROM crm_lead_notification_settings WHERE namespace_id = ? LIMIT 1", namespace_id)
    return rows and rows[1] or nil
end

--- Effective settings (row merged over DEFAULTS) — always returns a table.
function CrmLeadNotificationQueries.getEffective(namespace_id)
    local row = CrmLeadNotificationQueries.get(namespace_id)
    if not row then
        local d = {}
        for k, v in pairs(DEFAULTS) do d[k] = v end
        return d
    end
    return row
end

--- API-safe view: masks the bot token (never echo the secret).
function CrmLeadNotificationQueries.getForApi(namespace_id)
    local row = CrmLeadNotificationQueries.get(namespace_id)
    local s = row or DEFAULTS
    local token = row and row.telegram_bot_token or nil
    local hint = nil
    if token and token ~= "" then
        hint = "•••" .. string.sub(token, -4)
    end
    return {
        notify_admin = s.notify_admin ~= false,
        admin_email = s.admin_email or "",
        send_confirmation = s.send_confirmation ~= false,
        telegram_enabled = s.telegram_enabled == true,
        telegram_chat_id = s.telegram_chat_id or "",
        has_telegram_token = token ~= nil and token ~= "",
        telegram_token_hint = hint or "",
    }
end

--- Create or update settings. `data` is already-coerced values from the route.
-- telegram_bot_token is only written when a fresh non-empty value is supplied
-- (so the masked round-trip from the UI never clears an existing token).
function CrmLeadNotificationQueries.upsert(namespace_id, data)
    local now = db.raw("NOW()")
    local existing = CrmLeadNotificationQueries.get(namespace_id)

    local fields = {
        notify_admin = data.notify_admin == true,
        admin_email = (data.admin_email ~= nil and data.admin_email ~= "") and data.admin_email or nil,
        send_confirmation = data.send_confirmation == true,
        telegram_enabled = data.telegram_enabled == true,
        telegram_chat_id = (data.telegram_chat_id ~= nil and data.telegram_chat_id ~= "") and data.telegram_chat_id or nil,
        updated_at = now,
    }
    -- Only overwrite the token when the caller sent a new, real one.
    if data.telegram_bot_token ~= nil and data.telegram_bot_token ~= "" then
        fields.telegram_bot_token = data.telegram_bot_token
    end

    if existing then
        db.update("crm_lead_notification_settings", fields, { id = existing.id })
    else
        fields.uuid = Global.generateUUID()
        fields.namespace_id = namespace_id
        fields.created_at = now
        db.insert("crm_lead_notification_settings", fields)
    end
    return CrmLeadNotificationQueries.getForApi(namespace_id)
end

--- Resolve the recipient for the admin "you got a lead" email:
-- explicit admin_email override, else the namespace owner's email.
function CrmLeadNotificationQueries.resolveAdminEmail(namespace_id, settings)
    if settings and settings.admin_email and settings.admin_email ~= "" then
        return settings.admin_email
    end
    local rows = db.query([[
        SELECT u.email FROM users u
        JOIN namespaces n ON n.owner_user_id = u.id
        WHERE n.id = ? LIMIT 1
    ]], namespace_id)
    if rows and rows[1] and rows[1].email and rows[1].email ~= "" then
        return rows[1].email
    end
    return nil
end

-- Build the Telegram HTML alert body for a captured lead.
local function telegram_body(Telegram, namespace, lead)
    local esc = Telegram.esc
    local name = ((lead.first_name or "") .. " " .. (lead.last_name or "")):gsub("^%s+", ""):gsub("%s+$", "")
    local parts = {}
    parts[#parts + 1] = "🎯 <b>New lead</b>" .. (namespace.name and (" — " .. esc(namespace.name)) or "")
    parts[#parts + 1] = ""
    if name ~= "" then parts[#parts + 1] = "<b>" .. esc(name) .. "</b>" end
    if lead.company_name and lead.company_name ~= "" then parts[#parts + 1] = "🏢 " .. esc(lead.company_name) end
    if lead.email and lead.email ~= "" then parts[#parts + 1] = "📧 " .. esc(lead.email) end
    if lead.phone and lead.phone ~= "" then parts[#parts + 1] = "📞 " .. esc(lead.phone) end
    if lead.source and lead.source ~= "" then parts[#parts + 1] = "🔖 " .. esc(lead.source) end
    if lead.notes and lead.notes ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "💬 " .. esc(lead.notes)
    end
    return table.concat(parts, "\n")
end

-- Pure network sends (no DB). Runs inside an ngx.timer so Mail (sync SMTP) and
-- the Telegram cosocket never hold the HTTP response. `p` is a self-contained
-- payload built in request context by notify(). Never throws.
local function do_sends(p)
    local Mail = require("helper.mail")
    local lead, s = p.lead, p.settings

    -- 1) Confirmation to the submitter
    if s.send_confirmation ~= false and lead.email and lead.email ~= "" then
        pcall(function()
            if not Mail.isConfigured() then return end
            Mail.send({
                to = lead.email,
                subject = "We got your enquiry — thanks for getting in touch",
                template = "lead_confirmation",
                sync = true,
                data = { first_name = lead.first_name, company_name = lead.company_name, notes = lead.notes },
            })
        end)
    end

    -- 2) "You got a lead" to the namespace owner/admin
    if s.notify_admin ~= false and p.admin_email and p.admin_email ~= "" then
        pcall(function()
            if not Mail.isConfigured() then return end
            Mail.send({
                to = p.admin_email,
                subject = "New lead: " .. ((lead.first_name or "") .. " " .. (lead.last_name or "")):gsub("%s+$", ""),
                template = "lead_admin_notification",
                sync = true,
                data = {
                    first_name = lead.first_name, last_name = lead.last_name, email = lead.email,
                    phone = lead.phone, company_name = lead.company_name, job_title = lead.job_title,
                    source = lead.source, notes = lead.notes, namespace_name = p.namespace.name,
                },
            })
        end)
    end

    -- 3) Telegram alert
    if s.telegram_enabled == true then
        pcall(function()
            local Telegram = require("helper.telegram")
            local ok, err = Telegram.send(s.telegram_bot_token, s.telegram_chat_id,
                telegram_body(Telegram, p.namespace, lead))
            if not ok then
                ngx.log(ngx.WARN, "[lead-notify] telegram failed for namespace ", p.namespace.id, ": ", tostring(err))
            end
        end)
    end
end

--- Fire all configured notifications for a freshly-captured lead.
-- Call from a request handler: DB reads (settings + owner email) happen now, in
-- request context; the actual sends are deferred to an ngx.timer so the caller's
-- HTTP response returns immediately. Never throws.
function CrmLeadNotificationQueries.notify(namespace, lead)
    local ok, err = pcall(function()
        local settings = CrmLeadNotificationQueries.getEffective(namespace.id)
        local admin_email = nil
        if settings.notify_admin ~= false then
            admin_email = CrmLeadNotificationQueries.resolveAdminEmail(namespace.id, settings)
        end
        -- Snapshot into a plain payload — no ngx.var / DB access inside the timer.
        local payload = {
            namespace = { id = namespace.id, name = namespace.name },
            admin_email = admin_email,
            settings = {
                notify_admin = settings.notify_admin ~= false,
                send_confirmation = settings.send_confirmation ~= false,
                telegram_enabled = settings.telegram_enabled == true,
                telegram_bot_token = settings.telegram_bot_token,
                telegram_chat_id = settings.telegram_chat_id,
            },
            lead = {
                first_name = lead.first_name, last_name = lead.last_name, email = lead.email,
                phone = lead.phone, company_name = lead.company_name, job_title = lead.job_title,
                source = lead.source, notes = lead.notes,
            },
        }
        local tok, terr = ngx.timer.at(0, function(premature)
            if premature then return end
            do_sends(payload)
        end)
        if not tok then
            ngx.log(ngx.WARN, "[lead-notify] failed to schedule notifications: ", tostring(terr))
        end
    end)
    if not ok then
        ngx.log(ngx.WARN, "[lead-notify] notify() error: ", tostring(err))
    end
end

--- Send a test Telegram message for the "Send test" button. Returns (ok, err).
function CrmLeadNotificationQueries.sendTestTelegram(namespace_id, override)
    local settings = CrmLeadNotificationQueries.get(namespace_id) or {}
    -- Allow testing with values from the form before they're saved.
    local token = (override and override.telegram_bot_token ~= nil and override.telegram_bot_token ~= "")
        and override.telegram_bot_token or settings.telegram_bot_token
    local chat = (override and override.telegram_chat_id ~= nil and override.telegram_chat_id ~= "")
        and override.telegram_chat_id or settings.telegram_chat_id
    local Telegram = require("helper.telegram")
    return Telegram.send(token, chat,
        "✅ <b>OpsAPI</b>\nTelegram lead alerts are connected. You'll get a message here whenever a new lead comes in.")
end

return CrmLeadNotificationQueries
