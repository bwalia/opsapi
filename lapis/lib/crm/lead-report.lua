-- luacheck: max line length 140
--[[
    The AI lead report: a PDF per analysis, kept in MinIO, linked from the new-lead email
    =====================================================================================

    Every finished AI analysis (lib/crm/lead-ai.lua) is drawn as a PDF (lib/pdf-lite.lua): the
    rating out of 10, where the lead came from (website form, email, shop chat, ...), what they
    want, the value estimate, why it scored what it did, warnings, the suggested next step, partner
    ideas, questions for the first call, a draft reply and the lead's own message. It is stored in
    the deployment's MinIO at crm/lead-reports/<workspace id>/<lead uuid>/<analysis uuid>.pdf
    (crm_lead_analyses.report_key) and never served from MinIO directly (it isn't reachable from
    the internet everywhere, and the file holds personal data):

      * signed-in staff:  GET /api/v2/crm/leads/:uuid/report          (crm_leads read, the lead visible to them)
      * the email link:   <dashboard>/lead-report/<token>  →  GET /api/v2/public/crm/lead-reports/:token
        token = HMAC-signed (analysis uuid, lead uuid, expiry), LINK_DAYS days, key derived from
        JWT_SECRET_KEY (rotating that key ends every link). The route re-checks the lead still exists.

    The "you've got a new lead" email waits for the report: a fresh lead from a public form or the
    shop is marked crm_leads.alert_held_at instead of emailed at once (CrmLeadNotificationQueries),
    when the workspace's AI is on. It goes out with the rating, summary and report link as soon as
    the analysis finishes (done, failed or skipped), or after HOLD_MINUTES without it (the sweep in
    lib/crm/lead-jobs.lua) — never twice: sending first clears alert_held_at with a conditional UPDATE.
    The submitter's confirmation and the Telegram alert are never held.

    Web price research (Google grounded results) is shown only to the person it ran for, so the
    report gives the estimate and says it came from a web search, never the research itself.

    Specced by spec/lead-report_spec.lua.
]]

local cjson = require("cjson")

local Report = {}

Report.LINK_DAYS = 30
Report.HOLD_MINUTES = 10
Report.MAX_MESSAGE = 4000

local SOURCES = {
    website_form = "Website form", website = "Website", web_form = "Website form", form = "Online form",
    shop = "Online shop", shop_chat = "Shop AI advisor chat", shop_quote = "Shop quote", shop_order = "Shop order",
    email = "Email", phone = "Phone call", call = "Phone call", manual = "Added by the team", referral = "Referral",
    partner = "Partner", social = "Social media", import = "Imported", event = "Event", chat = "Chat", whatsapp = "WhatsApp",
}

local function v(x)
    if x == nil or x == cjson.null or (type(x) == "userdata") then return nil end
    if type(x) == "string" and not x:match("%S") then return nil end
    return x
end

local function humanize(s)
    s = tostring(s):gsub("[_%-]+", " ")
    return (s:gsub("^%l", string.upper))
end

--- 0..100 score → whole number out of 10 (nil when there is no score).
function Report.rating(score)
    local n = tonumber(v(score))
    if not n then return nil end
    return math.max(0, math.min(10, math.floor(n / 10 + 0.5)))
end

function Report.rating_word(r)
    if not r then return "Not rated" end
    if r >= 8 then return "Hot lead" elseif r >= 6 then return "Good lead" elseif r >= 4 then return "Maybe" end
    return "Weak lead"
end

local function rating_colour(r)
    if not r then return { 0.45, 0.48, 0.52 } end
    if r >= 7 then return { 0.09, 0.55, 0.32 } elseif r >= 4 then return { 0.85, 0.55, 0.05 } end
    return { 0.78, 0.2, 0.18 }
end

--- The host of a URL ("https://www.x.co.uk/a?b" → "www.x.co.uk"), or nil.
function Report.host(url)
    url = v(url)
    if type(url) ~= "string" then return nil end
    return url:match("^%a[%w+.-]*://([^/?#:]+)") or nil
end

--- Where the lead came from, in plain words: "Website form · campaign spring · from google.com".
function Report.origin(lead)
    local src = v(lead.source)
    local parts = { src and (SOURCES[tostring(src):lower()] or humanize(src)) or "Unknown" }
    if v(lead.channel) then parts[#parts + 1] = humanize(lead.channel) end
    if v(lead.campaign) then parts[#parts + 1] = "campaign " .. tostring(lead.campaign) end
    local ref = Report.host(lead.referrer_url)
    if ref then parts[#parts + 1] = "from " .. ref end
    return table.concat(parts, " · ")
end

local function money(n, currency)
    n = tonumber(v(n))
    if not n then return nil end
    local sym = ({ GBP = "£", EUR = "€", USD = "$" })[tostring(currency or "GBP"):upper()]
    local whole = tostring(math.floor(n + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return sym and (sym .. whole) or (whole .. " " .. tostring(currency))
end

local function name_of(lead)
    local n = ((v(lead.first_name) or "") .. " " .. (v(lead.last_name) or "")):gsub("^%s+", ""):gsub("%s+$", "")
    return n ~= "" and n or v(lead.company_name) or v(lead.email) or "New lead"
end
Report.name_of = name_of

--- The PDF (a string). a = { workspace, lead, analysis = { uuid, result (table), model?, finished_at? }, currency?, lead_url? }
function Report.build(a)
    local Pdf = require("lib.pdf-lite")
    local lead, r = a.lead or {}, (a.analysis or {}).result or {}
    local rating = Report.rating(r.score)
    local doc = Pdf.new({ title = "Lead report - " .. name_of(lead), footer = (a.workspace or "OpsAPI") .. " · AI lead report" })

    doc:text(a.workspace or "", { size = 9, color = { 0.45, 0.48, 0.52 } })
    doc:heading("Lead report: " .. name_of(lead), 18)
    doc:text("Made by AI on " .. os.date("!%d %b %Y %H:%M UTC") .. ". Check it before you act on it.",
        { size = 9, color = { 0.45, 0.48, 0.52 } })
    doc:space(6)
    doc:badge(rating and (rating .. "/10") or "-/10", Report.rating_word(rating), rating_colour(rating))

    doc:heading("Where it came from", 12)
    doc:row("Source", Report.origin(lead))
    if v(r.origin) then doc:row("What that tells us", r.origin) end
    doc:row("Landing page", v(lead.landing_page_url))
    doc:row("Received", v(lead.created_at) and tostring(lead.created_at):sub(1, 16) or nil)

    doc:heading("Who", 12)
    doc:row("Name", name_of(lead))
    doc:row("Company", v(lead.company_name))
    doc:row("Job title", v(lead.job_title))
    doc:row("Email", v(lead.email))
    doc:row("Phone", v(lead.phone))

    doc:heading("What they want", 12)
    if v(r.summary) then doc:text(r.summary) end
    doc:row("Wants", v(r.wants))
    doc:row("Intent", v(r.intent) and humanize(r.intent) or nil)
    doc:row("Urgency", v(r.urgency) and humanize(r.urgency) or nil)
    doc:row("Deadline", v(r.deadline))
    doc:row("Quantity", v(r.quantity) and tostring(r.quantity) or nil)

    local value = money(r.estimated_value, a.currency)
    if value then
        doc:heading("Deal size (estimate)", 12)
        doc:row("Estimated value", value)
        local lo, hi = money(r.value_low, a.currency), money(r.value_high, a.currency)
        if lo and hi then doc:row("Range", lo .. " to " .. hi) end
        doc:row("How", r.value_source == "web_search" and "From a web price search" or v(r.value_basis)
            or "The AI's own estimate (no web search)")
    end

    local reasons = type(r.score_reasons) == "table" and r.score_reasons or {}
    if #reasons > 0 then
        doc:heading("Why " .. (rating and (rating .. "/10") or "this rating"), 12)
        doc:bullets(reasons)
    end

    local f, warn = type(r.flags) == "table" and r.flags or {}, {}
    if f.spam == true then warn[#warn + 1] = "Looks like spam" end
    if f.vulnerable == true then warn[#warn + 1] = "May be a vulnerable person: take extra care" end
    if f.existing_customer == true then warn[#warn + 1] = "Already a customer or contact of ours" end
    if f.out_of_scope == true then warn[#warn + 1] = "Probably not something we do" end
    if #warn > 0 then
        doc:heading("Warnings", 12)
        doc:bullets(warn, { color = { 0.7, 0.2, 0.15 } })
    end

    local nba = type(r.next_best_action) == "table" and r.next_best_action or {}
    if v(nba.label) then
        doc:heading("Suggested next step", 12)
        doc:row("Do", nba.label .. (v(nba.when) and (" (" .. humanize(nba.when) .. ")") or ""))
        doc:row("Why", v(nba.reason))
    end

    local partners = type(r.partner_suggestions) == "table" and r.partner_suggestions or {}
    if #partners > 0 then
        doc:heading("Partners who could fulfil it", 12)
        local items = {}
        for _, p in ipairs(partners) do
            items[#items + 1] = tostring(p.partner_name) .. (tonumber(v(p.fit)) and (" (fit " .. p.fit .. "/100)") or "")
                .. (v(p.reason) and (": " .. p.reason) or "")
        end
        doc:bullets(items)
    end

    local questions = type(r.questions) == "table" and r.questions or {}
    if #questions > 0 then
        doc:heading("Questions for the first call", 12)
        doc:bullets(questions)
    end

    local reply = type(r.first_reply) == "table" and r.first_reply or {}
    if v(reply.body) then
        doc:heading("Draft first reply (" .. humanize(v(reply.channel) or "email") .. ")", 12)
        if v(reply.subject) then doc:row("Subject", reply.subject) end
        doc:space(4)
        doc:text(reply.body, { color = { 0.2, 0.22, 0.25 } })
    end

    local message = v(lead.notes)
    if message then
        doc:heading("Their message", 12)
        local m = tostring(message)
        if #m > Report.MAX_MESSAGE then m = m:sub(1, Report.MAX_MESSAGE) .. " ..." end
        doc:text(m, { color = { 0.2, 0.22, 0.25 } })
    end

    doc:rule()
    local who = v((a.analysis or {}).model) and ("Model: " .. a.analysis.model .. ". ") or ""
    doc:text(who .. "The AI suggests and drafts only: it never contacts anyone or changes the lead."
        .. (a.lead_url and (" Open the lead: " .. a.lead_url) or ""), { size = 8, color = { 0.45, 0.48, 0.52 } })
    return doc:render()
end

-- ---------------------------------------------------------------------------
-- Signed links (pure, with the key and hmac passed in; see linkKey below)
-- ---------------------------------------------------------------------------

function Report.sign(analysis_uuid, lead_uuid, now, key, hmac, days)
    return require("lib.supplier-portal").signToken(analysis_uuid, lead_uuid, now,
        (days or Report.LINK_DAYS) * 86400, key, hmac)
end

--- → { analysis_uuid, lead_uuid, exp } | nil, "invalid" | "expired"
function Report.verify(token, now, key, hmac)
    local t, why = require("lib.supplier-portal").verifyToken(token, now, key, hmac)
    if not t then return nil, why end
    return { analysis_uuid = t.doc_uuid, lead_uuid = t.user_uuid, exp = t.exp }
end

-- ---------------------------------------------------------------------------
-- Storage and sending (OpenResty + database from here on)
-- ---------------------------------------------------------------------------

local function env(name)
    local x = os.getenv(name)
    if x == nil then return nil end
    x = x:match("^%s*(.-)%s*$")
    return x ~= "" and x or nil
end

local function frontend()
    return ((env("FRONTEND_URL") or env("DASHBOARD_URL") or ""):gsub("/+$", ""))
end

function Report.linkKey()
    local Files = require("lib.supplier-portal-files")
    local secret = env("JWT_SECRET_KEY") or error("JWT_SECRET_KEY not configured")
    return Files.hmac(secret, "opsapi:crm:lead-reports:v1")
end

--- The email link to a report (via the dashboard, which knows where the API is), or nil.
function Report.link(analysis_uuid, lead_uuid)
    local base = frontend()
    if base == "" then return nil end
    local Files = require("lib.supplier-portal-files")
    return base .. "/lead-report/" .. Report.sign(analysis_uuid, lead_uuid, ngx.time(), Report.linkKey(), Files.hmac)
end

local function client()
    local Minio = require("helper.minio")
    local c = Minio.new({ bucket = env("CRM_REPORTS_BUCKET") or env("MINIO_BUCKET") })
    if not c:validate() then return nil end
    return c
end

function Report.key(ns_id, lead_uuid, analysis_uuid)
    return ("crm/lead-reports/%s/%s/%s.pdf"):format(tostring(ns_id), tostring(lead_uuid), tostring(analysis_uuid))
end

local function lead_row(lead_id)
    local db = require("lapis.db")
    return db.query([[SELECT id, uuid, namespace_id, first_name, last_name, email, phone, company_name, job_title, source,
        channel, campaign, referrer_url, landing_page_url, notes, currency, created_at::text AS created_at
        FROM crm_leads WHERE id = ? AND deleted_at IS NULL]], lead_id)[1]
end

local function analysis_row(lead_id, analysis_uuid)
    local db = require("lapis.db")
    if analysis_uuid then
        return db.query([[SELECT id, uuid, lead_id, namespace_id, status, result, model, report_key, error, finished_at
            FROM crm_lead_analyses WHERE lead_id = ? AND uuid::text = ?]], lead_id, analysis_uuid)[1]
    end
    return db.query([[SELECT id, uuid, lead_id, namespace_id, status, result, model, report_key, error, finished_at
        FROM crm_lead_analyses WHERE lead_id = ? AND status IN ('done', 'failed', 'skipped')
        ORDER BY created_at DESC, id DESC LIMIT 1]], lead_id)[1]
end

local function decode(x)
    if type(x) == "table" then return x end
    if type(x) ~= "string" then return {} end
    local ok, t = pcall(cjson.decode, x)
    return ok and type(t) == "table" and t or {}
end

--- Draw, store and record the report of a finished analysis. → key | nil, why. Never raises.
function Report.make(analysis)
    local ok, key_or_err, why = pcall(function()
        if not analysis or analysis.status ~= "done" then return nil, "no finished analysis" end
        local lead = lead_row(analysis.lead_id)
        if not lead then return nil, "the lead is gone" end
        local c = client()
        if not c then return nil, "file storage (MinIO) isn't set up here" end
        local db = require("lapis.db")
        local ws = (db.query("SELECT name FROM namespaces WHERE id = ?", lead.namespace_id)[1] or {}).name
        local Settings = require("lib.crm.lead-settings")
        local bytes = Report.build({
            workspace = ws, lead = lead, currency = v(lead.currency) or Settings.get(tonumber(lead.namespace_id)).currency,
            analysis = { uuid = analysis.uuid, result = decode(analysis.result), model = v(analysis.model) },
            lead_url = frontend() ~= "" and (frontend() .. "/dashboard/leads/" .. lead.uuid) or nil,
        })
        local key = Report.key(lead.namespace_id, lead.uuid, analysis.uuid)
        local _, err, info = c:upload({ content = bytes, filename = "report.pdf", content_type = "application/pdf" },
            { object_key = key, validate_type = false, max_size = 20 * 1024 * 1024 })
        if not info then return nil, "storing the report failed: " .. tostring(err) end
        db.query("UPDATE crm_lead_analyses SET report_key = ?, report_bytes = ? WHERE id = ?", info.key or key, #bytes, analysis.id)
        analysis.report_key = info.key or key
        return analysis.report_key
    end)
    if not ok then
        ngx.log(ngx.ERR, "[lead-report] ", tostring(key_or_err))
        return nil, "the report couldn't be made"
    end
    if not key_or_err and why then
        ngx.log(ngx.WARN, "[lead-report] no report for analysis ", tostring(analysis and analysis.uuid), ": ", why)
    end
    return key_or_err, why
end

--- The PDF bytes of an analysis (made now when it has none yet): the one asked for, else the latest that
-- finished (a later failed or skipped run doesn't hide it). → bytes, filename | nil, status, message
function Report.bytes(lead_id, analysis_uuid)
    local a = analysis_uuid and analysis_row(lead_id, analysis_uuid) or require("lapis.db").query([[
        SELECT id, uuid, lead_id, namespace_id, status, result, model, report_key, error, finished_at
        FROM crm_lead_analyses WHERE lead_id = ? AND status = 'done' ORDER BY created_at DESC, id DESC LIMIT 1]], lead_id)[1]
    if not a or a.status ~= "done" then return nil, 404, "This lead has no finished AI analysis yet" end
    if not v(a.report_key) then
        local key, why = Report.make(a)
        if not key then return nil, 503, "The report isn't available: " .. tostring(why) end
    end
    local c = client()
    if not c then return nil, 503, "File storage isn't set up here" end
    local body, err = c:get(a.report_key)
    if not body then
        ngx.log(ngx.ERR, "[lead-report] read ", tostring(a.report_key), ": ", tostring(err))
        return nil, 503, "The report couldn't be read. Try again shortly."
    end
    local lead = lead_row(lead_id) or {}
    local slug = name_of(lead):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):sub(1, 40)
    return body, "lead-report-" .. (slug ~= "" and slug or "lead") .. ".pdf"
end

-- ---------------------------------------------------------------------------
-- The held new-lead email
-- ---------------------------------------------------------------------------

--- Should a fresh lead's "new lead" email wait for the AI? (request context, never raises)
function Report.should_hold(ns_id)
    local ok, yes = pcall(function()
        local Settings = require("lib.crm.lead-settings")
        local s = Settings.get(ns_id)
        return s.ai_enabled == true and #require("lib.crm.lead-ai").chain(ns_id, s) > 0
    end)
    return ok and yes == true
end

function Report.hold(lead_id)
    require("lapis.db").query("UPDATE crm_leads SET alert_held_at = NOW() WHERE id = ? AND alert_held_at IS NULL", lead_id)
end

--- The AI part of the new-lead email for this lead's latest analysis (template fields).
function Report.email_fields(lead_id, lead_uuid)
    local a = analysis_row(lead_id)
    if not a then return { ai_note = "The AI hasn't finished this lead yet. Its report will be on the lead's page." } end
    if a.status ~= "done" then
        return { ai_note = "The AI couldn't analyse this lead: " .. tostring(v(a.error) or "no answer") }
    end
    local r = decode(a.result)
    local rating = Report.rating(r.score)
    local nba = type(r.next_best_action) == "table" and r.next_best_action or {}
    local out = {
        ai_rating = rating and (rating .. "/10 (" .. Report.rating_word(rating) .. ")") or nil,
        ai_summary = v(r.summary), ai_origin = v(r.origin),
        ai_next = v(nba.label) and (nba.label .. (v(nba.reason) and (": " .. nba.reason) or "")) or nil,
        ai_spam = type(r.flags) == "table" and r.flags.spam == true or nil,
    }
    if not v(a.report_key) then Report.make(a) end
    if v(a.report_key) then
        local ok, link = pcall(Report.link, a.uuid, lead_uuid)
        if ok and link then
            out.ai_report_url = link
            out.ai_report_days = Report.LINK_DAYS
        end
    end
    return out
end

--- Send the held "new lead" email now (once: the first caller clears the flag). → true when sent
function Report.release(lead_id)
    local db = require("lapis.db")
    local l = db.query([[UPDATE crm_leads SET alert_held_at = NULL WHERE id = ? AND alert_held_at IS NOT NULL
        RETURNING id, uuid, namespace_id, first_name, last_name, email, phone, company_name, job_title, source, notes]], lead_id)[1]
    if not l then return false end
    local ok, err = pcall(function()
        local ns = db.query("SELECT id, slug, name FROM namespaces WHERE id = ?", l.namespace_id)[1]
        if not ns then return end
        local ai = Report.email_fields(l.id, l.uuid)
        local base = frontend()
        ai.lead_url = base ~= "" and (base .. "/dashboard/leads/" .. l.uuid) or nil
        require("queries.CrmLeadNotificationQueries").sendHeld(ns, l, ai)
    end)
    if not ok then ngx.log(ngx.ERR, "[lead-report] held lead email for ", tostring(lead_id), ": ", tostring(err)) end
    return ok
end

--- The sweep: leads held longer than HOLD_MINUTES go out without waiting any longer.
function Report.release_overdue()
    -- Before migration zzcrmc (a deploy rolling out) there is nothing to release.
    if not require("helper.table-exists")("crm_leads", "alert_held_at") then return end
    local db = require("lapis.db")
    for _, l in ipairs(db.query([[SELECT id FROM crm_leads WHERE alert_held_at IS NOT NULL
        AND alert_held_at < NOW() - make_interval(mins => ?) ORDER BY alert_held_at LIMIT 50]], Report.HOLD_MINUTES)) do
        Report.release(l.id)
    end
end

--- After an analysis run (lib/crm/lead-ai.lua process): its report, then a held email.
function Report.after_run(run)
    local db = require("lapis.db")
    local a = db.query([[SELECT id, uuid, lead_id, namespace_id, status, result, model, report_key
        FROM crm_lead_analyses WHERE id = ?]], run.id)[1]
    if a and a.status == "done" then Report.make(a) end
    Report.release(run.lead_id)
end

return Report
