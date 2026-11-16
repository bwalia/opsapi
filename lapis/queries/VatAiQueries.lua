--[[
    AI VAT coding that learns (VAT plan phase 3): runs lib/vat-classifier.lua over a
    business's un-coded bank lines, learns supplier rules from people's decisions,
    reads VAT receipts, and measures the live model on the labelled set.

    The model only chooses a VAT code / reclaimable share; figures come from lib/vat.
    People's own decisions (vat_source = 'user') are never overwritten.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local VAT = require("lib.vat")
local VC = require("lib.vat-classifier")
local VatQueries = require("queries.VatQueries")
local VatReturnQueries = require("queries.VatReturnQueries")

local Q = {}

local function null(v) return v == nil or v == db.NULL or (ngx and v == ngx.null) end
local function decode(v)
    if type(v) == "table" then return v end
    if type(v) ~= "string" or v == "" then return nil end
    local ok, t = pcall(cjson.decode, v)
    return ok and t or nil
end

local function model_fn(feature)
    return function(messages)
        local Llm = require("lib.agent.llm")
        local msg, err = Llm.chat(messages, nil, { json = true, temperature = 0, max_tokens = 1600,
            usage = { feature = feature or "vat_classify" } })
        if not msg then
            ngx.log(ngx.WARN, "[vat-ai] model call failed: ", tostring(err))
            return nil, err
        end
        return msg.content
    end
end

function Q.rules(reg)
    return db.query([[SELECT id, registration_id, match_type, match_value, vat_code, reclaimable_pct, reason,
            is_active FROM vat_rules WHERE is_active AND (registration_id IS NULL OR registration_id = ?)]],
        reg.id) or {}
end

--- People's own past VAT decisions for this business (most recent first), from its own lines.
function Q.decisions(reg)
    local from = VatReturnQueries.lines_from(reg)
    local rows = from and db.query([[SELECT l.description, l.merchant, l.dir AS transaction_type, l.vat_code,
            l.vat_reclaimable_pct FROM ]] .. from .. [[
        WHERE l.vat_registration_id = ? AND l.vat_source = 'user' AND l.vat_code IS NOT NULL
        ORDER BY l.vat_decided_at DESC NULLS LAST LIMIT 500]], reg.id) or {}
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { key = VC.memory_key({ merchant = not null(r.merchant) and r.merchant or nil,
                description = r.description }),
            vat_code = r.vat_code, reclaimable_pct = tonumber(r.vat_reclaimable_pct),
            description = r.description, direction = r.transaction_type == "CREDIT" and "sale" or "purchase" }
    end
    return out
end

local function line_of(r)
    return { src = r.src, id = r.id, description = r.description, merchant = not null(r.merchant) and r.merchant or nil,
        category = not null(r.category) and r.category or nil, amount = tonumber(r.amount),
        direction = r.transaction_type == "CREDIT" and "sale" or "purchase",
        evidence = decode(r.vat_evidence) or {} }
end

--- The business's lines that still need a VAT code (or, with recode, also AI-coded ones).
function Q.lines_to_code(reg, opts)
    opts = opts or {}
    local from = VatReturnQueries.lines_from(reg)
    if not from then return {} end
    local where = VatReturnQueries.line_filters(reg, opts)
    where[#where + 1] = opts.recode and "(l.vat_code IS NULL OR l.vat_source IN ('ai', 'memory'))"
        or "l.vat_code IS NULL"
    local rows = db.query([[SELECT l.src, l.id, l.description, l.merchant, l.category, l.amount,
            l.dir AS transaction_type, l.vat_evidence
        FROM ]] .. from .. " WHERE " .. table.concat(where, " AND ") .. " ORDER BY l.date, l.id LIMIT "
        .. (tonumber(opts.limit) or 2000)) or {}
    local lines = {}
    for _, r in ipairs(rows) do lines[#lines + 1] = line_of(r) end
    return lines
end

--- Write the classifier's results to the lines.
function Q.save_results(reg, lines, results)
    for i, l in ipairs(lines) do
        local s = results[i]
        if s and not s.error then
            local vf = VatQueries.vat_fields(l.amount, s.vat_code, { reclaimable_pct = s.reclaimable_pct })
            if vf then
                vf.vat_source = (s.source == "memory") and "ai" or s.source
                vf.vat_confidence = s.confidence or 0
                vf.vat_reason = s.reason or db.NULL
                vf.vat_rule_id = s.rule_id or db.NULL
                vf.vat_registration_id = reg.id
                vf.vat_review = #(s.review_reasons or {}) > 0
                vf.vat_review_reasons = #(s.review_reasons or {}) > 0 and cjson.encode(s.review_reasons) or db.NULL
                vf.vat_decided_at = db.raw("NOW()")
                vf.updated_at = db.raw("NOW()")
                -- The person may have decided meanwhile: never overwrite their decision.
                VatReturnQueries.write_line(l.src, l.id, vf, "AND COALESCE(vat_source, '') <> 'user'")
            end
        elseif s and s.error then
            db.query("UPDATE " .. l.src .. [[ SET vat_review = true, vat_review_reasons = ?, updated_at = NOW()
                WHERE id = ? AND vat_code IS NULL]], cjson.encode({ s.error }), l.id)
        end
    end
    local hits = {}
    for _, s in ipairs(results) do
        if s and s.rule_id then hits[s.rule_id] = (hits[s.rule_id] or 0) + 1 end
    end
    for id, n in pairs(hits) do db.query("UPDATE vat_rules SET hits = hits + ? WHERE id = ?", n, id) end
end

--- Code a business's lines now (rules, memory, model). Used by the background job.
-- @return stats
function Q.classify_now(reg, opts)
    local lines = Q.lines_to_code(reg, opts)
    if #lines == 0 then return { lines = 0 } end
    local deps = {
        rules = Q.rules(reg), decisions = Q.decisions(reg),
        model = (opts or {}).no_model and nil or model_fn("vat_classify"), decode = cjson.decode,
        ctx = { scheme = reg.scheme, business_name = reg.business_name,
            partially_exempt = reg.partially_exempt == true or reg.partially_exempt == "t" },
    }
    -- One model batch at a time, saved as it goes: progress shows, and a slow or
    -- failed batch doesn't lose the others.
    local all_results, total = {}, { rule = 0, memory = 0, ai = 0, failed = 0, model_calls = 0, review = 0 }
    for start = 1, #lines, VC.BATCH do
        local chunk = {}
        for j = start, math.min(start + VC.BATCH - 1, #lines) do chunk[#chunk + 1] = lines[j] end
        local results, stats = VC.classify(chunk, deps)
        Q.save_results(reg, chunk, results)
        for k, v in pairs(stats) do total[k] = (total[k] or 0) + v end
        for _, r in ipairs(results) do all_results[#all_results + 1] = r end
        Q.touch_job(reg)
    end
    -- Then make the model consistent with itself across batches and save the changes.
    total.harmonised = VC.harmonise(lines, all_results)
    if total.harmonised > 0 then Q.save_results(reg, lines, all_results) end
    total.lines = #lines
    return total
end

-- One coding run per business across every pod: a claim on the registration row.
-- A claim older than 30 minutes is treated as dead (pod restarted mid-run).
function Q.claim_job(reg)
    local r = db.query([[UPDATE vat_registrations SET ai_job_started_at = NOW()
        WHERE id = ? AND (ai_job_started_at IS NULL OR ai_job_started_at < NOW() - INTERVAL '30 minutes')
        RETURNING id]], reg.id)
    return r and #r > 0
end
function Q.touch_job(reg)
    db.query("UPDATE vat_registrations SET ai_job_started_at = NOW() WHERE id = ? AND ai_job_started_at IS NOT NULL",
        reg.id)
end
function Q.release_job(reg)
    db.query("UPDATE vat_registrations SET ai_job_started_at = NULL WHERE id = ?", reg.id)
end
local function job_running(reg)
    local r = db.query([[SELECT 1 FROM vat_registrations WHERE id = ?
        AND ai_job_started_at > NOW() - INTERVAL '30 minutes']], reg.id)
    return r and #r > 0
end

--- Start coding in the background; returns at once.
-- @return { started = bool, pending = n }
function Q.start(reg, opts)
    local pending = #Q.lines_to_code(reg, opts)
    if pending == 0 then return { started = false, pending = 0 } end
    if not Q.claim_job(reg) then
        return { started = false, already_running = true, pending = pending }
    end
    local ok, err = ngx.timer.at(0, function(premature)
        if premature then Q.release_job(reg) return end
        local ok2, res = pcall(Q.classify_now, reg, opts)
        if not ok2 then ngx.log(ngx.ERR, "[vat-ai] classify failed: ", tostring(res)) end
        Q.release_job(reg)
    end)
    if not ok then
        Q.release_job(reg)
        ngx.log(ngx.ERR, "[vat-ai] couldn't start the coding job: ", tostring(err))
        return nil, "Couldn't start VAT coding just now. Try again in a minute."
    end
    return { started = true, pending = pending }
end

--- Where coding stands for this business.
function Q.status(reg, opts)
    local from = VatReturnQueries.lines_from(reg)
    local where = VatReturnQueries.line_filters(reg, { tax_year = (opts or {}).tax_year })
    local r = from and db.query([[SELECT COUNT(*) AS total,
            COUNT(*) FILTER (WHERE l.vat_code IS NULL) AS uncoded,
            COUNT(*) FILTER (WHERE l.vat_source = 'rule') AS by_rule,
            COUNT(*) FILTER (WHERE l.vat_source = 'ai') AS by_ai,
            COUNT(*) FILTER (WHERE l.vat_source = 'user') AS by_you,
            COUNT(*) FILTER (WHERE l.vat_review AND COALESCE(l.vat_source, '') <> 'user') AS to_check
        FROM ]] .. from .. (#where > 0 and (" WHERE " .. table.concat(where, " AND ")) or ""))[1]
    r = r or { total = 0, uncoded = 0, by_rule = 0, by_ai = 0, by_you = 0, to_check = 0 }
    r.running = job_running(reg)
    for k, v in pairs(r) do if k ~= "running" then r[k] = tonumber(v) or 0 end end
    return r
end

--- The lines a person should check, with the reasons.
function Q.review_queue(reg, opts)
    opts = opts or {}
    local from = VatReturnQueries.lines_from(reg)
    local rows = from and db.query([[SELECT l.uuid, l.date AS transaction_date, l.description, l.amount,
            l.dir AS transaction_type, l.vat_code, l.net_amount, l.vat_amount, l.vat_reclaimable_pct, l.vat_source,
            l.vat_confidence, l.vat_reason, l.vat_review_reasons, l.vat_evidence
        FROM ]] .. from .. [[ WHERE l.vat_review AND COALESCE(l.vat_source, '') <> 'user'
        ORDER BY l.date, l.id LIMIT ?]], tonumber(opts.limit) or 200) or {}
    for _, r in ipairs(rows) do
        r.vat_review_reasons = decode(r.vat_review_reasons) or {}
        r.vat_evidence = decode(r.vat_evidence)
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Learning from people's decisions
-- ---------------------------------------------------------------------------

--- After a person sets a line's VAT: learn a supplier rule once their decisions agree.
-- @return the new rule (to show "We'll now treat X as ...") or nil
function Q.learn(reg, transaction_uuid, actor_id)
    local from = VatReturnQueries.lines_from(reg)
    local t = from and db.query([[SELECT l.description, l.merchant, l.vat_code, l.vat_reclaimable_pct
        FROM ]] .. from .. [[ WHERE l.uuid = ? AND l.vat_registration_id = ? AND l.vat_source = 'user']],
        transaction_uuid, reg.id)[1]
    if not t then return nil end
    local key = VC.memory_key({ merchant = not null(t.merchant) and t.merchant or nil, description = t.description })
    if key == "" or #key < 3 then return nil end
    local code, pct = VC.should_learn(Q.decisions(reg), key)
    if not code then return nil end
    local exists = db.query([[SELECT 1 FROM vat_rules WHERE registration_id = ? AND lower(match_value) = lower(?)]],
        reg.id, key)
    if exists and #exists > 0 then return nil end
    local label = (VAT.code(code) or {}).label or code
    db.insert("vat_rules", { registration_id = reg.id, match_type = "contains", match_value = key, vat_code = code,
        reclaimable_pct = pct or db.NULL, source = "learned", created_by = actor_id,
        reason = "Learned from your decisions: " .. key .. " is " .. label .. "." })
    local rule = db.query("SELECT * FROM vat_rules WHERE registration_id = ? AND lower(match_value) = lower(?)",
        reg.id, key)[1]
    -- Count the businesses that taught the same thing; an admin may promote it.
    local n = db.query([[SELECT COUNT(DISTINCT registration_id) AS n FROM vat_rules WHERE source = 'learned'
        AND registration_id IS NOT NULL AND lower(match_value) = lower(?) AND vat_code = ?]], key, code)[1].n
    db.query([[INSERT INTO vat_rule_candidates (match_type, match_value, vat_code, reclaimable_pct, businesses)
        VALUES ('contains', ?, ?, ?, ?)
        ON CONFLICT (match_type, lower(match_value), vat_code)
        DO UPDATE SET businesses = EXCLUDED.businesses, updated_at = NOW()]], key, code, pct or db.NULL, n)
    return rule
end

function Q.candidates(status)
    return db.query([[SELECT * FROM vat_rule_candidates WHERE status = ? ORDER BY businesses DESC, updated_at DESC
        LIMIT 200]], status or "pending") or {}
end

--- Platform admin: make a candidate a global rule (or dismiss it).
function Q.decide_candidate(uuid, promote, actor_id)
    local c = db.query("SELECT * FROM vat_rule_candidates WHERE uuid = ? LIMIT 1", uuid)[1]
    if not c then return nil, "Not found", 404 end
    if c.status ~= "pending" then return nil, "Already " .. c.status, 409 end
    if promote then
        local exists = db.query([[SELECT 1 FROM vat_rules WHERE registration_id IS NULL AND match_type = ?
            AND lower(match_value) = lower(?)]], c.match_type, c.match_value)
        if exists and #exists > 0 then return nil, "A global rule for that already exists", 409 end
        db.insert("vat_rules", { registration_id = db.NULL, match_type = c.match_type, match_value = c.match_value,
            vat_code = c.vat_code, reclaimable_pct = c.reclaimable_pct, source = "learned", created_by = actor_id,
            reason = string.format("Learned from %d businesses' decisions.", tonumber(c.businesses) or 0) })
    end
    db.update("vat_rule_candidates", { status = promote and "promoted" or "dismissed", decided_by = actor_id,
        decided_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { id = c.id })
    return db.query("SELECT * FROM vat_rule_candidates WHERE id = ?", c.id)[1]
end

-- ---------------------------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------------------------

local RECEIPT_PROMPT = [[Read this UK receipt or invoice. Answer ONLY with JSON:
{"supplier_name": "...", "supplier_vrn": "<VAT number exactly as printed, or empty>",
 "date": "YYYY-MM-DD", "total": <amount paid including VAT>, "vat_amount": <VAT shown, 0 if none>,
 "vat_rate": <20, 5 or 0>}
Use the figures printed on the document; don't calculate anything that isn't shown.]]

--- Read a receipt for one of the business's lines and code it from the receipt.
-- body: { mime = "image/jpeg" | "image/png" | "application/pdf", data = <base64> }
function Q.read_receipt(reg, uuid, body, actor_id)
    body = body or {}
    if type(body.data) ~= "string" or body.data == "" then return nil, "Attach the receipt (base64 data)", 400 end
    if #body.data > 14 * 1024 * 1024 then return nil, "The receipt is too large (max about 10 MB)", 413 end
    local mime = tostring(body.mime or "image/jpeg")
    if not (mime:match("^image/") or mime == "application/pdf") then
        return nil, "Upload an image or a PDF", 415
    end
    local t = VatQueries.find_line(reg, uuid)
    if not t then return nil, "Transaction not found", 404 end

    local Llm = require("lib.agent.llm")
    local msg, err = Llm.chat({ { role = "user", content = RECEIPT_PROMPT,
            attachments = { { mime = mime, data = body.data } } } }, nil,
        { cfg = Llm.vision, json = true, temperature = 0, usage = { feature = "vat_receipt" } })
    if not msg then
        ngx.log(ngx.ERR, "[vat-ai] receipt model call failed: ", tostring(err))
        return nil, "Couldn't read the receipt just now. Try again, or set the VAT yourself.", 502
    end
    local data = decode((msg.content or ""):match("%b{}") or msg.content)
    if not data then return nil, "Couldn't read the receipt's figures", 422 end

    local rc, rerr = VC.from_receipt(t.amount, data)
    if not rc then return nil, rerr, 422 end
    local vf, verr = VatQueries.vat_fields(t.amount, rc.vat_code, { vat_amount = rc.vat_amount })
    if not vf then return nil, verr, 422 end
    local line = { direction = t.transaction_type == "CREDIT" and "sale" or "purchase", amount = tonumber(t.amount),
        description = t.description, category = not null(t.category) and t.category or nil,
        evidence = rc.evidence, vat_amount = rc.vat_amount }
    local suggestion = { vat_code = rc.vat_code, confidence = 0.9, reclaimable_pct = vf.vat_reclaimable_pct }
    local reasons = VC.review_reasons(line, suggestion)
    for _, w in ipairs(rc.warnings) do reasons[#reasons + 1] = w end
    vf.vat_source = "ai"
    vf.vat_confidence = 0.9
    vf.vat_reason = "Read from the receipt"
        .. (data.supplier_name and (" (" .. tostring(data.supplier_name) .. ")") or "")
    vf.vat_evidence = cjson.encode({ has_receipt = true, supplier_vrn = rc.evidence.supplier_vrn,
        supplier_name = data.supplier_name, receipt_date = data.date, receipt_total = tonumber(data.total) })
    vf.vat_registration_id = reg.id
    vf.vat_review = #reasons > 0
    vf.vat_review_reasons = #reasons > 0 and cjson.encode(reasons) or db.NULL
    vf.vat_decided_by = actor_id
    vf.vat_decided_at = db.raw("NOW()")
    vf.updated_at = db.raw("NOW()")
    VatReturnQueries.write_line(t.src, t.id, vf)
    return db.query([[SELECT l.uuid, l.amount, l.vat_code, l.net_amount, l.vat_amount, l.vat_reclaimable_pct,
        l.vat_source, l.vat_reason, l.vat_evidence, l.vat_review, l.vat_review_reasons
        FROM ]] .. VatReturnQueries.lines_from(reg) .. " WHERE l.src = ? AND l.id = ?", t.src, t.id)[1]
end

-- ---------------------------------------------------------------------------
-- Measuring the live model
-- ---------------------------------------------------------------------------

local function eval_lines()
    local paths = { "/app/lib/data/vat-eval.json", "lib/data/vat-eval.json", "lapis/lib/data/vat-eval.json" }
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
            local s = f:read("*a"); f:close()
            local ok, d = pcall(cjson.decode, s)
            if ok and d and d.lines then return d.lines end
        end
    end
    return nil
end

--- Run the labelled set through the live pipeline (global rules + model) in the
-- background; results land in vat_eval_runs.
function Q.start_eval(actor_id)
    local lines = eval_lines()
    if not lines then return nil, "The labelled set (lib/data/vat-eval.json) is missing" end
    db.insert("vat_eval_runs", { status = "running", lines = #lines, started_by = actor_id })
    local run = db.query("SELECT id FROM vat_eval_runs ORDER BY id DESC LIMIT 1")[1]
    local ok, err = ngx.timer.at(0, function(premature)
        if premature then return end
        local ok2, e2 = pcall(function()
            local rules = db.query([[SELECT id, registration_id, match_type, match_value, vat_code, reclaimable_pct,
                reason, is_active FROM vat_rules WHERE is_active AND registration_id IS NULL]]) or {}
            local results, stats = VC.classify(lines, { rules = rules, decisions = {},
                model = model_fn("vat_eval"), decode = cjson.decode, ctx = { scheme = "standard" } })
            local right, pct_right, coded, review, mistakes = 0, 0, 0, 0, {}
            for i, l in ipairs(lines) do
                local r = results[i]
                if r and not r.error then
                    coded = coded + 1
                    if r.vat_code == l.expected then
                        right = right + 1
                        local p = tonumber(r.reclaimable_pct) or ((VAT.code(r.vat_code) or {}).reclaimable)
                        if l.expected == "OUTSIDE" or l.expected == "EXEMPT" or p == l.expected_pct then
                            pct_right = pct_right + 1
                        end
                    else
                        mistakes[#mistakes + 1] = { description = l.description, expected = l.expected,
                            got = r.vat_code, source = r.source, reason = r.reason }
                    end
                    if #(r.review_reasons or {}) > 0 then review = review + 1 end
                else
                    mistakes[#mistakes + 1] = { description = l.description, expected = l.expected, got = "none" }
                end
            end
            local n = #lines
            local Llm = require("lib.agent.llm")
            db.update("vat_eval_runs", {
                status = "done", model = tostring((Llm.default or {}).model or ""),
                accuracy = right / n, pct_accuracy = pct_right / n, review_rate = review / n,
                model_call_rate = (stats.ai + stats.failed) / n,
                stats = cjson.encode(stats), mistakes = cjson.encode(mistakes),
                finished_at = db.raw("NOW()") }, { id = run.id })
        end)
        if not ok2 then
            db.update("vat_eval_runs", { status = "failed", error = tostring(e2):sub(1, 2000),
                finished_at = db.raw("NOW()") }, { id = run.id })
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "[vat-ai] couldn't start the eval: ", tostring(err))
        return nil, "Couldn't start the evaluation just now. Try again in a minute."
    end
    return { id = run.id, status = "running", lines = #lines }
end

function Q.eval_runs()
    local rows = db.query("SELECT * FROM vat_eval_runs ORDER BY id DESC LIMIT 20") or {}
    for _, r in ipairs(rows) do r.stats = decode(r.stats); r.mistakes = decode(r.mistakes) end
    return rows
end

return Q
