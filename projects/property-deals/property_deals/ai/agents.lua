-- The agent catalogue (SPEC §3.5). Each agent = a prompt + a fixed tool
-- allowlist + what its draft turns into. Agents never act: `draft()` turns a
-- model's JSON into an approval request; the executor acts after a person
-- approves. Recipients are filled here from the deal's parties, never from
-- model output, so neither a model nor an email it read can redirect a message.
--
--   key = { name, job_type, version, tools, needs_deal, approval (default rule),
--           instructions, context(ctx) -> table, draft(ctx, out) -> approval | nil, summary }
local db = require("lapis.db")
local U = require("property_deals.util")
local G = require("property_deals.ai.guard")

local A = {}

local PARTY_ROLES = { seller = true, buyer = true, buyer_solicitor = true, seller_solicitor = true, lender = true,
    broker = true, surveyor = true, estate_agent = true, freeholder = true, managing_agent = true }

--- The deal's reference tag, added to outbound subjects so replies match back.
function A.ref(deal_uuid)
    return "[PD-" .. tostring(deal_uuid):sub(1, 8) .. "]"
end

--- Email address of the primary party with this role on the deal (contact, else firm).
function A.party_address(ns, deal_uuid, role)
    local r = U.one([[
        SELECT COALESCE(NULLIF(c.email, ''), NULLIF(a.email, '')) AS email,
               COALESCE(a.name, TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, ''))) AS name
        FROM property_deals_deal_parties p
        LEFT JOIN crm_contacts c ON c.uuid = p.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = p.account_uuid
        WHERE p.namespace_id = ? AND p.deal_uuid = ? AND p.role = ?
        ORDER BY p.is_primary DESC, (COALESCE(c.email, a.email) IS NULL), p.created_at LIMIT 1
    ]], ns, deal_uuid, role)
    if not r or r.email == db.NULL then return nil, r and r.name ~= db.NULL and r.name or nil end
    return r.email, r.name ~= db.NULL and r.name or nil
end

local function open_enquiries(ns, deal_uuid)
    return db.query([[
        SELECT uuid, title, owner_party FROM property_deals_enquiries
        WHERE namespace_id = ? AND deal_uuid = ? AND status = 'open' ORDER BY raised_at
    ]], ns, deal_uuid)
end

local function deal_name(ns, deal_uuid)
    local r = U.one([[SELECT cd.name FROM property_deals_deals dl JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
        WHERE dl.namespace_id = ? AND dl.uuid = ?]], ns, deal_uuid)
    return r and r.name or "the deal"
end

-- ---------------------------------------------------------------------------
-- 5. Legal chaser
-- ---------------------------------------------------------------------------
A.legal_chaser = {
    name = "Legal chaser",
    job_type = "draft",
    version = "legal_chaser@1",
    needs_deal = true,
    approval = "any_operator",
    tools = { "get_deal_summary", "list_open_enquiries", "list_recent_chases", "list_recent_emails", "list_parties" },
    instructions = [[
Draft ONE short, polite, specific chase email to the party who owns the most open blocking enquiries
(usually the seller's or buyer's solicitor). List every open enquiry they owe, numbered, by its title.
Mention the target completion date if there is one. Plain text, no markdown, sign off as "The team".
Also read any recent emails: if one clearly answers an open enquiry, propose resolving it (with a one-line
note quoting where); if one raises a new issue, propose it as a new enquiry. Never resolve anything that
isn't clearly answered. Reply with JSON only:
{"summary": "...", "blockers": ["..."],
 "email": {"to_party": "seller_solicitor", "subject": "...", "body": "..."} or null,
 "enquiry_updates": [{"enquiry_uuid": "...", "action": "resolved", "note": "..."}],
 "new_enquiries": [{"title": "...", "owner_party": "seller_solicitor", "detail": "..."}]}]],
    context = function(ctx)
        local T = require("property_deals.ai.tools")
        return {
            deal = T.defs.get_deal_summary.run(ctx),
            open_enquiries = T.defs.list_open_enquiries.run(ctx),
            recent_chases = T.defs.list_recent_chases.run(ctx),
        }
    end,
    draft = function(ctx, out)
        local ns, deal = ctx.ns, ctx.deal_uuid
        local payload = { deal_uuid = deal, enquiry_updates = U.array({}), new_enquiries = U.array({}) }
        local valid = {}
        for _, e in ipairs(open_enquiries(ns, deal)) do valid[e.uuid] = e end
        for _, u in ipairs(type(out.enquiry_updates) == "table" and out.enquiry_updates or {}) do
            if type(u) == "table" and valid[u.enquiry_uuid] and (u.action == "resolved" or u.action == "note") then
                payload.enquiry_updates[#payload.enquiry_updates + 1] = { enquiry_uuid = u.enquiry_uuid,
                    title = valid[u.enquiry_uuid].title, action = u.action, note = G.text(u.note, 500) }
            end
        end
        for _, n in ipairs(type(out.new_enquiries) == "table" and out.new_enquiries or {}) do
            if type(n) == "table" and G.text(n.title) then
                payload.new_enquiries[#payload.new_enquiries + 1] = { title = G.text(n.title, 200),
                    owner_party = PARTY_ROLES[n.owner_party] and n.owner_party or "seller_solicitor",
                    detail = G.text(n.detail, 1000) }
            end
        end
        local email = type(out.email) == "table" and out.email or nil
        if email and G.text(email.body) then
            local party = PARTY_ROLES[email.to_party] and email.to_party or "seller_solicitor"
            local to, to_name = A.party_address(ns, deal, party)
            local subject = G.text(email.subject, 200) or ("Update on " .. deal_name(ns, deal))
            if not subject:find(A.ref(deal), 1, true) then subject = subject .. " " .. A.ref(deal) end
            local owed = {}
            for _, e in pairs(valid) do if e.owner_party == party then owed[#owed + 1] = e.uuid end end
            payload.channel, payload.to_party, payload.to, payload.to_name = "email", party, to, to_name
            payload.subject, payload.body, payload.enquiry_uuids = subject, G.text(email.body, 8000), U.array(owed)
            return { subject_type = "chase", action = "send_email",
                title = "Chase " .. party:gsub("_", " ") .. " — " .. deal_name(ns, deal)
                    .. (to and "" or " (no email address on file: add one before approving)"),
                payload = payload }
        end
        if #payload.enquiry_updates > 0 or #payload.new_enquiries > 0 then
            return { subject_type = "agent_draft", action = "update_enquiries",
                title = "Update enquiries — " .. deal_name(ns, deal), payload = payload }
        end
        return nil
    end,
}

-- ---------------------------------------------------------------------------
-- 6. Booking agent
-- ---------------------------------------------------------------------------
local SERVICE_BY_TASK = { book_epc = "epc_assessor", book_survey = "surveyor", book_valuation = "surveyor" }

A.booking_agent = {
    name = "Booking agent",
    job_type = "plan",
    version = "booking_agent@1",
    approval = "any_operator",
    tools = { "get_property", "find_suppliers", "get_deal_summary" },
    instructions = [[
Find the 2-3 best suppliers for the service (nearest first, then the most reliable on time) with
find_suppliers, and draft a short booking request email to each asking for their earliest slots.
Do not invent suppliers: only use supplier_uuid values that find_suppliers returned. Reply with JSON only:
{"service": "epc_assessor", "requests": [{"supplier_uuid": "...", "subject": "...", "body": "..."}],
 "note": "why these suppliers"}]],
    context = function(ctx)
        local T = require("property_deals.ai.tools")
        local service = SERVICE_BY_TASK[ctx.task and ctx.task.template_key or ""]
        return {
            task = ctx.task and ctx.task.title, service = service,
            property = T.defs.get_property.run(ctx),
            suppliers = service and T.defs.find_suppliers.run(ctx, { service = service, limit = 3 }) or nil,
        }
    end,
    draft = function(ctx, out)
        local reqs = U.array({})
        for _, r in ipairs(type(out.requests) == "table" and out.requests or {}) do
            if #reqs >= 3 then break end
            local s = type(r) == "table" and U.is_uuid(r.supplier_uuid) and U.one([[
                SELECT s.uuid, a.name, NULLIF(a.email, '') AS email FROM property_deals_suppliers s
                JOIN crm_accounts a ON a.uuid = s.account_uuid
                WHERE s.namespace_id = ? AND s.uuid = ? AND s.active
            ]], ctx.ns, r.supplier_uuid)
            if s then
                local subject = G.text(r.subject, 200) or "Booking request"
                if ctx.deal_uuid and not subject:find(A.ref(ctx.deal_uuid), 1, true) then
                    subject = subject .. " " .. A.ref(ctx.deal_uuid)
                end
                reqs[#reqs + 1] = { supplier_uuid = s.uuid, supplier_name = s.name,
                    to = s.email ~= db.NULL and s.email or nil, subject = subject, body = G.text(r.body, 4000) or "" }
            end
        end
        if #reqs == 0 then return nil end
        local service = G.text(out.service, 40) or SERVICE_BY_TASK[ctx.task and ctx.task.template_key or ""] or "other"
        return { subject_type = "booking", action = "request_booking",
            title = "Request " .. service:gsub("_", " ") .. " slots from " .. #reqs .. " supplier(s)",
            payload = { service = service:gsub("[^%w_]", ""), requests = reqs, deal_uuid = ctx.deal_uuid,
                property_uuid = ctx.property_uuid, task_uuid = ctx.task_uuid, note = G.text(out.note, 500) } }
    end,
}

-- ---------------------------------------------------------------------------
-- 9. Daily digest writer (no approval: it only rewrites a person's own digest,
-- which the rules engine already decided to send them)
-- ---------------------------------------------------------------------------
A.digest_writer = {
    name = "Daily digest writer",
    job_type = "summarise",
    version = "digest_writer@1",
    approval = "none",
    tools = {},
    instructions = [[
Turn this person's rules-based digest into 3-6 short plain-English sentences: what is most urgent first
(red deals and money at risk, then overdue tasks, then approvals waiting, then expiring compliance).
Use only the facts given; don't add advice or new deadlines. Reply with JSON only: {"summary": "..."}]],
}

A.ORDER = { "legal_chaser", "booking_agent", "digest_writer" }

function A.get(key)
    local a = A[key]
    if type(a) == "table" and a.instructions then return a end
    return nil
end

--- Public view of the catalogue.
function A.list()
    local out = {}
    for _, k in ipairs(A.ORDER) do
        local a = A[k]
        out[#out + 1] = { key = k, name = a.name, job_type = a.job_type, version = a.version,
            tools = U.array(a.tools), default_approval = a.approval, needs_deal = a.needs_deal == true }
    end
    return U.array(out)
end

return A
