--[[
    Email a lead from the dashboard (a question, a follow-up)
    ========================================================

    Sent through the workspace's "Questions and follow-up" email account (Workspace →
    Email), else its default account, else the deployment's server. Replies go
    to the account's reply-to address, else to the person who sent it, so the
    answer lands with someone who reads it. With the CRM module deployed the
    email is logged on the lead's timeline as a completed "email" activity.
]]

local db = require("lapis.db")
local U = require("lib.crm.util")

local LeadEmail = {}

local EMAIL = "^[^%s@]+@[^%s@]+%.[^%s@]+$"

local function esc(s)
    return (tostring(s):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;",
        ["'"] = "&#39;" }))
end

--- Plain text → paragraphs (blank line = new paragraph, newline = <br>), escaped.
local function paragraphs(text)
    local out = {}
    for block in (text .. "\n\n"):gmatch("(.-)\n%s*\n") do
        if block:match("%S") then out[#out + 1] = "<p>" .. esc(block):gsub("\n", "<br>") .. "</p>" end
    end
    return table.concat(out)
end

--- @param lead   crm_leads row (already checked visible + workable)
-- @param sender  { uuid, email, name } the staff member sending it
-- @param b       { subject, message, cc_me? }
-- @return { to, account } | nil, err ({ status, code, message, fields })
function LeadEmail.send(ns, lead, sender, b)
    local to = U.nz(lead.email)
    if not to or not tostring(to):match(EMAIL) then
        return U.fail(422, "LEAD_NO_EMAIL", "This lead has no email address. Add one first.", { email = "required" })
    end
    local subject = U.text(b.subject, 200)
    if not subject then return U.fail(422, "LEAD_EMAIL_SUBJECT", "Add a subject", { subject = "required" }) end
    local message = U.text(b.message, 20000)
    if not message then return U.fail(422, "LEAD_EMAIL_MESSAGE", "Write a message", { message = "required" }) end
    subject = subject:gsub("[\r\n]+", " ")

    local ns_row = db.query("SELECT name FROM namespaces WHERE id = ?", ns)[1] or {}
    local brand = U.nz(ns_row.name) or "OpsAPI"
    -- The sender's address from their account (a token may not carry it).
    local staff_email = sender.email
    if (type(staff_email) ~= "string" or staff_email == "") and sender.uuid then
        local u = db.query("SELECT email FROM users WHERE uuid = ?", sender.uuid)[1]
        staff_email = u and U.nz(u.email) or nil
    end
    if staff_email and not tostring(staff_email):match(EMAIL) then staff_email = nil end

    local NamespaceMail = require("helper.namespace-mail")
    local msg, perr = NamespaceMail.prepare(ns, "lead_followup", {
        to = to,
        subject = subject,
        html = paragraphs(message),
        text = message,
        wrap_in_layout = true,
        data = { app_name = brand },
        from_name = brand,
        reply_to = staff_email,
        cc = (b.cc_me == true and staff_email) and staff_email or nil,
        sync = true,
    })
    if not msg then return U.fail(503, "EMAIL_NOT_CONFIGURED", perr) end
    local account = msg.smtp and msg.smtp.account_name or nil

    local ok, err = require("helper.mail").send(msg)
    if not ok then
        -- The server's reply stays in the log: it can echo addresses and server details.
        ngx.log(ngx.ERR, "[crm-leads] email to lead ", tostring(lead.uuid), " failed: ", tostring(err))
        return U.fail(502, "EMAIL_FAILED", account
            and ("The email account \"" .. account .. "\" didn't accept the email. Check it in Workspace → Email.")
            or "The email couldn't be sent. Try again shortly.")
    end

    db.query([[UPDATE crm_leads SET first_contacted_at = COALESCE(first_contacted_at, NOW()),
        last_contacted_at = NOW(), updated_at = NOW() WHERE id = ?]], lead.id)
    if U.crm() then
        pcall(db.query, [[
            INSERT INTO crm_activities (uuid, namespace_id, lead_id, activity_type, subject, description, activity_date,
                owner_user_uuid, status, completed_at, metadata, created_at, updated_at)
            VALUES (?, ?, ?, 'email', ?, ?, (NOW() AT TIME ZONE 'UTC'), ?, 'completed', NOW(), ?::jsonb, NOW(), NOW())
        ]], require("helper.global").generateUUID(), ns, lead.id, "Emailed: " .. subject, message,
            sender.uuid or "system", U.enc({ to = to, account = account, direction = "outbound" }))
    end
    return { to = to, account = account or "platform" }
end

return LeadEmail
