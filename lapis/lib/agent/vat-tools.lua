-- VAT tools for the File My Tax assistant (VAT plan phase 5, docs/plans/VAT_MTD.md).
-- Installed into lib/agent/tax-tools.lua's registry when the "vat" feature is on.
-- The assistant can explain and show VAT, start AI coding and work out the return
-- with our engine; it never calculates VAT itself and never files a return (filing
-- is a click on the VAT screen, after the person ticks the declaration).

local VatTools = {}

local BOXES = {
    box1 = "Box 1 is the VAT you charged on your sales (output VAT), plus VAT you account for "
        .. "yourself under the reverse charge or postponed import VAT.",
    box2 = "Box 2 is VAT on goods brought into Northern Ireland from the EU. Most businesses leave it at 0.",
    box3 = "Box 3 is Box 1 plus Box 2: all the VAT due.",
    box4 = "Box 4 is the VAT you can reclaim on purchases (input VAT) — only the reclaimable share, so "
        .. "not VAT on business entertainment, and only part for cars with private use.",
    box5 = "Box 5 is the difference between Box 3 and Box 4: what you pay HMRC, or what HMRC pays you back.",
    box6 = "Box 6 is your total sales excluding VAT, in whole pounds — including zero-rated and exempt "
        .. "sales, but not things outside the scope of VAT like wages or transfers.",
    box7 = "Box 7 is your total purchases excluding VAT, in whole pounds — not wages, tax payments, "
        .. "loan repayments or transfers.",
    box8 = "Box 8 is goods sold from Northern Ireland to the EU, excluding VAT. Most businesses leave it at 0.",
    box9 = "Box 9 is goods bought into Northern Ireland from the EU, excluding VAT. Most businesses leave it at 0.",
}
VatTools.BOXES = BOXES

local function registration(ctx)
    local VatQueries = require("queries.VatQueries")
    local reg = VatQueries.get_registration(ctx.namespace_id, ctx.user_id)
    if not reg then
        return nil, "There's no VAT registration yet. Ask the user to add their VAT number on the VAT page "
            .. "(Tax -> VAT)."
    end
    return reg
end

function VatTools.install(register)
    local perms = { { "tax_transactions", "read" } }

    register({
        name = "get_vat_status",
        description = "The user's VAT registration (VAT number, scheme) and how far VAT coding has got: "
            .. "how many bank lines are coded by rules, by AI, by the user, still uncoded, and to check.",
        perms = perms,
        parameters = { type = "object", properties = {} },
        handler = function(ctx)
            local reg, err = registration(ctx); if not reg then return nil, err end
            local st = require("queries.VatAiQueries").status(reg, ctx.user_id, {})
            return { vrn = reg.vrn, scheme = reg.scheme, business_name = reg.business_name, coding = st,
                note = "To code remaining lines call start_vat_coding; lines to check are in get_vat_review_queue." }
        end,
    })

    register({
        name = "start_vat_coding",
        description = "Start coding the user's un-coded bank lines for VAT in the background (rules, their "
            .. "past decisions, then AI). Returns at once; it takes a few minutes.",
        perms = perms,
        parameters = { type = "object", properties = {
            tax_year = { type = "string", description = "Optional UK tax year, e.g. 2025-26" } } },
        handler = function(ctx, args)
            local reg, err = registration(ctx); if not reg then return nil, err end
            local res, serr = require("queries.VatAiQueries").start(reg, ctx.user_id, { tax_year = args.tax_year })
            if not res then return nil, serr end
            return res
        end,
    })

    register({
        name = "get_vat_review_queue",
        description = "The bank lines the user should check for VAT, with the reason each was flagged "
            .. "(not sure, no receipt for large VAT, entertainment, cars, reverse charge...).",
        perms = perms,
        parameters = { type = "object", properties = {} },
        handler = function(ctx)
            local reg, err = registration(ctx); if not reg then return nil, err end
            local rows = require("queries.VatAiQueries").review_queue(reg, ctx.user_id, { limit = 15 })
            local out = {}
            for _, r in ipairs(rows) do
                out[#out + 1] = { date = r.transaction_date, description = r.description, amount = r.amount,
                    vat_code = r.vat_code, reasons = r.vat_review_reasons }
            end
            return { lines = out, note = "The user changes or confirms these on the VAT page." }
        end,
    })

    register({
        name = "compute_vat_return",
        description = "Work out the 9-box VAT return for a period with OpsAPI's VAT engine (never estimate "
            .. "VAT yourself). Dates are YYYY-MM-DD, e.g. a quarter 2026-01-01 to 2026-03-31.",
        perms = perms,
        parameters = { type = "object", properties = {
            period_start = { type = "string" }, period_end = { type = "string" } },
            required = { "period_start", "period_end" } },
        handler = function(ctx, args)
            local reg, err = registration(ctx); if not reg then return nil, err end
            local res, perr = require("queries.VatReturnQueries").preview(reg, args.period_start, args.period_end)
            if not res then return nil, perr end
            return { boxes = res.boxes, direction = res.direction, due_date = res.period.due_date,
                lines = res.line_count, uncoded = res.uncoded_count, warnings = res.warnings,
                note = "Filing happens on the VAT page after the user confirms the declaration." }
        end,
    })

    register({
        name = "explain_vat_box",
        description = "Explain in plain English what goes in a VAT return box (box1..box9).",
        parameters = { type = "object", properties = {
            box = { type = "string", description = "box1 .. box9" } }, required = { "box" } },
        handler = function(_, args)
            local key = tostring(args.box or ""):lower():gsub("%s", "")
            if key:match("^%d$") then key = "box" .. key end
            local text = BOXES[key]
            if not text then return nil, "Use box1 to box9." end
            return { box = key, explanation = text }
        end,
    })
end

return VatTools
