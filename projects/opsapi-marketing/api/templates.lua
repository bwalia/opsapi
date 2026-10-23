local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local U = require("opsapi_marketing.util")
local T = require("opsapi_marketing.templates")
local db = require("lapis.db")

local function find_template(ns, id)
    if U.is_uuid(id) then
        return U.one("SELECT * FROM mkt_templates WHERE namespace_id = ? AND uuid = ?", ns, id)
    end
    return U.one("SELECT * FROM mkt_templates WHERE namespace_id = ? AND id = ?", ns, tonumber(id))
end

return function(app)
    sdk.crud(app, "/templates", {
        table = "mkt_templates",
        module = "opsapi_marketing_templates",
        fields = {
            name = { type = "string", required = true },
            channel = { type = "string", required = true, enum = U.CHANNEL_ENUM },
            subject = { type = "string", max = 998 },
            preview_text = { type = "string", max = 255 },
            body_html = { type = "text" },
            body_text = { type = "text" },
            status = { type = "string", enum = { "draft", "published", "archived" } },
        },
        searchable = { "name", "subject", "channel" },
        filterable = { "channel", "status" },
        sortable = { "name", "channel", "status", "created_at", "updated_at" },
        ui = {
            label = "Templates",
            columns = { "name", "channel", "status", "subject" },
            form = { "name", "channel", "subject", "preview_text", "status", "body_html", "body_text" },
        },
    })

    -- Sanitise + analyse without saving
    app:post("/templates/analyse", sdk.handler({ permission = "opsapi_marketing_templates.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        return sdk.ok(T.analyse(ns, body))
    end))

    app:post("/templates/preview", sdk.handler({ permission = "opsapi_marketing_templates.read" }, function(self)
        local ns = sdk.namespace_id(self)
        -- Do not coerce a failed parse to {}: form-urlencoded bodies used to
        -- "succeed" with an empty payload and look like a blank preview.
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local sample = body.sample
        local payload = body.template or body
        if body.template_uuid or body.uuid then
            local row = find_template(ns, body.template_uuid or body.uuid)
            if not row then return sdk.not_found("template") end
            payload = row
            if body.subject then payload.subject = body.subject end
            if body.body_html then payload.body_html = body.body_html end
            if body.body_text then payload.body_text = body.body_text end
        end
        local out, err = T.preview(ns, payload, sample)
        if not out then return sdk.error(400, err) end
        return sdk.ok(out)
    end))

    -- "Create a design with AI": { brief, tone?, save? } -> { name, subject, preview_text, body_html,
    -- body_text } (+ uuid when saved as a template). Built from the same blocks as the ready-made designs.
    app:post("/templates/ai", sdk.handler({ permission = "opsapi_marketing_templates.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local ws = U.one("SELECT name FROM namespaces WHERE id = ?", ns)
        local user = sdk.user(self)
        local design, err, status = require("opsapi_marketing.ai_design").generate(ns, user and user.uuid,
            body.brief, body.tone, ws and ws.name or "[Your business name]")
        if not design then return sdk.error(status or 502, err) end
        if body.save == true then
            local row = db.query([[
                INSERT INTO mkt_templates (namespace_id, name, channel, subject, preview_text, body_html, body_text, status)
                VALUES (?, ?, 'email', ?, ?, ?, ?, 'draft') RETURNING uuid
            ]], ns, design.name, design.subject, design.preview_text, design.body_html, design.body_text)[1]
            design.uuid = row and row.uuid
        end
        return sdk.ok(design)
    end))

    app:post("/templates/seed", sdk.handler({ permission = "opsapi_marketing_templates.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local created = T.seed_defaults(ns)
        return sdk.ok({ created = sdk.array(created), count = #created })
    end))

    app:post("/templates/:id/publish", sdk.handler({ permission = "opsapi_marketing_templates.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local row = find_template(ns, self.params.id)
        if not row then return sdk.not_found("template") end
        local published, err = T.publish(ns, row.id)
        if not published then return sdk.error(400, err) end
        return sdk.ok(published)
    end))

    app:post("/templates/:id/clone", sdk.handler({ permission = "opsapi_marketing_templates.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local row = find_template(ns, self.params.id)
        if not row then return sdk.not_found("template") end
        local body = sdk.body(self) or {}
        local cloned, err = T.clone(ns, row.id, body.name)
        if not cloned then return sdk.error(400, err) end
        return sdk.created(cloned)
    end))

    -- Save with sanitisation (creates new version when publishing from draft edits)
    app:put("/templates/:id/studio", sdk.handler({ permission = "opsapi_marketing_templates.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local row = find_template(ns, self.params.id)
        if not row then return sdk.not_found("template") end
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local prepared = T.prepare_payload({
            name = body.name or row.name,
            channel = body.channel or row.channel,
            subject = body.subject,
            preview_text = body.preview_text,
            body_html = body.body_html,
            body_text = body.body_text,
            status = body.status or row.status,
        })
        local analysis = T.analyse(ns, prepared)
        db.query([[
            UPDATE mkt_templates SET name = ?, subject = ?, preview_text = ?,
                body_html = ?, body_text = ?, status = ?, updated_at = NOW()
            WHERE id = ? AND namespace_id = ?
        ]], prepared.name, prepared.subject or db.NULL, prepared.preview_text or db.NULL,
            prepared.body_html or db.NULL, prepared.body_text or db.NULL,
            prepared.status, row.id, ns)
        local updated = U.one("SELECT * FROM mkt_templates WHERE id = ?", row.id)
        return sdk.ok({ template = updated, analysis = analysis })
    end))
end
