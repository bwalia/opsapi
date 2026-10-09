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

-- ---------------------------------------------------------------------------
-- 1. Lead intake & triage
-- ---------------------------------------------------------------------------
local KINDS = { seller = 1, buyer_investor = 1, landlord = 1, agent_referral = 1, other = 1 }
local SITUATIONS = { probate = 1, broken_chain = 1, divorce = 1, relocation = 1, care_fees = 1, repossession_risk = 1,
    tenanted = 1, unmortgageable = 1, other = 1 }
local PRIORITIES = { critical = 1, high = 1, medium = 1, low = 1 }

A.lead_triage = {
    name = "Lead intake & triage",
    job_type = "classify",
    version = "lead_triage@1",
    needs_lead = true,
    approval = "any_operator",
    tools = { "get_lead" },
    instructions = [[
Read the lead's form / call notes and fill its structured fields. Only use what the notes say; leave a field
null when they don't say. Flag vulnerability (bereavement, illness, debt, age, distress) with a short factual
note — never a judgement. Suggest a priority from the seller's deadline and situation. Reply with JSON only:
{"lead_kind": "seller|buyer_investor|landlord|agent_referral|other", "situation": "probate|broken_chain|divorce|
relocation|care_fees|repossession_risk|tenanted|unmortgageable|other", "situation_note": "...",
"deadline_date": "YYYY-MM-DD" or null, "vulnerability_flag": true|false, "vulnerability_note": "..." or null,
"priority": "critical|high|medium|low", "summary": "one line"}]],
    context = function(ctx)
        return { lead = require("property_deals.ai.tools").defs.get_lead.run(ctx) }
    end,
    draft = function(ctx, out)
        local d = {}
        if KINDS[out.lead_kind] then d.lead_kind = out.lead_kind end
        if SITUATIONS[out.situation] then d.situation = out.situation end
        d.situation_note = G.text(out.situation_note, 500)
        if type(out.deadline_date) == "string" and out.deadline_date:match("^%d%d%d%d%-%d%d%-%d%d$") then
            d.deadline_date = out.deadline_date
        end
        if out.vulnerability_flag == true then
            d.vulnerability_flag, d.vulnerability_note = true, G.text(out.vulnerability_note, 500)
        elseif out.vulnerability_flag == false then d.vulnerability_flag = false end
        if not next(d) then return nil end
        return { subject_type = "agent_draft", action = "update_lead",
            title = "Lead triage: " .. (G.text(out.summary, 120) or "fill the lead's details"),
            payload = { lead_uuid = ctx.lead_uuid, details = d,
                priority = PRIORITIES[out.priority] and out.priority or nil, summary = G.text(out.summary, 300) } }
    end,
}

-- ---------------------------------------------------------------------------
-- 2. Property enrichment (official data first, then the model reads it)
-- ---------------------------------------------------------------------------
local RISK = { low = 1, medium = 1, high = 1, very_high = 1, unknown = 1 }

A.property_enrichment = {
    name = "Property enrichment",
    job_type = "extract",
    version = "property_enrichment@1",
    approval = "any_operator",
    tools = { "get_property", "get_comps" },
    instructions = [[
The EPC register and sold prices have already been looked up (see the records). From the records only,
propose: flood_risk and mining_risk (low|medium|high|very_high|unknown) when the data says so, known issues
to add (e.g. short_lease, spray_foam, non_standard_construction, knotweed, subsidence, cladding,
sitting_tenant) when the data shows them, and a short summary of the comparables. Never guess.
Reply with JSON only: {"summary": "...", "updates": {"flood_risk": null, "mining_risk": null,
"known_issues_add": [], "notes": "..."}}]],
    context = function(ctx)
        if ctx.property_uuid then
            pcall(require("property_deals.market").enrich_property, ctx.ns, ctx.property_uuid)
        end
        local T = require("property_deals.ai.tools")
        return { property = T.defs.get_property.run(ctx), comps = T.defs.get_comps.run(ctx) }
    end,
    draft = function(ctx, out)
        if not ctx.property_uuid then return nil end
        local u = type(out.updates) == "table" and out.updates or {}
        local changes = {}
        if RISK[u.flood_risk] then changes.flood_risk = u.flood_risk end
        if RISK[u.mining_risk] then changes.mining_risk = u.mining_risk end
        local add = {}
        for _, i in ipairs(type(u.known_issues_add) == "table" and u.known_issues_add or {}) do
            local k = tostring(i):lower():gsub("[^%w_]", "_"):sub(1, 40)
            if k ~= "" then add[#add + 1] = k end
        end
        if #add > 0 then changes.known_issues_add = U.array(add) end
        if not next(changes) then return nil end
        changes.notes = G.text(u.notes, 1000)
        return { subject_type = "agent_draft", action = "update_property",
            title = "Property facts from official data — " .. (G.text(out.summary, 100) or "review"),
            payload = { property_uuid = ctx.property_uuid, changes = changes, summary = G.text(out.summary, 1000) } }
    end,
}

-- ---------------------------------------------------------------------------
-- 3. Offer reasoning drafter (manager approval)
-- ---------------------------------------------------------------------------
A.offer_reasoning = {
    name = "Offer reasoning drafter",
    job_type = "plan",
    version = "offer_reasoning@1",
    needs_deal = true,
    approval = "manager",
    tools = { "get_property", "get_comps", "get_deal_summary" },
    instructions = [[
Draft an offer range for this home from the comparables, its condition, refurb estimate and the deal's chosen
completion window. Explain it in plain English a seller would understand, and list your assumptions. Use only
the numbers in the records. Reply with JSON only: {"offer_low": 0, "offer_high": 0, "recommended": 0,
"reasoning": "...", "assumptions": ["..."]}]],
    context = function(ctx)
        local T = require("property_deals.ai.tools")
        return { deal = T.defs.get_deal_summary.run(ctx), property = T.defs.get_property.run(ctx),
            comps = T.defs.get_comps.run(ctx) }
    end,
    draft = function(ctx, out)
        local lo, hi, rec = tonumber(out.offer_low), tonumber(out.offer_high), tonumber(out.recommended)
        if not (lo and hi and rec) or lo <= 0 or lo > rec or rec > hi then return nil end
        local reasoning = G.text(out.reasoning, 4000)
        if not reasoning then return nil end
        local assumptions = {}
        for _, a in ipairs(type(out.assumptions) == "table" and out.assumptions or {}) do
            assumptions[#assumptions + 1] = G.text(a, 300)
        end
        return { subject_type = "offer", action = "record_offer",
            title = string.format("Offer £%s–£%s (recommend £%s) — %s", math.floor(lo), math.floor(hi), math.floor(rec),
                deal_name(ctx.ns, ctx.deal_uuid)),
            payload = { deal_uuid = ctx.deal_uuid, offer_low = lo, offer_high = hi, recommended = rec,
                reasoning = reasoning, assumptions = U.array(assumptions) } }
    end,
}

-- ---------------------------------------------------------------------------
-- 4. Buyer matcher (scores are rules; the model writes the personal packs)
-- ---------------------------------------------------------------------------
A.buyer_matcher = {
    name = "Buyer matcher",
    job_type = "draft",
    version = "buyer_matcher@1",
    approval = "any_operator",
    tools = { "list_matches", "get_property", "get_comps" },
    instructions = [[
For each buyer in list_matches (best first, at most 5), write a short personal deal-pack email: why this home
fits them (use the score breakdown's reasons), the key facts and numbers, and a clear next step. No promises,
no invented facts. Reply with JSON only: {"packs": [{"match_uuid": "...", "subject": "...", "body": "..."}]}]],
    context = function(ctx)
        if ctx.property_uuid then
            require("property_deals.matching").recompute(ctx.ns, { property_uuid = ctx.property_uuid },
                require("helper.plugin-sdk").settings("property_deals", ctx.ns))
        end
        local T = require("property_deals.ai.tools")
        return { property = T.defs.get_property.run(ctx), matches = T.defs.list_matches.run(ctx) }
    end,
    draft = function(ctx, out)
        local reqs = {}
        for _, p in ipairs(type(out.packs) == "table" and out.packs or {}) do
            if #reqs >= 5 then break end
            local m = type(p) == "table" and U.is_uuid(p.match_uuid) and U.one([[
                SELECT m.uuid, m.score, m.breakdown, COALESCE(c.first_name, a.name) AS buyer,
                       COALESCE(NULLIF(c.email, ''), NULLIF(a.email, '')) AS email
                FROM property_deals_matches m JOIN property_deals_buyer_profiles b ON b.uuid = m.buyer_profile_uuid
                LEFT JOIN crm_contacts c ON c.uuid = b.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = b.account_uuid
                WHERE m.namespace_id = ? AND m.uuid = ? AND m.property_uuid = ? AND m.score > 0
            ]], ctx.ns, p.match_uuid, ctx.property_uuid or "00000000-0000-0000-0000-000000000000")
            if m and G.text(p.body) then
                reqs[#reqs + 1] = { subject_type = "deal_pack", action = "send_deal_pack",
                    title = "Deal pack to " .. tostring(m.buyer) .. " (score " .. tostring(m.score) .. ")"
                        .. (m.email == db.NULL and " — no email address on file" or ""),
                    payload = { match_uuid = m.uuid, to = m.email ~= db.NULL and m.email or nil,
                        subject = G.text(p.subject, 200) or "A home for you", body = G.text(p.body, 6000), score = tonumber(m.score) } }
            end
        end
        if #reqs == 0 then return nil end
        return reqs
    end,
}

-- ---------------------------------------------------------------------------
-- 7. Document checker (flags only, never clears)
-- ---------------------------------------------------------------------------
local SEVERITY = { high = true, medium = true, low = true }

A.document_checker = {
    name = "Document checker",
    job_type = "extract",
    version = "document_checker@1",
    needs_deal = true,
    approval = "any_operator",
    tools = { "list_documents", "read_document", "get_property" },
    instructions = [[
Read the deal's title, lease, survey, EPC and search documents (list_documents, then read_document) and list
red flags a conveyancer would raise: restrictive covenants, short lease, onerous ground rent, defects,
planning or building control gaps, flood or mining risk, rights of way, charges. Cite the document and page.
You can only flag; never say an issue is fine or cleared. Reply with JSON only: {"summary": "...",
"flags": [{"document_uuid": "...", "page": 1, "title": "...", "detail": "...", "severity": "high|medium|low",
"owner_party": "seller_solicitor|buyer_solicitor|lender|freeholder|managing_agent|council|other"}]}]],
    context = function(ctx)
        local T = require("property_deals.ai.tools")
        return { documents = T.defs.list_documents.run(ctx) }
    end,
    draft = function(ctx, out)
        local flags = {}
        for _, f in ipairs(type(out.flags) == "table" and out.flags or {}) do
            if type(f) == "table" and G.text(f.title) then
                local doc = U.is_uuid(f.document_uuid) and U.one(
                    "SELECT uuid, filename FROM property_deals_documents WHERE namespace_id = ? AND uuid = ?", ctx.ns, f.document_uuid)
                flags[#flags + 1] = { title = G.text(f.title, 200), detail = G.text(f.detail, 1000),
                    severity = SEVERITY[f.severity] and f.severity or "medium",
                    owner_party = PARTY_ROLES[f.owner_party] and f.owner_party or "seller_solicitor",
                    document_uuid = doc and doc.uuid or nil, filename = doc and doc.filename or nil,
                    page = tonumber(f.page) and math.floor(tonumber(f.page)) or nil }
            end
            if #flags >= 25 then break end
        end
        if #flags == 0 then return nil end
        return { subject_type = "agent_draft", action = "add_red_flags",
            title = #flags .. " red flag(s) in the documents — " .. deal_name(ctx.ns, ctx.deal_uuid),
            payload = { deal_uuid = ctx.deal_uuid, flags = U.array(flags), summary = G.text(out.summary, 1000) } }
    end,
}

-- ---------------------------------------------------------------------------
-- 8. Compliance assistant (a person signs off every check)
-- ---------------------------------------------------------------------------
A.compliance_assistant = {
    name = "Compliance assistant",
    job_type = "extract",
    version = "compliance_assistant@1",
    needs_deal = true,
    approval = "any_operator",
    tools = { "list_compliance_checks", "list_documents", "read_document", "list_parties" },
    instructions = [[
Prepare the AML checklist for this deal: which checks each party still needs (from list_compliance_checks),
gaps in the evidence, and any mismatch between ID documents (names, dates of birth, addresses). Flag expiries.
You never pass, waive or close a check — a person does. Reply with JSON only: {"summary": "...",
"missing": [{"check_type": "aml_cdd_buyer", "party_role": "buyer", "why": "..."}],
"notes": [{"check_uuid": "...", "note": "..."}], "mismatches": ["..."]}]],
    context = function(ctx)
        local T = require("property_deals.ai.tools")
        return { checks = T.defs.list_compliance_checks.run(ctx), documents = T.defs.list_documents.run(ctx),
            parties = T.defs.list_parties.run(ctx) }
    end,
    draft = function(ctx, out)
        local missing, notes, mismatches = {}, {}, {}
        for _, m in ipairs(type(out.missing) == "table" and out.missing or {}) do
            if type(m) == "table" and type(m.check_type) == "string" and m.check_type:match("^[%w_]+$") then
                missing[#missing + 1] = { check_type = m.check_type:sub(1, 60),
                    party_role = PARTY_ROLES[m.party_role] and m.party_role or nil, why = G.text(m.why, 500) }
            end
        end
        for _, n in ipairs(type(out.notes) == "table" and out.notes or {}) do
            if type(n) == "table" and U.is_uuid(n.check_uuid) and G.text(n.note) and U.one(
                "SELECT 1 FROM property_deals_compliance_checks WHERE namespace_id = ? AND uuid = ? AND deal_uuid = ?",
                ctx.ns, n.check_uuid, ctx.deal_uuid) then
                notes[#notes + 1] = { check_uuid = n.check_uuid, note = G.text(n.note, 1000) }
            end
        end
        for _, m in ipairs(type(out.mismatches) == "table" and out.mismatches or {}) do mismatches[#mismatches + 1] = G.text(m, 500) end
        if #missing == 0 and #notes == 0 and #mismatches == 0 then return nil end
        return { subject_type = "agent_draft", action = "compliance_notes",
            title = "Compliance: " .. #missing .. " missing check(s), " .. #mismatches .. " mismatch(es) — " .. deal_name(ctx.ns, ctx.deal_uuid),
            payload = { deal_uuid = ctx.deal_uuid, missing = U.array(missing), notes = U.array(notes),
                mismatches = U.array(mismatches), summary = G.text(out.summary, 1000) } }
    end,
}

-- ---------------------------------------------------------------------------
-- 10. Investor update writer
-- ---------------------------------------------------------------------------
A.investor_update = {
    name = "Investor update writer",
    job_type = "draft",
    version = "investor_update@1",
    needs_deal = true,
    approval = "any_operator",
    tools = { "deal_progress", "get_deal_summary", "list_parties" },
    instructions = [[
Write this week's short plain-English progress note to the buyer/investor on this deal: what happened, what's
next, any risk to the dates, and how many new photos there are. Friendly, factual, no promises. Reply with
JSON only: {"summary": "...", "email": {"to_party": "buyer", "subject": "...", "body": "..."}}]],
    context = function(ctx)
        local T = require("property_deals.ai.tools")
        return { deal = T.defs.get_deal_summary.run(ctx), progress = T.defs.deal_progress.run(ctx) }
    end,
    draft = function(ctx, out)
        local email = type(out.email) == "table" and out.email or nil
        if not email or not G.text(email.body) then return nil end
        local to, to_name = A.party_address(ctx.ns, ctx.deal_uuid, "buyer")
        local subject = G.text(email.subject, 200) or ("Your update: " .. deal_name(ctx.ns, ctx.deal_uuid))
        if not subject:find(A.ref(ctx.deal_uuid), 1, true) then subject = subject .. " " .. A.ref(ctx.deal_uuid) end
        return { subject_type = "agent_draft", action = "send_email",
            title = "Investor update — " .. deal_name(ctx.ns, ctx.deal_uuid) .. (to and "" or " (no buyer email on file)"),
            payload = { deal_uuid = ctx.deal_uuid, channel = "email", to_party = "buyer", to = to, to_name = to_name,
                subject = subject, body = G.text(email.body, 8000), enquiry_uuids = U.array({}),
                enquiry_updates = U.array({}), new_enquiries = U.array({}) } }
    end,
}

A.ORDER = { "lead_triage", "property_enrichment", "offer_reasoning", "buyer_matcher", "legal_chaser", "booking_agent",
    "document_checker", "compliance_assistant", "digest_writer", "investor_update" }

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
            tools = U.array(a.tools), default_approval = a.approval, needs_deal = a.needs_deal == true,
            needs_lead = a.needs_lead == true }
    end
    return U.array(out)
end

return A
