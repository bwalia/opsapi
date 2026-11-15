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

local function registration_json(r)
    if not r then return cjson.null end
    return {
        uuid = r.uuid, vrn = r.vrn, business_name = r.business_name, effective_date = r.effective_date,
        scheme = r.scheme, scheme_label = VAT.SCHEMES[r.scheme], stagger = r.stagger,
        flat_rate_pct = r.flat_rate_pct, flat_rate_first_year = r.flat_rate_first_year,
        limited_cost_trader = r.limited_cost_trader, partially_exempt = r.partially_exempt,
        recovery_pct = r.recovery_pct, status = r.status, scope = r.user_id and "user" or "namespace",
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
        local uid, actor, e = business_of(self, action); if e then return nil, nil, e end
        local r = VatQueries.get_registration(self.namespace.id, uid)
        if not r then return nil, nil, err(409, "Add your VAT registration first") end
        return r, actor
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
        local actor = user_pk(self); if not actor then return err(401, "User not found") end
        local reg = VatQueries.get_registration(self.namespace.id, actor)
        if not reg then return err(409, "Add your VAT registration first") end
        local body = read_body(self)
        local res = VatQueries.apply_rules(reg, actor, {
            tax_year = body.tax_year, statement_id = body.statement_id,
            refresh = body.refresh == true or body.refresh == "true",
        })
        return { status = 200, json = { success = true, data = res } }
    end))

    app:put("/api/v2/vat/transactions/:uuid", authed(function(self)
        local actor = user_pk(self); if not actor then return err(401, "User not found") end
        local reg = VatQueries.get_registration(self.namespace.id, actor)
        if not reg then return err(409, "Add your VAT registration first") end
        local row, msg, status = VatQueries.set_transaction_vat(reg, actor, self.params.uuid, read_body(self), actor)
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
    local function own_registration(self)
        local actor = user_pk(self); if not actor then return nil, nil, err(401, "User not found") end
        local reg = VatQueries.get_registration(self.namespace.id, actor)
        if not reg then return nil, nil, err(409, "Add your VAT registration first") end
        return reg, actor
    end

    app:post("/api/v2/vat/transactions/classify", authed(function(self)
        local reg, actor, e = own_registration(self); if e then return e end
        local b = read_body(self)
        local res, msg = VatAiQueries.start(reg, actor, { tax_year = b.tax_year, period_start = b.period_start,
            period_end = b.period_end, recode = b.recode == true or b.recode == "true" })
        if not res then return err(500, msg) end
        return { status = 202, json = { success = true, data = res } }
    end))

    app:get("/api/v2/vat/transactions/classify-status", authed(function(self)
        local reg, actor, e = own_registration(self); if e then return e end
        return { status = 200, json = { success = true,
            data = VatAiQueries.status(reg, actor, { tax_year = self.params.tax_year }) } }
    end))

    app:get("/api/v2/vat/review", authed(function(self)
        local reg, actor, e = own_registration(self); if e then return e end
        return { status = 200, json = { success = true, data = VatAiQueries.review_queue(reg, actor) } }
    end))

    app:post("/api/v2/vat/transactions/:uuid/receipt", authed(function(self)
        local reg, actor, e = own_registration(self); if e then return e end
        local row, msg, status = VatAiQueries.read_receipt(reg, actor, self.params.uuid, read_body(self), actor)
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
end
