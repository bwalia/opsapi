-- Week 2 capture: note in, confirm sheet out.
--   POST /captures/start               { text, channel?, opportunity_uuid?, person_uuid?, audio_document_uuid? }
--                                      log the note (stored as data) and ask the PA to propose the changes
--   GET  /interactions/:id/capture     the confirm sheet: stated / inferred / proposed rows, old -> new, the quote,
--                                      material flags, and the PA run (polled while it is running)
--   POST /interactions/:id/decide      { decisions: [{ uuid, action, value? }], confirm_rest? } confirm / correct /
--                                      reject rows; confirm_rest confirms the rest ([Confirm] on the sheet)
-- Voice: the dashboard records, /api/v2/voice/transcribe (our own STT, PA_STT_URL) returns the text, and that
-- text is sent here with channel "voice".
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

local cjson = require("cjson")
local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local C = require("property_pa.capture")
local B = require("property_pa.bridge")
local I = require("property_pa.interactions")

return function(app)
    app:post("/captures/start", sdk.handler({ permission = "property_pa_records.create" }, U.guard_create(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local d, errors = sdk.validate(body, {
            text = { type = "text", max = 50000, required = true },
            channel = { enum = { "voice", "note", "call", "meeting", "email", "whatsapp", "sms" } },
            opportunity_uuid = { type = "uuid" }, person_uuid = { type = "string", max = 64 },
            audio_document_uuid = { type = "uuid" },
        })
        if not d then return sdk.error(422, "Validation failed", errors) end
        local channel = d.channel or "note"
        local it = I.log(ns, { channel = channel, direction = "internal",
            transcript = channel == "voice" and d.text or nil, raw_text = channel ~= "voice" and d.text or nil,
            opportunity_uuid = d.opportunity_uuid, person_uuid = d.person_uuid,
            audio_document_uuid = d.audio_document_uuid, source = "human" }, me)
        -- The PA proposes the changes; if it isn't connected the note is still saved.
        local ok, run = pcall(B.ask, ns, me, sdk.settings(self), {
            mode = "capture", role = "seller_agent", opportunity_uuid = d.opportunity_uuid, interaction_uuid = it.uuid,
            message = "Capture this " .. (channel == "voice" and "voice note" or "note") .. " (interaction "
                .. it.uuid .. "). Propose every change it supports, then the next action.\n\n" .. d.text,
        })
        local pa
        if ok then
            pa = { run_uuid = run.uuid, status = run.status }
        elseif type(run) == "table" and run.pd_error then
            pa = { error = run.message } -- our own words: B.ask logs JobShout's and never passes them on
        else
            ngx.log(ngx.ERR, "[property_pa] capture run: ", tostring(run))
            pa = { error = "The PA couldn't be asked" }
        end
        return { status = 201, json = { success = true, data = { interaction = it, pa = pa } } }
    end)))

    app:get("/interactions/:id/capture", sdk.handler({ permission = "property_pa_updates.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local id = tostring(self.params.id or "")
        local sheet = C.sheet(ns, id)
        if not sheet then return sdk.not_found("Interaction") end
        if sheet.run ~= cjson.null and sheet.run.status == "running" then
            local run = U.one(B.SELECT .. " WHERE namespace_id = ? AND uuid = ?::uuid", ns, sheet.run.uuid)
            if run then B.poll(ns, run) end
            sheet = C.sheet(ns, id)
        end
        return sdk.ok(sheet)
    end)))

    app:post("/interactions/:id/decide", sdk.handler({ permission = "property_pa_updates.update" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        if body.decisions ~= nil and type(body.decisions) ~= "table" then
            return sdk.error(422, "Validation failed", { decisions = "a list" })
        end
        if (body.decisions == nil or #body.decisions == 0) and body.confirm_rest ~= true then
            return sdk.error(422, "Validation failed", { decisions = "nothing to decide" })
        end
        local out = C.decide(sdk.namespace_id(self), tostring(self.params.id or ""), body.decisions or {},
            body.confirm_rest == true, sdk.user(self).uuid, sdk.settings(self))
        return sdk.ok(out)
    end)))
end
