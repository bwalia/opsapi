--[[
    Forms + AI: draft a form from a description, summarise its responses
    ====================================================================

    Both go through Llm.chat (lib/agent/llm.lua), metered as feature "forms"
    in ai_usage and subject to AI_USER_DAILY_TOKEN_LIMIT.

    generate(): the model proposes title/description/fields/targets as JSON;
    every field is put through Fields.normalize on its own, so one bad field
    is dropped (and counted) instead of failing the whole draft. Nothing is
    saved: the builder shows it and the user decides.

    summarise(): counts and averages are computed here, exactly; the model
    only writes the narrative, from answers to free-text questions with the
    contact questions (name, email, phone, address) left out.
]]

local db = require("lapis.db")
local cjson = require("lib.forms.json")
local Fields = require("lib.forms.fields")
local Targets = require("lib.forms.targets")

local AI = {}

AI.MAX_FIELDS = 40
AI.SAMPLE = 60

local TYPES_HELP = "short_text, long_text, email, phone, number, date, time, url, single_select (dropdown), radio, "
    .. "multi_select (checkboxes), boolean (yes/no), rating, consent, name, address, file_upload, hidden, heading, "
    .. "paragraph, page_break"

local GENERATE_PROMPT = [[You design web forms for a business. Reply with JSON only, no prose:
{"title": "...", "description": "...", "fields": [{"label": "...", "type": "...", "required": true|false,
"options": ["..."], "help": "...", "text": "..."}], "create_records": ["customer" | "lead" | "user"]}
Field types: ]] .. TYPES_HELP .. [[.
Rules: choice types (single_select, radio, multi_select) need "options". "consent" and "paragraph" need "text".
Use "page_break" (with a short label) to split a long form into steps. Keep it as short as the purpose allows.
Only fill "create_records" when the description asks to turn people into customers, leads or workspace users;
then don't add name or email fields yourself: they are added automatically. At most 40 fields.]]

local function llm(messages, opts)
    local Llm = require("lib.agent.llm")
    return Llm.chat(messages, nil, opts)
end

local function decode_json(text)
    if type(text) ~= "string" then return nil end
    local ok, v = pcall(cjson.decode, text)
    if ok and type(v) == "table" then return v end
    local inner = text:match("```%w*%s*(.-)%s*```") or text:match("(%b{})")
    if inner then
        ok, v = pcall(cjson.decode, inner)
        if ok and type(v) == "table" then return v end
    end
end

--- Draft a form from a description.
-- @param auth { has_permission, can_assign_roles } of the person asking
-- @return { title, description, schema, targets, dropped } | nil, err, status
function AI.generate(namespace_id, user_uuid, prompt, auth)
    prompt = Fields.text(prompt, 2000, true)
    if not prompt or #prompt < 5 then return nil, "Describe the form you want (a sentence or two)." end
    local msg, err, status = llm({
        { role = "system", content = GENERATE_PROMPT },
        { role = "user", content = prompt },
    }, { json = true, max_tokens = 2500, temperature = 0.2,
         usage = { feature = "forms", user_uuid = user_uuid, namespace_id = namespace_id } })
    if not msg then return nil, err or "The AI didn't answer. Please try again.", status == 429 and 429 or 502 end
    local out = decode_json(msg.content)
    if not out then return nil, "The AI's answer wasn't a form. Please try again or rephrase.", 502 end

    -- Targets the model suggested that this deployment has and the person may use.
    local targets = {}
    for _, t in ipairs(type(out.create_records) == "table" and out.create_records or {}) do
        if Targets.get(t) and Targets.clean({ t }, auth, namespace_id) then targets[#targets + 1] = { type = t } end
    end
    local clean_targets, roles = Targets.clean(targets, auth, namespace_id)
    if not clean_targets then clean_targets, roles = {}, {} end

    local fields, dropped = {}, 0
    for _, f in ipairs(type(out.fields) == "table" and out.fields or {}) do
        if #fields >= AI.MAX_FIELDS then break end
        if type(f) == "table" and type(f.options) == "table" then
            for i, o in ipairs(f.options) do
                if type(o) == "table" then f.options[i] = o.label or o.value end
            end
        end
        if type(f) == "table" and Fields.normalize({ fields = { f } }, {}) then
            f.logic = nil
            fields[#fields + 1] = f
        else
            dropped = dropped + 1
        end
    end
    local schema, serr = Fields.normalize({ fields = fields }, roles)
    if not schema then return nil, serr end
    local title = Fields.text(out.title, 200)
    return {
        title = (title and title ~= "") and title or "Untitled form",
        description = Fields.text(out.description or "", 2000, true) or nil,
        schema = schema,
        targets = setmetatable(clean_targets, cjson.array_mt),
        dropped = dropped,
    }
end

--- Numbers about a form's recent responses, plus an AI-written summary.
-- @param form forms row (namespace-checked by the caller)
-- @return { responses, fields = { per-question stats }, summary? , summary_error? }
function AI.summarise(form, user_uuid, opts)
    opts = opts or {}
    local rows = db.query([[
        SELECT s.data, v.schema FROM form_submissions s JOIN form_versions v ON v.id = s.version_id
        WHERE s.form_id = ? AND s.status <> 'spam' ORDER BY s.created_at DESC, s.id DESC LIMIT 500
    ]], form.id)
    local cols, by_key = require("queries.FormSubmissionQueries").columns(form)
    local stats, texts = {}, {}
    for _, c in ipairs(cols) do
        local f = by_key[c.key]
        local st = { key = c.key, label = c.label, type = c.type, answered = 0 }
        stats[#stats + 1] = st
        for _, r in ipairs(rows) do
            local data = type(r.data) == "string" and cjson.decode(r.data) or r.data or {}
            local v = data[c.key]
            if v ~= nil then
                st.answered = st.answered + 1
                if f.type == "single_select" or f.type == "radio" or f.type == "multi_select" then
                    st.counts = st.counts or {}
                    for _, x in ipairs(type(v) == "table" and v or { v }) do
                        local label = Fields.show(f, x)
                        st.counts[label] = (st.counts[label] or 0) + 1
                    end
                elseif f.type == "boolean" then
                    st.counts = st.counts or { Yes = 0, No = 0 }
                    st.counts[v == true and "Yes" or "No"] = st.counts[v == true and "Yes" or "No"] + 1
                elseif f.type == "rating" or f.type == "number" then
                    local n = tonumber(v)
                    if n then
                        st.sum = (st.sum or 0) + n
                        st.min = math.min(st.min or n, n)
                        st.max = math.max(st.max or n, n)
                    end
                elseif (f.type == "short_text" or f.type == "long_text") and not f.system
                    and f.maps_to ~= "phone" and f.maps_to ~= "address" then
                    texts[c.label] = texts[c.label] or {}
                    if #texts[c.label] < AI.SAMPLE then
                        texts[c.label][#texts[c.label] + 1] = tostring(v):sub(1, 300)
                    end
                end
            end
        end
        if st.sum then
            st.average = math.floor(st.sum / st.answered * 10 + 0.5) / 10
            st.sum = nil
        end
    end
    local result = { responses = #rows, fields = setmetatable(stats, cjson.array_mt) }
    if opts.numbers_only or #rows == 0 then return result end

    -- The narrative: the numbers above plus free-text answers (no contact details).
    local lines = { ("Form: %s. %d responses (newest first, up to 500)."):format(form.title, #rows) }
    for _, st in ipairs(stats) do
        if st.counts then
            local parts = {}
            for label, n in pairs(st.counts) do parts[#parts + 1] = label .. " " .. n end
            lines[#lines + 1] = st.label .. ": " .. table.concat(parts, ", ")
        elseif st.average then
            lines[#lines + 1] = st.label .. ": average " .. st.average .. " (" .. st.min .. "-" .. st.max .. ")"
        end
    end
    for label, list in pairs(texts) do
        lines[#lines + 1] = "\nAnswers to \"" .. label .. "\":\n- " .. table.concat(list, "\n- ")
    end
    local msg, err = llm({
        { role = "system", content = "You summarise form responses for a business team. Write 4-8 short bullet "
            .. "points: what people said most, notable or surprising answers, and any action worth taking. Use the "
            .. "numbers given; don't invent any. Never repeat names, emails, phone numbers or addresses." },
        { role = "user", content = table.concat(lines, "\n"):sub(1, 24000) },
    }, { max_tokens = 800, temperature = 0.3,
         usage = { feature = "forms", user_uuid = user_uuid, namespace_id = form.namespace_id } })
    if msg and type(msg.content) == "string" and msg.content ~= "" then
        result.summary = msg.content
    else
        result.summary_error = err or "The AI didn't answer."
    end
    return result
end

return AI
