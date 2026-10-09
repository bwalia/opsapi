-- Map data, connectors, matching and the deal scout (SPEC §3.6, §3.7):
--   GET/POST /connectors, GET/PUT/DELETE /connectors/:id      data sources (secrets sealed, never returned)
--   POST /connectors/:id/run { postcode }                      fetch now → { fetched, stored }
--   GET  /market-records ?record_type=&postcode=&per_page=     what connectors / imports brought in
--   POST /market-records/import { record_type, csv, source? }  CSV with a header row (auction lots, agent feeds)
--   POST /properties/:id/enrich                                EPC register + nearby sold prices for a property
--   GET  /companies/search?q=                                  Companies House search
--   POST /buyer-profiles/:id/company-check { company_number? } Companies House profile + officers + flags
--   /saved-searches (CRUD) + POST /saved-searches/:id/run      the deal scout's pins
--   GET  /scout-alerts ?saved_search_uuid=&unseen=true · POST /scout-alerts/seen { uuids? }
--   POST /matches/recompute { property_uuid?, buyer_profile_uuid? }
--   GET  /properties/:id/matches · GET /buyer-profiles/:id/matches   with the score breakdown
--   POST /matches/:id/send { subject?, body? }                 deal pack to the buyer — through an approval
--   POST /suppliers/nearest { kind, task_uuid? | property_uuid? | lat+lng, limit? }   "book nearest"
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local cjson = require("cjson")
local U = require("property_deals.util")
local Connectors = require("property_deals.connectors")
local Market = require("property_deals.market")

--- Minimal RFC 4180 CSV: quoted fields, "" escapes, CRLF or LF.
local function parse_csv(text)
    local rows, row, field, i, inq = {}, {}, {}, 1, false
    local n = #text
    while i <= n do
        local c = text:sub(i, i)
        if inq then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then field[#field + 1] = '"'; i = i + 1 else inq = false end
            else field[#field + 1] = c end
        elseif c == '"' then inq = true
        elseif c == "," then row[#row + 1] = table.concat(field); field = {}
        elseif c == "\n" or c == "\r" then
            if c == "\r" and text:sub(i + 1, i + 1) == "\n" then i = i + 1 end
            row[#row + 1] = table.concat(field); field = {}
            if #row > 1 or row[1] ~= "" then rows[#rows + 1] = row end
            row = {}
        else field[#field + 1] = c end
        i = i + 1
    end
    if #field > 0 or #row > 0 then row[#row + 1] = table.concat(field); rows[#rows + 1] = row end
    return rows
end

local function truthy(v) v = tostring(v or ""):lower() return v == "true" or v == "yes" or v == "y" or v == "1" end

local function match_rows(where, ...)
    return db.query([[
        SELECT m.uuid, m.property_uuid, m.buyer_profile_uuid, m.score, m.breakdown, m.status, m.sent_at, m.computed_at,
               COALESCE(c.first_name || COALESCE(' ' || c.last_name, ''), a.name) AS buyer_name,
               p.address_line1, p.postcode, p.town
        FROM property_deals_matches m
        JOIN property_deals_buyer_profiles b ON b.uuid = m.buyer_profile_uuid
        JOIN property_deals_properties p ON p.uuid = m.property_uuid
        LEFT JOIN crm_contacts c ON c.uuid = b.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = b.account_uuid
        WHERE ]] .. where .. [[ ORDER BY m.score DESC LIMIT 50]], ...)
end

return function(app)
    -- ---------------------------------------------------------------- connectors
    app:get("/connectors", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local out = {}
        for _, r in ipairs(db.query("SELECT * FROM property_deals_connectors WHERE namespace_id = ? ORDER BY kind, name",
            sdk.namespace_id(self))) do out[#out + 1] = Connectors.present(r) end
        return sdk.ok(sdk.array(out))
    end))

    app:post("/connectors", sdk.handler({ permission = "property_deals_settings.update" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local row, errors = Connectors.save(sdk.namespace_id(self), body)
        if not row then return sdk.error(422, "Validation failed", errors) end
        return sdk.created(Connectors.present(row))
    end)))

    app:get("/connectors/:id", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local row = Connectors.get(sdk.namespace_id(self), self.params.id)
        if not row then return sdk.not_found("Connector") end
        return sdk.ok(Connectors.present(row))
    end))

    app:put("/connectors/:id", sdk.handler({ permission = "property_deals_settings.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local existing = Connectors.get(ns, self.params.id)
        if not existing then return sdk.not_found("Connector") end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local row, errors = Connectors.save(ns, body, existing)
        if not row then return sdk.error(422, "Validation failed", errors) end
        return sdk.ok(Connectors.present(row))
    end)))

    app:delete("/connectors/:id", sdk.handler({ permission = "property_deals_settings.update" }, function(self)
        local row = Connectors.get(sdk.namespace_id(self), self.params.id)
        if not row then return sdk.not_found("Connector") end
        db.delete("property_deals_connectors", { id = row.id })
        return sdk.ok({ deleted = true })
    end))

    app:post("/connectors/:id/run", sdk.handler({ permission = "property_deals_settings.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local conn = Connectors.get(ns, self.params.id)
        if not conn then return sdk.not_found("Connector") end
        local body = sdk.body(self) or {}
        local res, err = Connectors.run(ns, conn, { postcode = body.postcode })
        if not res then return sdk.error(Connectors.KINDS[conn.kind].stub and 501 or 502, err) end
        return sdk.ok(res)
    end)))

    -- ---------------------------------------------------------------- market data
    app:get("/market-records", sdk.handler({ permission = "property_deals_properties.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local where, args = { "namespace_id = ?" }, { ns }
        if Market.TYPES[self.params.record_type or ""] then where[#where + 1] = "record_type = ?"; args[#args + 1] = self.params.record_type end
        if self.params.postcode and self.params.postcode ~= "" then
            where[#where + 1] = "UPPER(REPLACE(postcode, ' ', '')) = UPPER(REPLACE(?, ' ', ''))"; args[#args + 1] = self.params.postcode
        end
        local per_page = math.max(1, math.min(200, tonumber(self.params.per_page) or 50))
        args[#args + 1] = per_page
        return sdk.ok(sdk.array(db.query("SELECT * FROM property_deals_market_records WHERE " .. table.concat(where, " AND ")
            .. " ORDER BY event_date DESC NULLS LAST, id DESC LIMIT ?", unpack(args))))
    end))

    app:post("/market-records/import", sdk.handler({ permission = "property_deals_properties.create" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        if not Market.TYPES[body.record_type or ""] then
            return sdk.error(422, "Validation failed", { record_type = "sold_price, epc, listing, auction_lot or other" })
        end
        if type(body.csv) ~= "string" or #body.csv < 3 then return sdk.error(422, "Validation failed", { csv = "CSV text with a header row" }) end
        if #body.csv > 5 * 1024 * 1024 then return sdk.error(413, "CSV over 5 MB; split it") end
        local rows = parse_csv(body.csv)
        local head = {}
        for i, h in ipairs(rows[1] or {}) do head[i] = h:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%s%-]+", "_") end
        local records, skipped = {}, 0
        for r = 2, #rows do
            local x = {}
            for i, v in ipairs(rows[r]) do if head[i] and v ~= "" then x[head[i]] = v end end
            local id = x.external_id or x.id or x.lot or x.url or ((x.address or "") .. "|" .. (x.postcode or ""))
            if (x.address or x.postcode) and id ~= "|" then
                records[#records + 1] = { record_type = body.record_type, external_id = id, address = x.address,
                    postcode = x.postcode and x.postcode:upper():gsub("%s+", " ") or nil, lat = x.lat, lng = x.lng or x.lon,
                    property_type = x.property_type or x.type, tenure = x.tenure, bedrooms = x.bedrooms or x.beds,
                    price = x.price and x.price:gsub("[£,%s]", ""), event_date = x.date or x.event_date or x.auction_date,
                    epc_rating = x.epc_rating, status = x.status, cash_only = truthy(x.cash_only), url = x.url,
                    data = { lot = x.lot, guide = x.guide_price, notes = x.notes }, source = body.source }
            else skipped = skipped + 1 end
        end
        local conn = { uuid = nil, kind = type(body.source) == "string" and body.source:gsub("[^%w_]", ""):sub(1, 30) or "csv" }
        if conn.kind == "" then conn.kind = "csv" end
        local stored = Market.upsert(sdk.namespace_id(self), conn, records)
        return sdk.ok({ rows = #rows - 1, stored = stored, skipped = skipped })
    end)))

    app:post("/properties/:id/enrich", sdk.handler({ permission = "property_deals_properties.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        if not U.is_uuid(self.params.id) then return sdk.not_found("Property") end
        local res, err = Market.enrich_property(ns, self.params.id)
        if not res then return sdk.error(err == "Property not found" and 404 or 422, err) end
        res.property = U.one("SELECT * FROM property_deals_properties WHERE namespace_id = ? AND uuid = ?", ns, self.params.id)
        local p = res.property
        res.comps = Market.comps(ns, tonumber(p.lat), tonumber(p.lng))
        return sdk.ok(res)
    end)))

    -- ---------------------------------------------------------------- Companies House
    app:get("/companies/search", sdk.handler({ permission = "property_deals_buyers.read" }, U.guard(function(self)
        local q = self.params.q
        if type(q) ~= "string" or #q < 2 then return sdk.error(422, "Validation failed", { q = "at least 2 characters" }) end
        local res, err, status = Connectors.company_search(sdk.namespace_id(self), q)
        if not res then return sdk.error(status or 502, err) end
        return sdk.ok(res)
    end)))

    app:post("/buyer-profiles/:id/company-check", sdk.handler({ permission = "property_deals_buyers.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local b = U.is_uuid(self.params.id) and U.one("SELECT * FROM property_deals_buyer_profiles WHERE namespace_id = ? AND uuid = ?",
            ns, self.params.id)
        if not b then return sdk.not_found("Buyer profile") end
        local body = sdk.body(self) or {}
        local number = body.company_number or (b.company_number ~= db.NULL and b.company_number or nil)
        local res, err, status = Connectors.company_check(ns, number)
        if not res then return sdk.error(status or 502, err) end
        db.update("property_deals_buyer_profiles", { company_number = res.company_number, company_check = cjson.encode(res),
            company_checked_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = b.id })
        return sdk.ok(res)
    end)))

    -- ---------------------------------------------------------------- deal scout
    sdk.crud(app, "/saved-searches", {
        table = "property_deals_saved_searches",
        module = "property_deals_properties",
        fields = {
            name = { type = "string", required = true, max = 120 },
            lat = { type = "number", min = -90, max = 90 }, lng = { type = "number", min = -180, max = 180 },
            radius_miles = { type = "number", min = 1, max = 100, label = "Radius (miles), default 25" },
            polygon = { type = "json", label = "[[lat,lng], ...] instead of a pin" },
            filters = { type = "json", label = "{ min_price, max_price, min_bedrooms, property_types[], record_types[] }" },
            alerts = { type = "boolean" }, stale_after_days = { type = "integer", min = 7, max = 365 },
            owner_user_uuid = { type = "uuid" },
        },
        filterable = { "owner_user_uuid", "alerts" },
        sortable = { "name", "created_at", "last_run_at" },
    })

    app:post("/saved-searches/:id/run", sdk.handler({ permission = "property_deals_properties.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local s = U.is_uuid(self.params.id) and U.one("SELECT * FROM property_deals_saved_searches WHERE namespace_id = ? AND uuid = ?",
            ns, self.params.id)
        if not s then return sdk.not_found("Saved search") end
        return sdk.ok(require("property_deals.scout").run_search(ns, s))
    end)))

    app:get("/scout-alerts", sdk.handler({ permission = "property_deals_properties.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local where, args = { "a.namespace_id = ?" }, { ns }
        if U.is_uuid(self.params.saved_search_uuid) then where[#where + 1] = "a.saved_search_uuid = ?"; args[#args + 1] = self.params.saved_search_uuid end
        if self.params.unseen == "true" then where[#where + 1] = "a.seen_at IS NULL" end
        return sdk.ok(sdk.array(db.query([[
            SELECT a.uuid, a.saved_search_uuid, s.name AS saved_search_name, a.kind, a.detail, a.price, a.previous_price,
                   a.seen_at, a.created_at, m.uuid AS market_record_uuid, m.record_type, m.address, m.postcode, m.lat, m.lng,
                   m.url, m.property_type, m.bedrooms, m.cash_only
            FROM property_deals_scout_alerts a
            JOIN property_deals_saved_searches s ON s.uuid = a.saved_search_uuid
            JOIN property_deals_market_records m ON m.uuid = a.market_record_uuid
            WHERE ]] .. table.concat(where, " AND ") .. " ORDER BY a.created_at DESC LIMIT 200", unpack(args))))
    end))

    app:post("/scout-alerts/seen", sdk.handler({ permission = "property_deals_properties.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local body = sdk.body(self) or {}
        local rows
        if type(body.uuids) == "table" and #body.uuids > 0 then
            local lits = {}
            for _, u in ipairs(body.uuids) do if U.is_uuid(u) then lits[#lits + 1] = db.escape_literal(u) end end
            if #lits == 0 then return sdk.ok({ updated = 0 }) end
            rows = db.query("UPDATE property_deals_scout_alerts SET seen_at = NOW() WHERE namespace_id = ? AND seen_at IS NULL AND uuid IN ("
                .. table.concat(lits, ",") .. ") RETURNING id", ns)
        else
            rows = db.query("UPDATE property_deals_scout_alerts SET seen_at = NOW() WHERE namespace_id = ? AND seen_at IS NULL RETURNING id", ns)
        end
        return sdk.ok({ updated = #rows })
    end)))

    -- ---------------------------------------------------------------- matching
    app:post("/matches/recompute", sdk.handler({ permission = "property_deals_buyers.update" }, U.guard(function(self)
        local body = sdk.body(self) or {}
        local opts = { property_uuid = U.is_uuid(body.property_uuid) and body.property_uuid or nil,
            buyer_profile_uuid = U.is_uuid(body.buyer_profile_uuid) and body.buyer_profile_uuid or nil }
        local n = require("property_deals.matching").recompute(sdk.namespace_id(self), opts, sdk.settings(self))
        return sdk.ok({ scored = n })
    end)))

    app:get("/properties/:id/matches", sdk.handler({ permission = "property_deals_buyers.read" }, function(self)
        if not U.is_uuid(self.params.id) then return sdk.not_found("Property") end
        return sdk.ok(sdk.array(match_rows("m.namespace_id = ? AND m.property_uuid = ?", sdk.namespace_id(self), self.params.id)))
    end))

    app:get("/buyer-profiles/:id/matches", sdk.handler({ permission = "property_deals_buyers.read" }, function(self)
        if not U.is_uuid(self.params.id) then return sdk.not_found("Buyer profile") end
        return sdk.ok(sdk.array(match_rows("m.namespace_id = ? AND m.buyer_profile_uuid = ?", sdk.namespace_id(self), self.params.id)))
    end))

    app:post("/matches/:id/send", sdk.handler({ permission = "property_deals_buyers.update" }, U.guard_create(function(self)
        local ns = sdk.namespace_id(self)
        local body = sdk.body(self) or {}
        local m = U.is_uuid(self.params.id) and U.one([[
            SELECT m.*, p.address_line1, p.town, p.postcode, p.bedrooms, p.property_type, p.est_market_value,
                   COALESCE(NULLIF(c.email, ''), NULLIF(a.email, '')) AS buyer_email,
                   COALESCE(c.first_name, a.name) AS buyer_first
            FROM property_deals_matches m
            JOIN property_deals_properties p ON p.uuid = m.property_uuid
            JOIN property_deals_buyer_profiles b ON b.uuid = m.buyer_profile_uuid
            LEFT JOIN crm_contacts c ON c.uuid = b.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = b.account_uuid
            WHERE m.namespace_id = ? AND m.uuid = ?
        ]], ns, self.params.id)
        if not m then return sdk.not_found("Match") end
        local bd = U.json(m.breakdown) or {}
        if type(bd.deal_breakers) == "table" and #bd.deal_breakers > 0 then
            return sdk.error(409, "This home hits the buyer's deal-breakers: " .. table.concat(bd.deal_breakers, ", "))
        end
        local where = table.concat({ m.address_line1 ~= db.NULL and m.address_line1 or nil, m.town ~= db.NULL and m.town or nil }, ", ")
        local text = body.body or table.concat({
            "Hello " .. tostring(m.buyer_first ~= db.NULL and m.buyer_first or "") .. ",", "",
            "A home that fits what you're looking for: " .. where .. ".",
            (m.bedrooms ~= db.NULL and m.bedrooms and (m.bedrooms .. " bedrooms, ") or "") .. tostring(m.property_type ~= db.NULL and m.property_type or ""),
            "Match score " .. tostring(m.score) .. "/100.", "", "Reply if you'd like the full pack.", "The team" }, "\n")
        local deal = U.one("SELECT uuid FROM property_deals_deals WHERE namespace_id = ? AND property_uuid = ? AND status = 'active' LIMIT 1",
            ns, m.property_uuid)
        local a = require("property_deals.approvals").create(ns, {
            subject_type = "deal_pack", action = "send_deal_pack", rule = "any_operator",
            title = "Send " .. where .. " to " .. tostring(m.buyer_first ~= db.NULL and m.buyer_first or "the buyer")
                .. (m.buyer_email == db.NULL and " (no email address on file)" or ""),
            payload = { match_uuid = m.uuid, to = m.buyer_email ~= db.NULL and m.buyer_email or nil,
                subject = body.subject or ("A home for you: " .. where), body = text, score = tonumber(m.score) },
            deal_uuid = deal and deal.uuid or nil, requested_by_user_uuid = sdk.user(self).uuid,
        })
        return sdk.created(a)
    end)))

    -- ---------------------------------------------------------------- suppliers: book nearest
    app:post("/suppliers/nearest", sdk.handler({ permission = "property_deals_suppliers.read" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        if type(body.kind) ~= "string" or body.kind == "" then return sdk.error(422, "Validation failed", { kind = "e.g. epc_assessor" }) end
        local ns = sdk.namespace_id(self)
        local ctx = { ns = ns }
        if U.is_uuid(body.task_uuid) then
            local t = require("property_deals.tasks").get(ns, body.task_uuid)
            if not t then return sdk.not_found("Task") end
            ctx.property_uuid = t.property_uuid ~= db.NULL and t.property_uuid or nil
            if not ctx.property_uuid and t.deal_uuid ~= db.NULL then
                local d = U.one("SELECT property_uuid FROM property_deals_deals WHERE uuid = ?", t.deal_uuid)
                ctx.property_uuid = d and d.property_uuid ~= db.NULL and d.property_uuid or nil
            end
        elseif U.is_uuid(body.property_uuid) then ctx.property_uuid = body.property_uuid end
        if not ctx.property_uuid and not (tonumber(body.lat) and tonumber(body.lng)) then
            return sdk.error(422, "Validation failed", { task_uuid = "give task_uuid, property_uuid, or lat + lng" })
        end
        if not ctx.property_uuid then
            -- A bare pin: borrow find_suppliers' distance query with a stand-in property row.
            ctx.pin = { lat = tonumber(body.lat), lng = tonumber(body.lng) }
        end
        local T = require("property_deals.ai.tools")
        local rows = ctx.pin and T.nearest(ns, ctx.pin.lat, ctx.pin.lng, body.kind, body.limit)
            or T.defs.find_suppliers.run(ctx, { service = body.kind, limit = body.limit or 5 })
        return sdk.ok(rows)
    end)))
end
