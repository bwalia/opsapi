-- Carries out an approved action (only ever called by Approvals.execute, after
-- a person approved). Each action returns { result, task_status? } or raises.
--
--   send_email         email the deal party (workspace SMTP), log a chase, apply
--                      the approved enquiry updates → task done
--   update_enquiries   apply approved enquiry updates only
--   request_booking    email 2-3 suppliers for slots, record bookings as requested
--                      → task waiting_third_party
--   confirm_booking    email the chosen supplier, mark it confirmed, cancel the
--                      other requests for the task → task done
--   send_deal_pack     email a matched buyer the deal pack, mark the match sent
--   send_lead_followup a personal follow-up to a lead: email (workspace SMTP) or SMS (the workspace's own
--                      Android SMS Gateway) is sent; WhatsApp gives a click-to-chat link a person sends from
--                      (no paid API). Refused when the lead opted out or has no lawful basis recorded.
--   (anything else)    recorded as approved; nothing to run
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local X = {}

local EMAIL = "^[%w%._%%%+%-]+@[%w%.%-]+%.%a%a+$"

--- Send through the workspace's own SMTP if it has one, else the deployment's.
function X.send_email(ns, to, subject, body)
    if type(to) ~= "string" or not to:match(EMAIL) then
        U.fail(422, "No valid recipient address; edit the draft to add one, then approve again")
    end
    local Mail = require("helper.mail")
    local smtp = require("helper.namespace-mail").smtp(ns)
    if not smtp and not Mail.isConfigured() then
        U.fail(422, "No email server: set the workspace's SMTP in Settings → Email")
    end
    local msg = { to = to, subject = subject, text = body, sync = true, smtp = smtp }
    if smtp then msg.from_email, msg.from_name, msg.reply_to = smtp.from_email, smtp.from_name, smtp.reply_to end
    local ok, err = Mail.send(msg)
    if not ok then U.fail(502, "Email not sent: " .. tostring(err)) end
    return true
end

local function apply_enquiries(ns, p, actor)
    local resolved, added = 0, 0
    for _, u in ipairs(type(p.enquiry_updates) == "table" and p.enquiry_updates or {}) do
        if U.is_uuid(u.enquiry_uuid) and u.action == "resolved" then
            local r = db.query([[
                UPDATE property_deals_enquiries SET status = 'resolved', resolved_at = NOW(), updated_at = NOW(),
                    resolution = ? WHERE namespace_id = ? AND uuid = ? AND status = 'open' RETURNING id
            ]], (u.note or "Resolved") .. " (AI-proposed, approved)", ns, u.enquiry_uuid)
            resolved = resolved + #r
        end
    end
    for _, n in ipairs(type(p.new_enquiries) == "table" and p.new_enquiries or {}) do
        if type(n.title) == "string" and n.title ~= "" and U.is_uuid(p.deal_uuid) then
            db.insert("property_deals_enquiries", { namespace_id = ns, deal_uuid = p.deal_uuid, title = n.title:sub(1, 255),
                detail = n.detail, owner_party = n.owner_party or "seller_solicitor", source = "agent" })
            added = added + 1
        end
    end
    return resolved, added
end

X.actions = {}

X.actions.send_email = function(ns, a, p, actor)
    X.send_email(ns, p.to, p.subject or a.title, p.body or "")
    local enquiries = type(p.enquiry_uuids) == "table" and p.enquiry_uuids or {}
    local chase = db.insert("property_deals_chases", {
        namespace_id = ns, deal_uuid = U.is_uuid(p.deal_uuid) and p.deal_uuid or a.deal_uuid,
        task_uuid = a.task_uuid, to_party = p.to_party or "other", to_name = p.to_name, to_address = p.to,
        channel = "email", subject = p.subject, body = p.body, status = "sent", sent_at = db.raw("NOW()"),
        sent_by_user_uuid = actor, approval_uuid = a.uuid,
        enquiry_uuid = #enquiries == 1 and U.is_uuid(enquiries[1]) and enquiries[1] or nil,
    }, { returning = "*" })[1]
    local resolved, added = apply_enquiries(ns, p, actor)
    return { result = { chase_uuid = chase.uuid, sent_to = p.to, enquiries_resolved = resolved, enquiries_added = added },
        task_status = "done" }
end

X.actions.update_enquiries = function(ns, a, p, actor)
    local resolved, added = apply_enquiries(ns, p, actor)
    return { result = { enquiries_resolved = resolved, enquiries_added = added } }
end

X.actions.request_booking = function(ns, a, p, actor)
    local bookings, skipped = {}, {}
    for _, r in ipairs(type(p.requests) == "table" and p.requests or {}) do
        local s = U.is_uuid(r.supplier_uuid) and U.one([[
            SELECT s.uuid, COALESCE(NULLIF(?, ''), NULLIF(acc.email, '')) AS email FROM property_deals_suppliers s
            JOIN crm_accounts acc ON acc.uuid = s.account_uuid WHERE s.namespace_id = ? AND s.uuid = ? AND s.active
        ]], type(r.to) == "string" and r.to or "", ns, r.supplier_uuid)
        if not s or s.email == db.NULL then
            skipped[#skipped + 1] = { supplier_uuid = r.supplier_uuid, reason = "no active supplier with an email" }
        else
            X.send_email(ns, s.email, r.subject or a.title, r.body or "")
            local b = db.insert("property_deals_bookings", {
                namespace_id = ns, supplier_uuid = s.uuid, deal_uuid = U.is_uuid(p.deal_uuid) and p.deal_uuid or a.deal_uuid,
                property_uuid = U.is_uuid(p.property_uuid) and p.property_uuid or nil, task_uuid = a.task_uuid,
                service = p.service or "other", status = "requested", approval_uuid = a.uuid,
                notes = "Slots requested by email (approved request)",
            }, { returning = "*" })[1]
            bookings[#bookings + 1] = { booking_uuid = b.uuid, supplier_uuid = s.uuid, sent_to = s.email }
        end
    end
    if #bookings == 0 then U.fail(422, "No booking request could be sent", { skipped = skipped }) end
    return { result = { bookings = U.array(bookings), skipped = U.array(skipped) }, task_status = "waiting_third_party" }
end

X.actions.confirm_booking = function(ns, a, p, actor)
    local b = U.is_uuid(p.booking_uuid) and U.one([[
        SELECT b.*, NULLIF(acc.email, '') AS email FROM property_deals_bookings b
        JOIN property_deals_suppliers s ON s.uuid = b.supplier_uuid JOIN crm_accounts acc ON acc.uuid = s.account_uuid
        WHERE b.namespace_id = ? AND b.uuid = ?
    ]], ns, p.booking_uuid)
    if not b then U.fail(404, "Booking not found") end
    if b.status == "confirmed" or b.status == "done" then return { result = { booking_uuid = b.uuid, already = b.status } } end
    local to = type(p.to) == "string" and p.to ~= "" and p.to or (b.email ~= db.NULL and b.email or nil)
    X.send_email(ns, to, p.subject or a.title, p.body or "Please confirm the booking.")
    db.update("property_deals_bookings", { status = "confirmed", confirmed_at = db.raw("NOW()"),
        slot_start = p.slot_start, slot_end = p.slot_end, cost = tonumber(p.cost), updated_at = db.raw("NOW()") },
        { id = b.id })
    local cancelled = 0
    if b.task_uuid and b.task_uuid ~= db.NULL then
        cancelled = #db.query([[
            UPDATE property_deals_bookings SET status = 'cancelled', updated_at = NOW()
            WHERE namespace_id = ? AND task_uuid = ? AND id <> ? AND status IN ('requested', 'tentative') RETURNING id
        ]], ns, b.task_uuid, b.id)
    end
    return { result = { booking_uuid = b.uuid, confirmed_with = to, other_requests_cancelled = cancelled },
        task_status = "done" }
end

--- A deal pack to a matched buyer: email them, mark the match sent.
X.actions.send_deal_pack = function(ns, a, p, actor)
    X.send_email(ns, p.to, p.subject or a.title, p.body or "")
    if U.is_uuid(p.match_uuid) then
        db.query([[UPDATE property_deals_matches SET status = 'sent', sent_at = NOW(), approval_uuid = ?, updated_at = NOW()
            WHERE namespace_id = ? AND uuid = ?]], a.uuid, ns, p.match_uuid)
    end
    return { result = { sent_to = p.to, match_uuid = p.match_uuid } }
end

--- Lead triage: write the approved fields to the lead's Property Deals details (+ priority).
X.actions.update_lead = function(ns, a, p, actor)
    if not U.is_uuid(p.lead_uuid) then U.fail(422, "No lead in the draft") end
    local lead = U.one("SELECT uuid FROM crm_leads WHERE namespace_id = ? AND uuid = ?", ns, p.lead_uuid)
    if not lead then U.fail(404, "Lead not found") end
    local d = type(p.details) == "table" and p.details or {}
    local allowed = { lead_kind = 1, situation = 1, situation_note = 1, deadline_date = 1, vulnerability_flag = 1,
        vulnerability_note = 1 }
    local row = {}
    for k, v in pairs(d) do if allowed[k] and v ~= cjson.null then row[k] = v end end
    local existing = U.one("SELECT id FROM property_deals_lead_details WHERE namespace_id = ? AND lead_uuid = ?", ns, lead.uuid)
    if next(row) then
        row.updated_at = db.raw("NOW()")
        if existing then db.update("property_deals_lead_details", row, { id = existing.id })
        else
            row.namespace_id, row.lead_uuid = ns, lead.uuid
            db.insert("property_deals_lead_details", row)
        end
    end
    if p.priority then
        db.update("crm_leads", { priority = p.priority, updated_at = db.raw("NOW()") }, { uuid = lead.uuid, namespace_id = ns })
    end
    return { result = { lead_uuid = lead.uuid, fields = U.array((function() local k = {} for f in pairs(row) do
        if f ~= "updated_at" then k[#k + 1] = f end end table.sort(k) return k end)()) } }
end

--- Property enrichment: approved risk levels and known issues from official data.
X.actions.update_property = function(ns, a, p, actor)
    local prop = U.is_uuid(p.property_uuid) and U.one("SELECT * FROM property_deals_properties WHERE namespace_id = ? AND uuid = ?",
        ns, p.property_uuid)
    if not prop then U.fail(404, "Property not found") end
    local c = type(p.changes) == "table" and p.changes or {}
    local row = { updated_at = db.raw("NOW()") }
    if c.flood_risk then row.flood_risk = c.flood_risk end
    if c.mining_risk then row.mining_risk = c.mining_risk end
    if type(c.known_issues_add) == "table" then
        local issues, seen = U.json(prop.known_issues) or {}, {}
        for _, i in ipairs(issues) do seen[i] = true end
        for _, i in ipairs(c.known_issues_add) do if not seen[i] then issues[#issues + 1] = i; seen[i] = true end end
        row.known_issues = cjson.encode(U.array(issues))
    end
    if c.notes then
        row.known_issues_note = ((prop.known_issues_note ~= db.NULL and prop.known_issues_note or "") .. "\n" .. c.notes):gsub("^\n", "")
    end
    db.update("property_deals_properties", row, { id = prop.id })
    return { result = { property_uuid = prop.uuid, changed = U.array((function() local k = {} for f in pairs(row) do
        if f ~= "updated_at" then k[#k + 1] = f end end table.sort(k) return k end)()) }, task_status = "done" }
end

--- Offer reasoning: record the approved offer on the deal, with the reasoning in its notes.
X.actions.record_offer = function(ns, a, p, actor)
    local deal = U.is_uuid(p.deal_uuid) and U.one("SELECT * FROM property_deals_deals WHERE namespace_id = ? AND uuid = ?", ns, p.deal_uuid)
    if not deal then U.fail(404, "Deal not found") end
    local rec = tonumber(p.recommended)
    if not rec or rec <= 0 then U.fail(422, "No recommended offer in the draft") end
    local note = string.format("Offer reasoning (approved %s): £%d–£%d, recommended £%d.\n%s",
        require("property_deals.workdays").now():sub(1, 10), math.floor(tonumber(p.offer_low) or rec),
        math.floor(tonumber(p.offer_high) or rec), math.floor(rec), tostring(p.reasoning or ""))
    db.update("property_deals_deals", { offer_amount = rec, updated_at = db.raw("NOW()"),
        notes = db.raw("CONCAT_WS(E'\\n\\n', NULLIF(notes, ''), " .. db.escape_literal(note) .. ")") }, { id = deal.id })
    return { result = { deal_uuid = deal.uuid, offer_amount = rec }, task_status = "done" }
end

--- Document checker: each approved red flag becomes an open enquiry (blocking when high).
X.actions.add_red_flags = function(ns, a, p, actor)
    if not U.is_uuid(p.deal_uuid) then U.fail(422, "No deal in the draft") end
    local added = {}
    for _, f in ipairs(type(p.flags) == "table" and p.flags or {}) do
        if type(f.title) == "string" and f.title ~= "" then
            local where = f.filename and (" (" .. f.filename .. (f.page and (", page " .. f.page) or "") .. ")") or ""
            local e = db.insert("property_deals_enquiries", { namespace_id = ns, deal_uuid = p.deal_uuid,
                title = (f.title .. where):sub(1, 255), detail = f.detail, owner_party = f.owner_party or "seller_solicitor",
                blocking = f.severity == "high", source = "agent" }, { returning = "*" })[1]
            added[#added + 1] = e.uuid
        end
    end
    return { result = { enquiries_added = #added, enquiry_uuids = U.array(added) }, task_status = "done" }
end

--- Compliance assistant: notes on checks and the missing ones as not_started.
-- Never passes, waives or closes anything (that needs a named person, DB check + API).
X.actions.compliance_notes = function(ns, a, p, actor)
    if not U.is_uuid(p.deal_uuid) then U.fail(422, "No deal in the draft") end
    local created, noted = 0, 0
    for _, m in ipairs(type(p.missing) == "table" and p.missing or {}) do
        local exists = U.one([[SELECT 1 FROM property_deals_compliance_checks WHERE namespace_id = ? AND deal_uuid = ?
            AND check_type = ? AND party_role IS NOT DISTINCT FROM ?]], ns, p.deal_uuid, m.check_type, m.party_role or db.NULL)
        if not exists then
            db.insert("property_deals_compliance_checks", { namespace_id = ns, deal_uuid = p.deal_uuid, subject_type = "deal",
                check_type = m.check_type, party_role = m.party_role, status = "not_started",
                notes = "Raised by the compliance assistant: " .. tostring(m.why or "") })
            created = created + 1
        end
    end
    for _, n in ipairs(type(p.notes) == "table" and p.notes or {}) do
        local r = db.query([[UPDATE property_deals_compliance_checks
            SET data = jsonb_set(COALESCE(data, '{}'::jsonb), '{assistant_notes}',
                COALESCE(data -> 'assistant_notes', '[]'::jsonb) || to_jsonb(?::text)), updated_at = NOW()
            WHERE namespace_id = ? AND uuid = ? AND deal_uuid = ? RETURNING id]], n.note, ns, n.check_uuid, p.deal_uuid)
        noted = noted + #r
    end
    return { result = { checks_created = created, checks_noted = noted, mismatches = p.mismatches } }
end

--- Personal follow-up to a lead (lead_followup agent), after a person approved the exact text.
X.actions.send_lead_followup = function(ns, a, p, actor)
    if not U.is_uuid(p.lead_uuid) and type(p.lead_uuid) ~= "string" then U.fail(422, "No lead in the draft") end
    local lead = U.one([[
        SELECT l.uuid, l.first_name, l.company_name, NULLIF(l.email, '') AS email, NULLIF(l.phone, '') AS phone,
               d.opted_out_at, d.consent_basis
        FROM crm_leads l LEFT JOIN property_deals_lead_details d ON d.lead_uuid = l.uuid
        WHERE l.namespace_id = ? AND l.uuid = ? AND l.deleted_at IS NULL
    ]], ns, p.lead_uuid)
    if not lead then U.fail(404, "Lead not found") end
    local function null(v) return v == nil or v == db.NULL end
    if not null(lead.opted_out_at) then U.fail(409, "The lead asked not to be contacted: nothing was sent") end
    -- UK GDPR / PECR: a private person needs a recorded basis; a company contact (B2B) may be contacted.
    local b2b = not null(lead.company_name) and tostring(lead.company_name) ~= ""
    if null(lead.consent_basis) and not b2b then
        U.fail(422, "No lawful basis recorded for this person: set the lead's consent basis, then approve again")
    end
    local channel = p.channel or "email"
    local body = tostring(p.body or "")
    -- The address comes from the lead record at send time (it may have been corrected since the draft).
    local to = channel == "email" and lead.email or lead.phone
    if null(to) then to = nil end
    local result = { channel = channel, sent_to = to }
    local status = "sent"
    if channel == "email" then
        X.send_email(ns, to, p.subject or a.title, body .. "\n\n--\nIf you'd rather not hear from us, just reply STOP.")
    elseif channel == "sms" then
        if not to then U.fail(422, "The lead has no phone number") end
        local M = require("property_deals.messaging")
        local text = body .. " Reply STOP to opt out."
        if M.available(ns, "sms") then
            local ok, err = M.send(ns, "sms", M.e164(to) or to, { body = text })
            if not ok then U.fail(502, "SMS not sent: " .. tostring(err)) end
        else
            status, result.manual_link = "draft", "sms:" .. to:gsub("%s+", "") .. "?&body=" .. ngx.escape_uri(text)
        end
    elseif channel == "whatsapp" then
        if not to then U.fail(422, "The lead has no phone number") end
        local num = (require("property_deals.messaging").e164(to) or to):gsub("[^%d]", "")
        status, result.manual_link = "draft", "https://wa.me/" .. num .. "?text=" .. ngx.escape_uri(body)
    else
        U.fail(422, "Unknown channel")
    end
    local chase = db.insert("property_deals_chases", {
        namespace_id = ns, lead_uuid = lead.uuid, task_uuid = a.task_uuid, to_party = "other",
        to_name = p.to_name, to_address = to, channel = channel, subject = p.subject, body = body,
        status = status, sent_at = status == "sent" and db.raw("NOW()") or nil, sent_by_user_uuid = actor,
        approval_uuid = a.uuid, outcome = "followup",
    }, { returning = "*" })[1]
    if U.is_uuid(p.signal_uuid) then
        db.query("UPDATE property_deals_lead_signals SET used_at = NOW() WHERE namespace_id = ? AND uuid = ?", ns, p.signal_uuid)
    end
    db.query([[UPDATE property_deals_lead_details SET last_followup_at = NOW(), updated_at = NOW()
        WHERE namespace_id = ? AND lead_uuid = ?]], ns, lead.uuid)
    result.chase_uuid = chase.uuid
    -- Sent: done. A click-to-send link: the task stays open until the person sends it and marks it done.
    return { result = result, task_status = status == "sent" and "done" or "in_progress" }
end

function X.run(ns, a, actor)
    local fn = X.actions[a.action]
    local p = U.json(a.payload)
    if type(p) ~= "table" then p = {} end
    if not fn then return { result = { note = "approved; no automatic action for '" .. tostring(a.action) .. "'" } } end
    return fn(ns, a, p, actor)
end

return X
