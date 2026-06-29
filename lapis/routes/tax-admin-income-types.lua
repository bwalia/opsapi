--[[
    Tax Admin Income Types Routes

    Admin CRUD for the income_types catalogue. Mirrors tax-admin-profiles.lua
    (same isAdmin gate, same { data, total } / { error } envelope). Rows created
    here are the single source of truth for:
      - the My Income dropdown + validation (routes/my-incomes.lua)
      - FastAPI's IncomeTypeLoader (backend/app/services/income_type_loader.py)

    CRUD /api/v2/tax/admin/income-types
         /api/v2/tax/admin/income-types/:uuid/usage

    NOTE: DELETE is a soft disable (is_active = false), not a hard delete, and is
    NOT blocked by usage. Unlike classification_profiles (a wizard tree where a
    delete orphans children + user picks), income types are flat and the key
    persists on historical my_incomes rows — disabling only hides the type from
    new entries. The /usage count lets the admin UI warn before disabling.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")
local IncomeTypeQueries = require("queries.IncomeTypeQueries")

-- Same admin gate as routes/tax-admin-profiles.lua.
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

-- Parse a JSON request body. Mirrors routes/tax-admin-profiles.lua: falls back
-- to the temp file OpenResty writes when the body exceeds client_body_buffer_size.
local function parseJSON(self)
    local ok, result = pcall(function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        if not data or data == "" then
            local file = ngx.req.get_body_file()
            if file then
                local f = io.open(file, "r")
                if f then
                    data = f:read("*a")
                    f:close()
                end
            end
        end
        if not data or data == "" then return {} end
        return cjson.decode(data)
    end)
    if ok and type(result) == "table" then return result end
    return {}
end

local function forbidden()
    return { status = 403, json = { error = "Admin access required" } }
end

return function(app)

    -- ========================================
    -- LIST income types (?include_inactive=true to see disabled)
    -- ========================================
    app:get("/api/v2/tax/admin/income-types",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            return { status = 200, json = IncomeTypeQueries.admin_list(self.params) }
        end)
    )

    -- ========================================
    -- GET single income type
    -- ========================================
    app:get("/api/v2/tax/admin/income-types/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local row = IncomeTypeQueries.show(self.params.uuid)
            if not row then return { status = 404, json = { error = "Income type not found" } } end
            return { status = 200, json = { data = row } }
        end)
    )

    -- ========================================
    -- CREATE income type
    -- ========================================
    app:post("/api/v2/tax/admin/income-types",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local body = parseJSON(self)
            local row, err, status = IncomeTypeQueries.create(body)
            if not row then
                return { status = status or 400, json = { error = err or "Failed to create income type" } }
            end
            return { status = 201, json = { data = row } }
        end)
    )

    -- ========================================
    -- UPDATE income type (income_type_key is immutable)
    -- ========================================
    app:put("/api/v2/tax/admin/income-types/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local body = parseJSON(self)
            local row, err, status = IncomeTypeQueries.update(self.params.uuid, body)
            if not row then
                return { status = status or 400, json = { error = err or "Failed to update income type" } }
            end
            return { status = 200, json = { data = row } }
        end)
    )

    -- ========================================
    -- DELETE income type (soft disable)
    -- ========================================
    app:delete("/api/v2/tax/admin/income-types/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local ok, err, status = IncomeTypeQueries.soft_delete(self.params.uuid)
            if not ok then
                return { status = status or 404, json = { error = err or "Income type not found" } }
            end
            return { status = 200, json = { message = "Income type deactivated" } }
        end)
    )

    -- ========================================
    -- Usage count — lets the admin UI warn before disabling a type that
    -- existing My Income rows still reference.
    -- ========================================
    app:get("/api/v2/tax/admin/income-types/:uuid/usage",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then return forbidden() end
            local result, err, status = IncomeTypeQueries.usage(self.params.uuid)
            if not result then
                return { status = status or 404, json = { error = err or "Income type not found" } }
            end
            return { status = 200, json = result }
        end)
    )
end
