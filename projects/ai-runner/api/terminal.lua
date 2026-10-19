-- Public terminal webhook from workstation-terminal (sshweb).
--   POST /public/terminal/webhook   HMAC-SHA256 (X-Opsapi-Signature: sha256=<hex>)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local cjson = require("cjson.safe")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local T = require("ai_runner.terminal")

return function(app)
    app:post("/public/terminal/webhook", sdk.handler({ namespace = false }, U.guard(function(self)
        if not T.webhook_secret() then
            return sdk.error(503, "Terminal webhook is not configured")
        end
        ngx.req.read_body()
        local raw = ngx.req.get_body_data() or ""
        local headers = ngx.req.get_headers()
        local sig = headers["x-opsapi-signature"] or headers["X-Opsapi-Signature"]
        if type(sig) == "table" then sig = sig[1] end
        if not T.verify_signature(raw, sig) then
            return sdk.error(401, "Invalid signature")
        end
        local payload = cjson.decode(raw)
        if type(payload) ~= "table" then U.fail(400, "Invalid JSON") end
        local row, err = T.apply_webhook(payload)
        if not row then U.fail(400, err or "webhook rejected") end
        return sdk.ok(T.view(row))
    end)))
end
