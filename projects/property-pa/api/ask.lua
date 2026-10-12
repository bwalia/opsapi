-- PA chat (Week 1): talk to your PA. The agents run in JobShout; OpsAPI checks every answer before it is shown.
--   POST /ask                              { message, mode?, role?, opportunity_uuid?, inputs? } -> 202 run
--   GET  /ask/:id                          my run: running, or the checked answer (polls JobShout if needed)
--   POST /public/jobshout/events           JobShout webhook (run.completed / run.failed), HMAC-signed
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

local cjson = require("cjson")
local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local B = require("property_pa.bridge")

local MODES = { "today", "prepare", "capture", "coach", "ask", "handoff", "manager_today", "teach" }
-- Modes in which the agent proposes or writes (as the pd_agent service account): the person asking must be allowed
-- to make that change themselves. The other modes only read.
local WRITES = { capture = "property_pa_updates", handoff = "property_pa_handoffs", teach = "property_pa_knowledge" }
local MAX_SKEW = 300 -- seconds a webhook timestamp may be off

local function view(r)
    r.input_snapshot = U.json(r.input_snapshot)
    r.output = U.json(r.output)
    if r.output == nil then r.output = cjson.null end
    return r
end

local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local function hmac_hex(secret, msg)
    local resty_hmac = require("resty.hmac")
    local h = resty_hmac:new(secret, resty_hmac.ALGOS.SHA256)
    h:update(msg)
    return hex(h:final())
end

-- constant-time compare
local function same(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    local bit = require("bit")
    for i = 1, #a do diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i))) end
    return diff == 0
end

return function(app)
    app:post("/ask", sdk.handler({ permission = "property_pa_records.read" }, U.guard_create(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local d, errors = sdk.validate(body, {
            message = { type = "text", max = 8000, required = true }, mode = { enum = MODES },
            role = { enum = { "seller_agent", "manager" } }, opportunity_uuid = { type = "uuid" },
        })
        if not d then return sdk.error(422, "Validation failed", errors) end
        d.mode = d.mode or "ask"
        d.role = d.role or (B.MANAGER_ONLY[d.mode] and "manager") or "seller_agent"
        if d.role == "manager" and not sdk.can(self, "property_pa_knowledge", "manage") then
            return sdk.error(403, "Only managers can talk to the Manager PA")
        end
        if B.MANAGER_ONLY[d.mode] and d.role ~= "manager" then
            return sdk.error(422, "Validation failed", { mode = d.mode .. " is a Manager PA mode" })
        end
        if WRITES[d.mode] and not sdk.can(self, WRITES[d.mode], "create") then
            return sdk.error(403, "Permission denied: " .. d.mode .. " mode needs " .. WRITES[d.mode] .. ".create")
        end
        if body.inputs ~= nil and type(body.inputs) ~= "table" then
            return sdk.error(422, "Validation failed", { inputs = "must be an object" })
        end
        d.inputs = body.inputs
        local run = B.ask(ns, me, sdk.settings(self), d)
        return { status = 202, json = { success = true, data = view(run) } }
    end)))

    app:get("/ask/:id", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local run = B.get(ns, self.params.id, me)
        if not run then return sdk.not_found("PA run") end
        if run.status == "running" then run = B.poll(ns, run) end
        return sdk.ok(view(run))
    end)))

    -- JobShout calls this; no user session. The run it names decides the workspace, whose secret must sign it.
    app:post("/public/jobshout/events", sdk.handler({ namespace = false }, U.guard(function(self)
        ngx.req.read_body()
        local raw = ngx.req.get_body_data() or ""
        local headers = ngx.req.get_headers()
        local ts, sig = headers["x-jobshout-timestamp"], headers["x-jobshout-signature"]
        if type(ts) ~= "string" or type(sig) ~= "string" or not tonumber(ts) then
            return sdk.error(401, "Missing signature")
        end
        if math.abs(ngx.time() - tonumber(ts)) > MAX_SKEW then return sdk.error(401, "Stale delivery") end
        local ok, ev = pcall(cjson.decode, raw)
        if not ok or type(ev) ~= "table" or type(ev.data) ~= "table" then return sdk.error(400, "Not a JobShout event") end
        if ev.type ~= "run.completed" and ev.type ~= "run.failed" then return sdk.ok({ ignored = ev.type }) end
        local run_id = ev.data.run_id
        local run = type(run_id) == "string" and U.one([[SELECT namespace_id FROM property_deals_agent_runs
            WHERE provider = ? AND jobshout_run_id = ? LIMIT 1]], B.PROVIDER, run_id)
        -- Not ours (another integration's run): acknowledge so JobShout stops retrying, change nothing.
        if not run then return sdk.ok({ ignored = "unknown run" }) end
        local ns = run.namespace_id
        local secret = sdk.settings("property_pa", ns).jobshout_webhook_secret
        if type(secret) ~= "string" or secret == "" then return sdk.error(401, "Webhook secret not set") end
        if not same("sha256=" .. hmac_hex(secret, ts .. "." .. raw), sig) then return sdk.error(401, "Bad signature") end
        -- Turned off in that workspace: acknowledged (so JobShout stops retrying), nothing applied.
        if not require("helper.plugin-workspaces").isEnabled("property_pa", ns) then
            return sdk.ok({ ignored = "Property PA is off in this workspace" })
        end
        local full = U.one(B.SELECT .. " WHERE namespace_id = ? AND provider = ? AND jobshout_run_id = ?", ns, B.PROVIDER, run_id)
        local done = B.finish(ns, full, ev.data)
        return sdk.ok({ run = done.uuid, status = done.status })
    end)))
end
