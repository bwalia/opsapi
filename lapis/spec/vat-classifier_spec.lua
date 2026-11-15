--[[
    Spec: AI VAT coding that learns (lib/vat-classifier.lua).

    Measures the deterministic layers on a labelled set of UK bank lines
    (lib/data/vat-eval.json) and checks the pipeline with a stubbed model:
    rules > memory > model, strict checking of model output, the risk checks,
    receipts, and when a supplier rule is learned. The live model is measured on
    int with POST /api/v2/vat/admin/eval.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-classifier_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local cjson = require("cjson")
local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

local VC = require("lib.vat-classifier")
local SEED = require("lib.vat-seed-rules")

local f = io.open("lapis/lib/data/vat-eval.json"):read("*a")
local eval = cjson.decode(f).lines

local rules = {}
for i, r in ipairs(SEED) do
    rules[#rules + 1] = { id = i, match_type = r[1], match_value = r[2], vat_code = r[3], reclaimable_pct = r[4],
        reason = r[5] }
end

print("== the starting rules on " .. #eval .. " labelled lines")
local covered, right, wrong = 0, 0, {}
local results = VC.classify(eval, { rules = rules })
for i, l in ipairs(eval) do
    local r = results[i]
    if r.source == "rule" then
        covered = covered + 1
        if r.vat_code == l.expected then right = right + 1
        else wrong[#wrong + 1] = l.description .. " -> " .. r.vat_code .. " (expected " .. l.expected .. ")" end
    end
end
print(string.format("     rules code %d of %d lines (%.0f%%); %d of those right (%.0f%%)", covered, #eval,
    covered / #eval * 100, right, covered > 0 and right / covered * 100 or 0))
for _, w in ipairs(wrong) do print("     wrong: " .. w) end
check("rules are right on every line they code", #wrong == 0, #wrong)
check("rules code at least a third of typical lines", covered >= #eval / 3, covered)
check("congestion charge beats the TFL zero-rate rule", (function()
    local r = VC.classify({ { description = "CONGESTION CHARGE TFL", direction = "purchase", amount = 15 } },
        { rules = rules })[1]
    return r.vat_code == "OUTSIDE"
end)())

print("== memory: what this business decided before")
local decisions = {
    { key = VC.memory_key({ description = "PROPDESK LTD REF 2931" }), vat_code = "STD20", reclaimable_pct = 100,
      description = "PROPDESK LTD REF 2931", direction = "purchase" },
    { key = VC.memory_key({ description = "PROPDESK LTD REF 3001" }), vat_code = "STD20", reclaimable_pct = 100,
      description = "PROPDESK LTD REF 3001", direction = "purchase" },
}
check("supplier key ignores reference numbers", VC.memory_key({ description = "PROPDESK LTD REF 2931" })
    == VC.memory_key({ description = "Propdesk Ltd ref 77" }), VC.memory_key({ description = "PROPDESK LTD REF 2931" }))
local m = VC.from_memory(decisions, { description = "PROPDESK LTD REF 4100" })
check("remembers the business's decision, with confidence 0.95", m and m.vat_code == "STD20" and m.confidence == 0.95)
check("unknown supplier: no memory", VC.from_memory(decisions, { description = "NEW SUPPLIER LTD" }) == nil)
local key = VC.memory_key({ description = "PROPDESK LTD" })
check("two agreeing decisions -> learn a rule", VC.should_learn(decisions, key) == "STD20")
check("one decision -> not yet", VC.should_learn({ decisions[1] }, key) == nil)
check("a disagreeing decision -> never", VC.should_learn({ decisions[1], decisions[2],
    { key = key, vat_code = "ZERO", reclaimable_pct = 100 } }, key) == nil)

print("== the model step (stubbed)")
local calls = 0
local function perfect_model(messages)
    calls = calls + 1
    -- answer from the labelled set, matching by the description in the prompt
    local out = {}
    local i = 0
    for line in messages[2].content:gmatch("[^\n]+") do
        local n, desc = line:match("^(%d+)%. (.-) |")
        if n then
            i = i + 1
            for _, l in ipairs(eval) do
                if l.description == desc then
                    out[#out + 1] = { i = tonumber(n), vat_code = l.expected, reclaimable_pct = l.expected_pct,
                        confidence = 0.9, reason = "stub" }
                end
            end
        end
    end
    return cjson.encode({ lines = out })
end
local res, stats = VC.classify(eval, { rules = rules, decisions = {}, model = perfect_model, decode = cjson.decode,
    ctx = { scheme = "standard", business_name = "Test Ltd" } })
local all_right = true
for i, l in ipairs(eval) do
    if res[i].error or (res[i].source == "ai" and res[i].vat_code ~= l.expected) then all_right = false end
end
check("every line gets a code (rules, then the model)", stats.failed == 0 and stats.rule + stats.ai == #eval,
    cjson.encode(stats))
check("model answers land on the right lines", all_right)
check("batched: " .. stats.model_calls .. " model call(s) for " .. stats.ai .. " lines",
    stats.model_calls == math.ceil(stats.ai / VC.BATCH))
check("prompt includes the codes and the business", (function()
    local msgs = VC.messages({ eval[1] }, { scheme = "flat_rate", business_name = "Acme" })
    return msgs[1].content:find("RC_SERVICES", 1, true) and msgs[2].content:find("Acme", 1, true)
        and msgs[2].content:find("flat_rate", 1, true)
end)() and true or false)

print("== model output is checked, never trusted")
local p = VC.parse('{"lines":[{"i":1,"vat_code":"STD20","confidence":1.7,"reclaimable_pct":250},'
    .. '{"i":2,"vat_code":"MADE_UP"},{"i":9,"vat_code":"ZERO"},{"i":3,"vat_code":"zero","confidence":0.4}]}', 3,
    cjson.decode)
check("confidence clamped to 1, bad % falls back to the code's default", p[1] and p[1].confidence == 1
    and p[1].reclaimable_pct == 100)
check("unknown code dropped", p[2] == nil)
check("out-of-range line number dropped", p[9] == nil)
check("code case-insensitive", p[3] and p[3].vat_code == "ZERO")
check("prose around the JSON is tolerated", VC.parse('Sure! {"lines":[{"i":1,"vat_code":"EXEMPT"}]} hope that helps',
    1, cjson.decode)[1].vat_code == "EXEMPT")
check("garbage -> nothing", next(VC.parse("not json", 2, cjson.decode)) == nil)
local res2, st2 = VC.classify({ { description = "UNKNOWN THING", direction = "purchase", amount = 10 } },
    { rules = {}, model = function() return "I don't know" end, decode = cjson.decode })
check("unusable answer -> the line is left for a person", res2[1].error ~= nil and st2.failed == 1)

print("== risk checks")
local function reasons(line, s) return VC.review_reasons(line, s) end
check("low confidence", #reasons({ direction = "purchase", amount = 10, description = "X" },
    { vat_code = "STD20", confidence = 0.5 }) == 1)
check("£400 VAT reclaimed with no receipt", reasons({ direction = "purchase", amount = 2400, description = "SUPPLIER" },
    { vat_code = "STD20", confidence = 0.9, reclaimable_pct = 100 })[1]:find("receipt") ~= nil)
check("…but fine with a receipt", #reasons({ direction = "purchase", amount = 2400, description = "SUPPLIER",
    evidence = { has_receipt = true } }, { vat_code = "STD20", confidence = 0.9 }) == 0)
check("£40 VAT without a receipt is fine", #reasons({ direction = "purchase", amount = 240, description = "X" },
    { vat_code = "STD20", confidence = 0.9 }) == 0)
check("entertainment", #reasons({ direction = "purchase", amount = 60, category = "client_entertainment",
    description = "DINNER" }, { vat_code = "STD20", confidence = 0.9, reclaimable_pct = 0 }) == 1)
check("cars", #reasons({ direction = "purchase", amount = 60, category = "vehicle_fuel", description = "SHELL" },
    { vat_code = "STD20", confidence = 0.9 }) == 1)
check("reverse charge", #reasons({ direction = "purchase", amount = 60, description = "SLACK LLC" },
    { vat_code = "RC_SERVICES", confidence = 0.9 }) == 1)
check("bad supplier VAT number", #reasons({ direction = "purchase", amount = 60, description = "X",
    evidence = { has_receipt = true, supplier_vrn = "123456789" } }, { vat_code = "STD20", confidence = 0.9 }) == 1)
check("sales don't need receipts", #reasons({ direction = "sale", amount = 12000, description = "INVOICE 1" },
    { vat_code = "STD20", confidence = 0.9 }) == 0)

print("== receipts")
local rc = VC.from_receipt(130, { total = 130, vat_amount = 21.67, vat_rate = 20, supplier_vrn = "GB980780684" })
check("20% receipt -> STD20 with the receipt's VAT and a valid VRN", rc.vat_code == "STD20" and rc.vat_amount == 21.67
    and rc.evidence.supplier_vrn == "980780684" and rc.evidence.has_receipt and #rc.warnings == 0)
rc = VC.from_receipt(100, { total = 105, vat_amount = 5, vat_rate = 5, supplier_vrn = "123456789" })
check("5% receipt; total mismatch and bad VRN warned", rc.vat_code == "RED5" and #rc.warnings == 2)
check("VAT larger than the payment is refused", VC.from_receipt(10, { vat_amount = 20, vat_rate = 20 }) == nil)
check("no rate or VAT on the receipt -> refused", VC.from_receipt(10, { total = 10 }) == nil)

print("== the model is made consistent with itself across batches")
local hl = {
    { description = "HARBOUR BLOCK MGMT SERVICE CHARGE", direction = "purchase", amount = 400 },
    { description = "HARBOUR BLOCK MGMT SERVICE CHARGE", direction = "purchase", amount = 400 },
    { description = "HARBOUR BLOCK MGMT SERVICE CHARGE", direction = "purchase", amount = 400 },
    { description = "ROOFLINE REPAIRS LTD", direction = "purchase", amount = 900 },
    { description = "ROOFLINE REPAIRS LTD", direction = "purchase", amount = 120 },
}
local hr = {
    { source = "ai", vat_code = "EXEMPT", reclaimable_pct = 0, confidence = 0.9, review_reasons = {} },
    { source = "ai", vat_code = "STD20", reclaimable_pct = 100, confidence = 0.9, review_reasons = {} },
    { source = "ai", vat_code = "EXEMPT", reclaimable_pct = 0, confidence = 0.9, review_reasons = {} },
    { source = "ai", vat_code = "STD20", reclaimable_pct = 100, confidence = 0.9, review_reasons = {} },
    { source = "ai", vat_code = "STD20", reclaimable_pct = 100, confidence = 0.9, review_reasons = {} },
}
hr[2].review_reasons = { "£80.00 of VAT reclaimed without a VAT receipt." } -- from its standard-rated guess
local touched = VC.harmonise(hl, hr)
check("the old code's warnings are dropped when the code changes",
    #hr[2].review_reasons == 1 and hr[2].review_reasons[1]:find("differently") ~= nil, hr[2].review_reasons[1])
check("the odd one out takes the majority answer", hr[2].vat_code == "EXEMPT" and hr[2].reclaimable_pct == 0)
check("every line of that supplier is flagged to confirm", touched == 3 and #hr[1].review_reasons == 1
    and #hr[3].review_reasons == 1, touched)
check("a supplier coded the same way everywhere is left alone",
    #hr[4].review_reasons == 0 and #hr[5].review_reasons == 0)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
