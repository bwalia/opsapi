-- VAT management (VAT plan phase 6, docs/plans/VAT_MTD.md):
--   * registration threshold watch for people who aren't VAT registered;
--   * deadline reminders (14 and 3 days before each VAT return is due);
--   * the inspection export (every line behind every box: "digital links");
--   * VAT reports (by VAT code, by supplier; reclaimable vs blocked VAT).
-- Pure helpers first (specced without a database), then the database parts.

local VAT = require("lib.vat")

local M = {}

--- The registration threshold, from configuration (HMRC changes it; never hard-code).
function M.threshold_amount()
    return tonumber(os.getenv("VAT_REGISTRATION_THRESHOLD") or "") or 90000
end

-- Income categories that count towards taxable turnover when a line has no VAT code
-- yet. Exempt income (residential rent, interest) and money that isn't a supply
-- (transfers, refunds, loans) don't count.
M.TAXABLE_INCOME_CATEGORIES = { sales_income = true, consulting_income = true, income_other = true }
local TAXABLE_CODES = { STD20 = true, RED5 = true, ZERO = true, RC_CIS = true, NI_EU_GOODS = true, MARGIN = true }

--- Does a money-in line count as taxable turnover?
function M.is_taxable_sale(line)
    if line.vat_code and line.vat_code ~= "" then return TAXABLE_CODES[line.vat_code] == true end
    return M.TAXABLE_INCOME_CATEGORIES[line.category or ""] == true
end

local function add_months(ym, n)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    local idx = tonumber(y) * 12 + tonumber(m) - 1 + n
    return string.format("%04d-%02d", math.floor(idx / 12), idx % 12 + 1)
end

local function last_day(ym)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    return os.date("%Y-%m-%d", os.time({ year = tonumber(y), month = tonumber(m) + 1, day = 0, hour = 12 }))
end

--- The rolling 12-month test (VAT Notice 700/1 §3): at the end of any month, if
-- taxable turnover for the last 12 months is over the threshold you must register
-- within 30 days of the end of that month.
-- @param monthly table { ["YYYY-MM"] = taxable turnover that month }
-- @param as_of_month "YYYY-MM" (the last complete month)
-- @return { turnover, threshold, pct, status = ok|approaching|over, crossed_month?, register_by?, months = {...} }
function M.threshold_check(monthly, as_of_month, threshold)
    threshold = threshold or M.threshold_amount()
    local function rolling(end_month)
        local t = 0
        for i = 0, 11 do t = t + (tonumber(monthly[add_months(end_month, -i)]) or 0) end
        return t
    end
    local turnover = rolling(as_of_month)
    -- The first month-end in the last 12 where the rolling total went over.
    local crossed
    for i = 11, 0, -1 do
        local m = add_months(as_of_month, -i)
        if rolling(m) > threshold then crossed = m break end
    end
    local pct = threshold > 0 and turnover / threshold * 100 or 0
    local status = turnover > threshold and "over" or (pct >= 80 and "approaching" or "ok")
    local out = { turnover = VAT.round2(turnover), threshold = threshold, pct = math.floor(pct * 10 + 0.5) / 10,
        status = crossed and "over" or status, as_of = last_day(as_of_month) }
    if crossed then
        out.crossed_month = crossed
        local t = os.time({ year = tonumber(crossed:sub(1, 4)), month = tonumber(crossed:sub(6, 7)) + 1, day = 0,
            hour = 12 }) + 30 * 86400
        out.register_by = os.date("%Y-%m-%d", t)
    end
    return out
end

--- VAT periods for a stagger that ended on or before `today`, most recent first.
-- @return list of { start, ["end"], due }
function M.recent_periods(stagger, scheme, today, count)
    count = count or 4
    local len = stagger == "monthly" and 1 or (stagger == "annual" and 12 or 3)
    local offset = stagger == "quarterly_apr" and 1 or (stagger == "quarterly_may" and 2 or 0)
    local ym = today:sub(1, 7)
    local endm = add_months(ym, -1)
    if len == 3 then
        -- quarters end in months where (month - 3 - offset) is a multiple of 3
        while ((tonumber(endm:sub(6, 7)) - 3 - offset) % 3) ~= 0 do endm = add_months(endm, -1) end
    elseif len == 12 then
        while tonumber(endm:sub(6, 7)) ~= 3 do endm = add_months(endm, -1) end
    end
    local out = {}
    for _ = 1, count do
        local e = last_day(endm)
        local s = add_months(endm, -(len - 1)) .. "-01"
        out[#out + 1] = { start = s, ["end"] = e, due = VAT.due_date(e, scheme) }
        endm = add_months(endm, -len)
    end
    return out
end

local function days_between(a, b)
    local function t(d)
        local y, m, dd = d:match("^(%d+)%-(%d+)%-(%d+)")
        return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })
    end
    return math.floor((t(b) - t(a)) / 86400 + 0.5)
end
M._days_between = days_between

--- Which reminders are due today for a registration. filed[period_end] = true when filed.
-- @return list of { period = {...}, days_left, kind = "14_days"|"3_days"|"overdue" }
function M.reminders_due(reg, today, filed)
    local out = {}
    for _, p in ipairs(M.recent_periods(reg.stagger or "quarterly_mar", reg.scheme, today, 3)) do
        if not (filed or {})[p["end"]] and p.due then
            local left = days_between(today, p.due)
            local kind = (left == 14 and "14_days") or (left == 3 and "3_days") or (left == -1 and "overdue") or nil
            if kind then out[#out + 1] = { period = p, days_left = left, kind = kind } end
        end
    end
    return out
end

--- The inspection export: one row per line, with the boxes it went to.
-- lines: { ref = {date, description, amount, vat_code, net_amount, vat_amount, vat_notional,
--          vat_reclaimable_pct, transaction_type} }, audit: { box1 = {refs}, ... }
-- @return CSV text
function M.export_csv(by_ref, audit, adjustments)
    local boxes_of = {}
    for box, refs in pairs(audit or {}) do
        for _, r in ipairs(refs) do
            boxes_of[r] = boxes_of[r] or {}
            local n = box:gsub("box", "") -- (gsub also returns a count: keep only the text)
            table.insert(boxes_of[r], n)
        end
    end
    local function esc(v)
        if v == nil then return "" end
        local s = tostring(v)
        if s:find('[,"\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
        return s
    end
    local rows = { "reference,date,description,money,amount,vat_code,net,vat,notional_vat,reclaimable_pct,boxes" }
    local refs = {}
    for r in pairs(boxes_of) do refs[#refs + 1] = r end
    table.sort(refs)
    for _, ref in ipairs(refs) do
        local l = by_ref[ref]
        local a = (adjustments or {})[ref]
        local b = table.concat((function() local t = boxes_of[ref]; table.sort(t, function(x, y)
            return tonumber(x) < tonumber(y) end); return t end)(), " ")
        if l then
            rows[#rows + 1] = table.concat({ esc(ref), esc(l.date), esc(l.description),
                esc(l.transaction_type == "CREDIT" and "in" or "out"), esc(l.amount), esc(l.vat_code),
                esc(l.net_amount),
                esc(l.vat_amount), esc(l.vat_notional), esc(l.vat_reclaimable_pct), esc(b) }, ",")
        elseif a then
            local what = (a.type or "") .. ": " .. (a.description or "")
            rows[#rows + 1] = table.concat({ esc(ref), "", esc(what), "", "",
                "", esc(a.net), esc(a.vat or a.box1 or a.box4), "", "", esc(b) }, ",")
        end
    end
    return table.concat(rows, "\n") .. "\n"
end

--- VAT by code and by supplier for a set of coded lines.
-- lines: { vat_code, direction, net, vat, notional_vat, reclaimable_pct, supplier }
function M.report(lines)
    local by_code, by_supplier = {}, {}
    local totals = { output_vat = 0, input_vat = 0, reclaimable = 0, blocked = 0 }
    for _, l in ipairs(lines) do
        local c = by_code[l.vat_code] or { vat_code = l.vat_code, label = (VAT.code(l.vat_code) or {}).label,
            sales_net = 0, purchases_net = 0, output_vat = 0, input_vat = 0, reclaimable = 0, blocked = 0, lines = 0 }
        by_code[l.vat_code] = c
        c.lines = c.lines + 1
        local net, vat, notional = tonumber(l.net) or 0, tonumber(l.vat) or 0, tonumber(l.notional_vat) or 0
        if l.direction == "sale" then
            c.sales_net = c.sales_net + net
            c.output_vat = c.output_vat + vat
            totals.output_vat = totals.output_vat + vat
        else
            local input = vat + notional
            local rec = VAT.reclaimable(vat, notional, l.reclaimable_pct)
            c.purchases_net = c.purchases_net + net
            c.input_vat = c.input_vat + input
            c.reclaimable = c.reclaimable + rec
            c.blocked = c.blocked + (input - rec)
            totals.input_vat = totals.input_vat + input
            totals.reclaimable = totals.reclaimable + rec
            totals.blocked = totals.blocked + (input - rec)
            local s = l.supplier or "?"
            local sp = by_supplier[s] or { supplier = s, spend = 0, vat = 0, lines = 0 }
            by_supplier[s] = sp
            sp.spend = sp.spend + net + vat
            sp.vat = sp.vat + input
            sp.lines = sp.lines + 1
        end
    end
    local codes, suppliers = {}, {}
    for _, c in pairs(by_code) do
        for _, k in ipairs({ "sales_net", "purchases_net", "output_vat", "input_vat", "reclaimable", "blocked" }) do
            c[k] = VAT.round2(c[k])
        end
        codes[#codes + 1] = c
    end
    table.sort(codes, function(a, b) return a.lines > b.lines end)
    for _, s in pairs(by_supplier) do
        s.spend = VAT.round2(s.spend); s.vat = VAT.round2(s.vat)
        suppliers[#suppliers + 1] = s
    end
    table.sort(suppliers, function(a, b) return a.spend > b.spend end)
    while #suppliers > 20 do table.remove(suppliers) end
    for k, v in pairs(totals) do totals[k] = VAT.round2(v) end
    return { by_code = codes, top_suppliers = suppliers, totals = totals }
end

return M
