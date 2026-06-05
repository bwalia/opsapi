--[[
    Tax Categories Management Routes

    Namespace-scoped CRUD over tax_categories, gated by the tax_categories RBAC
    module. Two kinds of categories are visible to a tenant:
      - global  (namespace_id IS NULL)  : seeded HMRC categories, read-only.
      - tenant  (namespace_id = <id>)   : created by this namespace, editable.

    GET    /api/v2/tax/categories        — list global + own-namespace categories
    POST   /api/v2/tax/categories        — create a category for this namespace
    PUT    /api/v2/tax/categories/:uuid  — update an own-namespace category
    DELETE /api/v2/tax/categories/:uuid  — delete an own-namespace category

    Every route runs through NamespaceMiddleware.requirePermission, so the tenant
    is resolved and membership/permission is enforced before the handler runs.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local VALID_TYPES = { income = true, expense = true }

local function read_body(self)
    ngx.req.read_body()
    local ct = ngx.var.content_type or ""
    if ct:find("application/json", 1, true) then
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, parsed = pcall(cjson.decode, body)
        return (ok and type(parsed) == "table") and parsed or {}
    end
    return ngx.req.get_post_args() or {}
end

-- Build a globally-unique key (the column is UNIQUE) from the label, scoped by
-- namespace and de-duplicated with a numeric suffix when needed.
local function unique_key(namespace_id, label)
    local base = "ns" .. tostring(namespace_id) .. "_" ..
        (label:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
    if base == ("ns" .. tostring(namespace_id) .. "_") then base = base .. "category" end
    local candidate = base
    local n = 1
    while #db.select("* FROM tax_categories WHERE key = ? LIMIT 1", candidate) > 0 do
        n = n + 1
        candidate = base .. "_" .. n
    end
    return candidate
end

local function map_row(r)
    return {
        id = r.id,
        uuid = r.uuid,
        key = r.key,
        name = r.label,
        category_type = r.type,
        is_deductible = r.is_tax_deductible,
        description = r.description,
        is_global = (r.namespace_id == nil or r.namespace_id == db.NULL),
    }
end

return function(app)

    -- LIST: global + this namespace's categories
    app:get("/api/v2/tax/categories",
        AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("tax_categories", "read",
            function(self)
                local ns_id = self.namespace.id
                local ok, rows = pcall(db.query, [[
                    SELECT id, uuid, key, label, type, is_tax_deductible, description, namespace_id
                    FROM tax_categories
                    WHERE is_active = true AND (namespace_id IS NULL OR namespace_id = ?)
                    ORDER BY type, label
                ]], ns_id)
                if not ok then
                    return { status = 500, json = { error = "Failed to list categories", details = tostring(rows) } }
                end
                local data = {}
                for _, r in ipairs(rows or {}) do data[#data + 1] = map_row(r) end
                return { status = 200, json = { data = data } }
            end)))

    -- CREATE: namespace-scoped category
    app:post("/api/v2/tax/categories",
        AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("tax_categories", "create",
            function(self)
                local body = read_body(self)
                local name = body.name and tostring(body.name):gsub("^%s*(.-)%s*$", "%1") or ""
                local ctype = tostring(body.category_type or body.type or ""):lower()

                if name == "" then
                    return { status = 400, json = { error = "name is required" } }
                end
                if not VALID_TYPES[ctype] then
                    return { status = 400, json = { error = "category_type must be 'income' or 'expense'" } }
                end

                local ns_id = self.namespace.id
                local deductible = body.is_deductible == true or body.is_deductible == "true"

                local ok, row = pcall(function()
                    return db.insert("tax_categories", {
                        uuid = db.raw("gen_random_uuid()::text"),
                        key = unique_key(ns_id, name),
                        label = name,
                        type = ctype,
                        is_tax_deductible = deductible,
                        description = body.description or db.NULL,
                        namespace_id = ns_id,
                        is_active = true,
                        created_at = db.raw("NOW()"),
                        updated_at = db.raw("NOW()"),
                    }, db.raw("*"))
                end)
                if not ok then
                    return { status = 500, json = { error = "Failed to create category", details = tostring(row) } }
                end
                local created = (type(row) == "table" and row[1]) or row
                return { status = 201, json = { data = map_row(created) } }
            end)))

    -- UPDATE: own-namespace categories only (global ones are read-only)
    app:put("/api/v2/tax/categories/:uuid",
        AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("tax_categories", "update",
            function(self)
                local ns_id = self.namespace.id
                local found = db.select(
                    "* FROM tax_categories WHERE uuid = ? AND namespace_id = ? LIMIT 1",
                    self.params.uuid, ns_id)
                if #found == 0 then
                    return { status = 404, json = { error = "Category not found (or it is a read-only global category)" } }
                end

                local body = read_body(self)
                local updates = { updated_at = db.raw("NOW()") }
                if body.name and tostring(body.name) ~= "" then
                    updates.label = tostring(body.name):gsub("^%s*(.-)%s*$", "%1")
                end
                local ctype = body.category_type or body.type
                if ctype then
                    ctype = tostring(ctype):lower()
                    if not VALID_TYPES[ctype] then
                        return { status = 400, json = { error = "category_type must be 'income' or 'expense'" } }
                    end
                    updates.type = ctype
                end
                if body.is_deductible ~= nil then
                    updates.is_tax_deductible = (body.is_deductible == true or body.is_deductible == "true")
                end
                if body.description ~= nil then updates.description = body.description end

                local ok, err = pcall(function()
                    db.update("tax_categories", updates, { uuid = self.params.uuid, namespace_id = ns_id })
                end)
                if not ok then
                    return { status = 500, json = { error = "Failed to update category", details = tostring(err) } }
                end
                local row = db.select("* FROM tax_categories WHERE uuid = ? LIMIT 1", self.params.uuid)
                return { status = 200, json = { data = row[1] and map_row(row[1]) or nil } }
            end)))

    -- DELETE: own-namespace categories only
    app:delete("/api/v2/tax/categories/:uuid",
        AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("tax_categories", "delete",
            function(self)
                local ns_id = self.namespace.id
                local found = db.select(
                    "* FROM tax_categories WHERE uuid = ? AND namespace_id = ? LIMIT 1",
                    self.params.uuid, ns_id)
                if #found == 0 then
                    return { status = 404, json = { error = "Category not found (or it is a read-only global category)" } }
                end
                local ok, err = pcall(function()
                    db.delete("tax_categories", { uuid = self.params.uuid, namespace_id = ns_id })
                end)
                if not ok then
                    return { status = 500, json = { error = "Failed to delete category", details = tostring(err) } }
                end
                return { status = 200, json = { message = "Category deleted" } }
            end)))

    ngx.log(ngx.NOTICE, "[Tax Categories] management routes initialized")
end
