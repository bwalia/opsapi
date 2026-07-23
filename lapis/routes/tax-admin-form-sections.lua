--[[
    Tax Admin Form Section Routes — admin CRUD for tax_form_sections, the
    catalogue behind the generic sections/sub-forms engine. This surface is
    what makes new screens a no-deploy operation: an admin creates an
    income_types row, then defines its sections (and their checkbox
    sub-form fields) here, and the frontend's generic /my-income/[type]
    page renders the whole thing.

    CRUD /api/v2/tax/admin/form-sections            ?income_type=&include_inactive=
         /api/v2/tax/admin/form-sections/:uuid

    Mirrors tax-admin-income-types.lua (same isAdmin gate, same envelope).
    DELETE is a soft disable: section keys persist on historical
    tax_form_items rows, so disabling only hides the section from new
    entries (its rows surface in the user page's "no longer available"
    list and drop out of totals).

    income_type_key and section_key are immutable after create — they are
    the join keys user rows hang off.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")
local FormSectionQueries = require("queries.FormSectionQueries")

-- Same admin gate as routes/tax-admin-income-types.lua.
local function isAdmin(user)
    if not user then return false end
    local roles = user.roles or ""
    if type(roles) == "string" then
        for role in roles:gmatch("[^,]+") do
            local trimmed = role:match("^%s*(.-)%s*$")
            if trimmed == "administrative" or trimmed == "tax_admin" then return true end
        end
    end
    if type(roles) == "table" then
        for _, r in ipairs(roles) do
            local name = r.role_name or r
            if name == "administrative" or name == "tax_admin" then return true end
        end
    end
    local user_uuid = user.uuid or user.id
    local rows = db.query([[
        SELECT r.name FROM roles r
        JOIN user__roles ur ON ur.role_id = r.id
        JOIN users u ON u.id = ur.user_id
        WHERE u.uuid = ? AND r.name IN ('administrative', 'tax_admin')
        LIMIT 1
    ]], user_uuid)
    return rows and #rows > 0
end

-- JSON body parser with the spooled-body fallback (same as siblings).
local function parseJSON()
    local ok, result = pcall(function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        if not data or data == "" then
            local file = ngx.req.get_body_file()
            if file then
                local f = io.open(file, "rb")
                if f then
                    data = f:read("*a")
                    f:close()
                end
            end
        end
        if not data or data == "" then return {} end
        return cjson.decode(data)
    end)
    if ok and type(result) == "table" then
        for k, v in pairs(result) do
            if v == cjson.null then result[k] = nil end
        end
        return result
    end
    return {}
end

local KEY_PATTERN = "^%l[%l%d_]*$"

-- Field types a record-mode section may declare. Fixed whitelist — the
-- user route validates submitted values by exactly these.
local FIELD_TYPES = {
    money = true, number = true, text = true,
    textarea = true, date = true, boolean = true,
}

-- Validate + normalise config.fields (record mode). Returns list|nil, err.
local function build_fields(fields)
    if type(fields) ~= "table" then return nil, "fields must be an array" end
    local seen, list = {}, {}
    for i, f in ipairs(fields) do
        if type(f) ~= "table" then return nil, "fields[" .. i .. "] must be an object" end
        if type(f.key) ~= "string" or not f.key:match(KEY_PATTERN) or #f.key > 40 then
            return nil, "field keys must be snake_case (a-z, 0-9, _), 40 characters or fewer"
        end
        if seen[f.key] then return nil, "duplicate field key: " .. f.key end
        seen[f.key] = true
        if type(f.label) ~= "string" or f.label == "" or #f.label > 200 then
            return nil, "each field needs a label of 200 characters or fewer"
        end
        if not FIELD_TYPES[f.type] then
            return nil, "field type must be one of: money, number, text, textarea, date, boolean"
        end
        if f.help ~= nil and (type(f.help) ~= "string" or #f.help > 300) then
            return nil, "field help must be a string of 300 characters or fewer"
        end
        if f.placeholder ~= nil and (type(f.placeholder) ~= "string" or #f.placeholder > 200) then
            return nil, "field placeholder must be a string of 200 characters or fewer"
        end
        if f.box ~= nil and (type(f.box) ~= "string" or #f.box > 40) then
            return nil, "field box must be a string of 40 characters or fewer"
        end
        if f.format ~= nil and f.format ~= "" then
            if f.type ~= "text" or not FormSectionQueries.FORMAT_NAMES[f.format] then
                return nil, "field format is only valid on text fields (supported: paye_reference)"
            end
        end
        local show_if
        if f.show_if ~= nil and (type(f.show_if) ~= "table" or f.show_if.field == nil) then
            return nil, "show_if must be an object like {\"field\":\"is_director\"}"
        end
        if type(f.show_if) == "table" and f.show_if.field ~= nil then
            local dep = f.show_if.field
            if type(dep) ~= "string" or not dep:match(KEY_PATTERN) or #dep > 40 then
                return nil, "show_if.field must be a snake_case field key"
            end
            -- The frontend drops hidden fields on save while required is
            -- enforced unconditionally server-side — the combination would
            -- make every record unsavable while the condition is unticked.
            if f.required == true then
                return nil, "a conditionally-shown field (show_if) cannot be required"
            end
            show_if = { field = dep }
        end
        list[#list + 1] = {
            key = f.key,
            label = f.label,
            type = f.type,
            help = (f.help ~= "" and f.help or nil),
            placeholder = (f.placeholder ~= "" and f.placeholder or nil),
            box = (f.box ~= "" and f.box or nil),
            format = (f.format ~= "" and f.format or nil),
            required = f.required == true or nil,
            summary = (f.type == "money" and f.summary == true) or nil,
            show_if = show_if,
        }
    end
    return list
end

-- Validate + normalise the `config` object into a config_json string.
-- Returns encoded_json|nil, err, has_fields. Unknown top-level fields are
-- stripped so the stored config is exactly what the engine understands.
local function build_config_json(config)
    if config == nil then return nil end
    if type(config) ~= "table" then return nil, "config must be an object" end
    local out = {}
    for _, field in ipairs({ "description_label", "description_placeholder", "amount_label", "amount_help" }) do
        local v = config[field]
        if v ~= nil then
            if type(v) ~= "string" or #v > 300 then
                return nil, field .. " must be a string of 300 characters or fewer"
            end
            if v ~= "" then out[field] = v end
        end
    end
    local boxes = config.checkboxes
    if boxes ~= nil then
        if type(boxes) ~= "table" then return nil, "checkboxes must be an array" end
        local seen, list = {}, {}
        for i, c in ipairs(boxes) do
            if type(c) ~= "table" then return nil, "checkboxes[" .. i .. "] must be an object" end
            if type(c.key) ~= "string" or not c.key:match(KEY_PATTERN) or #c.key > 40 then
                return nil, "checkbox keys must be snake_case (a-z, 0-9, _), 40 characters or fewer"
            end
            if seen[c.key] then return nil, "duplicate checkbox key: " .. c.key end
            seen[c.key] = true
            if type(c.label) ~= "string" or c.label == "" or #c.label > 200 then
                return nil, "each checkbox needs a label of 200 characters or fewer"
            end
            if c.help ~= nil and (type(c.help) ~= "string" or #c.help > 300) then
                return nil, "checkbox help must be a string of 300 characters or fewer"
            end
            list[#list + 1] = { key = c.key, label = c.label, help = (c.help ~= "" and c.help or nil) }
        end
        out.checkboxes = #list > 0 and list or cjson.empty_array
    else
        out.checkboxes = cjson.empty_array
    end

    local has_fields = false
    if config.fields ~= nil then
        local list, ferr = build_fields(config.fields)
        if not list then return nil, ferr end
        has_fields = #list > 0
        out.fields = has_fields and list or cjson.empty_array
    else
        out.fields = cjson.empty_array
    end
    -- One paradigm per section: repeating rows (checkboxes optional) OR a
    -- fixed field-form — the user page renders one or the other.
    if has_fields and type(out.checkboxes) == "table" and #out.checkboxes > 0 then
        return nil, "a section cannot define both checkboxes (row mode) and fields (record mode)"
    end

    -- Record-mode presentation settings (noun + list card fields). Stored
    -- on any section; the engine uses the first active section (by
    -- display_order) that carries one.
    if config.record ~= nil then
        local r = config.record
        if type(r) ~= "table" then return nil, "record must be an object" end
        local rec = {}
        if r.noun ~= nil and r.noun ~= "" then
            if type(r.noun) ~= "string" or #r.noun > 60 then
                return nil, "record.noun must be a string of 60 characters or fewer"
            end
            rec.noun = r.noun
        end
        for _, k in ipairs({ "title_field", "subtitle_field" }) do
            local v = r[k]
            if v ~= nil and v ~= "" then
                if type(v) ~= "string" or not v:match(KEY_PATTERN) or #v > 40 then
                    return nil, "record." .. k .. " must be a snake_case field key"
                end
                rec[k] = v
            end
        end
        if next(rec) then out.record = rec end
    end

    return cjson.encode(out), nil, has_fields
end

-- Mixing paradigms across one type's ACTIVE sections would render half a
-- page: the user surface is either a rows page or a records page. Returns
-- an error string when the new/updated section disagrees with siblings.
local function mode_conflict(income_type_key, new_has_fields, exclude_uuid)
    for _, s in ipairs(FormSectionQueries.admin_list({ income_type = income_type_key })) do
        if s.uuid ~= exclude_uuid then
            local sibling_has_fields = #FormSectionQueries.field_defs(s.config) > 0
            if sibling_has_fields ~= new_has_fields then
                if new_has_fields then
                    return "this income type already has repeating-row sections — one type can't mix rows and field-form sections"
                end
                return "this income type already has field-form (record) sections — one type can't mix rows and field-form sections"
            end
        end
    end
    return nil
end

-- hmrc_mapping arrives as an object (preferred) or a pre-encoded string;
-- either way what's stored must decode as a JSON object.
local function build_hmrc_mapping(v)
    if v == nil then return nil end
    if type(v) == "table" then return cjson.encode(v) end
    if type(v) == "string" then
        if v == "" then return "" end -- explicit clear
        local ok, decoded = pcall(cjson.decode, v)
        if ok and type(decoded) == "table" then return v end
        return nil, "hmrc_mapping must be a JSON object"
    end
    return nil, "hmrc_mapping must be a JSON object"
end

return function(app)
    app:get("/api/v2/tax/admin/form-sections", AuthMiddleware.requireAuth(function(self)
        if not isAdmin(self.current_user) then
            return { json = { error = "Admin access required" }, status = 403 }
        end
        local rows = FormSectionQueries.admin_list(self.params)
        return { json = { data = #rows > 0 and rows or cjson.empty_array, total = #rows }, status = 200 }
    end))

    app:post("/api/v2/tax/admin/form-sections", AuthMiddleware.requireAuth(function(self)
        if not isAdmin(self.current_user) then
            return { json = { error = "Admin access required" }, status = 403 }
        end
        local body = parseJSON()

        if type(body.income_type_key) ~= "string" or body.income_type_key == "" then
            return { json = { error = "income_type_key is required" }, status = 400 }
        end
        local it = db.select("id FROM income_types WHERE income_type_key = ?", body.income_type_key)
        if not it or #it == 0 then
            return { json = { error = "income_type_key does not exist in the income types catalogue" }, status = 400 }
        end
        if type(body.section_key) ~= "string" or not body.section_key:match(KEY_PATTERN) or #body.section_key > 64 then
            return { json = { error = "section_key must be snake_case (a-z, 0-9, _), 64 characters or fewer" }, status = 400 }
        end
        if type(body.label) ~= "string" or body.label == "" or #body.label > 200 then
            return { json = { error = "label is required (200 characters or fewer)" }, status = 400 }
        end
        if body.description ~= nil and (type(body.description) ~= "string" or #body.description > 1000) then
            return { json = { error = "description must be a string of 1000 characters or fewer" }, status = 400 }
        end
        local config_json, cerr, has_fields = build_config_json(body.config or {})
        if not config_json then
            return { json = { error = cerr or "invalid config" }, status = 400 }
        end
        local mode_err = mode_conflict(body.income_type_key, has_fields == true, nil)
        if mode_err then return { json = { error = mode_err }, status = 400 } end
        local hmrc, herr = build_hmrc_mapping(body.hmrc_mapping)
        if herr then return { json = { error = herr }, status = 400 } end

        local row, err = FormSectionQueries.admin_create({
            income_type_key = body.income_type_key,
            section_key = body.section_key,
            label = body.label,
            description = body.description,
            hmrc_mapping = (hmrc ~= "" and hmrc or nil),
            config_json = config_json,
            display_order = body.display_order,
        })
        if not row then return { json = { error = err or "Failed to create section" }, status = 400 } end
        return { json = { data = row }, status = 201 }
    end))

    app:put("/api/v2/tax/admin/form-sections/:uuid", AuthMiddleware.requireAuth(function(self)
        if not isAdmin(self.current_user) then
            return { json = { error = "Admin access required" }, status = 403 }
        end
        local body = parseJSON()

        local data = {}
        if body.label ~= nil then
            if type(body.label) ~= "string" or body.label == "" or #body.label > 200 then
                return { json = { error = "label must be a non-empty string of 200 characters or fewer" }, status = 400 }
            end
            data.label = body.label
        end
        if body.description ~= nil then
            if type(body.description) ~= "string" or #body.description > 1000 then
                return { json = { error = "description must be a string of 1000 characters or fewer" }, status = 400 }
            end
            data.description = body.description
        end
        if body.hmrc_mapping ~= nil then
            local hmrc, herr = build_hmrc_mapping(body.hmrc_mapping)
            if herr then return { json = { error = herr }, status = 400 } end
            data.hmrc_mapping = hmrc
        end
        local new_has_fields -- nil = config untouched by this request
        if body.config ~= nil then
            local config_json, cerr, has_fields = build_config_json(body.config)
            if not config_json then
                return { json = { error = cerr or "invalid config" }, status = 400 }
            end
            data.config_json = config_json
            new_has_fields = has_fields == true
        end
        if body.display_order ~= nil then data.display_order = body.display_order end
        if body.is_active ~= nil then data.is_active = body.is_active == true end

        -- Guard the type's single paradigm when this edit could change it:
        -- a config rewrite, or re-enabling a section into a type that may
        -- have switched modes since it was disabled. Only sections that
        -- will be ACTIVE after the edit participate in the mode.
        if new_has_fields ~= nil or data.is_active == true then
            local rows = db.query(
                "SELECT income_type_key, config_json, is_active FROM tax_form_sections WHERE uuid = ? LIMIT 1",
                tostring(self.params.uuid))
            if rows and #rows > 0 then
                local will_be_active = data.is_active
                if will_be_active == nil then will_be_active = rows[1].is_active == true end
                if will_be_active then
                    local has_fields = new_has_fields
                    if has_fields == nil then
                        local stored = FormSectionQueries.decode_config(rows[1].config_json)
                        has_fields = #FormSectionQueries.field_defs(stored) > 0
                    end
                    local mode_err = mode_conflict(rows[1].income_type_key, has_fields,
                        tostring(self.params.uuid))
                    if mode_err then return { json = { error = mode_err }, status = 400 } end
                end
            end
        end

        local row = FormSectionQueries.admin_update(tostring(self.params.uuid), data)
        if not row then return { json = { error = "Section not found" }, status = 404 } end
        return { json = { data = row }, status = 200 }
    end))

    app:delete("/api/v2/tax/admin/form-sections/:uuid", AuthMiddleware.requireAuth(function(self)
        if not isAdmin(self.current_user) then
            return { json = { error = "Admin access required" }, status = 403 }
        end
        local ok = FormSectionQueries.admin_disable(tostring(self.params.uuid))
        if not ok then return { json = { error = "Section not found" }, status = 404 } end
        return { json = { message = "Section disabled" }, status = 200 }
    end))
end
