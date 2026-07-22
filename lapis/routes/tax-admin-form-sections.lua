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

-- Validate + normalise the `config` object into a config_json string.
-- Returns encoded_json|nil, err. Unknown top-level fields are stripped so
-- the stored config is exactly what the engine understands.
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
    return cjson.encode(out)
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
        local config_json, cerr = build_config_json(body.config or {})
        if not config_json then
            return { json = { error = cerr or "invalid config" }, status = 400 }
        end
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
        if body.config ~= nil then
            local config_json, cerr = build_config_json(body.config)
            if not config_json then
                return { json = { error = cerr or "invalid config" }, status = 400 }
            end
            data.config_json = config_json
        end
        if body.display_order ~= nil then data.display_order = body.display_order end
        if body.is_active ~= nil then data.is_active = body.is_active == true end

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
