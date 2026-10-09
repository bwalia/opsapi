--[[
    Forms: background work
    ======================

    handlers: the "core.forms" subscriber of the event outbox
    (helper/plugin-events.lua). A response insert queues form.submission.created
    in the same transaction, so its emails are sent at least once, retried with
    backoff, and survive a pod restart. Each email is recorded in the
    response's `notifications` once sent, so a retry never sends it twice:
      * the new-response alert (settings.notify_emails, else the creator);
      * the auto-reply to the respondent (settings.auto_reply);
      * the invitation email of a workspace invitation the response created.
    form.submission.updated (a spam response marked "not spam", a retry)
    sends whatever is still due.

    maintain(): hourly on worker 0, one pod at a time (advisory lock): purge
    spam after SPAM_DAYS, responses past a form's retention_days, and forms
    deleted more than DELETED_FORM_DAYS ago.
]]

local db = require("lapis.db")
local cjson = require("lib.forms.json")
local Fields = require("lib.forms.fields")

local FormJobs = {}

FormJobs.SPAM_DAYS = 30
FormJobs.DELETED_FORM_DAYS = 30
local BATCH = 1000

local function decode(v, fallback)
    return require("lib.forms.submit").decode(v, fallback)
end

local function nonnull(v)
    if v == nil or v == db.NULL or v == cjson.null then return nil end
    return v
end

local function mark(id, kind)
    db.query("UPDATE form_submissions SET notifications = notifications || jsonb_build_object(?::text, true) "
        .. "WHERE id = ?", kind, id)
end

local function origin_of(row)
    local o = nonnull(row.public_origin) or os.getenv("FRONTEND_URL")
    return o and o ~= "" and o:gsub("/+$", "") or nil
end

-- "Label: answer" lines and a { label, value } list for the emails.
local function answer_lines(schema, answers)
    local list, lines = {}, {}
    for _, f in ipairs(schema.fields or {}) do
        local def = Fields.TYPES[f.type]
        if def and def.input ~= false and answers[f.key] ~= nil then
            local value = Fields.show(f, answers[f.key])
            list[#list + 1] = { label = f.label, value = value }
            lines[#lines + 1] = f.label .. ": " .. value
        end
    end
    return list, table.concat(lines, "\n")
end

local function deliver(event)
    local s = db.query([[
        SELECT s.id, s.uuid, s.namespace_id, s.status, s.data, s.respondent_email, s.notifications, s.created_at,
               f.uuid AS form_uuid, f.title, f.settings, f.public_origin, f.created_by_uuid,
               n.name AS namespace_name, v.schema AS version_schema
        FROM form_submissions s
        JOIN forms f ON f.id = s.form_id
        JOIN namespaces n ON n.id = s.namespace_id
        JOIN form_versions v ON v.id = s.version_id
        WHERE s.uuid = ?
    ]], event.entity_id)[1]
    if not s or s.status == "spam" then return true end

    local NamespaceMail = require("helper.namespace-mail")
    local mail_ok = NamespaceMail.smtp(s.namespace_id) ~= nil or require("helper.mail").isConfigured()

    local sent = decode(s.notifications, {})
    local settings = decode(s.settings, {})
    local schema = decode(s.version_schema, { fields = {} })
    local answers = decode(s.data, {})
    local brand = { app_name = s.namespace_name }
    local origin = origin_of(s)
    local list, text = answer_lines(schema, answers)

    -- 4/5 (no email needed): the in-app alert and the chat channel post.
    local alerts_ok, alerts_err = pcall(FormJobs.alerts, s, settings, sent, list, origin)
    if not alerts_ok then return nil, "alerts: " .. tostring(alerts_err) end
    -- No SMTP anywhere: no email can be sent, and retrying won't change that.
    if not mail_ok then return true end

    -- 1. New-response alert
    local recipients = settings.notify_emails
    if type(recipients) ~= "table" or #recipients == 0 then
        local creator = nonnull(s.created_by_uuid)
            and db.query("SELECT email FROM users WHERE uuid = ?", s.created_by_uuid)[1]
        recipients = creator and { creator.email } or {}
    end
    for _, to in ipairs(recipients) do
        local kind = "admin:" .. to
        if not sent[kind] then
            local ok, err = NamespaceMail.send(s.namespace_id, "forms.new_response", to, {
                form_title = s.title,
                answers = list,
                answers_text = text,
                response_url = origin and (origin .. "/dashboard/forms/" .. s.form_uuid .. "?response=" .. s.uuid),
            }, brand)
            if not ok then return nil, "new-response email to " .. to .. ": " .. tostring(err) end
            mark(s.id, kind)
        end
    end

    -- 2. Auto-reply to the respondent. {{field_key}} placeholders are filled
    -- with plain-text answers; the template escapes everything it prints.
    local reply = type(settings.auto_reply) == "table" and settings.auto_reply or {}
    local to = nonnull(s.respondent_email)
    if reply.enabled and to and not sent.auto_reply then
        local vars = { form_title = s.title }
        for _, f in ipairs(schema.fields or {}) do
            if answers[f.key] ~= nil then vars[f.key] = Fields.show(f, answers[f.key]) end
        end
        local ok, err = NamespaceMail.send(s.namespace_id, "forms.auto_reply", to, {
            form_title = s.title,
            reply_subject = NamespaceMail.fill(reply.subject or "", vars, true),
            reply_body = NamespaceMail.fill(reply.body or "", vars, true),
        }, brand)
        if not ok then return nil, "auto-reply: " .. tostring(err) end
        mark(s.id, "auto_reply")
    end

    -- 3. Invitations this response created
    for _, l in ipairs(db.query([[SELECT entity_uuid FROM form_submission_links
        WHERE submission_id = ? AND outcome = 'invited' AND entity_type = 'invitation']], s.id)) do
        local kind = "invite:" .. l.entity_uuid
        if not sent[kind] then
            local ok, err = require("queries.NamespaceInvitationQueries").sendEmail(l.entity_uuid, origin)
            if not ok and err ~= "not_pending" then return nil, "invitation email: " .. tostring(err) end
            mark(s.id, kind)
        end
    end
    return true
end

--- The in-app notification (the header bell) and the chat channel post.
function FormJobs.alerts(s, settings, sent, list, origin)
    local link = "/dashboard/forms/" .. s.form_uuid .. "?response=" .. s.uuid
    local who = nonnull(s.respondent_email) or "Someone"
    if settings.notify_in_app ~= false and not sent.in_app
        and db.query("SELECT to_regclass('notifications') IS NOT NULL AS ok")[1].ok then
        -- The form's creator, and the notify addresses that are members here.
        local users = db.query([[
            SELECT DISTINCT u.id FROM users u JOIN namespace_members m ON m.user_id = u.id
            WHERE m.namespace_id = ? AND m.status = 'active'
              AND (u.uuid = ? OR lower(u.email) IN ?)
        ]], s.namespace_id, nonnull(s.created_by_uuid) or "",
            db.list(#(settings.notify_emails or {}) > 0 and settings.notify_emails or { "" }))
        local Notify = require("helper.notification-helper")
        for _, u in ipairs(users) do
            Notify.create(u.id, "form_response", "New response: " .. s.title, who .. " answered " .. s.title,
                { form_uuid = s.form_uuid, submission_uuid = s.uuid, namespace_id = tonumber(s.namespace_id),
                  url = link })
        end
        mark(s.id, "in_app")
    end
    local channel = settings.chat_channel_uuid
    if channel and not sent.chat and require("helper.project-config").isFeatureEnabled("chat") then
        local ch = db.query("SELECT uuid, name, type, namespace_id FROM chat_channels WHERE uuid = ? AND namespace_id = ?",
            channel, s.namespace_id)[1]
        if ch then
            local lines = { ("New response to \"%s\" from %s"):format(s.title, who) }
            for i = 1, math.min(#list, 6) do
                lines[#lines + 1] = "• " .. list[i].label .. ": " .. tostring(list[i].value):sub(1, 200)
            end
            if origin then lines[#lines + 1] = origin .. link end
            local ChatMessageQueries = require("queries.ChatMessageQueries")
            local msg = ChatMessageQueries.createSystemMessage(ch.uuid, table.concat(lines, "\n"))
            pcall(function()
                require("lib.chat-ws").broadcast_message(ch.uuid, ch.namespace_id,
                    ChatMessageQueries.show(msg.uuid) or msg, ch)
            end)
        end
        mark(s.id, "chat")
    end
end

FormJobs.handlers = {
    ["form.submission.created"] = deliver,
    ["form.submission.updated"] = deliver,
}

-- ---------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------

local function batched(sql, ...)
    local total = 0
    for _ = 1, 50 do
        local res = db.query(sql, ...)
        local n = res.affected_rows or 0
        total = total + n
        if n < BATCH then break end
    end
    return total
end

--- One pass; one pod at a time (session advisory lock, released at the end).
function FormJobs.purge()
    if not db.query("SELECT pg_try_advisory_lock(hashtext('opsapi.forms.purge')) AS l")[1].l then return 0 end
    local ok, res = pcall(function()
        local n = batched(([[DELETE FROM form_submissions WHERE id IN (
            SELECT id FROM form_submissions WHERE status = 'spam' AND created_at < NOW() - interval '%d days'
            LIMIT %d)]]):format(FormJobs.SPAM_DAYS, BATCH))

        -- Per-form retention: delete, then recount the forms that lost rows.
        local touched = {}
        for _ = 1, 50 do
            local rows = db.query(([[DELETE FROM form_submissions WHERE id IN (
                SELECT s.id FROM form_submissions s JOIN forms f ON f.id = s.form_id
                WHERE (f.settings ->> 'retention_days') IS NOT NULL
                  AND s.created_at < NOW() - make_interval(days => (f.settings ->> 'retention_days')::int)
                LIMIT %d) RETURNING form_id]]):format(BATCH))
            for _, r in ipairs(rows) do touched[tonumber(r.form_id)] = true end
            n = n + #rows
            if #rows < BATCH then break end
        end
        for id in pairs(touched) do
            db.query([[UPDATE forms SET submission_count = (SELECT COUNT(*) FROM form_submissions
                WHERE form_id = ? AND status <> 'spam') WHERE id = ?]], id, id)
        end

        -- Files never attached within a day, or whose response is gone.
        local Uploads = require("lib.forms.uploads")
        for _ = 1, 20 do
            local gone = Uploads.purge(500)
            n = n + gone
            if gone < 500 then break end
        end

        -- Deleted forms: their responses in batches, then the form.
        for _, f in ipairs(db.query(([[SELECT id FROM forms WHERE deleted_at < NOW() - interval '%d days'
            ORDER BY id LIMIT 20]]):format(FormJobs.DELETED_FORM_DAYS))) do
            n = n + batched(([[DELETE FROM form_submissions WHERE id IN (
                SELECT id FROM form_submissions WHERE form_id = %d LIMIT %d)]]):format(tonumber(f.id), BATCH))
            db.query("DELETE FROM forms WHERE id = ?", f.id)
        end
        return n
    end)
    pcall(db.query, "SELECT pg_advisory_unlock(hashtext('opsapi.forms.purge'))")
    if not ok then error(res, 0) end
    return res
end

function FormJobs.maintain(premature)
    if premature then return end
    local ok, n = pcall(FormJobs.purge)
    if not ok then
        ngx.log(ngx.ERR, "[forms] purge failed: ", tostring(n))
    elseif n > 0 then
        ngx.log(ngx.NOTICE, "[forms] purged ", n, " response(s)")
    end
    require("helper.plugin-events").releaseConnection()
end

return FormJobs
