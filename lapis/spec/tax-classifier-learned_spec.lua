--[[
    Spec: the income tax classifier learns from the taxpayer's confirmed history
    (lib/tax-classifier.lua, layer 2.4).

    Checks that a payee confirmed in an earlier year is classified the same way without a
    model call, that ambiguous or new payees still go to the model, that the large-amount
    check accepts a payee seen before at a similar size, and that similar-example lookup
    never runs without a namespace.

    Standalone: run in the API image from the repo root:
        docker run --rm -v "$PWD:/w" -w /w bwalia/opsapi:latest \
            /usr/local/openresty/luajit/bin/luajit lapis/spec/tax-classifier-learned_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end

-- Stubs: ngx, the database and the model client.
_G.ngx = _G.ngx or { log = function() end, WARN = 4, ERR = 3, INFO = 7 }
local queries = {}
package.loaded["lapis.db"] = {
    select = function() return {} end,
    query = function(sql, ...) queries[#queries + 1] = sql; return {} end,
    NULL = {},
}
package.loaded["lib.merchant-cleaner"] = {
    clean_merchant_name = function(d) return tostring(d or ""):upper() end,
}
local model_calls, embed_calls = 0, 0
package.loaded["lib.llm-client"] = {
    classify = function()
        model_calls = model_calls + 1
        return { category = "repairs_property", confidence = 0.9, reasoning = "model" }
    end,
    generate_embedding = function() embed_calls = embed_calls + 1; return { embedding = { 0.1, 0.2 } } end,
}

local C = require("lib.tax-classifier")

print("== payee keys")
check("references and months are ignored",
    C.learn_key("HARTWELL LETTINGS RENT REMITTANCE REF 0425 APR") == "hartwell lettings rent remittance ref",
    C.learn_key("HARTWELL LETTINGS RENT REMITTANCE REF 0425 APR"))
check("same payee, different month, same key",
    C.learn_key("KESTREL COFFEE CO QTR RENT JUN 24") == C.learn_key("KESTREL COFFEE CO QTR RENT SEP 25"))
check("too short to learn", C.learn_key("12 / 4") == nil)
check("tax year from a date (before 6 April)", C._uk_tax_year("2025-04-05") == "2024-25")
check("tax year from a date (6 April on)", C._uk_tax_year("2025-04-06") == "2025-26")

print("== building the memory")
local past = {}
for m = 1, 12 do
    past[#past + 1] = { description = "HARTWELL LETTINGS RENT REMITTANCE", transaction_type = "CREDIT",
        category = "rental_income", hmrc_category = "property_income", amount = 26000 + m,
        transaction_date = string.format("2024-%02d-27", (m % 12) + 1) }
    past[#past + 1] = { description = "BIRCHWOOD BUILDING SOCIETY BTL MORTGAGE", transaction_type = "DEBIT",
        category = "transfer", hmrc_category = nil, amount = 16850, transaction_date = "2024-06-01" }
end
-- An ambiguous payee: 2 of 3 agree, below the 80% bar.
past[#past + 1] = { description = "CLEARVIEW WINDOWS LTD", transaction_type = "DEBIT", category = "repairs_property",
    amount = 900, transaction_date = "2024-07-01" }
past[#past + 1] = { description = "CLEARVIEW WINDOWS LTD", transaction_type = "DEBIT", category = "repairs_property",
    amount = 700, transaction_date = "2024-08-01" }
past[#past + 1] = { description = "CLEARVIEW WINDOWS LTD", transaction_type = "DEBIT", category = "capital_allowances",
    amount = 7000, transaction_date = "2024-09-01" }
local mem = C.build_learned_memory(past)
check("memory built", mem ~= nil)
check("rent remittance learned as rental income",
    mem and mem["hartwell lettings rent remittance|C"] and mem["hartwell lettings rent remittance|C"].category == "rental_income")
check("direction is part of the key", mem and mem["hartwell lettings rent remittance|D"] == nil)
check("ambiguous payee is not learned", mem and mem["clearview windows ltd|D"] == nil)
check("nothing to learn from nothing", C.build_learned_memory({}) == nil)

print("== matching")
local valid = { rental_income = true, transfer = true, repairs_property = true }
local hit = C.learned_match(mem, "HARTWELL LETTINGS RENT REMITTANCE 0526", true, valid)
check("same payee next year matches", hit and hit.category == "rental_income" and hit.classified_by == "learned")
check("reasoning names the year it was learned from", hit and hit.reasoning:find("2024%-25") ~= nil, hit and hit.reasoning)
check("new payee does not match", C.learned_match(mem, "NEW TENANT LTD", true, valid) == nil)
check("a retired category is not reused",
    C.learned_match(mem, "HARTWELL LETTINGS RENT REMITTANCE", true, { transfer = true }) == nil)

print("== the pipeline")
local cats = { { name = "rental_income" }, { name = "transfer" }, { name = "repairs_property" } }
local meta = {
    rental_income = { income = true, hmrc_key = "property_income", deductible = false },
    transfer = { income = false, deductible = false },
    repairs_property = { income = false, hmrc_key = "repairs", deductible = true },
}
local opts = { categories = cats, cat_meta = meta, learned = mem, guidance = false, box_map = {} }
local r = C.classify_transaction({ description = "HARTWELL LETTINGS RENT REMITTANCE", amount = 27500,
    transaction_type = "CREDIT" }, opts)
check("learned payee: no model call", model_calls == 0, model_calls)
check("learned payee: classified and not flagged", r.category == "rental_income" and not r.needs_review,
    r.reasoning)
check("learned payee: marked as learned", r.classified_by == "learned")
check("internal size hint is not returned", r.learned_max_abs == nil)

local big = C.classify_transaction({ description = "HARTWELL LETTINGS RENT REMITTANCE", amount = -90000,
    transaction_type = "DEBIT" }, opts)
check("same payee the other way round is not learned", big.classified_by ~= "learned")

local before = model_calls
local n = C.classify_transaction({ description = "PLUMBFAST LTD BOILER REPAIR", amount = 400,
    transaction_type = "DEBIT" }, opts)
check("new payee goes to the model", model_calls == before + 1 and n.classified_by == "ai")
check("no namespace: no similar-example lookup", embed_calls == 0, embed_calls)

opts.namespace_id = 7
C.classify_transaction({ description = "SPARKWELL ELECTRICAL", amount = 300, transaction_type = "DEBIT" }, opts)
local scoped = false
for _, q in ipairs(queries) do
    if q:find("classification_training_data", 1, true) and q:find("namespace_id = 7", 1, true) then scoped = true end
end
check("similar-example lookup is limited to the namespace", embed_calls == 1 and scoped)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
