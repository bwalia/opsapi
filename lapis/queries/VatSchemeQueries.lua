--[[
    Less common VAT schemes (VAT plan phase 10): partial exemption attribution and
    the annual adjustment, the capital goods scheme, VAT groups and the Northern
    Ireland EC Sales List. Figures come from lib/vat-return and lib/vat-schemes.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local VAT = require("lib.vat")
local Schemes = require("lib.vat-schemes")
local VatReturnQueries = require("queries.VatReturnQueries")

local Q = {}

local function null(v) return v == nil or v == db.NULL or (ngx and v == ngx.null) end
local function valid_date(s) return type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil end

-- ---------------------------------------------------------------------------
-- Partial exemption
-- ---------------------------------------------------------------------------

Q.ATTRIBUTIONS = { taxable = true, exempt = true, residual = true }

--- Say how purchases are used: { refs = {"t12", "b3", "e4"}, attribution }.
-- t = the owner's tax_transactions; b/e = the workspace's bank lines / expenses.
function Q.set_attribution(reg, owner_user_id, body)
    body = body or {}
    local a = body.attribution
    if a == "" or a == cjson.null then a = nil end
    if a ~= nil and not Q.ATTRIBUTIONS[a] then return nil, "attribution must be taxable, exempt or residual", 400 end
    if type(body.refs) ~= "table" or #body.refs == 0 or #body.refs > 500 then
        return nil, "refs must list 1–500 lines", 400
    end
    local value = a and a or db.NULL
    local updated = 0
    for _, ref in ipairs(body.refs) do
        local kind, id = tostring(ref):match("^([tbe])(%d+)$")
        id = tonumber(id)
        local res
        if kind == "t" and not null(reg.user_id) then
            res = db.query([[UPDATE tax_transactions SET vat_attribution = ? WHERE id = ? AND namespace_id = ?
                AND user_id = ?]], value, id, reg.namespace_id, owner_user_id)
        elseif kind == "b" and null(reg.user_id) then
            res = db.query([[UPDATE accounting_bank_transactions SET vat_attribution = ? WHERE id = ?
                AND namespace_id = ?]], value, id, reg.namespace_id)
        elseif kind == "e" and null(reg.user_id) then
            res = db.query([[UPDATE accounting_expenses SET vat_attribution = ? WHERE id = ? AND namespace_id = ?]],
                value, id, reg.namespace_id)
        end
        updated = updated + ((res and tonumber(res.affected_rows)) or 0)
    end
    return { updated = updated, attribution = a or "residual" }
end

--- The annual adjustment for a partial exemption year (at most 12 months).
-- Recovered in year = what the year's returns recovered (their saved partial
-- exemption figures).
function Q.annual(reg, year_start, year_end)
    local months, err = VatReturnQueries.check_period(year_start, year_end)
    if not months then return nil, err, 400 end
    local lines, uncoded = VatReturnQueries.collect_lines(reg, year_start, year_end)
    local claimed, returns, missing = 0, 0, 0
    for _, r in ipairs(db.query([[SELECT box4, calculation FROM vat_returns WHERE registration_id = ?
        AND period_start >= ? AND period_end <= ? AND status IN ('draft', 'submitting', 'submitted')
        ORDER BY period_start, (status = 'submitted') DESC]], reg.id, year_start, year_end) or {}) do
        local c = r.calculation
        if type(c) == "string" then
            local ok, t = pcall(cjson.decode, c); c = ok and t or nil
        end
        local pe = type(c) == "table" and c.partial_exemption
        returns = returns + 1
        if type(pe) == "table" and tonumber(pe.input_vat_recovered) then
            claimed = claimed + tonumber(pe.input_vat_recovered)
        else
            missing = missing + 1
        end
    end
    local res = Schemes.annual_adjustment(lines, reg, claimed)
    res.year = { start = year_start, ["end"] = year_end }
    res.returns_counted = returns
    res.uncoded_count = uncoded
    res.warnings = {}
    if returns == 0 then
        res.warnings[#res.warnings + 1] = "No VAT returns saved for this year yet: the adjustment assumes nothing "
            .. "was recovered."
    end
    if missing > 0 then
        res.warnings[#res.warnings + 1] = missing .. " return(s) weren't worked out under partial exemption; "
            .. "check what they recovered."
    end
    if uncoded > 0 then
        res.warnings[#res.warnings + 1] = uncoded .. " line(s) in the year have no VAT code yet."
    end
    return res
end

-- ---------------------------------------------------------------------------
-- Capital goods scheme
-- ---------------------------------------------------------------------------

function Q.list_items(reg)
    local items = db.query("SELECT * FROM vat_capital_items WHERE registration_id = ? ORDER BY id", reg.id) or {}
    for _, it in ipairs(items) do
        it.adjustments = db.query([[SELECT uuid, period_start, period_end, interval_no, vat, description
            FROM vat_adjustments WHERE capital_item_id = ? ORDER BY interval_no, id]], it.id) or {}
        it.kind_label = (Schemes.CGS_KINDS[it.kind] or {}).label
    end
    return items
end

function Q.create_item(reg, f, actor_id)
    f = f or {}
    local desc = tostring(f.description or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if desc == "" then return nil, "description is required", 400 end
    local clean, err = Schemes.validate_item(f)
    if not clean then return nil, err, 400 end
    clean.registration_id = reg.id
    clean.description = desc:sub(1, 1000)
    clean.first_used_on = valid_date(f.first_used_on) and f.first_used_on or db.NULL
    clean.created_by = actor_id
    local row = db.insert("vat_capital_items", clean, "uuid")
    local uuid = row[1] and row[1].uuid or row.uuid
    return db.query("SELECT * FROM vat_capital_items WHERE uuid = ?", uuid)[1]
end

local function own_item(reg, uuid)
    local it = db.query("SELECT * FROM vat_capital_items WHERE uuid = ? AND registration_id = ? LIMIT 1",
        uuid, reg.id)[1]
    if not it then return nil, "Capital item not found", 404 end
    return it
end

function Q.delete_item(reg, uuid)
    local it, err, status = own_item(reg, uuid)
    if not it then return nil, err, status end
    local used = db.query("SELECT 1 FROM vat_adjustments WHERE capital_item_id = ? LIMIT 1", it.id)
    if used and #used > 0 then return nil, "This item has adjustments on returns; remove them first.", 409 end
    db.query("DELETE FROM vat_capital_items WHERE id = ?", it.id)
    return true
end

--- Record the adjustment for a later interval: { interval_no (2..n), use_pct, period_start, period_end }.
function Q.adjust_item(reg, uuid, f, actor_id)
    f = f or {}
    local it, err, status = own_item(reg, uuid)
    if not it then return nil, err, status end
    if not null(it.disposed_on) then return nil, "This item has been sold.", 409 end
    local n = tonumber(f.interval_no)
    if not n or n ~= math.floor(n) or n < 2 or n > tonumber(it.intervals) then
        return nil, "interval_no must be 2–" .. tostring(it.intervals) .. " (the first interval is the original "
            .. "claim)", 400
    end
    local dup = db.query("SELECT 1 FROM vat_adjustments WHERE capital_item_id = ? AND interval_no = ?", it.id, n)
    if dup and #dup > 0 then return nil, "That interval is already adjusted.", 409 end
    local use = tonumber(f.use_pct)
    if not use or use < 0 or use > 100 then return nil, "use_pct must be 0–100", 400 end
    local vat = Schemes.cgs_interval_adjustment(it, use)
    return VatReturnQueries.create_adjustment(reg, { period_start = f.period_start, period_end = f.period_end,
        type = "cgs", vat = vat, capital_item_id = it.id, interval_no = n,
        description = string.format("Capital goods scheme: %s, interval %d, taxable use %s%% (was %s%%)",
            it.description, n, tostring(use), tostring(it.original_use_pct)) }, actor_id)
end

--- The item is sold: { disposed_on, intervals_used, sale_taxable, sale_output_vat?, period_start, period_end }.
function Q.dispose_item(reg, uuid, f, actor_id)
    f = f or {}
    local it, err, status = own_item(reg, uuid)
    if not it then return nil, err, status end
    if not null(it.disposed_on) then return nil, "This item is already recorded as sold.", 409 end
    if not valid_date(f.disposed_on) then return nil, "disposed_on is required", 400 end
    local used = tonumber(f.intervals_used)
    if not used or used < 1 or used > tonumber(it.intervals) then
        return nil, "intervals_used must be 1–" .. tostring(it.intervals), 400
    end
    local taxable = f.sale_taxable == true or f.sale_taxable == "true"
    local d = Schemes.cgs_disposal(it, used, taxable, tonumber(f.sale_output_vat))
    local adj
    if d.adjustment ~= 0 then
        local row, aerr, astatus = VatReturnQueries.create_adjustment(reg, { period_start = f.period_start,
            period_end = f.period_end, type = "cgs", vat = d.adjustment, capital_item_id = it.id,
            description = string.format("Capital goods scheme: %s sold (%s), %d interval(s) left",
                it.description, taxable and "taxable" or "exempt", d.remaining_intervals) }, actor_id)
        if not row then return nil, aerr, astatus end
        adj = row
    end
    db.update("vat_capital_items", { disposed_on = f.disposed_on, updated_at = db.raw("NOW()") }, { id = it.id })
    d.adjustment_row = adj
    return d
end

-- ---------------------------------------------------------------------------
-- VAT groups (the representative member's registration holds the group)
-- ---------------------------------------------------------------------------

local function group_reg_only(reg)
    if not null(reg.user_id) then
        return nil, "A VAT group is for the workspace's VAT (use ?scope=namespace)", 400
    end
    return true
end

function Q.group(reg)
    local ok, err, status = group_reg_only(reg)
    if not ok then return nil, err, status end
    return {
        members = db.query([[SELECT uuid, member_name, status, member_namespace_id IS NOT NULL AS joined, joined_at,
                CASE WHEN status = 'pending' THEN invite_code END AS invite_code, created_at
            FROM vat_group_members WHERE group_registration_id = ? AND status <> 'removed' ORDER BY id]], reg.id)
            or {},
        member_of = VatReturnQueries.group_of(reg),
    }
end

function Q.invite_member(reg, f, actor_id)
    local ok, err, status = group_reg_only(reg)
    if not ok then return nil, err, status end
    if VatReturnQueries.group_of(reg) then return nil, "This workspace is a member of another VAT group.", 409 end
    local name = tostring((f or {}).member_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or #name > 255 then return nil, "member_name is required", 400 end
    local code = db.query("SELECT replace(gen_random_uuid()::text, '-', '') AS c")[1].c
    db.insert("vat_group_members", { group_registration_id = reg.id, member_name = name, invite_code = code,
        created_by = actor_id })
    return db.query("SELECT uuid, member_name, status, invite_code FROM vat_group_members WHERE invite_code = ?",
        code)[1]
end

function Q.remove_member(reg, uuid)
    local m = db.query([[SELECT id FROM vat_group_members WHERE uuid = ? AND group_registration_id = ?
        AND status <> 'removed']], uuid, reg.id)[1]
    if not m then return nil, "Member not found", 404 end
    db.update("vat_group_members", { status = "removed", updated_at = db.raw("NOW()") }, { id = m.id })
    return true
end

--- A workspace joins a group with the code its representative gave it.
function Q.join(namespace_id, code, actor_id)
    code = tostring(code or "")
    if not code:match("^%x+$") or #code ~= 32 then return nil, "That code isn't valid", 400 end
    local m = db.query([[SELECT m.*, r.namespace_id AS rep_namespace_id FROM vat_group_members m
        JOIN vat_registrations r ON r.id = m.group_registration_id
        WHERE m.invite_code = ? AND m.status = 'pending' LIMIT 1]], code)[1]
    if not m then return nil, "That code isn't valid or has been used", 404 end
    if m.rep_namespace_id == namespace_id then return nil, "This workspace is the group's representative", 409 end
    local already = db.query([[SELECT 1 FROM vat_group_members WHERE member_namespace_id = ? AND status = 'active']],
        namespace_id)
    if already and #already > 0 then return nil, "This workspace is already in a VAT group", 409 end
    db.update("vat_group_members", { member_namespace_id = namespace_id, status = "active", joined_by = actor_id,
        joined_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = m.id })
    return { member_name = m.member_name, status = "active" }
end

-- ---------------------------------------------------------------------------
-- EC Sales List (Northern Ireland goods to EU customers, from issued invoices)
-- ---------------------------------------------------------------------------

function Q.ec_sales_list(reg, period_start, period_end)
    local months, err = VatReturnQueries.check_period(period_start, period_end)
    if not months then return nil, err, 400 end
    local lines = VatReturnQueries.collect_lines(reg, period_start, period_end)
    local esl_lines = {}
    for _, l in ipairs(lines) do
        if l.direction == "sale" and l.vat_code == "NI_EU_GOODS" then
            esl_lines[#esl_lines + 1] = { customer_vat_number = not null(l.customer_vat_number)
                and l.customer_vat_number or nil, customer_name = not null(l.customer_name) and l.customer_name
                or l.description, net = l.net, invoice = l.invoice_number }
        end
    end
    local res = Schemes.ec_sales_list(esl_lines)
    res.period = { start = period_start, ["end"] = period_end }
    res.notes = { "Only Northern Ireland businesses selling goods to VAT-registered EU customers send an "
        .. "EC Sales List. Bank lines aren't included: the customer's EU VAT number comes from the invoice." }
    if #res.missing > 0 then
        res.notes[#res.notes + 1] = #res.missing .. " sale(s) have no valid EU VAT number for the customer: add it "
            .. "to the invoice (customer VAT number)."
    end
    return res
end

Q.round2 = VAT.round2

return Q
