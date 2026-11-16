--[[
    Spec: sorting a statement's transactions never waits on one browser request.

    The AI takes from seconds to about a minute per transaction, so a 29-line statement
    ran past the Statements page's 5-minute wait and showed "Failed to classify" while the
    server carried on. Now:
    - classify_batch hands back each finished batch (on_batch), and /tax/classify saves it
      straight away, so progress is real and a crash keeps the rows already done;
    - the Statements page starts the background worker (/tax/statements/process) with its
      profile and re-classify choice, and the worker doesn't re-read a statement already read.

    Run from the repo root: /usr/local/openresty/luajit/bin/luajit lapis/spec/classify-in-background_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end

package.loaded["lapis.db"] = { select = function() return {} end, query = function() return {} end }
_G.ngx = _G.ngx or {}
ngx.thread = {
    spawn = function(fn) return { fn = fn } end,
    wait = function(t) return true, t.fn() end,
}

print("== classify_batch hands back each batch as it finishes")
local C = require("lib.tax-classifier")
C.classify_transaction = function(txn) return { category = "c" .. txn.id, confidence = 0.9 } end
local txns = {}
for i = 1, 5 do txns[i] = { id = i } end
local seen = {}
local results = C.classify_batch(txns, { max_concurrent = 2, on_batch = function(res, from, to)
    seen[#seen + 1] = { from = from, to = to, done = res[to] and res[to].category }
end })
check("three batches of 2, 2, 1", #seen == 3 and seen[1].from == 1 and seen[1].to == 2
    and seen[2].from == 3 and seen[3].from == 5 and seen[3].to == 5, #seen)
check("each batch's rows are ready when it is handed back", seen[1].done == "c2" and seen[3].done == "c5")
check("all results still returned", #results == 5 and results[5].category == "c5")
check("no on_batch: unchanged", #C.classify_batch(txns, { max_concurrent = 2 }) == 5)

print("== /tax/classify saves per batch")
local cls = read("lapis/routes/tax-classify.lua")
local main = cls:match('app:post%("/api/v2/tax/classify",.-\n    %)\n')
check("saves through on_batch", main and main:find("on_batch = save", 1, true) ~= nil)
check("no save loop after the whole batch", main and not main:find("for i, txn in ipairs(transactions)", 1, true))

print("== the worker takes the Statements page's choices")
local proc = read("lapis/routes/tax-process.lua")
check("profile_type from the request (checked), after the landlord chat rule",
    proc:find('classify_profile(session, user_id)\n            or (asked:match("^[%w_]+$")', 1, true) ~= nil)
check("reclassify passed to /tax/classify", proc:find('body .. "&reclassify=true"', 1, true) ~= nil)
check("a statement already read skips extract", proc:find('step ~= "EXTRACTED" and step ~= "CLASSIFIED"', 1, true) ~= nil)

print("== the Statements page follows the job instead of waiting on it")
local page = read("opsapi-dashboard/app/dashboard/tax/statements/page.tsx")
check("Classify starts the background job", page:find("taxService.classifyInBackground(", 1, true) ~= nil)
check("polls the job's status", page:find("taxAgentService.processStatus()", 1, true) ~= nil)
check("the old 5-minute request is gone",
    not read("opsapi-dashboard/services/tax.service.ts"):find("timeout: 300000", 1, true))

if failures > 0 then print(failures .. " FAILED") os.exit(1) end
print("all passed")
