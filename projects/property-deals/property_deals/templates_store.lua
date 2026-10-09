-- Workflow templates in the database: create a template from a definition,
-- publish a new immutable version, read the active version.
local cjson = require("cjson")
local db = require("lapis.db")
local Template = require("property_deals.template")

local S = {}

local function one(sql, ...)
    return db.query(sql, ...)[1]
end

--- Publish `def` as the next version of a template and make it active.
-- @return version row | nil, errors
function S.publish(ns, template_uuid, def, user_uuid, notes)
    local clean, errs = Template.validate(def)
    if not clean then return nil, errs end
    local tpl = one("SELECT * FROM property_deals_workflow_templates WHERE namespace_id = ? AND uuid = ?",
        ns, template_uuid)
    if not tpl then return nil, { "template: not found" } end
    if clean.key ~= tpl.key then return nil, { "key: must stay '" .. tpl.key .. "' (it identifies the template)" } end

    local next_version = one([[
        SELECT COALESCE(MAX(version), 0) + 1 AS v FROM property_deals_workflow_template_versions
        WHERE template_uuid = ?
    ]], template_uuid).v
    local version = db.insert("property_deals_workflow_template_versions", {
        namespace_id = ns,
        template_uuid = template_uuid,
        version = next_version,
        definition = cjson.encode(clean),
        notes = notes,
        published_by_user_uuid = user_uuid,
    }, { returning = "*" })[1]
    db.update("property_deals_workflow_templates", {
        active_version_uuid = version.uuid,
        name = clean.name,
        description = clean.description or db.NULL,
        jurisdiction = clean.jurisdiction or db.NULL,
        updated_at = db.raw("NOW()"),
    }, { namespace_id = ns, uuid = template_uuid })
    return version
end

--- Create a template (and its version 1) from a definition.
-- @return template row, version row | nil, errors
function S.create(ns, def, user_uuid, notes)
    local clean, errs = Template.validate(def)
    if not clean then return nil, errs end
    if one("SELECT 1 FROM property_deals_workflow_templates WHERE namespace_id = ? AND key = ?", ns, clean.key) then
        return nil, { "key: a template '" .. clean.key .. "' already exists; import it as a new version instead" }
    end
    local tpl = db.insert("property_deals_workflow_templates", {
        namespace_id = ns, key = clean.key, name = clean.name,
        description = clean.description, jurisdiction = clean.jurisdiction,
    }, { returning = "*" })[1]
    local version, verrs = S.publish(ns, tpl.uuid, clean, user_uuid, notes or "Initial version")
    if not version then return nil, verrs end
    tpl.active_version_uuid = version.uuid
    return tpl, version
end

--- A version row with its definition decoded.
function S.version(ns, version_uuid)
    local v = one([[
        SELECT * FROM property_deals_workflow_template_versions WHERE namespace_id = ? AND uuid = ?
    ]], ns, version_uuid)
    if v and type(v.definition) == "string" then v.definition = cjson.decode(v.definition) end
    return v
end

--- The active version of a template, looked up by template uuid or key.
function S.active(ns, uuid_or_key)
    local tpl = one([[
        SELECT * FROM property_deals_workflow_templates
        WHERE namespace_id = ? AND (uuid::text = ? OR key = ?) AND is_active
    ]], ns, uuid_or_key, uuid_or_key)
    if not tpl or not tpl.active_version_uuid then return nil end
    return tpl, S.version(ns, tpl.active_version_uuid)
end

return S
