--[[
    Regression spec: what two or more API pods need beyond chat (the audit in PR #698).

    Standalone — run from the repo root with:
        luajit lapis/spec/multi-pod_spec.lua

    Live proof (two pods, one Redis): lapis/spec/chat-pubsub-e2e/run.sh covers
    kanban events, the delivery-partner code and a per-route rate limit across pods.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = io.open(path) or assert(io.open((path:gsub("^lapis/", ""))))
    local s = h:read("*a")
    h:close()
    return s
end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

print("secrets come from the CSPRNG:")
local Uuid = require("helper.uuid")
local seen, counts, draws = {}, {}, 0
for _ = 1, 2000 do
    local s = Uuid.random_string(30, "0123456789")
    seen[s] = true
    for c in s:gmatch(".") do counts[c] = (counts[c] or 0) + 1; draws = draws + 1 end
end
local n_unique = 0
for _ in pairs(seen) do n_unique = n_unique + 1 end
check("random_string: 2000 draws, all different", n_unique == 2000, n_unique)
local lo, hi = math.huge, 0
for d = 0, 9 do
    local c = counts[tostring(d)] or 0
    lo, hi = math.min(lo, c), math.max(hi, c)
end
check("random_string: digits evenly spread (no modulo bias)", lo > draws / 10 * 0.9 and hi < draws / 10 * 1.1,
    lo .. ".." .. hi)
check("random_string: only the alphabet", not Uuid.random_string(500, "ab"):find("[^ab]"))
check("Google sign-up passwords use it", has(read("lapis/helper/global.lua"),
    'return Uuid.random_string(16, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*")'))
for _, f in ipairs({ "lapis/queries/EmployeeQueries.lua", "lapis/queries/NamespaceInvitationQueries.lua",
    "lapis/routes/delivery-partner-verification.lua" }) do
    local src = read(f)
    check(f .. ": no math.random / randomseed", not src:find("math.random", 1, true) and has(src, "random_string("))
end
for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    check(conf .. ": each worker seeds math.random from the CSPRNG",
        has(read(conf), 'require("resty.random").bytes(4)') and has(read(conf), "math.randomseed(seed"))
end

print("rate limits hold across pods:")
local rl = read("lapis/middleware/rate-limit.lua")
check("RateLimit.check counts through RateLimit.incr (Redis, else shared memory)",
    has(rl, 'RateLimit.incr("rl:" .. key, window, local_only)') and has(rl, "red:eval(INCR, 1, key, window)")
    and has(rl, "dict:incr(key, 1, 0, window)"))
check("the global limit stays in-pod (no Redis hop per request)",
    has(read("lapis/middleware/global-rate-limit.lua"), "local_only = true"))
check("billing counters share the same code", has(read("lapis/lib/billing-guard.lua"),
    'RateLimit.incr("billing:" .. key, window)'))

print("delivery-partner phone codes:")
local dp = read("lapis/routes/delivery-partner-verification.lua")
check("stored in Postgres, not a per-pod table", has(dp, "INSERT INTO delivery_partner_otps")
    and not has(dp, "otp_storage"))
check("hashed, bound to the user and the profile phone", has(dp, "code_hash(user_id, phone, otp)")
    and has(dp, "digits(delivery_partner.contact_person_phone)"))
check("attempts capped", has(dp, "row.attempts >= MAX_ATTEMPTS") and has(dp, "attempts = attempts + 1"))
check("production answers 503 instead of revealing the code", has(dp, "if is_production() then")
    and has(dp, "status = 503"))
check("migration registered under the delivery feature",
    has(read("lapis/migrations.lua"), "['zzdp1_delivery_partner_otps'] = conditional_array(ProjectConfig.FEATURES.DELIVERY"))

print("kanban live board across pods:")
local kws = read("lapis/lib/kanban-ws.lua")
check("broadcast delivers here, then relays to other pods",
    has(kws, "fanout(project_id, payload)\n    ChatWS.relay_publish(\"kanban\", project_id, payload)"))
check("frames from other pods only enqueue", has(kws, 'ChatWS.relay("kanban", fanout)')
    and not kws:sub(kws:find("local function fanout", 1, true), kws:find("function _M.broadcast", 1, true)):find("send_"))
local cws = read("lapis/lib/chat-ws.lua")
check("chat-ws relays without a second Redis subscription", has(cws, "function _M.relay(name, deliver_fn)")
    and has(cws, "local relay = relays[m.r[1]]") and select(2, cws:gsub("psubscribe", "")) == 1)

print("monitoring:")
check("the Service carries the label the ServiceMonitor selects", has(
    read("devops/helm-charts/diytaxreturn-lapis/templates/service.yaml"), "  labels:\n    app: {{ .Release.Name }}"))

print(failures == 0 and "\nall multi-pod checks passed" or ("\n" .. failures .. " check(s) FAILED"))
os.exit(failures == 0 and 0 or 1)
