--[[
    Filing VAT returns with HMRC (VAT plan phase 4).

    submit() is BINDING. Guards (as the income-tax final declaration):
      * explicit declaration;
      * the draft is rebuilt from the current records first, every line is coded and
        the boxes pass HMRC's checks;
      * the draft is claimed atomically (draft -> submitting), so a double click or a
        second pod can't file twice; a filed period is never filed again;
      * on success HMRC's receipt is stored; on failure the reason is stored and the
        row is marked failed (a new draft can be made);
      * "already filed" from HMRC: we fetch HMRC's copy and only mark ours filed when
        the figures match.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local HMRC = require("helper.hmrc")
local Client = require("lib.hmrc-vat-client")
local Return = require("lib.vat-return")
local VatReturnQueries = require("queries.VatReturnQueries")

local Q = {}

-- Count every attempt to file (Prometheus: vat_submissions_total{result, environment}).
local function count(result)
    pcall(function()
        local m = require("lib.prometheus_metrics").get_metric_vat_submissions()
        if m then m:inc(1, { result, Client.is_sandbox() and "sandbox" or "production" }) end
    end)
end

--- Is filing VAT switched on here? In production it must be turned on explicitly
-- (VAT_FILING_ENABLED=true), so it can be switched off without a deploy; the
-- sandbox is always on.
function Q.filing_enabled()
    if Client.is_sandbox() then return true end
    return os.getenv("VAT_FILING_ENABLED") == "true"
end

local function decode(v)
    if type(v) == "table" then return v end
    if type(v) ~= "string" or v == "" then return nil end
    local ok, t = pcall(cjson.decode, v)
    return ok and t or nil
end

--- A valid HMRC token with the VAT scopes for this person.
-- @return token or nil, message, code
function Q.token(user_uuid)
    local token, err = HMRC.get_valid_token(user_uuid)
    if not token then return nil, err or "Connect to HMRC first", "NOT_CONNECTED" end
    local row = db.query("SELECT scope FROM hmrc_tokens WHERE user_uuid = ? LIMIT 1", user_uuid)[1]
    local scope = row and tostring(row.scope or "") or ""
    if not scope:find("write:vat", 1, true) then
        return nil, "Your HMRC connection doesn't include VAT yet. Connect to HMRC again for VAT.", "VAT_SCOPE_MISSING"
    end
    return token
end

-- err is our own text (it can hold the URL with the VAT number, socket errors): logged, never sent.
local function hmrc_error(err, body, status)
    local msg, code = Client.explain(body)
    ngx.log(ngx.WARN, "[vat-hmrc] ", tostring(err), " (HTTP ", tostring(status), ")")
    return { status = (status and status >= 400 and status < 500) and 422 or 502,
        json = { success = false, error = msg, code = code, hmrc = body } }
end

function Q.obligations(reg, user_uuid, params)
    local token, terr, tcode = Q.token(user_uuid)
    if not token then return nil, { status = 409, json = { success = false, error = terr, code = tcode } } end
    local list, err, body, status = Client.obligations(token, reg.vrn, {
        from = params.from, to = params.to, status = params.status, test_scenario = params.test_scenario })
    if not list then return nil, hmrc_error(err, body, status) end
    return list
end

local function boxes_of(row)
    local b = {}
    for i = 1, 9 do b["box" .. i] = tonumber(row["box" .. i]) or 0 end
    return b
end

local function same_figures(ours, hmrc)
    local map = { box1 = "vatDueSales", box2 = "vatDueAcquisitions", box3 = "totalVatDue",
        box4 = "vatReclaimedCurrPeriod", box5 = "netVatDue", box6 = "totalValueSalesExVAT",
        box7 = "totalValuePurchasesExVAT", box8 = "totalValueGoodsSuppliedExVAT", box9 = "totalAcquisitionsExVAT" }
    for k, f in pairs(map) do
        if math.abs((tonumber(ours[k]) or 0) - (tonumber(hmrc[f]) or 0)) > 0.005 then return false end
    end
    return true
end

--- Do two sets of boxes match to the penny?
function Q.same_boxes(a, b)
    for i = 1, 9 do
        local k = "box" .. i
        if math.abs((tonumber(a[k]) or 0) - (tonumber(b[k]) or 0)) > 0.005 then return false end
    end
    return true
end

--- File a draft return with HMRC. body: { period_key, declaration_accepted, test_scenario? }
-- @return filed row or nil, response
function Q.submit(reg, return_uuid, actor_id, user_uuid, body)
    body = body or {}
    if not Q.filing_enabled() then
        count("refused_locally")
        return nil, { status = 503, json = { success = false, code = "VAT_FILING_OFF",
            error = "Filing VAT returns with HMRC isn't switched on here yet. Your return is saved as a draft." } }
    end
    local declared = body.declaration_accepted == true or body.declaration_accepted == "true"
    if not declared then
        return nil, { status = 400, json = { success = false, code = "DECLARATION_REQUIRED",
            error = "Confirm the declaration before filing your VAT return." } }
    end
    local period_key = tostring(body.period_key or "")
    if period_key == "" or #period_key > 10 then
        return nil, { status = 400, json = { success = false, error = "Choose the VAT period (period_key) to file" } }
    end
    local draft = db.query("SELECT * FROM vat_returns WHERE uuid = ? AND registration_id = ? LIMIT 1",
        return_uuid, reg.id)[1]
    if not draft then return nil, { status = 404, json = { success = false, error = "VAT return not found" } } end
    if draft.status ~= "draft" then
        return nil, { status = 409, json = { success = false, error = "This return is already " .. draft.status } }
    end
    if VatReturnQueries.group_of(reg) then
        return nil, { status = 409, json = { success = false, code = "VAT_GROUP_MEMBER",
            error = "This workspace is in a VAT group: the group's representative files the return." } }
    end

    local token, terr, tcode = Q.token(user_uuid)
    if not token then return nil, { status = 409, json = { success = false, error = terr, code = tcode } } end

    -- In production the key must be the open HMRC period with exactly this return's dates,
    -- so one period's figures can't go under another's key (the sandbox's obligations are
    -- canned, so it accepts any key).
    if not Client.is_sandbox() then
        local open = Client.obligations(token, reg.vrn, { from = draft.period_start, to = draft.period_end,
            status = "O" }) or {}
        local found = false
        for _, o in ipairs(open) do
            if o.periodKey == period_key and tostring(o.start) == tostring(draft.period_start)
                and tostring(o["end"]) == tostring(draft.period_end) then found = true end
        end
        if not found then
            return nil, { status = 422, json = { success = false, code = "PERIOD_MISMATCH",
                error = "HMRC doesn't have a period open for this VAT number with this return's dates ("
                    .. tostring(draft.period_start) .. " to " .. tostring(draft.period_end) .. ")." } }
        end
    end

    -- Rebuild from the current records: never file stale figures.
    local fresh, ferr, fstatus = VatReturnQueries.save_draft(reg, draft.period_start, draft.period_end, actor_id)
    if not fresh then return nil, { status = fstatus or 400, json = { success = false, error = ferr } } end
    if (tonumber(fresh.uncoded_count) or 0) > 0 then
        return nil, { status = 422, json = { success = false, code = "UNCODED_LINES",
            error = fresh.uncoded_count .. " line(s) in this period have no VAT code. Code them before filing." } }
    end
    local boxes = boxes_of(fresh)
    -- File only what the person reviewed and declared: if the records changed since
    -- (AI coding, a colleague, a newly paid invoice), show the new figures first.
    if not Q.same_boxes(boxes_of(draft), boxes) then
        return nil, { status = 409, json = { success = false, code = "FIGURES_CHANGED",
            error = "Your figures changed since you checked them. Review the updated return, then file it.",
            data = { uuid = fresh.uuid, boxes = boxes } } }
    end
    local ok_v, verrs = Return.validate(boxes)
    if not ok_v then
        return nil, { status = 422, json = { success = false, code = "INVALID_BOXES",
            error = "The figures don't pass HMRC's checks.", validation = verrs } }
    end

    -- Claim it: only one filing, ever, for this draft.
    local claimed = db.query([[UPDATE vat_returns SET status = 'submitting', period_key = ?, submitted_by = ?,
            updated_at = NOW()
        WHERE id = ? AND status = 'draft' RETURNING id]], period_key, actor_id, fresh.id)
    if not claimed or #claimed == 0 then
        return nil, { status = 409, json = { success = false, error = "This return is already being filed." } }
    end

    local receipt, err, hbody, status = Client.submit_return(token, reg.vrn, Client.return_body(boxes, period_key),
        { test_scenario = body.test_scenario })

    if not receipt and type(hbody) == "table" and hbody.code == "DUPLICATE_SUBMISSION" then
        -- HMRC already has this period: only count it as ours if the figures match.
        local theirs = Client.view_return(token, reg.vrn, period_key)
        if theirs and same_figures(boxes, theirs) then
            receipt = { duplicate = true, hmrc_return = theirs }
        end
    end

    if receipt then
        count("filed")
        db.query([[UPDATE vat_returns SET status = 'submitted', hmrc_receipt = ?, submitted_at = NOW(),
            updated_at = NOW() WHERE id = ?]], cjson.encode(receipt), fresh.id)
    else
        local msg, code = Client.explain(hbody)
        count(status and "rejected" or "unreachable")
        db.query([[UPDATE vat_returns SET status = 'failed', hmrc_receipt = ?, updated_at = NOW() WHERE id = ?]],
            cjson.encode({ error = msg, code = code, detail = err, hmrc = hbody, http_status = status }), fresh.id)
        local resp = hmrc_error(err, hbody, status)
        if not status then
            resp.json.error = "We couldn't reach HMRC, so we don't know if the return arrived. Check "
                .. "\"View return from HMRC\" for this period before trying again."
        end
        return nil, resp
    end
    local row = db.query("SELECT * FROM vat_returns WHERE id = ?", fresh.id)[1]
    row.hmrc_receipt = decode(row.hmrc_receipt)
    row.calculation = decode(row.calculation)
    return row
end

function Q.view(reg, user_uuid, period_key, params)
    local token, terr, tcode = Q.token(user_uuid)
    if not token then return nil, { status = 409, json = { success = false, error = terr, code = tcode } } end
    local data, err, body, status = Client.view_return(token, reg.vrn, period_key,
        { test_scenario = (params or {}).test_scenario })
    if not data then return nil, hmrc_error(err, body, status) end
    return data
end

function Q.account(reg, user_uuid, what, params)
    params = params or {}
    local token, terr, tcode = Q.token(user_uuid)
    if not token then return nil, { status = 409, json = { success = false, error = terr, code = tcode } } end
    local fn = ({ liabilities = Client.liabilities, payments = Client.payments, penalties = Client.penalties })[what]
    if not fn then return nil, { status = 404, json = { success = false, error = "Unknown" } } end
    local data, err, body, status = fn(token, reg.vrn, { from = params.from, to = params.to,
        test_scenario = params.test_scenario })
    if not data then return nil, hmrc_error(err, body, status) end
    return data
end

return Q
