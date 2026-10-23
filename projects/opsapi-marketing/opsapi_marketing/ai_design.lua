-- "Create a design with AI": the model plans the email (subject, preview line, accent colour
-- and an ordered list of blocks) as JSON; we build the HTML from opsapi_marketing/blocks.lua.
-- So every AI design looks as polished as the ready-made ones, works in every mail client
-- and stays editable — small local models write unreliable email HTML, but plan content well.
-- Metered as feature "marketing" (lib/agent/llm.lua). Nothing is saved unless asked.
local cjson = require("cjson.safe")
local B = require("opsapi_marketing.blocks")

local A = {}

local TONES = {
    friendly = "warm and friendly",
    professional = "professional and clear",
    excited = "upbeat and exciting",
    formal = "formal and polite",
}

local EXAMPLE = [[{"name":"Spring sale","subject":"{{contact.first_name}}, 20% off for spring","preview_text":"This week only: use code SPRING20.","accent":"#e11d48","blocks":[{"type":"banner","text":"20% off for spring"},{"type":"lead","text":"Hi {{contact.first_name}},"},{"type":"paragraph","text":"Spring is here, so we're taking **20% off everything** on our website this week."},{"type":"code","text":"SPRING20","small":"Ends Sunday at midnight."},{"type":"button","text":"Shop the sale","link":"https://yourwebsite.co.uk"},{"type":"signature","closing":"Best wishes,"}]}]]

local PROMPT = [[You write marketing emails for small businesses. Reply with JSON only, no prose:
{"name": "a short name for this design", "subject": "...", "preview_text": "...", "accent": "#rrggbb",
 "blocks": [ ...in order... ]}
Block types:
 {"type":"banner","text":"a big headline on a coloured band"}  (or "title" for a plain big headline)
 {"type":"lead","text":"the opening line, e.g. Hi {{contact.first_name}},"}
 {"type":"paragraph","text":"..."}
 {"type":"heading","text":"a section heading"}
 {"type":"list","items":["...","..."]}
 {"type":"note","text":"a highlighted box for key details: an offer, date and place, opening hours"}
 {"type":"code","text":"SAVE20","small":"the conditions, e.g. Ends Sunday"}
 {"type":"button","text":"what the button says","link":"https://..."}
 {"type":"signature","closing":"Best wishes,"}
Rules:
- 5 to 12 blocks. Start with a banner or title, end with a signature. One clear button (two at most).
- Short sentences, plain words, no jargon. Subject under 60 characters; preview_text under 110.
- Greet with {{contact.first_name}} (it becomes "there" when the name is unknown). Use no other {{...}} tags.
- Never invent facts, prices, dates, phone numbers, names or web addresses the request doesn't give: write a
  placeholder in square brackets, e.g. [your price], [date], and use https://yourwebsite.co.uk for links.
- **double asterisks** for bold is allowed; no HTML, no emoji.
- Pick an accent colour that suits the mood (green welcome, red sale, purple event, navy news, teal business).
- Don't write an unsubscribe line or a postal address: they are added automatically.
Example reply:
]] .. EXAMPLE

local function esc(s)
    return (tostring(s or ""):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

--- The model's text, made safe: escaped, **bold** kept, only the first-name tag kept.
local function text(v, max)
    if type(v) ~= "string" then return nil end
    v = v:gsub("{{%s*contact%.first_name%s*}}", "\1"):gsub("{{.-}}", ""):gsub("\1", "{{contact.first_name}}")
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then return nil end
    v = esc(v:sub(1, max or 600))
    return (v:gsub("%*%*(.-)%*%*", "<strong>%1</strong>"))
end

local function plain(html)
    return (html:gsub("<br>", "\n"):gsub("<[^>]+>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"))
end

local function link(v)
    v = type(v) == "string" and v:gsub("%s", "") or ""
    if v:match("^https?://[%w%-%.]+") or v:match("^mailto:%S+@%S+$") or v:match("^tel:[+%d][%d%-]*$") then
        return esc(v:sub(1, 500))
    end
    return "https://yourwebsite.co.uk"
end

local function accent_of(v)
    return (type(v) == "string" and v:match("^#%x%x%x%x%x%x$")) and v:lower() or "#1d4ed8"
end

--- Build the email from the model's plan. @return { name, subject, preview_text, body_html, body_text } or nil
function A.render(plan, business)
    if type(plan) ~= "table" or type(plan.blocks) ~= "table" then return nil end
    local accent = accent_of(plan.accent)
    local name = (esc(business or "[Your business name]"):gsub("%%", "%%%%"))
    local function ours(h) return (h:gsub("%[Your business name%]", name)) end
    local html, txt, buttons = { ours(B.brand(accent)) }, {}, 0
    for _, b in ipairs(plan.blocks) do
        if #html >= 16 then break end
        local t = type(b) == "table" and b.type
        if t == "banner" or t == "title" or t == "heading" or t == "lead" or t == "paragraph" or t == "note" then
            local v = text(b.text, t == "paragraph" and 900 or 300)
            if v then
                html[#html + 1] = (t == "banner" and B.banner(accent, v)) or (t == "title" and B.title(v))
                    or (t == "heading" and B.heading(v)) or (t == "lead" and B.lead(v))
                    or (t == "note" and B.note(accent, v)) or B.p(v)
                txt[#txt + 1] = plain(v)
            end
        elseif t == "list" and type(b.items) == "table" then
            local items = {}
            for _, it in ipairs(b.items) do
                local v = text(it, 300)
                if v and #items < 8 then items[#items + 1] = v end
            end
            if #items > 0 then
                html[#html + 1] = B.list(items)
                for _, v in ipairs(items) do txt[#txt + 1] = "- " .. plain(v) end
            end
        elseif t == "code" then
            local c = type(b.text) == "string" and b.text:upper():gsub("[^%w%-]", ""):sub(1, 20) or ""
            if c ~= "" then
                html[#html + 1] = B.code(accent, c)
                local small = text(b.small, 200)
                if small then html[#html + 1] = B.small(small) end
                txt[#txt + 1] = "Code: " .. c .. (small and (" — " .. plain(small)) or "")
            end
        elseif t == "button" and buttons < 2 then
            local label = text(b.text, 40)
            if label then
                buttons = buttons + 1
                local href = link(b.link)
                html[#html + 1] = B.button(accent, label, href)
                txt[#txt + 1] = plain(label) .. ": " .. href
            end
        end
    end
    if #html < 3 then return nil end
    local closing = type(plan.blocks[#plan.blocks]) == "table" and plan.blocks[#plan.blocks].closing
    html[#html + 1] = ours(B.sign(text(closing, 40)))
    html[#html + 1] = B.footer()
    local subject, preview = text(plan.subject, 150), text(plan.preview_text, 150)
    return {
        name = (type(plan.name) == "string" and plan.name:sub(1, 80)) or "AI design",
        subject = subject and plain(subject) or "A message for you, {{contact.first_name}}",
        preview_text = preview and plain(preview) or "",
        body_html = B.card(html),
        body_text = table.concat(txt, "\n\n") .. "\n\nUnsubscribe: {{unsubscribe_url}}",
    }
end

local function decode(content)
    if type(content) ~= "string" then return nil end
    local v = cjson.decode(content)
    if type(v) == "table" then return v end
    local inner = content:match("```%w*%s*(.-)%s*```") or content:match("(%b{})")
    return inner and cjson.decode(inner) or nil
end

--- Ask the model for a design. @return design or nil, err, http status
function A.generate(ns, user_uuid, brief, tone, business)
    brief = type(brief) == "string" and brief:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if #brief < 8 then return nil, "Say what the email is about in a sentence or two.", 400 end
    local style = TONES[tone] or TONES.friendly
    local msg, err, status = require("lib.agent.llm").chat({
        { role = "system", content = PROMPT },
        { role = "user", content = "Business: " .. tostring(business) .. "\nTone: " .. style
            .. "\nWhat the email is about:\n" .. brief:sub(1, 2000) },
    }, nil, { json = true, max_tokens = 1800, temperature = 0.6,
              usage = { feature = "marketing", user_uuid = user_uuid, namespace_id = ns } })
    if not msg then
        return nil, err or "The AI didn’t answer. Please try again.", status == 429 and 429 or 502
    end
    local design = A.render(decode(msg.content), business)
    if not design then return nil, "The AI’s answer wasn’t usable. Please try again, or describe it differently.", 502 end
    return design
end

return A
