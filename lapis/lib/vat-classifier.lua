-- AI VAT coding that learns (VAT plan phase 3, docs/plans/VAT_MTD.md).
--
-- For each bank line, the VAT code comes from the first layer that knows it:
--   1. rules   — the business's own rules, then the global ones (lib/vat match_rule)
--   2. memory  — what this business decided before for the same supplier
--   3. model   — the LLM, in batches, as strict JSON; never trusted, always checked
-- Then risk checks flag lines a person must look at. The model only ever chooses a
-- code (and a reclaimable share); every figure is worked out by lib/vat.
--
-- Pure: the model is passed in as a function, so specs and the evaluation run
-- without a network.

local VAT = require("lib.vat")
local ok_mc, MerchantCleaner = pcall(require, "lib.merchant-cleaner")

local VC = {}

VC.REVIEW_CONFIDENCE = 0.75     -- below this, a person checks the line
VC.NO_RECEIPT_VAT = 250         -- reclaiming more VAT than this needs a VAT receipt
VC.LEARN_AFTER = 2              -- agreeing decisions before a supplier rule is learned
VC.BATCH = 20                   -- lines per model call

--- The supplier key a line is remembered by: the cleaned merchant name, normalised,
-- without reference numbers. "PROPDESK LTD REF 29384" and "Propdesk Ltd" -> "PROPDESK LTD".
function VC.memory_key(line)
    local m = line.merchant
    if (m == nil or m == "") and ok_mc and line.description then
        local ok, cleaned = pcall(MerchantCleaner.clean_merchant_name, line.description)
        if ok then m = cleaned end
    end
    if m == nil or m == "" then m = line.description end
    local k = VAT.norm(m)
    k = k:gsub("%f[%w]%w*%d%w*%f[%W]", " ")       -- drop tokens with digits (refs, dates)
    k = k:gsub("%f[%w]REF%f[%W]", " "):gsub("%f[%w]DD%f[%W]", " ")
    k = k:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return k
end

--- What this business decided before for the same supplier.
-- decisions: list of { key, vat_code, reclaimable_pct } (people's own decisions)
-- @return { vat_code, reclaimable_pct, confidence, reason } or nil
function VC.from_memory(decisions, line)
    local key = VC.memory_key(line)
    if key == "" then return nil end
    local tally, total = {}, 0
    for _, d in ipairs(decisions or {}) do
        if d.key == key then
            local id = d.vat_code .. "|" .. tostring(d.reclaimable_pct or "")
            tally[id] = (tally[id] or { n = 0, d = d })
            tally[id].n = tally[id].n + 1
            total = total + 1
        end
    end
    if total == 0 then return nil end
    local best
    for _, t in pairs(tally) do
        if not best or t.n > best.n then best = t end
    end
    local unanimous = best.n == total
    return {
        vat_code = best.d.vat_code,
        reclaimable_pct = best.d.reclaimable_pct,
        confidence = unanimous and 0.95 or 0.8,
        reason = unanimous
            and string.format("You coded %s this way before (%d time%s).", key, total, total == 1 and "" or "s")
            or string.format("You usually code %s this way (%d of %d times).", key, best.n, total),
    }
end

--- Should the business get a learned rule for this supplier?
-- @return vat_code, reclaimable_pct when VC.LEARN_AFTER decisions agree and none disagree
function VC.should_learn(decisions, key)
    local code, pct, n = nil, nil, 0
    for _, d in ipairs(decisions or {}) do
        if d.key == key then
            local p = d.reclaimable_pct
            if code == nil then code, pct = d.vat_code, p
            elseif d.vat_code ~= code or tostring(p) ~= tostring(pct) then return nil end
            n = n + 1
        end
    end
    if n >= VC.LEARN_AFTER then return code, pct end
    return nil
end

-- ------------------------------------------------------------------ model

local CODE_LIST = {}
for _, c in ipairs(VAT.CODES) do CODE_LIST[#CODE_LIST + 1] = c.code .. " = " .. c.label end

--- The messages for one model call (a batch of lines).
-- ctx: { scheme, business_name, partially_exempt, examples = { {description, direction, vat_code,
--        reclaimable_pct} } }
function VC.messages(lines, ctx)
    ctx = ctx or {}
    local sys = table.concat({
        "You code UK bank transactions for VAT for a VAT-registered business. For each line choose the VAT",
        "treatment of the supply. Codes:",
        "  " .. table.concat(CODE_LIST, "\n  "),
        "Rules: wages, tax payments, loans, transfers between own accounts, dividends and council tax are",
        "OUTSIDE. Insurance, most bank charges and interest, residential rent and Royal Mail stamps are EXEMPT.",
        "Passenger transport, most food (not catering), books and children's clothes are ZERO. Domestic fuel",
        "and power is RED5. Most other UK business purchases and sales are STD20. Services bought from",
        "overseas suppliers are RC_SERVICES. reclaimable_pct is the share of input VAT the business can",
        "reclaim: 100 normally, 0 for business entertainment, 50 for cars with private use.",
        "Answer ONLY with JSON: {\"lines\": [{\"i\": <line number>, \"vat_code\": \"...\",",
        "\"reclaimable_pct\": <0-100>, \"confidence\": <0-1>, \"reason\": \"<one short sentence>\"}]}.",
        "If unsure, say so with a low confidence rather than guessing.",
    }, "\n")
    local ctx_lines = { "Business: " .. tostring(ctx.business_name or "UK business")
        .. "; VAT scheme: " .. tostring(ctx.scheme or "standard")
        .. (ctx.partially_exempt and "; partially exempt" or "") }
    if ctx.examples and #ctx.examples > 0 then
        ctx_lines[#ctx_lines + 1] = "How this business coded similar lines before:"
        for _, e in ipairs(ctx.examples) do
            ctx_lines[#ctx_lines + 1] = string.format("  - %s (%s): %s, reclaimable %s%%", e.description,
                e.direction == "sale" and "money in" or "money out", e.vat_code, tostring(e.reclaimable_pct or 100))
        end
    end
    local body = { "Lines:" }
    for i, l in ipairs(lines) do
        body[#body + 1] = string.format("%d. %s | %s £%.2f%s", i, tostring(l.description or ""),
            l.direction == "sale" and "money in" or "money out", math.abs(tonumber(l.amount) or 0),
            l.category and (" | category: " .. l.category) or "")
    end
    return {
        { role = "system", content = sys },
        { role = "user", content = table.concat(ctx_lines, "\n") .. "\n\n" .. table.concat(body, "\n") },
    }
end

--- Read and check the model's answer for a batch of n lines.
-- @return list indexed 1..n of suggestion or nil (unusable for that line)
function VC.parse(text, n, decode)
    local out = {}
    if type(text) ~= "string" then return out end
    local s = text:match("%b{}") or text
    local ok, data = pcall(decode, s)
    if not ok or type(data) ~= "table" then return out end
    local list = data.lines or data
    if type(list) ~= "table" then return out end
    for _, item in ipairs(list) do
        local i = tonumber(type(item) == "table" and item.i or nil)
        local c = type(item) == "table" and VAT.code(item.vat_code) or nil
        if i and i >= 1 and i <= n and math.floor(i) == i and c then
            local pct = tonumber(item.reclaimable_pct)
            if pct == nil or pct < 0 or pct > 100 then pct = c.reclaimable end
            local conf = tonumber(item.confidence) or 0.5
            conf = math.max(0, math.min(1, conf))
            out[i] = { vat_code = c.code, reclaimable_pct = pct, confidence = conf,
                reason = type(item.reason) == "string" and item.reason:sub(1, 300) or nil }
        end
    end
    return out
end

-- ------------------------------------------------------------------ risk checks

local CAR = { vehicle_fuel = true, vehicle_insurance = true, vehicle_maintenance = true, mileage = true }

--- Why a person must look at this line (empty list = no review needed).
-- line: { direction, amount, description, category, evidence = { has_receipt, supplier_vrn } }
function VC.review_reasons(line, s)
    local reasons = {}
    if not s then return { "No VAT code could be worked out." } end
    if (s.confidence or 0) < VC.REVIEW_CONFIDENCE then
        reasons[#reasons + 1] = string.format("Not sure (%.0f%%).", (s.confidence or 0) * 100)
    end
    local c = VAT.code(s.vat_code)
    local ev = line.evidence or {}
    if line.direction == "purchase" and c and not c.no_vat and not c.reverse and c.rate > 0 then
        local split = VAT.split(line.amount, c.code, { vat_amount = line.vat_amount })
        local reclaim = split and VAT.reclaimable(split.vat, 0, s.reclaimable_pct) or 0
        if reclaim > VC.NO_RECEIPT_VAT and ev.has_receipt ~= true then
            reasons[#reasons + 1] = string.format("£%.2f of VAT reclaimed without a VAT receipt.", reclaim)
        end
    end
    local text = VAT.norm(line.description)
    if line.category == "client_entertainment" or text:find("ENTERTAIN", 1, true) then
        reasons[#reasons + 1] = "Business entertainment: VAT usually can't be reclaimed."
    end
    if CAR[line.category or ""] or text:find("CAR PURCHASE", 1, true) or text:find("VEHICLE", 1, true) then
        reasons[#reasons + 1] = "Car costs: check private use and how much VAT can be reclaimed."
    end
    if c and c.reverse then
        reasons[#reasons + 1] = "Reverse charge or import VAT: check the supplier is overseas / the import entry."
    end
    if ev.supplier_vrn and ev.supplier_vrn ~= "" and not VAT.valid_vrn(ev.supplier_vrn) then
        reasons[#reasons + 1] = "The supplier's VAT number fails HMRC's check."
    end
    return reasons
end

-- ------------------------------------------------------------------ the pipeline

--- Code a set of lines.
-- deps: { rules = {...}, decisions = {...}, model = function(messages) -> text | nil, err,
--         decode = json decode, ctx = { scheme, business_name, partially_exempt } }
-- @return results[i] = { vat_code, reclaimable_pct, confidence, reason, source = rule|memory|ai,
--                        rule_id?, review_reasons = {...} } or { error = ... }, stats
function VC.classify(lines, deps)
    deps = deps or {}
    local results, todo = {}, {}
    local stats = { rule = 0, memory = 0, ai = 0, failed = 0, model_calls = 0, review = 0 }
    for i, l in ipairs(lines) do
        local r = VAT.match_rule(deps.rules or {}, l)
        if r then
            results[i] = { vat_code = r.vat_code, reclaimable_pct = tonumber(r.reclaimable_pct),
                confidence = 1, reason = r.reason, source = "rule", rule_id = r.id }
            stats.rule = stats.rule + 1
        else
            local m = VC.from_memory(deps.decisions, l)
            if m then
                m.source = "memory"
                results[i] = m
                stats.memory = stats.memory + 1
            else
                todo[#todo + 1] = i
            end
        end
    end

    if #todo > 0 and deps.model then
        -- Few-shot: this business's own past decisions, most recent first.
        local examples = {}
        for _, d in ipairs(deps.decisions or {}) do
            if #examples >= 8 then break end
            if d.description then examples[#examples + 1] = d end
        end
        local ctx = {}
        for k, v in pairs(deps.ctx or {}) do ctx[k] = v end
        ctx.examples = examples
        for start = 1, #todo, VC.BATCH do
            local batch, idx = {}, {}
            for j = start, math.min(start + VC.BATCH - 1, #todo) do
                batch[#batch + 1] = lines[todo[j]]
                idx[#idx + 1] = todo[j]
            end
            stats.model_calls = stats.model_calls + 1
            local text = deps.model(VC.messages(batch, ctx))
            local parsed = VC.parse(text, #batch, deps.decode)
            for k, i in ipairs(idx) do
                local s = parsed[k]
                if s then
                    s.source = "ai"
                    results[i] = s
                    stats.ai = stats.ai + 1
                else
                    results[i] = { error = "The model gave no usable answer for this line." }
                    stats.failed = stats.failed + 1
                end
            end
        end
    else
        for _, i in ipairs(todo) do
            results[i] = { error = "No rule or past decision matched." }
            stats.failed = stats.failed + 1
        end
    end

    for i, l in ipairs(lines) do
        local s = results[i]
        if s and not s.error then
            s.review_reasons = VC.review_reasons(l, s)
            if #s.review_reasons > 0 then stats.review = stats.review + 1 end
        end
    end
    return results, stats
end

--- Code from a receipt's extracted figures (vision model output, already decoded).
-- receipt: { total, vat_amount, vat_rate, supplier_vrn }
-- @return { vat_code, vat_amount, evidence = {...}, warnings = {...} } or nil, message
function VC.from_receipt(line_amount, receipt)
    receipt = receipt or {}
    local warnings = {}
    local rate = tonumber(receipt.vat_rate)
    local code = (rate == 20 and "STD20") or (rate == 5 and "RED5") or (rate == 0 and "ZERO") or nil
    local vat = tonumber(receipt.vat_amount)
    if not code and vat and vat > 0 then code = "STD20" end
    if not code then return nil, "The receipt doesn't show a VAT rate or amount." end
    local total = tonumber(receipt.total)
    local amount = math.abs(tonumber(line_amount) or 0)
    if total and math.abs(total - amount) > 0.01 then
        warnings[#warnings + 1] = string.format("The receipt total (£%.2f) differs from the bank line (£%.2f).",
            total, amount)
    end
    if vat and (vat < 0 or vat > amount) then return nil, "The receipt's VAT is more than the amount paid." end
    local evidence = { has_receipt = true }
    if receipt.supplier_vrn and receipt.supplier_vrn ~= "" then
        local v = VAT.valid_vrn(receipt.supplier_vrn)
        if v then evidence.supplier_vrn = v
        else warnings[#warnings + 1] = "The supplier's VAT number on the receipt fails HMRC's check." end
    end
    return { vat_code = code, vat_amount = vat, evidence = evidence, warnings = warnings }
end

return VC
