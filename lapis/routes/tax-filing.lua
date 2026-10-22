--[[
    Filing: download your calculation (.xlsx) and "let our accountant file it for you".

    OpsAPI isn't an HMRC-recognised filer yet, so besides direct MTD filing (Tax → File)
    a customer can hand their return to our accountant, who files it with HMRC-recognised
    software (e.g. My Tax Digital) from the frozen figures the customer approved.

    Customer — requireAuth + requireNamespace; only their own rows (namespace + user):
      GET  /api/v2/tax/filing/overview?tax_year=     figures, hash, NINO on file, latest request
      GET  /api/v2/tax/filing/export?tax_year=       live calculation as .xlsx
      GET  /api/v2/tax/filing/requests               my requests
      POST /api/v2/tax/filing/requests               { tax_year, declaration_accepted, figures_hash }
      POST /api/v2/tax/filing/requests/:uuid/cancel
      POST /api/v2/tax/filing/requests/:uuid/reply   { text } — answer the accountant
      GET  /api/v2/tax/filing/requests/:uuid/export  the approved figures as .xlsx

    Accountant queue — RBAC module tax_filing_requests, this workspace only:
      GET  /api/v2/tax/filing/queue?status=          read
      GET  /api/v2/tax/filing/queue/:uuid            read
      GET  /api/v2/tax/filing/queue/:uuid/export     read (each download is put on the timeline)
      POST /api/v2/tax/filing/queue/:uuid/status     update { status, message?, hmrc_reference?,
                                                              hmrc_total_due?, variance_note? }

    Status: submitted → reviewing → filing → filed; needs_info is a question to the
    customer (their reply moves it back to reviewing); rejected / cancelled are closed.
    One open request per customer + tax year (DB-enforced). Emails carry no figures and
    no free text — just "log in to see the update" (matches diy).

    Env: TAX_FILING_NOTIFY_EMAIL — accountant inbox for new requests / replies / cancels.
         TAX_DIRECT_FILING_ENABLED=false — hide direct HMRC filing (until we're recognised).
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local Global = require("helper.global")
local TaxReport = require("lib.tax-report")

local DECLARATION = "My figures are correct and complete. I authorise this service's accountant to file my "
    .. "Self Assessment tax return with HMRC on my behalf, as my agent. I understand I remain responsible "
    .. "for my return and may have to pay penalties if I give false information."

local OPEN = { submitted = true, reviewing = true, needs_info = true, filing = true }
-- Accountant moves: from → allowed next statuses.
local NEXT = {
    submitted  = { reviewing = true, needs_info = true, rejected = true },
    reviewing  = { filing = true, needs_info = true, rejected = true },
    needs_info = { reviewing = true, rejected = true },
    filing     = { filed = true, needs_info = true, rejected = true },
}
local CUSTOMER_EMAIL = {
    reviewing  = "Our accountant has started reviewing your %s tax return.",
    filing     = "Your %s tax return is being filed with HMRC.",
    filed      = "Your %s tax return has been filed with HMRC. Log in to see the HMRC reference.",
    needs_info = "Our accountant has a question about your %s tax return — please log in to reply.",
    rejected   = "Our accountant has returned your %s tax return to you — please log in to see why.",
}
local VARIANCE_TOLERANCE = 1.00 -- £: an HMRC total further than this from ours needs a note

-- The statuses an accountant may move a request to next, as a JSON-friendly list.
local ORDER = { "reviewing", "filing", "filed", "needs_info", "rejected" }
local function next_statuses(status)
    local out = {}
    for _, s in ipairs(ORDER) do
        if NEXT[status] and NEXT[status][s] then out[#out + 1] = s end
    end
    if #out == 0 then return cjson.empty_array or setmetatable({}, cjson.array_mt) end
    return out
end

local function jsonb(value)
    return db.raw(db.escape_literal(cjson.encode(value)) .. "::jsonb")
end

local function decode(v)
    if type(v) == "table" then return v end
    if type(v) ~= "string" or v == "" then return nil end
    local ok, t = pcall(cjson.decode, v)
    return ok and t or nil
end

local function now_iso() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

local function read_body(self)
    local data = {}
    pcall(function()
        ngx.req.read_body()
        local raw = ngx.req.get_body_data()
        if raw and raw:match("^%s*{") then
            local ok, t = pcall(cjson.decode, raw)
            if ok and type(t) == "table" then data = t end
        end
    end)
    for k, v in pairs(self.params or {}) do
        if data[k] == nil then data[k] = v end
    end
    return data
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function truthy(v) return v == true or v == "true" or v == "1" or v == "on" end

local function current_user(self)
    local u = self.current_user
    local uuid = u and (u.uuid or u.id)
    if not uuid then return nil end
    return db.query("SELECT id, first_name, last_name, email FROM users WHERE uuid = ? LIMIT 1", uuid)[1]
end

local function display_name(u)
    local n = trim((u.first_name or "") .. " " .. (u.last_name or ""))
    return n ~= "" and n or (u.email or "")
end

local function valid_year(y)
    y = tostring(y or "")
    return y:match("^%d%d%d%d%-%d%d$") and y or nil
end

local function nino_info(user_id)
    local r = db.query("SELECT nino_last4, has_nino FROM tax_user_profiles WHERE user_id = ? LIMIT 1", user_id)[1]
    local has = r and (r.has_nino == true or r.has_nino == "t" or (r.nino_last4 and r.nino_last4 ~= "")) or false
    return { has = has and true or false, last4 = has and r.nino_last4 or nil }
end

local function report_ctx(self, user_id, tax_year)
    return {
        namespace_id = self.namespace.id, user_id = user_id, tax_year = tax_year,
        has_permission = function(module, action) return NamespaceMiddleware.hasPermission(self, module, action) end,
    }
end

local function fail(status, code, message, extra)
    local body = { error = message, code = code }
    for k, v in pairs(extra or {}) do body[k] = v end
    return { status = status, json = body }
end

local function xlsx_response(bytes, filename)
    return {
        status = 200,
        content_type = require("lib.xlsx").CONTENT_TYPE,
        headers = {
            ["Content-Disposition"] = ('attachment; filename="%s"'):format(filename),
            ["Cache-Control"] = "no-store",
        },
        layout = false,
        bytes,
    }
end

-- Fire-and-forget email; never fails the request. No figures / free text in the body.
local function notify(to, subject, line)
    if not to or not to:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then return end
    pcall(function()
        local Mail = require("helper.mail")
        if not Mail.isConfigured() then return end
        Mail.send({ to = to, subject = subject,
            html = "<p>" .. line .. "</p><p style=\"color:#666;font-size:13px\">You can see the details "
                .. "by logging in to your account.</p>" })
    end)
end

local function notify_accountant(subject, line)
    notify(os.getenv("TAX_FILING_NOTIFY_EMAIL"), subject, line)
end

local function append_update(id, entry)
    db.query("UPDATE tax_filing_requests SET updates = updates || ?, updated_at = NOW() WHERE id = ?",
        jsonb({ entry }), id)
end

-- What the customer sees of a request (internal events like downloads are hidden).
local function customer_json(r)
    local timeline = {}
    for _, e in ipairs(decode(r.updates) or {}) do
        if e.type ~= "export" then timeline[#timeline + 1] = e end
    end
    return {
        uuid = r.uuid, tax_year = r.tax_year, status = r.status, open = OPEN[r.status] or false,
        our_total_due = tonumber(r.our_total_due), declared_at = r.declared_at,
        hmrc_reference = r.hmrc_reference, filed_at = r.filed_at, client_message = r.client_message,
        created_at = r.created_at, updated_at = r.updated_at, timeline = timeline,
    }
end

local function own_request(self, user_id)
    return db.query([[SELECT * FROM tax_filing_requests WHERE uuid = ? AND namespace_id = ? AND user_id = ?
        LIMIT 1]], tostring(self.params.uuid or ""), self.namespace.id, user_id)[1]
end

local function queue_request(self)
    return db.query("SELECT * FROM tax_filing_requests WHERE uuid = ? AND namespace_id = ? LIMIT 1",
        tostring(self.params.uuid or ""), self.namespace.id)[1]
end

return function(app)
    local auth = function(fn)
        return AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(fn))
    end
    local perm = function(action, fn)
        return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("tax_filing_requests", action, fn))
    end

    -- ── Customer ──────────────────────────────────────────────────────────────

    app:get("/api/v2/tax/filing/overview", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "UNAUTHORIZED", "User not found") end
        local year = valid_year(self.params.tax_year)
        if not year then return fail(400, "BAD_TAX_YEAR", "tax_year must look like 2025-26") end
        local report, err = TaxReport.build(report_ctx(self, u.id, year))
        if not report then return fail(403, "FORBIDDEN", tostring(err)) end
        local est = {}
        for k, v in pairs(report.summary) do est[k] = v end
        for k, v in pairs(report.totals) do est[k] = v end
        local latest = db.query([[SELECT * FROM tax_filing_requests
            WHERE namespace_id = ? AND user_id = ? AND tax_year = ?
            ORDER BY (status IN ('submitted','reviewing','needs_info','filing','filed')) DESC, created_at DESC
            LIMIT 1]], self.namespace.id, u.id, year)[1]
        return { status = 200, json = { success = true, data = {
            tax_year = year,
            estimate = est,
            figures_hash = TaxReport.hash(report),
            nino = nino_info(u.id),
            direct_filing_enabled = os.getenv("TAX_DIRECT_FILING_ENABLED") ~= "false",
            declaration_text = DECLARATION,
            request = latest and customer_json(latest) or cjson.null,
        } } }
    end))

    app:get("/api/v2/tax/filing/export", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "UNAUTHORIZED", "User not found") end
        local year = valid_year(self.params.tax_year)
        if not year then return fail(400, "BAD_TAX_YEAR", "tax_year must look like 2025-26") end
        local report, err = TaxReport.build(report_ctx(self, u.id, year))
        if not report then return fail(403, "FORBIDDEN", tostring(err)) end
        return xlsx_response(TaxReport.xlsx(report), TaxReport.filename(report))
    end))

    app:get("/api/v2/tax/filing/requests", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "UNAUTHORIZED", "User not found") end
        local rows = db.query([[SELECT * FROM tax_filing_requests WHERE namespace_id = ? AND user_id = ?
            ORDER BY created_at DESC LIMIT 50]], self.namespace.id, u.id)
        local list = {}
        for _, r in ipairs(rows) do list[#list + 1] = customer_json(r) end
        return { status = 200, json = { success = true, data = list } }
    end))

    app:post("/api/v2/tax/filing/requests", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "UNAUTHORIZED", "User not found") end
        local body = read_body(self)
        local year = valid_year(body.tax_year)
        if not year then return fail(400, "BAD_TAX_YEAR", "tax_year must look like 2025-26") end
        if not truthy(body.declaration_accepted) then
            return fail(400, "DECLARATION_REQUIRED", "Please confirm the declaration to continue.")
        end
        if not nino_info(u.id).has then
            return fail(400, "NINO_REQUIRED", "Add your National Insurance number first.")
        end
        local existing = db.query([[SELECT * FROM tax_filing_requests WHERE namespace_id = ? AND user_id = ?
            AND tax_year = ? AND status IN ('submitted','reviewing','needs_info','filing','filed') LIMIT 1]],
            self.namespace.id, u.id, year)[1]
        if existing then
            return fail(409, "ALREADY_REQUESTED", "You already have a filing request for " .. year .. ".",
                { request = customer_json(existing) })
        end

        local report, err = TaxReport.build(report_ctx(self, u.id, year))
        if not report then return fail(403, "FORBIDDEN", tostring(err)) end
        if (report.totals.transactions or 0) == 0 then
            return fail(400, "NO_FIGURES", "Upload and categorise your bank statements for " .. year .. " first.")
        end
        -- Nothing is filed on figures the customer hasn't checked row by row.
        local unchecked = (report.totals.transactions or 0) - (report.totals.confirmed or 0)
        if unchecked > 0 then
            return fail(409, "TRANSACTIONS_NOT_CONFIRMED",
                ("Check and confirm your transactions first — %d still to confirm."):format(unchecked),
                { unconfirmed = unchecked })
        end
        local hash = TaxReport.hash(report)
        if tostring(body.figures_hash or "") ~= hash then
            return fail(409, "FIGURES_CHANGED",
                "Your figures changed since you reviewed them — please check them again before sending.",
                { figures_hash = hash })
        end

        local ok, res = pcall(db.query, [[INSERT INTO tax_filing_requests
            (uuid, namespace_id, user_id, tax_year, status, snapshot, figures_hash, our_total_due,
             declaration_text, declared_at, updates, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, 'submitted', ?, ?, ?, ?, NOW(), ?, NOW(), NOW())
            RETURNING *]],
            self.namespace.id, u.id, year, jsonb(report), hash, report.summary.total_tax_and_nic,
            DECLARATION, jsonb({ { type = "status", status = "submitted", by = "customer", at = now_iso() } }))
        if not ok then
            if tostring(res):find("uq_tax_filing_requests_open", 1, true) then
                return fail(409, "ALREADY_REQUESTED", "You already have a filing request for " .. year .. ".")
            end
            ngx.log(ngx.ERR, "[tax-filing] create failed: ", tostring(res))
            return fail(500, "CREATE_FAILED", "Could not send your request. Please try again.")
        end
        notify_accountant("New filing request — " .. year,
            "A customer has asked us to file their " .. year .. " Self Assessment return. Open Tax → Filing requests.")
        return { status = 201, json = { success = true, data = customer_json(res[1]) } }
    end))

    app:post("/api/v2/tax/filing/requests/:uuid/cancel", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "UNAUTHORIZED", "User not found") end
        local r = own_request(self, u.id); if not r then return fail(404, "NOT_FOUND", "Request not found") end
        if not (r.status == "submitted" or r.status == "reviewing" or r.status == "needs_info") then
            return fail(409, "CANNOT_CANCEL", "This request can no longer be cancelled.")
        end
        local res = db.query([[UPDATE tax_filing_requests SET status = 'cancelled', updated_at = NOW()
            WHERE id = ? AND status = ? RETURNING *]], r.id, r.status)
        if not res[1] then return fail(409, "CHANGED", "This request just changed — please reload.") end
        append_update(r.id, { type = "status", status = "cancelled", by = "customer", at = now_iso() })
        notify_accountant("Filing request cancelled — " .. r.tax_year,
            "A customer cancelled their " .. r.tax_year .. " filing request.")
        return { status = 200, json = { success = true, data = customer_json(own_request(self, u.id)) } }
    end))

    app:post("/api/v2/tax/filing/requests/:uuid/reply", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "UNAUTHORIZED", "User not found") end
        local r = own_request(self, u.id); if not r then return fail(404, "NOT_FOUND", "Request not found") end
        if r.status ~= "needs_info" then
            return fail(409, "NOT_WAITING", "Our accountant isn't waiting for a reply on this request.")
        end
        local text = trim(read_body(self).text)
        if text == "" or #text > 2000 then
            return fail(400, "BAD_TEXT", "Write a reply of up to 2000 characters.")
        end
        local res = db.query([[UPDATE tax_filing_requests SET status = 'reviewing', updated_at = NOW()
            WHERE id = ? AND status = 'needs_info' RETURNING *]], r.id)
        if not res[1] then return fail(409, "CHANGED", "This request just changed — please reload.") end
        append_update(r.id, { type = "reply", text = text, by = "customer", at = now_iso() })
        notify_accountant("Customer replied — " .. r.tax_year,
            "A customer answered your question on their " .. r.tax_year .. " return.")
        return { status = 200, json = { success = true, data = customer_json(own_request(self, u.id)) } }
    end))

    app:get("/api/v2/tax/filing/requests/:uuid/export", auth(function(self)
        local u = current_user(self); if not u then return fail(401, "UNAUTHORIZED", "User not found") end
        local r = own_request(self, u.id); if not r then return fail(404, "NOT_FOUND", "Request not found") end
        local snap = decode(r.snapshot)
        if not snap then return fail(500, "BAD_SNAPSHOT", "This request has no figures.") end
        return xlsx_response(TaxReport.xlsx(snap, { approved_at = tostring(r.declared_at) }),
            TaxReport.filename(snap))
    end))

    -- ── Accountant queue ──────────────────────────────────────────────────────

    app:get("/api/v2/tax/filing/queue", perm("read", function(self)
        local page = Global.pageParam(self.params.page)
        local per = Global.perPageParam(self.params.perPage, 50, 200)
        local status = tostring(self.params.status or "")
        local where, args = "r.namespace_id = ?", { self.namespace.id }
        if status == "open" then
            where = where .. " AND r.status IN ('submitted','reviewing','needs_info','filing')"
        elseif status ~= "" and status ~= "all" then
            where = where .. " AND r.status = ?"
            args[#args + 1] = status
        end
        args[#args + 1] = per
        args[#args + 1] = (page - 1) * per
        local rows = db.query([[SELECT r.uuid, r.tax_year, r.status, r.our_total_due, r.hmrc_reference,
                r.filed_at, r.created_at, r.updated_at,
                (r.snapshot->'totals'->>'unreviewed') AS unreviewed,
                u.first_name, u.last_name, u.email
            FROM tax_filing_requests r JOIN users u ON u.id = r.user_id
            WHERE ]] .. where .. [[
            ORDER BY CASE r.status WHEN 'submitted' THEN 0 WHEN 'reviewing' THEN 1 WHEN 'filing' THEN 2
                     WHEN 'needs_info' THEN 3 ELSE 4 END, r.created_at ASC
            LIMIT ? OFFSET ?]], (table.unpack or unpack)(args))
        local counts = {}
        for _, c in ipairs(db.query([[SELECT status, count(*) AS n FROM tax_filing_requests
            WHERE namespace_id = ? GROUP BY status]], self.namespace.id)) do
            counts[c.status] = tonumber(c.n)
        end
        local list = {}
        for _, r in ipairs(rows) do
            list[#list + 1] = {
                uuid = r.uuid, tax_year = r.tax_year, status = r.status, our_total_due = tonumber(r.our_total_due),
                unreviewed = tonumber(r.unreviewed) or 0, hmrc_reference = r.hmrc_reference, filed_at = r.filed_at,
                created_at = r.created_at, updated_at = r.updated_at,
                customer = { name = display_name(r), email = r.email },
            }
        end
        return { status = 200, json = { success = true, data = list, meta = { page = page, perPage = per,
            counts = counts } } }
    end))

    app:get("/api/v2/tax/filing/queue/:uuid", perm("read", function(self)
        local r = queue_request(self); if not r then return fail(404, "NOT_FOUND", "Request not found") end
        local cust = db.query("SELECT first_name, last_name, email FROM users WHERE id = ? LIMIT 1", r.user_id)[1] or {}
        local snap = decode(r.snapshot) or {}
        return { status = 200, json = { success = true, data = {
            uuid = r.uuid, tax_year = r.tax_year, status = r.status, next = next_statuses(r.status),
            customer = { name = display_name(cust), email = cust.email, nino_last4 = nino_info(r.user_id).last4 },
            our_total_due = tonumber(r.our_total_due), hmrc_total_due = tonumber(r.hmrc_total_due),
            hmrc_reference = r.hmrc_reference, variance_note = r.variance_note, client_message = r.client_message,
            declaration_text = r.declaration_text, declared_at = r.declared_at, filed_at = r.filed_at,
            created_at = r.created_at, updated_at = r.updated_at, timeline = decode(r.updates) or {},
            summary = snap.summary, boxes = snap.boxes, totals = snap.totals, income_types = snap.income_types,
        } } }
    end))

    app:get("/api/v2/tax/filing/queue/:uuid/export", perm("read", function(self)
        local r = queue_request(self); if not r then return fail(404, "NOT_FOUND", "Request not found") end
        local snap = decode(r.snapshot)
        if not snap then return fail(500, "BAD_SNAPSHOT", "This request has no figures.") end
        append_update(r.id, { type = "export", by = "accountant", at = now_iso() })
        return xlsx_response(TaxReport.xlsx(snap, { approved_at = tostring(r.declared_at), for_accountant = true }),
            TaxReport.filename(snap, snap.taxpayer and snap.taxpayer.name))
    end))

    app:post("/api/v2/tax/filing/queue/:uuid/status", perm("update", function(self)
        local actor = current_user(self); if not actor then return fail(401, "UNAUTHORIZED", "User not found") end
        local r = queue_request(self); if not r then return fail(404, "NOT_FOUND", "Request not found") end
        local body = read_body(self)
        local to = tostring(body.status or "")
        if not (NEXT[r.status] and NEXT[r.status][to]) then
            return fail(409, "BAD_TRANSITION", ("Can't move a %s request to %s."):format(r.status, to))
        end

        local message = trim(body.message)
        if #message > 2000 then return fail(400, "BAD_MESSAGE", "Keep the message under 2000 characters.") end
        if (to == "needs_info" or to == "rejected") and message == "" then
            return fail(400, "MESSAGE_REQUIRED", "Tell the customer what you need (or why it's returned).")
        end

        local sets, args, entry = { "status = ?", "handled_by = ?", "updated_at = NOW()" }, { to, actor.id },
            { type = "status", status = to, by = "accountant", at = now_iso() }
        if to == "needs_info" or to == "rejected" then
            sets[#sets + 1] = "client_message = ?"; args[#args + 1] = message
            entry.text = message
        end
        if to == "filed" then
            local ref = trim(body.hmrc_reference)
            if ref == "" or #ref > 100 or not ref:match("^[%w%-_/%. ]+$") then
                return fail(400, "REFERENCE_REQUIRED", "Enter HMRC's submission reference (letters, numbers, - _ / .).")
            end
            local hmrc_total = nil
            if body.hmrc_total_due ~= nil and trim(body.hmrc_total_due) ~= "" then
                hmrc_total = tonumber(body.hmrc_total_due)
                if not hmrc_total or hmrc_total ~= hmrc_total or math.abs(hmrc_total) > 1e9 then
                    return fail(400, "BAD_TOTAL", "HMRC's total must be a number.")
                end
            end
            local note = trim(body.variance_note)
            local ours = tonumber(r.our_total_due) or 0
            if hmrc_total and math.abs(hmrc_total - ours) > VARIANCE_TOLERANCE and note == "" then
                return fail(400, "VARIANCE_NOTE_REQUIRED", ("HMRC's total differs from ours (£%.2f) by more than "
                    .. "£%.2f — add a note explaining why."):format(ours, VARIANCE_TOLERANCE))
            end
            sets[#sets + 1] = "hmrc_reference = ?"; args[#args + 1] = ref
            sets[#sets + 1] = "hmrc_total_due = ?"; args[#args + 1] = hmrc_total or db.NULL
            sets[#sets + 1] = "variance_note = ?"; args[#args + 1] = note ~= "" and note or db.NULL
            sets[#sets + 1] = "filed_at = NOW()"
            sets[#sets + 1] = "client_message = NULL"
            entry.text = "HMRC reference: " .. ref
        end
        if to == "reviewing" or to == "filing" then sets[#sets + 1] = "client_message = NULL" end

        args[#args + 1] = r.id
        args[#args + 1] = r.status -- optimistic: only if nobody moved it meanwhile
        local res = db.query("UPDATE tax_filing_requests SET " .. table.concat(sets, ", ")
            .. " WHERE id = ? AND status = ? RETURNING *", (table.unpack or unpack)(args))
        if not res[1] then return fail(409, "CHANGED", "This request just changed — please reload.") end
        append_update(r.id, entry)

        local cust = db.query("SELECT email FROM users WHERE id = ? LIMIT 1", r.user_id)[1]
        if cust and CUSTOMER_EMAIL[to] then
            notify(cust.email, "Update on your " .. r.tax_year .. " tax return", CUSTOMER_EMAIL[to]:format(r.tax_year))
        end
        return { status = 200, json = { success = true, data = { uuid = r.uuid, status = to } } }
    end))
end
