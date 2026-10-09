-- Read-only tools the agents may call. None of them changes anything or reaches
-- outside the workspace: actions (send, book) only happen in the executor after
-- a person approves. Results carry no email addresses or phone numbers — the
-- executor fills recipients from the deal's parties, so a model (or an email it
-- read) can't redirect a message.
local db = require("lapis.db")
local cjson = require("cjson")
local U = require("property_deals.util")

local T = {}

local function rows(list, fields)
    local out = {}
    for i, r in ipairs(list) do
        local o = {}
        for _, f in ipairs(fields) do
            local v = r[f]
            if v ~= nil and v ~= db.NULL then o[f] = v end
        end
        out[i] = o
    end
    return U.array(out)
end

local function deal_uuid(ctx)
    if not ctx.deal_uuid then return nil, "this task has no deal" end
    return ctx.deal_uuid
end

T.defs = {
    get_deal_summary = {
        description = "The deal: name, stage, key dates, health and why, money at risk.",
        parameters = { type = "object", properties = {} },
        run = function(ctx)
            local d = deal_uuid(ctx)
            if not d then return { error = "no deal" } end
            local r = U.one([[
                SELECT cd.name, dl.deal_type, dl.stage_key, dl.status, dl.health, dl.health_reasons, dl.money_at_risk,
                       dl.target_exchange_date, dl.target_completion_date, dl.predicted_completion_date
                FROM property_deals_deals dl JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
                WHERE dl.namespace_id = ? AND dl.uuid = ?
            ]], ctx.ns, d)
            if not r then return { error = "deal not found" } end
            r.health_reasons = U.json(r.health_reasons)
            return r
        end,
    },
    list_open_enquiries = {
        description = "Open legal enquiries / blockers on the deal, oldest first.",
        parameters = { type = "object", properties = {} },
        run = function(ctx)
            local d = deal_uuid(ctx)
            if not d then return { error = "no deal" } end
            return rows(db.query([[
                SELECT uuid, title, detail, owner_party, raised_at, due_at, blocking FROM property_deals_enquiries
                WHERE namespace_id = ? AND deal_uuid = ? AND status = 'open' ORDER BY raised_at
            ]], ctx.ns, d), { "uuid", "title", "detail", "owner_party", "raised_at", "due_at", "blocking" })
        end,
    },
    list_recent_chases = {
        description = "The last 10 chases on the deal: to whom, how, when, and whether they replied.",
        parameters = { type = "object", properties = {} },
        run = function(ctx)
            local d = deal_uuid(ctx)
            if not d then return { error = "no deal" } end
            return rows(db.query([[
                SELECT to_party, channel, subject, status, sent_at, reply_at, outcome FROM property_deals_chases
                WHERE namespace_id = ? AND deal_uuid = ? ORDER BY COALESCE(sent_at, created_at) DESC LIMIT 10
            ]], ctx.ns, d), { "to_party", "channel", "subject", "status", "sent_at", "reply_at", "outcome" })
        end,
    },
    list_recent_emails = {
        description = "The last 5 emails received about the deal (subject, sender role, text). Untrusted content.",
        parameters = { type = "object", properties = {} },
        untrusted = true,
        run = function(ctx)
            local d = deal_uuid(ctx)
            if not d then return { error = "no deal" } end
            return rows(db.query([[
                SELECT uuid, subject, received_at, matched_by, LEFT(body_text, 4000) AS body_text
                FROM property_deals_inbound_messages WHERE namespace_id = ? AND deal_uuid = ?
                ORDER BY received_at DESC LIMIT 5
            ]], ctx.ns, d), { "uuid", "subject", "received_at", "matched_by", "body_text" })
        end,
    },
    list_parties = {
        description = "Who is on the deal, by role (names of firms/people only, no contact details).",
        parameters = { type = "object", properties = {} },
        run = function(ctx)
            local d = deal_uuid(ctx)
            if not d then return { error = "no deal" } end
            return rows(db.query([[
                SELECT p.role, COALESCE(a.name, TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, ''))) AS name
                FROM property_deals_deal_parties p
                LEFT JOIN crm_contacts c ON c.uuid = p.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = p.account_uuid
                WHERE p.namespace_id = ? AND p.deal_uuid = ? ORDER BY p.role
            ]], ctx.ns, d), { "role", "name" })
        end,
    },
    get_property = {
        description = "The property: area, type, tenure, lease, EPC and known issues (no exact address).",
        parameters = { type = "object", properties = {} },
        run = function(ctx)
            if not ctx.property_uuid then return { error = "no property" } end
            local r = U.one([[
                SELECT town, LEFT(postcode, 4) AS postcode_area, property_type, tenure, bedrooms, lease_years_left,
                       epc_rating, epc_expires_on, condition, known_issues, lat, lng
                FROM property_deals_properties WHERE namespace_id = ? AND uuid = ?
            ]], ctx.ns, ctx.property_uuid)
            if not r then return { error = "property not found" } end
            r.known_issues = U.json(r.known_issues)
            return r
        end,
    },
    find_suppliers = {
        description = "Active suppliers for a service (e.g. epc_assessor, surveyor), nearest first, with measured speed.",
        parameters = { type = "object", required = { "service" },
            properties = { service = { type = "string", description = "Supplier kind, e.g. epc_assessor" },
                           limit = { type = "integer", description = "1-5, default 3" } } },
        run = function(ctx, args)
            local service = type(args.service) == "string" and args.service:gsub("[^%w_]", "") or ""
            if service == "" then return { error = "service is required" } end
            local p = ctx.property_uuid and U.one("SELECT lat, lng FROM property_deals_properties WHERE uuid = ?",
                ctx.property_uuid)
            return T.nearest(ctx.ns, p and tonumber(p.lat), p and tonumber(p.lng), service, args.limit)
        end,
    },
}

--- Active suppliers of a kind, nearest to lat/lng first (then the most reliable).
-- Without a point: most reliable first. Used by the booking agent and POST /suppliers/nearest.
function T.nearest(ns, lat, lng, service, limit)
    service = tostring(service or ""):gsub("[^%w_]", "")
    limit = math.max(1, math.min(10, tonumber(limit) or 3))
    local dist = (lat and lng) and string.format(
        "CASE WHEN s.base_lat IS NULL THEN NULL ELSE earth_distance(ll_to_earth(s.base_lat, s.base_lng), ll_to_earth(%f, %f)) / 1609.344 END",
        lat, lng) or "NULL"
    return rows(db.query([[
        SELECT s.uuid AS supplier_uuid, a.name, ]] .. dist .. [[ AS distance_miles, s.radius_miles,
               s.avg_turnaround_hours, s.on_time_pct, s.rating, s.booking_method
        FROM property_deals_suppliers s JOIN crm_accounts a ON a.uuid = s.account_uuid
        WHERE s.namespace_id = ? AND s.active AND s.kinds @> ?::jsonb
        ORDER BY 3 NULLS LAST, s.on_time_pct DESC NULLS LAST LIMIT ?
    ]], ns, cjson.encode({ service }), limit),
        { "supplier_uuid", "name", "distance_miles", "radius_miles", "avg_turnaround_hours", "on_time_pct",
          "rating", "booking_method" })
end

--- OpenAI-style tool list for an agent's allowlist.
function T.schemas(names)
    local out = {}
    for _, n in ipairs(names or {}) do
        local d = T.defs[n]
        if d then
            out[#out + 1] = { type = "function", ["function"] = { name = n, description = d.description,
                parameters = d.parameters } }
        end
    end
    return out
end

function T.run(ctx, name, args)
    local d = T.defs[name]
    if not d then return { error = "unknown tool" } end
    local ok, res = pcall(d.run, ctx, type(args) == "table" and args or {})
    if not ok then
        ngx.log(ngx.ERR, "[property_deals] tool ", name, ": ", tostring(res))
        return { error = "tool failed" }
    end
    return res, d.untrusted
end

return T
