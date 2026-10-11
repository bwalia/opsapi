-- Captures and proposed updates: the only way the PA changes a record.
--   POST /captures                       { interaction | interaction_uuid, proposals: [...], model?, prompt_version?,
--                                          run_ref? } -> the interaction + one proposed update per field
--   GET  /proposed-updates               ?status=proposed&capture_uuid=&target_uuid=
--   GET  /proposed-updates/:id
--   POST /proposed-updates/:id/confirm
--   POST /proposed-updates/:id/correct   { value }
--   POST /proposed-updates/:id/reject
--
-- Grounded or silent: a proposal that is not marked is_inferred must quote the interaction (source_quote) and the
-- quote must be in its text, and any figure in the new value must appear in that quote. Otherwise it is refused.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

local cjson = require("cjson")
local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local P = require("property_pa.updates")
local I = require("property_pa.interactions")
local G = require("property_pa.grounding")

local function norm(s) return (tostring(s or ""):lower():gsub("[%s%p]+", " "):gsub("^ ", ""):gsub(" $", "")) end

--- Check each non-inferred proposal against the interaction text. @return errors table (empty when fine)
local function ungrounded(items, text)
    local errors = {}
    local hay = norm(text)
    for i, it in ipairs(items) do
        if it.is_inferred ~= true then
            local q = it.source_quote
            if type(q) ~= "string" or #norm(q) < 3 or not hay:find(norm(q), 1, true) then
                errors[tostring(i)] = "not grounded: quote the interaction in source_quote, or mark it is_inferred"
            else
                local in_quote = {}
                for _, n in ipairs(G.figures(q, true)) do in_quote[n] = true end
                local figures = G.figures(type(it.new_value) == "table" and cjson.encode(it.new_value) or tostring(it.new_value))
                for _, n in ipairs(figures) do
                    if not in_quote[n] then
                        errors[tostring(i)] = "not grounded: " .. string.format("%.0f", n) .. " is not in the quote"
                    end
                end
            end
        end
    end
    return errors
end

return function(app)
    app:post("/captures", sdk.handler({ permission = "property_pa_updates.create" }, U.guard_create(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local meta = sdk.validate(body, { model = { type = "string", max = 160 }, prompt_version = { type = "string", max = 80 },
            run_ref = { type = "string", max = 120 }, interaction_uuid = { type = "string", max = 64 } }) or {}
        local proposals = body.proposals
        if type(proposals) ~= "table" or #proposals == 0 or #proposals > 50 then
            return sdk.error(422, "Validation failed", { proposals = "1 to 50 proposed updates" })
        end
        local interaction
        if type(meta.interaction_uuid) == "string" then
            interaction = I.get(ns, meta.interaction_uuid)
            if not interaction then return sdk.error(422, "Validation failed", { interaction_uuid = "not found" }) end
        elseif type(body.interaction) == "table" then
            local d, errors = sdk.validate(body.interaction, I.RULES)
            if not d then return sdk.error(422, "Validation failed", { interaction = errors }) end
            for k, v in pairs(d) do if v == db.NULL then d[k] = nil end end
            if not (d.raw_text or d.transcript or d.summary) then
                return sdk.error(422, "Validation failed", { interaction = "raw_text, transcript or summary is required" })
            end
            d.source = "human"
            -- Validate the proposals before logging anything.
            local errors = ungrounded(proposals, table.concat({ d.raw_text or "", d.transcript or "", d.summary or "" }, "\n"))
            if next(errors) then return sdk.error(422, "Validation failed", { proposals = errors }) end
            interaction = I.log(ns, d, me)
        else
            return sdk.error(422, "Validation failed", { interaction = "interaction or interaction_uuid is required" })
        end
        local errors = ungrounded(proposals, I.text(ns, interaction.uuid))
        if next(errors) then return sdk.error(422, "Validation failed", { proposals = errors }) end
        -- Audit (P10): a capture the PA makes for a capture run is tied to that run, its model and prompt version.
        local pa_run = U.one([[SELECT uuid, model, prompt_version FROM property_deals_agent_runs WHERE namespace_id = ?
            AND provider = 'jobshout-pa' AND input_snapshot ->> 'interaction_uuid' = ? ORDER BY id DESC LIMIT 1]],
            ns, interaction.uuid)
        if pa_run then
            meta.run_ref = meta.run_ref or pa_run.uuid
            if not meta.model and pa_run.model ~= db.NULL then meta.model = pa_run.model end
        end
        local hv = ngx.req.get_headers()["x-jobshout-prompt-version"]
        if not meta.prompt_version and type(hv) == "string" and #hv <= 80 then meta.prompt_version = hv end
        local capture = db.query("SELECT gen_random_uuid() AS u")[1].u
        local rows, perrs = P.propose(ns, proposals, { capture_uuid = capture, source_interaction_uuid = interaction.uuid,
            model = meta.model, prompt_version = meta.prompt_version, run_ref = meta.run_ref }, sdk.settings(self))
        if not rows then return sdk.error(422, "Validation failed", { proposals = perrs }) end
        return { status = 201, json = { success = true, data = {
            capture_uuid = capture, interaction = interaction, proposed_updates = rows } } }
    end)))

    app:get("/proposed-updates", sdk.handler({ permission = "property_pa_updates.read" }, U.guard(function(self)
        return sdk.ok(P.list(sdk.namespace_id(self), self.params))
    end)))

    app:get("/proposed-updates/:id", sdk.handler({ permission = "property_pa_updates.read" }, U.guard(function(self)
        local r = P.get(sdk.namespace_id(self), self.params.id)
        if not r then return sdk.not_found("Proposed update") end
        return sdk.ok(r)
    end)))

    for _, action in ipairs({ "confirm", "correct", "reject" }) do
        app:post("/proposed-updates/:id/" .. action, sdk.handler({ permission = "property_pa_updates.update" },
            U.guard(function(self)
                local value
                if action == "correct" then
                    local body, err = sdk.body(self)
                    if not body then return sdk.error(400, err) end
                    if body.value == nil then return sdk.error(422, "Validation failed", { value = "is required" }) end
                    value = body.value
                end
                return sdk.ok(P.decide(sdk.namespace_id(self), self.params.id, action, value, sdk.user(self).uuid,
                    sdk.settings(self)))
            end)))
    end
end
