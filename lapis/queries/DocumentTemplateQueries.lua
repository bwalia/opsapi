--[[
    Document Template Queries
    =========================

    Database query functions for document templates, template versions,
    and generated documents. All data is namespace-scoped for multi-tenant isolation.
]]

local DocumentTemplateModel = require("models.DocumentTemplateModel")
local DocumentTemplateVersionModel = require("models.DocumentTemplateVersionModel")
local GeneratedDocumentModel = require("models.GeneratedDocumentModel")
local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

local DocumentTemplateQueries = {}

-- ============================================================
-- Templates
-- ============================================================

--- Create a new document template with initial version record
-- @param params table { namespace_id, name, type, description, template_html, template_css, header_html, footer_html, config, variables, page_size, page_orientation, margin_top, margin_bottom, margin_left, margin_right, created_by_uuid }
-- @return table { data = template }
function DocumentTemplateQueries.create(params)
    local uuid = Global.generateUUID()

    local template = DocumentTemplateModel:create({
        uuid = uuid,
        namespace_id = params.namespace_id,
        type = params.type,
        name = params.name,
        description = params.description,
        is_default = params.is_default or false,
        template_html = params.template_html,
        template_css = params.template_css,
        header_html = params.header_html,
        footer_html = params.footer_html,
        config = params.config or db.raw("'{}'::jsonb"),
        variables = params.variables or db.raw("'[]'::jsonb"),
        page_size = params.page_size or "A4",
        page_orientation = params.page_orientation or "portrait",
        margin_top = params.margin_top or "20mm",
        margin_bottom = params.margin_bottom or "20mm",
        margin_left = params.margin_left or "15mm",
        margin_right = params.margin_right or "15mm",
        version = 1,
        is_active = true,
        created_by_uuid = params.created_by_uuid,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    -- Create initial version record
    DocumentTemplateVersionModel:create({
        uuid = Global.generateUUID(),
        template_id = template.id,
        version = 1,
        template_html = params.template_html,
        template_css = params.template_css,
        header_html = params.header_html,
        footer_html = params.footer_html,
        config = params.config or db.raw("'{}'::jsonb"),
        change_notes = "Initial version",
        created_by_uuid = params.created_by_uuid,
        created_at = db.raw("NOW()")
    })

    template.internal_id = template.id
    template.id = template.uuid

    return { data = template }
end

--- List templates with pagination and filtering
-- @param namespace_id number
-- @param params table { page, perPage, type, is_active, search }
-- @return table { data, total, page, perPage }
function DocumentTemplateQueries.list(namespace_id, params)
    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 20
    local offset = (page - 1) * perPage

    local conditions = { "dt.namespace_id = " .. db.escape_literal(namespace_id) }

    -- Exclude soft-deleted
    table.insert(conditions, "dt.deleted_at IS NULL")

    -- Filter by type
    if params.type and params.type ~= "" and params.type ~= "all" then
        table.insert(conditions, "dt.type = " .. db.escape_literal(params.type))
    end

    -- Filter by active status
    if params.is_active ~= nil and params.is_active ~= "" then
        if params.is_active == "true" or params.is_active == true then
            table.insert(conditions, "dt.is_active = true")
        elseif params.is_active == "false" or params.is_active == false then
            table.insert(conditions, "dt.is_active = false")
        end
    end

    -- Search by name or description
    if params.search and params.search ~= "" then
        table.insert(conditions, "(dt.name ILIKE " .. db.escape_literal("%" .. params.search .. "%") ..
            " OR dt.description ILIKE " .. db.escape_literal("%" .. params.search .. "%") .. ")")
    end

    local where_clause = table.concat(conditions, " AND ")

    -- Get total count
    local count_result = db.query(
        "SELECT COUNT(*) as total FROM document_templates dt WHERE " .. where_clause
    )
    local total = count_result and count_result[1] and tonumber(count_result[1].total) or 0

    -- Get paginated results with version count
    local templates = db.query([[
        SELECT
            dt.id as internal_id,
            dt.uuid as id,
            dt.namespace_id,
            dt.type,
            dt.name,
            dt.description,
            dt.is_default,
            dt.page_size,
            dt.page_orientation,
            dt.version,
            dt.is_active,
            dt.created_by_uuid,
            dt.created_at,
            dt.updated_at,
            COALESCE(vc.version_count, 0) as version_count
        FROM document_templates dt
        LEFT JOIN (
            SELECT template_id, COUNT(*) as version_count
            FROM document_template_versions
            GROUP BY template_id
        ) vc ON vc.template_id = dt.id
        WHERE ]] .. where_clause .. [[
        ORDER BY dt.created_at DESC
        LIMIT ]] .. perPage .. [[ OFFSET ]] .. offset
    )

    return {
        data = templates or {},
        total = total,
        page = page,
        perPage = perPage
    }
end

--- Get a single template by UUID
-- @param uuid string
-- @return table|nil template
function DocumentTemplateQueries.get(uuid)
    local results = db.query([[
        SELECT
            dt.id as internal_id,
            dt.uuid as id,
            dt.namespace_id,
            dt.type,
            dt.name,
            dt.description,
            dt.is_default,
            dt.template_html,
            dt.template_css,
            dt.header_html,
            dt.footer_html,
            dt.config,
            dt.variables,
            dt.page_size,
            dt.page_orientation,
            dt.margin_top,
            dt.margin_bottom,
            dt.margin_left,
            dt.margin_right,
            dt.version,
            dt.is_active,
            dt.created_by_uuid,
            dt.created_at,
            dt.updated_at
        FROM document_templates dt
        WHERE dt.uuid = ?
          AND dt.deleted_at IS NULL
        LIMIT 1
    ]], uuid)

    return results and results[1] or nil
end

--- Update a template, increment version, and create a version record with old content
-- @param uuid string
-- @param params table
-- @return table|nil updated template, string|nil error
function DocumentTemplateQueries.update(uuid, params)
    local template = DocumentTemplateModel:find({ uuid = uuid })
    if not template then
        return nil, "Template not found"
    end
    if template.deleted_at then
        return nil, "Template not found"
    end

    local old_version = template.version or 1
    local new_version = old_version + 1

    -- Save old content as a version record
    DocumentTemplateVersionModel:create({
        uuid = Global.generateUUID(),
        template_id = template.id,
        version = old_version,
        template_html = template.template_html,
        template_css = template.template_css,
        header_html = template.header_html,
        footer_html = template.footer_html,
        config = template.config or db.raw("'{}'::jsonb"),
        change_notes = params.change_notes,
        created_by_uuid = params.updated_by_uuid,
        created_at = db.raw("NOW()")
    })

    -- Build update fields
    local update_fields = {
        version = new_version,
        updated_at = db.raw("NOW()")
    }

    local allowed = {
        "name", "description", "template_html", "template_css",
        "header_html", "footer_html", "config", "variables",
        "page_size", "page_orientation",
        "margin_top", "margin_bottom", "margin_left", "margin_right",
        "is_active"
    }
    for _, field in ipairs(allowed) do
        if params[field] ~= nil then
            update_fields[field] = params[field]
        end
    end

    template:update(update_fields, { returning = "*" })

    return DocumentTemplateQueries.get(uuid)
end

--- Soft delete a template
-- @param uuid string
-- @return boolean success, string|nil error
function DocumentTemplateQueries.delete(uuid)
    local template = DocumentTemplateModel:find({ uuid = uuid })
    if not template then
        return false, "Template not found"
    end
    if template.deleted_at then
        return false, "Template not found"
    end

    template:update({
        deleted_at = db.raw("NOW()"),
        is_active = false,
        updated_at = db.raw("NOW()")
    })

    return true
end

--- Clone a template with a new UUID and name
-- @param uuid string - source template UUID
-- @param new_name string - name for the cloned template
-- @return table|nil { data = template }, string|nil error
function DocumentTemplateQueries.clone(uuid, new_name)
    local source = DocumentTemplateModel:find({ uuid = uuid })
    if not source then
        return nil, "Template not found"
    end
    if source.deleted_at then
        return nil, "Template not found"
    end

    local clone_uuid = Global.generateUUID()

    local cloned = DocumentTemplateModel:create({
        uuid = clone_uuid,
        namespace_id = source.namespace_id,
        type = source.type,
        name = new_name,
        description = source.description,
        is_default = false,
        template_html = source.template_html,
        template_css = source.template_css,
        header_html = source.header_html,
        footer_html = source.footer_html,
        config = source.config or db.raw("'{}'::jsonb"),
        variables = source.variables or db.raw("'[]'::jsonb"),
        page_size = source.page_size,
        page_orientation = source.page_orientation,
        margin_top = source.margin_top,
        margin_bottom = source.margin_bottom,
        margin_left = source.margin_left,
        margin_right = source.margin_right,
        version = 1,
        is_active = true,
        created_by_uuid = source.created_by_uuid,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    -- Create initial version for clone
    DocumentTemplateVersionModel:create({
        uuid = Global.generateUUID(),
        template_id = cloned.id,
        version = 1,
        template_html = source.template_html,
        template_css = source.template_css,
        header_html = source.header_html,
        footer_html = source.footer_html,
        config = source.config or db.raw("'{}'::jsonb"),
        change_notes = "Cloned from template: " .. uuid,
        created_by_uuid = source.created_by_uuid,
        created_at = db.raw("NOW()")
    })

    cloned.internal_id = cloned.id
    cloned.id = cloned.uuid

    return { data = cloned }
end

--- Set a template as default for its namespace and type (unset others first)
-- @param uuid string
-- @param namespace_id number
-- @param type string - template type (invoice, timesheet, etc.)
-- @return boolean success, string|nil error
function DocumentTemplateQueries.setDefault(uuid, namespace_id, type)
    -- Unset existing defaults for same namespace + type
    db.query([[
        UPDATE document_templates
        SET is_default = false, updated_at = NOW()
        WHERE namespace_id = ?
          AND type = ?
          AND is_default = true
          AND deleted_at IS NULL
    ]], namespace_id, type)

    -- Set the new default
    local result = db.query([[
        UPDATE document_templates
        SET is_default = true, updated_at = NOW()
        WHERE uuid = ?
          AND namespace_id = ?
          AND deleted_at IS NULL
        RETURNING uuid
    ]], uuid, namespace_id)

    if not result or #result == 0 then
        return false, "Template not found"
    end

    return true
end

--- Get the default template for a namespace and type
-- @param namespace_id number
-- @param type string
-- @return table|nil template
function DocumentTemplateQueries.getDefault(namespace_id, type)
    local results = db.query([[
        SELECT
            id as internal_id,
            uuid as id,
            namespace_id,
            type,
            name,
            description,
            is_default,
            template_html,
            template_css,
            header_html,
            footer_html,
            config,
            variables,
            page_size,
            page_orientation,
            margin_top,
            margin_bottom,
            margin_left,
            margin_right,
            version,
            is_active,
            created_by_uuid,
            created_at,
            updated_at
        FROM document_templates
        WHERE namespace_id = ?
          AND type = ?
          AND is_default = true
          AND is_active = true
          AND deleted_at IS NULL
        LIMIT 1
    ]], namespace_id, type)

    return results and results[1] or nil
end

--- List version history for a template
-- @param template_id number - internal template ID
-- @return table versions
function DocumentTemplateQueries.getVersions(template_id)
    local versions = db.query([[
        SELECT
            v.id as internal_id,
            v.uuid as id,
            v.template_id,
            v.version,
            v.template_html,
            v.template_css,
            v.header_html,
            v.footer_html,
            v.config,
            v.change_notes,
            v.created_by_uuid,
            v.created_at
        FROM document_template_versions v
        WHERE v.template_id = ?
        ORDER BY v.version DESC
    ]], template_id)

    return versions or {}
end

--- Restore a template to a previous version
-- @param template_id number - internal template ID
-- @param version_number number - version to restore
-- @return table|nil restored template, string|nil error
function DocumentTemplateQueries.restoreVersion(template_id, version_number)
    -- Find the version record
    local version_results = db.query([[
        SELECT * FROM document_template_versions
        WHERE template_id = ? AND version = ?
        LIMIT 1
    ]], template_id, version_number)

    if not version_results or #version_results == 0 then
        return nil, "Version not found"
    end

    local version = version_results[1]

    -- Find the current template
    local template = DocumentTemplateModel:find({ id = template_id })
    if not template then
        return nil, "Template not found"
    end

    local old_version = template.version or 1
    local new_version = old_version + 1

    -- Save current content as a version record before restoring
    DocumentTemplateVersionModel:create({
        uuid = Global.generateUUID(),
        template_id = template.id,
        version = old_version,
        template_html = template.template_html,
        template_css = template.template_css,
        header_html = template.header_html,
        footer_html = template.footer_html,
        config = template.config or db.raw("'{}'::jsonb"),
        change_notes = "Auto-saved before restoring to version " .. version_number,
        created_by_uuid = template.created_by_uuid,
        created_at = db.raw("NOW()")
    })

    -- Restore the template content from the version
    template:update({
        template_html = version.template_html,
        template_css = version.template_css,
        header_html = version.header_html,
        footer_html = version.footer_html,
        config = version.config,
        version = new_version,
        updated_at = db.raw("NOW()")
    })

    return DocumentTemplateQueries.get(template.uuid)
end

-- ============================================================
-- Generated Documents
-- ============================================================

--- Log a document generation event
-- @param params table { namespace_id, template_id, document_type, entity_type, entity_id, file_path, file_size, file_format, rendered_html, generated_by_uuid, metadata, emailed_to, emailed_at }
-- @return table { data = generated_document }
function DocumentTemplateQueries.logGeneration(params)
    local uuid = Global.generateUUID()

    local metadata_value = params.metadata
    if type(metadata_value) == "table" then
        metadata_value = cjson.encode(metadata_value)
    end

    local doc = GeneratedDocumentModel:create({
        uuid = uuid,
        namespace_id = params.namespace_id,
        template_id = params.template_id,
        document_type = params.document_type,
        entity_type = params.entity_type,
        entity_id = params.entity_id,
        file_path = params.file_path,
        file_size = params.file_size,
        file_format = params.file_format or "pdf",
        rendered_html = params.rendered_html,
        metadata = metadata_value or db.raw("'{}'::jsonb"),
        generated_by_uuid = params.generated_by_uuid,
        emailed_to = params.emailed_to,
        emailed_at = params.emailed_at,
        created_at = db.raw("NOW()")
    }, { returning = "*" })

    doc.internal_id = doc.id
    doc.id = doc.uuid

    return { data = doc }
end

--- List generated documents with pagination and filtering
-- @param namespace_id number
-- @param params table { page, perPage, document_type, entity_type, entity_id }
-- @return table { data, total, page, perPage }
function DocumentTemplateQueries.getGeneratedDocuments(namespace_id, params)
    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 20
    local offset = (page - 1) * perPage

    local conditions = { "gd.namespace_id = " .. db.escape_literal(namespace_id) }

    -- Filter by document type
    if params.document_type and params.document_type ~= "" then
        table.insert(conditions, "gd.document_type = " .. db.escape_literal(params.document_type))
    end

    -- Filter by entity type
    if params.entity_type and params.entity_type ~= "" then
        table.insert(conditions, "gd.entity_type = " .. db.escape_literal(params.entity_type))
    end

    -- Filter by entity ID
    if params.entity_id and params.entity_id ~= "" then
        table.insert(conditions, "gd.entity_id = " .. db.escape_literal(params.entity_id))
    end

    local where_clause = table.concat(conditions, " AND ")

    -- Get total count
    local count_result = db.query(
        "SELECT COUNT(*) as total FROM generated_documents gd WHERE " .. where_clause
    )
    local total = count_result and count_result[1] and tonumber(count_result[1].total) or 0

    -- Get paginated results
    local documents = db.query([[
        SELECT
            gd.id as internal_id,
            gd.uuid as id,
            gd.namespace_id,
            gd.template_id,
            gd.document_type,
            gd.entity_type,
            gd.entity_id,
            gd.file_path,
            gd.file_size,
            gd.file_format,
            gd.metadata,
            gd.generated_by_uuid,
            gd.emailed_to,
            gd.emailed_at,
            gd.created_at,
            dt.name as template_name,
            dt.type as template_type
        FROM generated_documents gd
        LEFT JOIN document_templates dt ON dt.id = gd.template_id
        WHERE ]] .. where_clause .. [[
        ORDER BY gd.created_at DESC
        LIMIT ]] .. perPage .. [[ OFFSET ]] .. offset
    )

    return {
        data = documents or {},
        total = total,
        page = page,
        perPage = perPage
    }
end

--- Get a single generated document by UUID
-- @param uuid string
-- @return table|nil generated document
function DocumentTemplateQueries.getGeneratedDocument(uuid)
    local results = db.query([[
        SELECT
            gd.id as internal_id,
            gd.uuid as id,
            gd.namespace_id,
            gd.template_id,
            gd.document_type,
            gd.entity_type,
            gd.entity_id,
            gd.file_path,
            gd.file_size,
            gd.file_format,
            gd.rendered_html,
            gd.metadata,
            gd.generated_by_uuid,
            gd.emailed_to,
            gd.emailed_at,
            gd.created_at,
            dt.name as template_name,
            dt.uuid as template_uuid,
            dt.type as template_type
        FROM generated_documents gd
        LEFT JOIN document_templates dt ON dt.id = gd.template_id
        WHERE gd.uuid = ?
        LIMIT 1
    ]], uuid)

    return results and results[1] or nil
end

--- Mark a generated document as emailed
-- @param uuid string
-- @param emailed_to string - email address
-- @return boolean success, string|nil error
function DocumentTemplateQueries.markEmailed(uuid, emailed_to)
    local result = db.query([[
        UPDATE generated_documents
        SET emailed_to = ?, emailed_at = NOW()
        WHERE uuid = ?
        RETURNING uuid
    ]], emailed_to, uuid)

    if not result or #result == 0 then
        return false, "Generated document not found"
    end

    return true
end

return DocumentTemplateQueries
