--[[
    VAT management (VAT plan phase 6): threshold watch, deadline reminders, the
    inspection export and VAT reports, on top of lib/vat-management.lua.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local M = require("lib.vat-management")
local VC = require("lib.vat-classifier")
local VatReturnQueries = require("queries.VatReturnQueries")

local Q = {}

local function null(v) return v == nil or v == db.NULL or (ngx and v == ngx.null) end

--- The registration threshold check for a person (whether or not they're registered).
function Q.threshold(namespace_id, user_id)
    local rows = db.query([[SELECT to_char(transaction_date, 'YYYY-MM') AS ym, vat_code, category, SUM(amount) AS total
        FROM tax_transactions
        WHERE namespace_id = ? AND user_id = ? AND transaction_type = 'CREDIT'
          AND transaction_date >= date_trunc('month', NOW()) - INTERVAL '24 months'
        GROUP BY 1, 2, 3]], namespace_id, user_id) or {}
    local monthly = {}
    for _, r in ipairs(rows) do
        if M.is_taxable_sale({ vat_code = not null(r.vat_code) and r.vat_code or nil,
            category = not null(r.category) and r.category or nil }) then
            monthly[r.ym] = (monthly[r.ym] or 0) + (tonumber(r.total) or 0)
        end
    end
    local last_month = os.date("%Y-%m", os.time({ year = tonumber(os.date("%Y")), month = tonumber(os.date("%m")),
        day = 0, hour = 12 }))
    return M.threshold_check(monthly, last_month)
end

--- The inspection export for one return: CSV (or JSON) of every line behind every box.
function Q.export(reg, uuid, format)
    local row = db.query("SELECT * FROM vat_returns WHERE uuid = ? AND registration_id = ? LIMIT 1", uuid, reg.id)[1]
    if not row then return nil, "VAT return not found", 404 end
    local calc = type(row.calculation) == "table" and row.calculation or (cjson.decode(row.calculation or "{}") or {})
    local _, _, all = VatReturnQueries.collect_lines(reg, row.period_start, row.period_end)
    local by_ref = {}
    for _, r in ipairs(all) do
        by_ref[r.ref] = { date = r.date, description = r.description, amount = r.amount, vat_code = r.vat_code,
            net_amount = r.net_amount, vat_amount = r.vat_amount, vat_notional = r.vat_notional,
            vat_reclaimable_pct = r.vat_reclaimable_pct, transaction_type = r.dir }
    end
    local adj = {}
    for _, a in ipairs(VatReturnQueries.list_adjustments(reg, row.period_start, row.period_end)) do
        adj["adj:" .. a.uuid] = a
    end
    if format == "json" then
        return { period_start = row.period_start, period_end = row.period_end, period_key = row.period_key,
            status = row.status, vrn = reg.vrn, boxes = { box1 = row.box1, box2 = row.box2, box3 = row.box3,
                box4 = row.box4, box5 = row.box5, box6 = row.box6, box7 = row.box7, box8 = row.box8, box9 = row.box9 },
            audit = calc.audit, lines = by_ref, adjustments = adj }
    end
    return M.export_csv(by_ref, calc.audit or {}, adj), nil, nil,
        string.format("vat-return-%s-%s-to-%s.csv", reg.vrn, row.period_start, row.period_end)
end

--- VAT by code and supplier for a person's coded lines in a date range.
function Q.report(reg, user_id, from, to)
    local rows = db.query([[SELECT transaction_type, vat_code, net_amount, vat_amount, vat_notional,
            vat_reclaimable_pct, description, cleaned_merchant_name AS merchant
        FROM tax_transactions
        WHERE namespace_id = ? AND user_id = ? AND vat_code IS NOT NULL AND vat_code <> 'OUTSIDE'
          AND transaction_date BETWEEN ? AND ?]], reg.namespace_id, user_id, from, to) or {}
    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = { vat_code = r.vat_code,
            direction = r.transaction_type == "CREDIT" and "sale" or "purchase",
            net = r.net_amount, vat = r.vat_amount, notional_vat = r.vat_notional,
            reclaimable_pct = not null(r.vat_reclaimable_pct) and tonumber(r.vat_reclaimable_pct) or nil,
            supplier = VC.memory_key({ merchant = not null(r.merchant) and r.merchant or nil,
                description = r.description }) }
    end
    local out = M.report(lines)
    out.from, out.to = from, to
    return out
end

local function has_table(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)[1]
    return r and (r.ok == true or r.ok == "t")
end

--- Send today's deadline reminders (each one once). @return number sent
function Q.run_reminders(today)
    today = today or os.date("%Y-%m-%d")
    local regs = db.query("SELECT * FROM vat_registrations WHERE status = 'active'") or {}
    local notify = has_table("notifications")
    local sent = 0
    for _, reg in ipairs(regs) do
        local filed = {}
        for _, f in ipairs(db.query([[SELECT period_end FROM vat_returns WHERE registration_id = ?
            AND status = 'submitted']], reg.id) or {}) do filed[tostring(f.period_end)] = true end
        for _, due in ipairs(M.reminders_due(reg, today, filed)) do
            local ins = db.query([[INSERT INTO vat_reminders (registration_id, period_end, kind)
                VALUES (?, ?, ?) ON CONFLICT DO NOTHING RETURNING id]], reg.id, due.period["end"], due.kind)
            if ins and #ins > 0 then
                local who = not null(reg.user_id) and reg.user_id or reg.created_by
                local title = due.kind == "overdue" and "Your VAT return is overdue"
                    or ("Your VAT return is due in " .. due.days_left .. " days")
                local msg = string.format("VAT return for %s to %s is due by %s.", due.period.start,
                    due.period["end"], due.period.due)
                if notify and who and not null(who) then
                    pcall(db.insert, "notifications", { uuid = require("helper.global").generateUUID(),
                        user_id = who, type = "vat_deadline", title = title, message = msg, is_read = false,
                        data = cjson.encode({ link = "/dashboard/tax/vat", period_end = due.period["end"] }),
                        created_at = db.format_date() })
                end
                sent = sent + 1
            end
        end
    end
    return sent
end

--- Daily reminders (worker 0, deployments with the vat feature).
function Q.start()
    if ngx.worker.id() ~= 0 or not require("helper.project-config").isFeatureEnabled("vat") then return end
    local function run(premature)
        if premature then return end
        local ok, res = pcall(Q.run_reminders)
        if not ok then ngx.log(ngx.ERR, "[vat-reminders] failed: ", tostring(res))
        elseif res > 0 then ngx.log(ngx.NOTICE, "[vat-reminders] sent ", res) end
        pcall(require("lapis.nginx.context").run_after_dispatch)
    end
    ngx.timer.at(180, run)
    ngx.timer.every(6 * 3600, run)
end

return Q
