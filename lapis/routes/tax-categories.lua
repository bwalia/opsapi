--[[
    Tax Categories Routes (read for all, write for platform admins)

    The dashboard and the diy-tax-return frontend both need to *read* the master
    list of transaction categories (to label transactions and populate the
    "assign category" dropdown). That list lives in `tax_categories`, which is a
    SYSTEM-WIDE table (no namespace_id) — so writes are restricted to platform
    admins, while reads are open to any authenticated user.

    This route is purely additive: it introduces the `/api/v2/tax/categories`
    namespace that did not exist before, so it cannot affect existing callers.
    The pre-existing admin CRUD at `/api/v2/admin/categories` is left untouched.

      GET    /api/v2/tax/categories        — list active categories (any user)
      POST   /api/v2/tax/categories        — create (platform admin)
      PUT    /api/v2/tax/categories/:uuid  — update (platform admin)
      DELETE /api/v2/tax/categories/:uuid  — soft-delete (platform admin)
]]

local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")
local AdminCheck = require("helper.admin-check")
local TaxCategoryQueries = require("queries.TaxCategoryQueries")

-- Build a snake_case key from a human label, e.g. "Office Supplies" -> "office_supplies".
local function slugify(label)
    local key = tostring(label or ""):lower()
    key = key:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return key
end

-- The DB stores `label`/`key`; the dashboard's TaxCategory type reads `name`
-- and `is_deductible`. Emit both so either shape works without a breaking change.
local function shape(row)
    if not row then return nil end
    return {
        id = row.id,
        uuid = row.uuid,
        key = row.key,
        label = row.label,
        name = row.label,                       -- alias for the dashboard
        type = row.type,
        category_type = row.type,               -- alias
        description = row.description,
        examples = row.examples,
        hmrc_category_id = row.hmrc_category_id,
        is_tax_deductible = row.is_tax_deductible,
        is_deductible = row.is_tax_deductible,   -- alias
        deduction_rate = row.deduction_rate,
        is_active = row.is_active,
    }
end

local function parseBool(v, default)
    if v == nil or v == "" then return default end
    if type(v) == "boolean" then return v end
    v = tostring(v):lower()
    return v == "true" or v == "1" or v == "yes"
end

return function(app)

    -- GET /api/v2/tax/categories — list active categories (any authenticated user)
    app:get("/api/v2/tax/categories",
        AuthMiddleware.requireAuth(function(self)
            -- Default to active-only; allow ?include_inactive=true for admin UIs.
            local params = { per_page = 500 }
            if not parseBool(self.params.include_inactive, false) then
                params.is_active = true
            end
            if self.params.type then params.type = self.params.type end
            if self.params.search then params.search = self.params.search end

            local rows, total = TaxCategoryQueries.getAll(params)
            local data = {}
            for _, r in ipairs(rows or {}) do
                data[#data + 1] = shape(r)
            end
            return { status = 200, json = { data = data, total = total } }
        end)
    )

    -- POST /api/v2/tax/categories — create (platform admin only)
    app:post("/api/v2/tax/categories",
        AuthMiddleware.requireAuth(function(self)
            if not AdminCheck.isPlatformAdmin(self.current_user) then
                return { status = 403, json = { error = "Platform admin access required" } }
            end

            local label = self.params.label or self.params.name
            if not label or label == "" then
                return { status = 400, json = { error = "label is required" } }
            end

            local cat_type = (self.params.type or "expense"):lower()
            if cat_type ~= "income" and cat_type ~= "expense" then
                return { status = 400, json = { error = "type must be 'income' or 'expense'" } }
            end

            local key = self.params.key
            if not key or key == "" then key = slugify(label) end
            if key == "" then
                return { status = 400, json = { error = "could not derive a key from label" } }
            end

            -- Enforce the table's unique key constraint with a clean error.
            local existing = db.select("id FROM tax_categories WHERE key = ? LIMIT 1", key)
            if existing and #existing > 0 then
                return { status = 409, json = { error = "A category with key '" .. key .. "' already exists" } }
            end

            local created = TaxCategoryQueries.create({
                key = key,
                label = label,
                type = cat_type,
                description = self.params.description or db.NULL,
                examples = self.params.examples or db.NULL,
                hmrc_category_id = self.params.hmrc_category_id and tonumber(self.params.hmrc_category_id) or db.NULL,
                is_tax_deductible = parseBool(self.params.is_tax_deductible, cat_type == "expense"),
                deduction_rate = tonumber(self.params.deduction_rate) or db.NULL,
                is_active = true,
            })

            -- db.insert returns the inserted row(s); re-fetch for a consistent shape.
            local row = TaxCategoryQueries.getByUuid(created.uuid or (created[1] and created[1].uuid))
            return { status = 201, json = { data = shape(row), message = "Category created" } }
        end)
    )

    -- PUT /api/v2/tax/categories/:uuid — update (platform admin only)
    app:put("/api/v2/tax/categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not AdminCheck.isPlatformAdmin(self.current_user) then
                return { status = 403, json = { error = "Platform admin access required" } }
            end

            local existing = TaxCategoryQueries.getByUuid(self.params.uuid)
            if not existing then
                return { status = 404, json = { error = "Category not found" } }
            end

            local updates = {}
            local label = self.params.label or self.params.name
            if label then updates.label = label end
            if self.params.type then
                local t = self.params.type:lower()
                if t ~= "income" and t ~= "expense" then
                    return { status = 400, json = { error = "type must be 'income' or 'expense'" } }
                end
                updates.type = t
            end
            if self.params.description ~= nil then updates.description = self.params.description end
            if self.params.examples ~= nil then updates.examples = self.params.examples end
            if self.params.hmrc_category_id then updates.hmrc_category_id = tonumber(self.params.hmrc_category_id) end
            if self.params.deduction_rate then updates.deduction_rate = tonumber(self.params.deduction_rate) end
            if self.params.is_tax_deductible ~= nil then
                updates.is_tax_deductible = parseBool(self.params.is_tax_deductible, true)
            end
            if self.params.is_active ~= nil then
                updates.is_active = parseBool(self.params.is_active, true)
            end

            local updated = TaxCategoryQueries.update(self.params.uuid, updates)
            return { status = 200, json = { data = shape(updated), message = "Category updated" } }
        end)
    )

    -- DELETE /api/v2/tax/categories/:uuid — soft-delete (platform admin only)
    app:delete("/api/v2/tax/categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not AdminCheck.isPlatformAdmin(self.current_user) then
                return { status = 403, json = { error = "Platform admin access required" } }
            end

            local existing = TaxCategoryQueries.getByUuid(self.params.uuid)
            if not existing then
                return { status = 404, json = { error = "Category not found" } }
            end

            TaxCategoryQueries.delete(self.params.uuid)
            return { status = 200, json = { message = "Category deactivated" } }
        end)
    )
end
