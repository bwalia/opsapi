-- Inbound reply list + manual ingest (webhooks / agent assist). Never auto-sends.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local Replies = require("opsapi_marketing.replies")
local U = require("opsapi_marketing.util")

return function(app)
    app:get("/replies", sdk.handler({ permission = "opsapi_marketing_conversations.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local rows = Replies.list(ns, {
            page = self.params.page,
            per_page = self.params.per_page,
            classification = self.params.classification,
            campaign_id = self.params.campaign_id,
        })
        return sdk.ok({ data = sdk.array(rows) })
    end))

    app:get("/replies/:id", sdk.handler({ permission = "opsapi_marketing_conversations.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local row = U.one("SELECT * FROM mkt_replies WHERE namespace_id = ? AND (uuid = ? OR id::text = ?)",
            ns, self.params.id, self.params.id)
        if not row then return sdk.not_found("reply") end
        return sdk.ok(row)
    end))

    -- Manual / webhook-style ingest (authenticated). Classification side-effects run in code.
    app:post("/replies/ingest", sdk.handler({ permission = "opsapi_marketing_conversations.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local body = sdk.body(self) or {}
        local out = Replies.ingest(ns, body)
        if out.duplicate then
            return sdk.ok(out)
        end
        return { status = 201, json = { success = true, data = out } }
    end))

    app:post("/replies/classify-preview", sdk.handler({ permission = "opsapi_marketing_conversations.read" }, function(self)
        local body = sdk.body(self) or {}
        local class, conf = Replies.classify_text(body.subject, body.body_text or body.text)
        return sdk.ok({
            classification = class,
            confidence = conf,
            auto_send = false,
            note = "Preview only — nothing stored or sent.",
        })
    end))
end
