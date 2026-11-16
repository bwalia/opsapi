--[[
    VAT records API (VAT plan phase 1, docs/plans/VAT_MTD.md). Feature: vat.

    GET    /api/v2/vat/codes                    VAT codes and schemes (for pickers)
    GET    /api/v2/vat/registration             this business's VAT registration (or null)
    PUT    /api/v2/vat/registration             create/update it { vrn, scheme, stagger, effective_date,
                                                  business_name, flat_rate_pct, flat_rate_first_year,
                                                  limited_cost_trader, partially_exempt, recovery_pct }
    DELETE /api/v2/vat/registration             deregister (records are kept)
    GET    /api/v2/vat/rules                    own rules + the global starting rules
    POST   /api/v2/vat/rules                    { match_type, match_value, vat_code, reclaimable_pct?, reason? }
    PUT    /api/v2/vat/rules/:uuid              change an own rule
    DELETE /api/v2/vat/rules/:uuid              delete an own rule
    PUT    /api/v2/vat/transactions/:uuid       set the VAT on a bank line { vat_code, vat_amount?,
                                                  reclaimable_pct?, reason?, evidence? }
    POST   /api/v2/vat/transactions/apply-rules code un-coded lines by the rules { tax_year?, statement_id?,
                                                  refresh? }

    VAT returns (phase 2):
    POST   /api/v2/vat/returns/preview          build the 9 boxes for a period (not saved)
                                                 { period_start, period_end, relevant_goods_gross? }
    POST   /api/v2/vat/returns                  save/refresh the draft for a period
    GET    /api/v2/vat/returns                  this business's returns
    GET    /api/v2/vat/returns/:uuid            one return; ?lines=1 adds the lines behind each box
    GET    /api/v2/vat/adjustments              ?period_start&period_end
    POST   /api/v2/vat/adjustments              { period_start, period_end, type = fuel_scale | bad_debt_relief
                                                  | correction, vat, net, box1, box4, due_date, written_off }
    DELETE /api/v2/vat/adjustments/:uuid

    AI VAT coding (phase 3):
    POST   /api/v2/vat/transactions/classify    code un-coded lines in the background (rules, memory, model)
                                                 { tax_year?, period_start?, period_end?, recode? }
    GET    /api/v2/vat/transactions/classify-status ?tax_year   counts by source, to check, running
    GET    /api/v2/vat/review                   lines a person should check, with the reasons
    POST   /api/v2/vat/transactions/:uuid/receipt read a VAT receipt { mime, data (base64) }
    GET    /api/v2/vat/admin/rule-candidates    platform admin: rules several businesses taught us
    POST   /api/v2/vat/admin/rule-candidates/:uuid/(promote|dismiss)
    POST   /api/v2/vat/admin/eval               platform admin: measure the live model on the labelled set
    GET    /api/v2/vat/admin/eval               the last runs

    HMRC VAT (MTD) (phase 4) — connect with /auth/hmrc/initiate?purpose=vat first:
    GET    /api/v2/vat/hmrc/obligations         ?from&to&status=O|F  open / filed VAT periods
    POST   /api/v2/vat/returns/:uuid/submit     BINDING { period_key, declaration_accepted: true }
    GET    /api/v2/vat/hmrc/returns/:period_key the return HMRC holds
    GET    /api/v2/vat/hmrc/(liabilities|payments|penalties)  ?from&to
    (sandbox only: ?test_scenario= / "test_scenario" passes HMRC's Gov-Test-Scenario)

    Accountants (phase 8; RBAC module vat_agent; connect with /auth/hmrc/initiate?purpose=vat_agent):
    GET/PUT /api/v2/vat/agent/profile           your Agent Reference Number { arn }
    GET    /api/v2/vat/agent/clients            your clients and where each request stands
    POST   /api/v2/vat/agent/clients            ask a client for authority at HMRC { vrn, vat_registration_date? }
    POST   /api/v2/vat/agent/clients/:uuid/refresh  check with HMRC (active once HMRC confirms)
    DELETE /api/v2/vat/agent/clients/:uuid      stop / cancel
    Then any VAT route with ?client=<uuid> acts on that client's VAT.

    VAT on our own invoices (phase 9):
    GET    /api/v2/vat/invoices/:uuid/check     what a valid VAT invoice must show and this one is
                                                 missing; VAT by rate; reverse-charge wording

    Less common schemes (phase 10):
    PUT    /api/v2/vat/attribution              partial exemption: how purchases are used
                                                 { refs = ["t12","b3","e4"], attribution = taxable|exempt|residual }
    GET    /api/v2/vat/partial-exemption/annual ?year_start&year_end  the annual adjustment (Notice 706)
    POST   /api/v2/vat/partial-exemption/annual { year_start, year_end, period_start, period_end } put it on a return
    GET    /api/v2/vat/capital-items            capital goods scheme items (Notice 706/2)
    POST   /api/v2/vat/capital-items            { description, kind, cost_ex_vat, input_vat, original_use_pct,
                                                  short_lease?, first_used_on? }
    DELETE /api/v2/vat/capital-items/:uuid
    POST   /api/v2/vat/capital-items/:uuid/adjust  { interval_no, use_pct, period_start, period_end }
    POST   /api/v2/vat/capital-items/:uuid/dispose { disposed_on, intervals_used, sale_taxable, sale_output_vat?,
                                                     period_start, period_end }
    GET    /api/v2/vat/group                    VAT group members (representative) / the group this workspace is in
    POST   /api/v2/vat/group/members            { member_name } -> invite_code for the member workspace
    DELETE /api/v2/vat/group/members/:uuid
    POST   /api/v2/vat/group/join               { code } this workspace joins a VAT group
    GET    /api/v2/vat/ec-sales-list            ?period_start&period_end&format=json|csv  (Northern Ireland)
    PUT    /api/v2/vat/invoices/:uuid/vat-details { customer_vat_number?, tax_point? }
    Margin scheme: code second-hand stock MARGIN (global accounting, Notice 718).

    E-invoicing readiness (phase 11; UBL 2.1, Peppol BIS Billing 3.0 / EN 16931):
    GET    /api/v2/vat/invoices/:uuid/einvoice  our invoice as an e-invoice (XML download); ?check=1 -> JSON
    POST   /api/v2/vat/einvoice/check           { xml } check any UBL invoice against the business rules
    POST   /api/v2/vat/einvoice/import          { xml, record? } a supplier's e-invoice; record = add as purchases
                                                 (workspace VAT, waiting for approval)
    GET    /api/v2/vat/einvoice/documents       ?direction=in|out  e-invoices sent and received
    GET    /api/v2/vat/einvoice/documents/:uuid one, with its XML and check result

    VAT management (phase 6):
    GET    /api/v2/vat/threshold                rolling 12-month taxable turnover vs the registration threshold
    GET    /api/v2/vat/reports                  ?from&to  VAT by code and supplier; reclaimable vs blocked
    GET    /api/v2/vat/returns/:uuid/export     ?format=csv|json  every line behind every box (inspection)

    Whose business: `?scope=user` (default) is the signed-in person's own VAT
    registration (many sole traders share a namespace); `?scope=namespace` is the
    namespace's (accounting), and needs the "vat" module permission.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local VAT = require("lib.vat")
local VatQueries = require("queries.VatQueries")
local VatReturnQueries = require("queries.VatReturnQueries")
local VatAiQueries = require("queries.VatAiQueries")
local VatFilingQueries = require("queries.VatFilingQueries")
local VatManagementQueries = require("queries.VatManagementQueries")
local VatAgentQueries = require("queries.VatAgentQueries")
local VatSchemeQueries = require("queries.VatSchemeQueries")
local VatEinvoiceQueries = require("queries.VatEinvoiceQueries")

local function read_body(self)
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    local data = {}
    if raw and raw ~= "" then
        local ok, parsed = pcall(cjson.decode, raw)
        if ok and type(parsed) == "table" then data = parsed end
    end
    for k, v in pairs(self.params or {}) do
        if data[k] == nil then data[k] = v end
    end
    return data
end

local function user_pk(self)
    local u = self.current_user or {}
    local uuid = u.uuid or u.id or u.sub
    if not uuid then return nil end
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", uuid)
    return rows and rows[1] and rows[1].id or nil
end

local function err(status, message)
    return { status = status, json = { success = false, error = message } }
end

-- Resolve whose VAT this request is about. Returns (user_id_or_nil, actor_id) or
-- (nil, nil, error_response). user_id nil = the namespace's own registration.
local function business_of(self, action)
    local actor = user_pk(self)
    if not actor then return nil, nil, err(401, "User not found") end
    if (self.params.scope or "user") == "namespace" then
        if not NamespaceMiddleware.hasPermission(self, "vat", action) then
            return nil, nil, err(403, "You don't have permission to manage this workspace's VAT")
        end
        return nil, actor
    end
    return actor, actor
end

-- Whose VAT is this request about? Returns (registration, owner_user_id, actor_id)
-- or (nil, nil, nil, error_response).
--   default             the signed-in person's own registration
--   ?scope=namespace    the workspace's own (needs the "vat" permission)
--   ?client=<link uuid> a client's, for an accountant (needs "vat_agent", a link of
--                       theirs in this workspace that HMRC has confirmed: 'active')
local function resolve(self, action)
    local actor = user_pk(self)
    if not actor then return nil, nil, nil, err(401, "User not found") end
    local client = self.params.client
    if client and client ~= "" then
        if not NamespaceMiddleware.hasPermission(self, "vat_agent", action) then
            return nil, nil, nil, err(403, "You don't have permission to act for clients' VAT")
        end
        local reg = require("queries.VatAgentQueries").active_registration(self.namespace.id, actor, client)
        if not reg then
            return nil, nil, nil, err(403, "HMRC hasn't confirmed you can act for this client yet")
        end
        local owner = reg.user_id
        if owner == nil or owner == ngx.null then owner = actor end
        return reg, owner, actor
    end
    local uid, _, e = business_of(self, action); if e then return nil, nil, nil, e end
    local reg = VatQueries.get_registration(self.namespace.id, uid)
    if not reg then return nil, nil, nil, err(409, "Add your VAT registration first") end
    return reg, uid or actor, actor
end

local function registration_json(r)
    if not r then return cjson.null end
    return {
        uuid = r.uuid, vrn = r.vrn, business_name = r.business_name, effective_date = r.effective_date,
        scheme = r.scheme, scheme_label = VAT.SCHEMES[r.scheme], stagger = r.stagger,
        flat_rate_pct = r.flat_rate_pct, flat_rate_first_year = r.flat_rate_first_year,
        limited_cost_trader = r.limited_cost_trader, partially_exempt = r.partially_exempt,
        recovery_pct = r.recovery_pct, status = r.status, scope = r.user_id and "user" or "namespace",
        sales_from = r.sales_from, business_address = r.business_address,
    }
end

return function(app)
    local function authed(fn)
        return AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(fn))
    end

    app:get("/api/v2/vat/codes", authed(function()
        local schemes = {}
        for k, v in pairs(VAT.SCHEMES) do schemes[#schemes + 1] = { key = k, label = v } end
        table.sort(schemes, function(a, b) return a.key < b.key end)
        return { status = 200, json = { success = true, data = { codes = VAT.CODES, schemes = schemes } } }
    end))

    app:get("/api/v2/vat/registration", authed(function(self)
        local uid, _, e = business_of(self, "read"); if e then return e end
        local r = VatQueries.get_registration(self.namespace.id, uid)
        return { status = 200, json = { success = true, data = registration_json(r) } }
    end))

    app:put("/api/v2/vat/registration", authed(function(self)
        local uid, actor, e = business_of(self, "update"); if e then return e end
        local r, msg, status = VatQueries.save_registration(self.namespace.id, uid, read_body(self), actor)
        if not r then return err(status or 400, msg) end
        return { status = 200, json = { success = true, data = registration_json(r) } }
    end))

    app:delete("/api/v2/vat/registration", authed(function(self)
        local uid, _, e = business_of(self, "update"); if e then return e end
        local r = VatQueries.get_registration(self.namespace.id, uid)
        if not r then return err(404, "No VAT registration") end
        VatQueries.deregister(r)
        return { status = 200, json = { success = true, data = { status = "deregistered" } } }
    end))

    -- Rules need a registration: they belong to a business.
    local function with_registration(self, action)
        local reg, _, actor, e = resolve(self, action); if e then return nil, nil, e end
        return reg, actor
    end

    -- Bank lines belong to the registration's owner (the client, for an accountant).
    local function own_registration(self, action)
        local reg, owner, _, e = resolve(self, action or "read"); if e then return nil, nil, e end
        return reg, owner
    end

    app:get("/api/v2/vat/rules", authed(function(self)
        local uid, _, e = business_of(self, "read"); if e then return e end
        local r = VatQueries.get_registration(self.namespace.id, uid)
        return { status = 200, json = { success = true, data = VatQueries.list_rules(r and r.id) } }
    end))

    app:post("/api/v2/vat/rules", authed(function(self)
        local reg, actor, e = with_registration(self, "create"); if e then return e end
        local row, msg, status = VatQueries.create_rule(reg, read_body(self), actor)
        if not row then return err(status or 400, msg) end
        return { status = 201, json = { success = true, data = row } }
    end))

    app:put("/api/v2/vat/rules/:uuid", authed(function(self)
        local reg, _, e = with_registration(self, "update"); if e then return e end
        local row, msg, status = VatQueries.update_rule(reg, self.params.uuid, read_body(self))
        if not row then return err(status or 400, msg) end
        return { status = 200, json = { success = true, data = row } }
    end))

    app:delete("/api/v2/vat/rules/:uuid", authed(function(self)
        local reg, _, e = with_registration(self, "delete"); if e then return e end
        local ok, msg, status = VatQueries.delete_rule(reg, self.params.uuid)
        if not ok then return err(status or 400, msg) end
        return { status = 200, json = { success = true } }
    end))

    -- Bank lines are always the person's own (tax_transactions is per user).
    app:post("/api/v2/vat/transactions/apply-rules", authed(function(self)
        local reg, owner, _, e = resolve(self, "update"); if e then return e end
        local body = read_body(self)
        local res = VatQueries.apply_rules(reg, owner, {
            tax_year = body.tax_year, statement_id = body.statement_id,
            refresh = body.refresh == true or body.refresh == "true",
        })
        return { status = 200, json = { success = true, data = res } }
    end))

    app:put("/api/v2/vat/transactions/:uuid", authed(function(self)
        local reg, owner, actor, e = resolve(self, "update"); if e then return e end
        local row, msg, status = VatQueries.set_transaction_vat(reg, owner, self.params.uuid, read_body(self), actor)
        if not row then return err(status or 400, msg) end
        -- Two agreeing decisions for a supplier teach the business a rule.
        local ok_l, learned = pcall(VatAiQueries.learn, reg, self.params.uuid, actor)
        row.learned_rule = ok_l and learned or nil
        return { status = 200, json = { success = true, data = row } }
    end))
    -- ---------------------------------------------------------------- returns
    app:post("/api/v2/vat/returns/preview", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local b = read_body(self)
        local res, msg = VatReturnQueries.preview(reg, b.period_start, b.period_end,
            { relevant_goods_gross = b.relevant_goods_gross })
        if not res then return err(400, msg) end
        return { status = 200, json = { success = true, data = res } }
    end))

    app:post("/api/v2/vat/returns", authed(function(self)
        local reg, actor, e = with_registration(self, "update"); if e then return e end
        local b = read_body(self)
        local row, msg, status = VatReturnQueries.save_draft(reg, b.period_start, b.period_end, actor,
            { relevant_goods_gross = b.relevant_goods_gross })
        if not row then return err(status or 400, msg) end
        return { status = 200, json = { success = true, data = row } }
    end))

    app:get("/api/v2/vat/returns", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        return { status = 200, json = { success = true, data = VatReturnQueries.list(reg) } }
    end))

    app:get("/api/v2/vat/returns/:uuid", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local want = self.params.lines == "1" or self.params.lines == "true"
        local row, msg, status = VatReturnQueries.get(reg, self.params.uuid, { lines = want })
        if not row then return err(status or 404, msg) end
        return { status = 200, json = { success = true, data = row } }
    end))

    app:get("/api/v2/vat/adjustments", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local ok, perr = VatReturnQueries.check_period(self.params.period_start, self.params.period_end)
        if not ok then return err(400, perr) end
        return { status = 200, json = { success = true,
            data = VatReturnQueries.list_adjustments(reg, self.params.period_start, self.params.period_end) } }
    end))

    app:post("/api/v2/vat/adjustments", authed(function(self)
        local reg, actor, e = with_registration(self, "create"); if e then return e end
        local row, msg, status = VatReturnQueries.create_adjustment(reg, read_body(self), actor)
        if not row then return err(status or 400, msg) end
        return { status = 201, json = { success = true, data = row } }
    end))

    app:delete("/api/v2/vat/adjustments/:uuid", authed(function(self)
        local reg, _, e = with_registration(self, "delete"); if e then return e end
        local ok, msg, status = VatReturnQueries.delete_adjustment(reg, self.params.uuid)
        if not ok then return err(status or 400, msg) end
        return { status = 200, json = { success = true } }
    end))
    -- ---------------------------------------------------------------- AI coding

    app:post("/api/v2/vat/transactions/classify", authed(function(self)
        local reg, owner, _, e = resolve(self, "update"); if e then return e end
        local b = read_body(self)
        local res, msg = VatAiQueries.start(reg, owner, { tax_year = b.tax_year, period_start = b.period_start,
            period_end = b.period_end, recode = b.recode == true or b.recode == "true" })
        if not res then return err(500, msg) end
        return { status = 202, json = { success = true, data = res } }
    end))

    app:get("/api/v2/vat/transactions/classify-status", authed(function(self)
        local reg, owner, e = own_registration(self); if e then return e end
        return { status = 200, json = { success = true,
            data = VatAiQueries.status(reg, owner, { tax_year = self.params.tax_year }) } }
    end))

    app:get("/api/v2/vat/review", authed(function(self)
        local reg, owner, e = own_registration(self); if e then return e end
        return { status = 200, json = { success = true, data = VatAiQueries.review_queue(reg, owner) } }
    end))

    app:post("/api/v2/vat/transactions/:uuid/receipt", authed(function(self)
        local reg, owner, actor, e = resolve(self, "update"); if e then return e end
        local row, msg, status = VatAiQueries.read_receipt(reg, owner, self.params.uuid, read_body(self), actor)
        if not row then return err(status or 400, msg) end
        return { status = 200, json = { success = true, data = row } }
    end))

    local function platform_admin(self)
        if not self.is_platform_admin then return err(403, "Platform admins only") end
    end

    app:get("/api/v2/vat/admin/rule-candidates", authed(function(self)
        local e = platform_admin(self); if e then return e end
        return { status = 200, json = { success = true, data = VatAiQueries.candidates(self.params.status) } }
    end))

    app:post("/api/v2/vat/admin/rule-candidates/:uuid/:decision", authed(function(self)
        local e = platform_admin(self); if e then return e end
        local d = self.params.decision
        if d ~= "promote" and d ~= "dismiss" then return err(400, "promote or dismiss") end
        local row, msg, status = VatAiQueries.decide_candidate(self.params.uuid, d == "promote", user_pk(self))
        if not row then return err(status or 400, msg) end
        return { status = 200, json = { success = true, data = row } }
    end))

    app:post("/api/v2/vat/admin/eval", authed(function(self)
        local e = platform_admin(self); if e then return e end
        local res, msg = VatAiQueries.start_eval(user_pk(self))
        if not res then return err(500, msg) end
        return { status = 202, json = { success = true, data = res } }
    end))

    app:get("/api/v2/vat/admin/eval", authed(function(self)
        local e = platform_admin(self); if e then return e end
        return { status = 200, json = { success = true, data = VatAiQueries.eval_runs() } }
    end))
    -- ---------------------------------------------------------------- HMRC VAT (MTD)
    local function user_uuid_of(self)
        local u = self.current_user or {}
        return u.uuid or u.id or u.sub
    end

    app:get("/api/v2/vat/hmrc/obligations", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local list, resp = VatFilingQueries.obligations(reg, user_uuid_of(self), self.params)
        if not list then return resp end
        return { status = 200, json = { success = true, data = list } }
    end))

    app:post("/api/v2/vat/returns/:uuid/submit", authed(function(self)
        local reg, actor, e = with_registration(self, "update"); if e then return e end
        local row, resp = VatFilingQueries.submit(reg, self.params.uuid, actor, user_uuid_of(self), read_body(self))
        if not row then return resp end
        return { status = 200, json = { success = true, data = row } }
    end))

    app:get("/api/v2/vat/hmrc/returns/:period_key", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local data, resp = VatFilingQueries.view(reg, user_uuid_of(self), self.params.period_key, self.params)
        if not data then return resp end
        return { status = 200, json = { success = true, data = data } }
    end))

    app:get("/api/v2/vat/hmrc/:what", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local data, resp = VatFilingQueries.account(reg, user_uuid_of(self), self.params.what, self.params)
        if not data then return resp end
        return { status = 200, json = { success = true, data = data } }
    end))
    -- ---------------------------------------------------------------- management
    app:get("/api/v2/vat/threshold", authed(function(self)
        local actor = user_pk(self); if not actor then return err(401, "User not found") end
        local data = VatManagementQueries.threshold(self.namespace.id, actor)
        return { status = 200, json = { success = true, data = data } }
    end))

    app:get("/api/v2/vat/reports", authed(function(self)
        local reg, owner, e = own_registration(self); if e then return e end
        local from, to = self.params.from, self.params.to
        if not (from and to and from:match("^%d%d%d%d%-%d%d%-%d%d$") and to:match("^%d%d%d%d%-%d%d%-%d%d$")) then
            return err(400, "Give from and to like 2026-01-01")
        end
        return { status = 200, json = { success = true, data = VatManagementQueries.report(reg, owner, from, to) } }
    end))

    app:get("/api/v2/vat/returns/:uuid/export", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local fmt = self.params.format == "json" and "json" or "csv"
        local out, msg, status, filename = VatManagementQueries.export(reg, self.params.uuid, fmt)
        if not out then return err(status or 404, msg) end
        if fmt == "json" then return { status = 200, json = { success = true, data = out } } end
        ngx.header["Content-Disposition"] = 'attachment; filename="' .. filename .. '"'
        return { status = 200, content_type = "text/csv; charset=utf-8", layout = false, out }
    end))
    -- ---------------------------------------------------------------- accountants
    local function agent(self, action)
        local actor = user_pk(self); if not actor then return nil, err(401, "User not found") end
        if not NamespaceMiddleware.hasPermission(self, "vat_agent", action) then
            return nil, err(403, "You don't have permission to act for clients' VAT")
        end
        return actor
    end
    local function uuid_of(self) local u = self.current_user or {}; return u.uuid or u.id or u.sub end

    app:get("/api/v2/vat/agent/profile", authed(function(self)
        local actor, e = agent(self, "read"); if e then return e end
        return { status = 200, json = { success = true,
            data = VatAgentQueries.profile(self.namespace.id, actor) or cjson.null } }
    end))

    app:put("/api/v2/vat/agent/profile", authed(function(self)
        local actor, e = agent(self, "update"); if e then return e end
        local row, msg, status = VatAgentQueries.save_profile(self.namespace.id, actor, read_body(self).arn)
        if not row then return err(status or 400, msg) end
        return { status = 200, json = { success = true, data = row } }
    end))

    app:get("/api/v2/vat/agent/clients", authed(function(self)
        local actor, e = agent(self, "read"); if e then return e end
        return { status = 200, json = { success = true, data = VatAgentQueries.list(self.namespace.id, actor) } }
    end))

    app:post("/api/v2/vat/agent/clients", authed(function(self)
        local actor, e = agent(self, "create"); if e then return e end
        local row, resp = VatAgentQueries.invite(self.namespace.id, actor, uuid_of(self), read_body(self))
        if not row then return resp end
        return { status = 201, json = { success = true, data = row } }
    end))

    app:post("/api/v2/vat/agent/clients/:uuid/refresh", authed(function(self)
        local actor, e = agent(self, "read"); if e then return e end
        local row, resp = VatAgentQueries.refresh(self.namespace.id, actor, uuid_of(self), self.params.uuid)
        if not row then return resp end
        return { status = 200, json = { success = true, data = row } }
    end))

    app:delete("/api/v2/vat/agent/clients/:uuid", authed(function(self)
        local actor, e = agent(self, "delete"); if e then return e end
        local ok, resp = VatAgentQueries.cancel(self.namespace.id, actor, uuid_of(self), self.params.uuid)
        if not ok then return resp end
        return { status = 200, json = { success = true } }
    end))
    -- ---------------------------------------------------------------- invoices
    app:get("/api/v2/vat/invoices/:uuid/check", authed(function(self)
        if not NamespaceMiddleware.hasPermission(self, "invoices", "read") then
            return err(403, "You don't have permission to see invoices")
        end
        local inv = db.query([[SELECT * FROM invoices WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL
            LIMIT 1]], self.params.uuid, self.namespace.id)[1]
        if not inv then return err(404, "Invoice not found") end
        local lines = db.query("SELECT * FROM invoice_line_items WHERE invoice_id = ? ORDER BY sort_order, id",
            inv.id) or {}
        local reg = VatQueries.get_registration(self.namespace.id, nil)
        local addr = inv.customer_address
        if type(addr) == "table" then addr = next(addr) and cjson.encode(addr) or "" end
        local result = require("lib.vat-invoice").check({
            invoice_number = inv.invoice_number, issue_date = inv.issue_date, tax_point = inv.tax_point,
            customer_name = inv.customer_name, customer_address = addr, currency = inv.currency,
        }, lines, { name = reg and reg.business_name, address = reg and reg.business_address,
            vrn = reg and reg.vrn })
        if not reg then
            table.insert(result.missing, 1, "Add the workspace's VAT registration (Tax -> VAT, workspace) first")
            result.ok = false
        end
        result.supplier_vrn = reg and reg.vrn or nil
        return { status = 200, json = { success = true, data = result } }
    end))

    -- ---------------------------------------------------------------- schemes (phase 10)
    local function ok_json(data, status) return { status = status or 200, json = { success = true, data = data } } end
    local function result(row, msg, status, created)
        if not row then return err(status or 400, msg) end
        return ok_json(row, created and 201 or 200)
    end

    app:put("/api/v2/vat/attribution", authed(function(self)
        local reg, owner, _, e = resolve(self, "update"); if e then return e end
        return result(VatSchemeQueries.set_attribution(reg, owner, read_body(self)))
    end))

    app:get("/api/v2/vat/partial-exemption/annual", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        return result(VatSchemeQueries.annual(reg, self.params.year_start, self.params.year_end))
    end))

    app:post("/api/v2/vat/partial-exemption/annual", authed(function(self)
        local reg, actor, e = with_registration(self, "create"); if e then return e end
        local b = read_body(self)
        local a, msg, status = VatSchemeQueries.annual(reg, b.year_start, b.year_end)
        if not a then return err(status or 400, msg) end
        if a.adjustment == 0 then return err(409, "There's no adjustment to make for that year") end
        return result(VatReturnQueries.create_adjustment(reg, { period_start = b.period_start,
            period_end = b.period_end, type = "pe_annual", vat = a.adjustment,
            description = string.format("Partial exemption annual adjustment %s to %s (%d%%)", b.year_start,
                b.year_end, a.annual_pct) }, actor))
    end))

    app:get("/api/v2/vat/capital-items", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        return ok_json(VatSchemeQueries.list_items(reg))
    end))

    app:post("/api/v2/vat/capital-items", authed(function(self)
        local reg, actor, e = with_registration(self, "create"); if e then return e end
        local row, msg, status = VatSchemeQueries.create_item(reg, read_body(self), actor)
        return result(row, msg, status, true)
    end))

    app:delete("/api/v2/vat/capital-items/:uuid", authed(function(self)
        local reg, _, e = with_registration(self, "delete"); if e then return e end
        return result(VatSchemeQueries.delete_item(reg, self.params.uuid))
    end))

    app:post("/api/v2/vat/capital-items/:uuid/adjust", authed(function(self)
        local reg, actor, e = with_registration(self, "create"); if e then return e end
        local row, msg, status = VatSchemeQueries.adjust_item(reg, self.params.uuid, read_body(self), actor)
        return result(row, msg, status, true)
    end))

    app:post("/api/v2/vat/capital-items/:uuid/dispose", authed(function(self)
        local reg, actor, e = with_registration(self, "update"); if e then return e end
        return result(VatSchemeQueries.dispose_item(reg, self.params.uuid, read_body(self), actor))
    end))

    app:get("/api/v2/vat/group", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        return result(VatSchemeQueries.group(reg))
    end))

    app:post("/api/v2/vat/group/members", authed(function(self)
        local reg, actor, e = with_registration(self, "manage"); if e then return e end
        local row, msg, status = VatSchemeQueries.invite_member(reg, read_body(self), actor)
        return result(row, msg, status, true)
    end))

    app:delete("/api/v2/vat/group/members/:uuid", authed(function(self)
        local reg, _, e = with_registration(self, "manage"); if e then return e end
        return result(VatSchemeQueries.remove_member(reg, self.params.uuid))
    end))

    app:post("/api/v2/vat/group/join", authed(function(self)
        if not NamespaceMiddleware.hasPermission(self, "vat", "manage") then
            return err(403, "You don't have permission to manage this workspace's VAT")
        end
        local actor = user_pk(self)
        if not actor then return err(401, "User not found") end
        return result(VatSchemeQueries.join(self.namespace.id, read_body(self).code, actor))
    end))

    app:get("/api/v2/vat/ec-sales-list", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local res, msg, status = VatSchemeQueries.ec_sales_list(reg, self.params.period_start, self.params.period_end)
        if not res then return err(status or 400, msg) end
        if self.params.format == "csv" then
            ngx.header["Content-Disposition"] = string.format('attachment; filename="ec-sales-list-%s.csv"',
                tostring(self.params.period_end):gsub("[^%d%-]", ""))
            return { status = 200, content_type = "text/csv; charset=utf-8", layout = false,
                require("lib.vat-schemes").ec_sales_csv(res) }
        end
        return ok_json(res)
    end))

    app:put("/api/v2/vat/invoices/:uuid/vat-details", authed(function(self)
        if not NamespaceMiddleware.hasPermission(self, "invoices", "update") then
            return err(403, "You don't have permission to change invoices")
        end
        local inv = db.query([[SELECT id, status FROM invoices WHERE uuid = ? AND namespace_id = ?
            AND deleted_at IS NULL LIMIT 1]], self.params.uuid, self.namespace.id)[1]
        if not inv then return err(404, "Invoice not found") end
        local b, upd = read_body(self), {}
        if b.customer_vat_number ~= nil then
            local v = b.customer_vat_number
            if v == "" or v == cjson.null then
                upd.customer_vat_number = db.NULL
            else
                local cc, no = require("lib.vat-schemes").eu_vat_number(v)
                if cc then
                    upd.customer_vat_number = cc .. no
                else
                    local gb = VAT.valid_vrn(v)
                    if not gb then return err(400, "That isn't a valid EU or UK VAT number") end
                    upd.customer_vat_number = "GB" .. gb
                end
            end
        end
        if b.tax_point ~= nil then
            if b.tax_point == "" or b.tax_point == cjson.null then
                upd.tax_point = db.NULL
            elseif type(b.tax_point) == "string" and b.tax_point:match("^%d%d%d%d%-%d%d%-%d%d$") then
                upd.tax_point = b.tax_point
            else
                return err(400, "tax_point must be a date (YYYY-MM-DD)")
            end
        end
        if not next(upd) then return err(400, "Nothing to change") end
        upd.updated_at = db.raw("NOW()")
        db.update("invoices", upd, { id = inv.id })
        return ok_json(db.query("SELECT uuid, customer_vat_number, tax_point FROM invoices WHERE id = ?", inv.id)[1])
    end))


    -- ---------------------------------------------------------------- e-invoicing (phase 11)
    local MAX_XML = 512 * 1024

    app:get("/api/v2/vat/invoices/:uuid/einvoice", authed(function(self)
        if not NamespaceMiddleware.hasPermission(self, "invoices", "read") then
            return err(403, "You don't have permission to see invoices")
        end
        local reg = VatQueries.get_registration(self.namespace.id, nil)
        local res, msg, status = VatEinvoiceQueries.export(self.namespace.id, self.params.uuid, reg, user_pk(self))
        if not res then return err(status or 400, msg) end
        if self.params.check == "1" or self.params.check == "true" then
            return { status = 200, json = { success = true, data = { check = res.check, document = res.document,
                filename = res.filename } } }
        end
        ngx.header["Content-Disposition"] = 'attachment; filename="' .. res.filename .. '"'
        return { status = 200, content_type = "application/xml; charset=utf-8", layout = false, res.xml }
    end))

    app:post("/api/v2/vat/einvoice/check", authed(function(self)
        local xml = read_body(self).xml
        if type(xml) ~= "string" or xml == "" then return err(400, "Send the e-invoice XML (xml)") end
        if #xml > MAX_XML then return err(413, "That e-invoice is too large") end
        local res = require("lib.vat-einvoice").check(xml)
        return { status = 200, json = { success = true, data = res } }
    end))

    app:post("/api/v2/vat/einvoice/import", authed(function(self)
        local b = read_body(self)
        local record = b.record == true or b.record == "true"
        local reg, _, e = with_registration(self, record and "create" or "read"); if e then return e end
        if type(b.xml) == "string" and #b.xml > MAX_XML then return err(413, "That e-invoice is too large") end
        local u = self.current_user or {}
        local res, msg, status = VatEinvoiceQueries.import(reg, { id = user_pk(self), uuid = u.uuid or u.sub },
            b.xml, record)
        if not res then return err(status or 400, msg) end
        return { status = record and 201 or 200, json = { success = true, data = res } }
    end))

    app:get("/api/v2/vat/einvoice/documents", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        return { status = 200, json = { success = true,
            data = VatEinvoiceQueries.list(self.namespace.id, reg, self.params.direction) } }
    end))

    app:get("/api/v2/vat/einvoice/documents/:uuid", authed(function(self)
        local reg, _, e = with_registration(self, "read"); if e then return e end
        local row, msg, status = VatEinvoiceQueries.get(self.namespace.id, reg, self.params.uuid)
        if not row then return err(status or 404, msg) end
        return { status = 200, json = { success = true, data = row } }
    end))

end
