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

function X.run(ns, a, actor)
    local fn = X.actions[a.action]
    local p = U.json(a.payload)
    if type(p) ~= "table" then p = {} end
    if not fn then return { result = { note = "approved; no automatic action for '" .. tostring(a.action) .. "'" } } end
    return fn(ns, a, p, actor)
end

return X
