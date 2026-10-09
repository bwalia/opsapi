-- Workflow templates (versioned): /api/v2/property-deals/workflow-templates
--   GET    /workflow-templates                 list (with active version number)
--   GET    /workflow-templates/:id             template + active definition
--   PUT    /workflow-templates/:id             rename / activate / deactivate
--   GET    /workflow-templates/:id/versions    all versions (no definitions)
--   GET    /workflow-templates/:id/versions/:version   one version with its definition
--   POST   /workflow-templates/:id/versions    publish a new version { definition, notes }
--   GET    /workflow-templates/:id/export      the active definition as JSON
--   POST   /workflow-templates/import          { definition } -> new template, or new version of the same key
-- Published versions never change; deals keep the version they started on.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local Store = require("property_deals.templates_store")

local function find(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one([[
        SELECT t.*, v.version AS active_version
        FROM property_deals_workflow_templates t
        LEFT JOIN property_deals_workflow_template_versions v ON v.uuid = t.active_version_uuid
        WHERE t.namespace_id = ? AND t.uuid = ?
    ]], ns, id)
end

local function definition_from(self)
    local body, err = sdk.body(self)
    if not body then return nil, sdk.error(400, err) end
    if type(body.definition) ~= "table" then
        return nil, sdk.error(422, "Validation failed", { definition = "must be a template object" })
    end
    return body
end

return function(app)
    app:get("/workflow-templates", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local rows = db.query([[
            SELECT t.*, v.version AS active_version,
                   (SELECT COUNT(*)::int FROM property_deals_deals d
                    JOIN property_deals_workflow_template_versions dv ON dv.uuid = d.template_version_uuid
                    WHERE dv.template_uuid = t.uuid AND d.status = 'active') AS active_deals
            FROM property_deals_workflow_templates t
            LEFT JOIN property_deals_workflow_template_versions v ON v.uuid = t.active_version_uuid
            WHERE t.namespace_id = ? ORDER BY t.name
        ]], sdk.namespace_id(self))
        return sdk.ok(sdk.array(rows))
    end))

    app:get("/workflow-templates/:id", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local tpl = find(ns, self.params.id)
        if not tpl then return sdk.not_found("Template") end
        local v = tpl.active_version_uuid and Store.version(ns, tpl.active_version_uuid)
        tpl.definition = v and v.definition or require("cjson").null
        return sdk.ok(tpl)
    end))

    app:put("/workflow-templates/:id", sdk.handler({ permission = "property_deals_settings.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local tpl = find(ns, self.params.id)
        if not tpl then return sdk.not_found("Template") end
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, {
            name = { type = "string" }, description = { type = "text" }, is_active = { type = "boolean" },
            active_version_uuid = { type = "uuid", label = "Roll back/forward to this version" },
        }, true)
        if not data then return sdk.error(422, "Validation failed", errors) end
        if data.active_version_uuid and not U.one([[
            SELECT 1 FROM property_deals_workflow_template_versions WHERE template_uuid = ? AND uuid = ?
        ]], tpl.uuid, data.active_version_uuid) then
            return sdk.error(422, "Validation failed", { active_version_uuid = "not a version of this template" })
        end
        if next(data) then
            data.updated_at = db.raw("NOW()")
            db.update("property_deals_workflow_templates", data, { namespace_id = ns, uuid = tpl.uuid })
        end
        return sdk.ok(find(ns, tpl.uuid))
    end)))

    app:get("/workflow-templates/:id/versions", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local tpl = find(ns, self.params.id)
        if not tpl then return sdk.not_found("Template") end
        return sdk.ok(sdk.array(db.query([[
            SELECT uuid, version, notes, published_by_user_uuid, created_at,
                   (uuid = ?) AS is_active
            FROM property_deals_workflow_template_versions WHERE template_uuid = ? ORDER BY version DESC
        ]], tpl.active_version_uuid or db.NULL, tpl.uuid)))
    end))

    app:get("/workflow-templates/:id/versions/:version", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local tpl = find(ns, self.params.id)
        local n = tonumber(self.params.version)
        if not tpl or not n then return sdk.not_found("Version") end
        local v = U.one("SELECT uuid FROM property_deals_workflow_template_versions WHERE template_uuid = ? AND version = ?",
            tpl.uuid, n)
        if not v then return sdk.not_found("Version") end
        return sdk.ok(Store.version(ns, v.uuid))
    end))

    app:post("/workflow-templates/:id/versions", sdk.handler({ permission = "property_deals_settings.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local tpl = find(ns, self.params.id)
        if not tpl then return sdk.not_found("Template") end
        local body, bad = definition_from(self)
        if not body then return bad end
        local version, errs = U.tx(function()
            return Store.publish(ns, tpl.uuid, body.definition, sdk.user(self).uuid, body.notes)
        end)
        if not version then return sdk.error(422, "Template is not valid", errs) end
        return sdk.created(Store.version(ns, version.uuid))
    end)))

    app:get("/workflow-templates/:id/export", sdk.handler({ permission = "property_deals_settings.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local tpl = find(ns, self.params.id)
        if not tpl or not tpl.active_version_uuid then return sdk.not_found("Template") end
        return sdk.ok(Store.version(ns, tpl.active_version_uuid).definition)
    end))

    app:post("/workflow-templates/import", sdk.handler({ permission = "property_deals_settings.create" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local body, bad = definition_from(self)
        if not body then return bad end
        local def = body.definition
        local existing = type(def.key) == "string"
            and U.one("SELECT uuid FROM property_deals_workflow_templates WHERE namespace_id = ? AND key = ?", ns, def.key)
        if existing then
            local version, errs = U.tx(function()
                return Store.publish(ns, existing.uuid, def, sdk.user(self).uuid, body.notes or "Imported")
            end)
            if not version then return sdk.error(422, "Template is not valid", errs) end
            return sdk.created({ template = find(ns, existing.uuid), version = version.version })
        end
        local tpl, errs = U.tx(function() return Store.create(ns, def, sdk.user(self).uuid, body.notes or "Imported") end)
        if not tpl then return sdk.error(422, "Template is not valid", errs) end
        return sdk.created({ template = find(ns, tpl.uuid), version = 1 })
    end)))
end
