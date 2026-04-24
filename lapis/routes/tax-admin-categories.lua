--[[
    Tax Admin Categories Routes

    Admin CRUD for tax_categories and tax_hmrc_categories.

    CRUD /api/v2/admin/categories          — Transaction categories
    CRUD /api/v2/admin/hmrc-categories     — HMRC SA103F categories
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")

local function isAdmin(user)
    if not user then return false end
    local roles = user.roles or ""
    if type(roles) == "string" then
        return roles:match("admin") ~= nil or roles:match("tax_admin") ~= nil
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

return function(app)

    local ok_q, TaxCategoryQueries = pcall(require, "queries.TaxCategoryQueries")
    if not ok_q then
        ngx.log(ngx.ERR, "TaxCategoryQueries not available: ", tostring(TaxCategoryQueries))
        return
    end

    -- ========================================
    -- Transaction Categories
    -- ========================================

    -- GET /api/v2/admin/categories
    app:get("/api/v2/admin/categories",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local rows, total = TaxCategoryQueries.getAll(self.params)
            return {
                status = 200,
                json = { data = rows, total = total, page = tonumber(self.params.page) or 1 }
            }
        end)
    )

    -- POST /api/v2/admin/categories
    app:post("/api/v2/admin/categories",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            if not self.params.name then
                return { status = 400, json = { error = "name is required" } }
            end

            local category = TaxCategoryQueries.create({
                name = self.params.name,
                description = self.params.description or db.NULL,
                type = self.params.type or "EXPENSE",
                hmrc_category_id = self.params.hmrc_category_id and tonumber(self.params.hmrc_category_id) or db.NULL,
                is_tax_deductible = self.params.is_tax_deductible ~= false,
                deduction_rate = tonumber(self.params.deduction_rate) or db.NULL,
                examples = self.params.examples or db.NULL,
                is_active = true,
            })

            return { status = 201, json = { data = category, message = "Category created" } }
        end)
    )

    -- PUT /api/v2/admin/categories/:uuid
    app:put("/api/v2/admin/categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local existing = TaxCategoryQueries.getByUuid(self.params.uuid)
            if not existing then
                return { status = 404, json = { error = "Category not found" } }
            end

            local updates = {}
            if self.params.name then updates.name = self.params.name end
            if self.params.description then updates.description = self.params.description end
            if self.params.type then updates.type = self.params.type end
            if self.params.hmrc_category_id then updates.hmrc_category_id = tonumber(self.params.hmrc_category_id) end
            if self.params.is_tax_deductible ~= nil then updates.is_tax_deductible = self.params.is_tax_deductible end
            if self.params.deduction_rate then updates.deduction_rate = tonumber(self.params.deduction_rate) end
            if self.params.examples then updates.examples = self.params.examples end
            if self.params.is_active ~= nil then updates.is_active = self.params.is_active end

            local updated = TaxCategoryQueries.update(self.params.uuid, updates)
            return { status = 200, json = { data = updated, message = "Category updated" } }
        end)
    )

    -- DELETE /api/v2/admin/categories/:uuid
    app:delete("/api/v2/admin/categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local existing = TaxCategoryQueries.getByUuid(self.params.uuid)
            if not existing then
                return { status = 404, json = { error = "Category not found" } }
            end

            TaxCategoryQueries.delete(self.params.uuid)
            return { status = 200, json = { message = "Category deactivated" } }
        end)
    )

    -- ========================================
    -- HMRC Categories
    -- ========================================

    -- GET /api/v2/admin/hmrc-categories
    app:get("/api/v2/admin/hmrc-categories",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local rows = TaxCategoryQueries.getHmrcCategories()
            return { status = 200, json = { data = rows } }
        end)
    )

    -- POST /api/v2/admin/hmrc-categories
    app:post("/api/v2/admin/hmrc-categories",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            if not self.params.key or not self.params.label then
                return { status = 400, json = { error = "key and label are required" } }
            end

            local category = TaxCategoryQueries.createHmrc({
                key = self.params.key,
                label = self.params.label,
                box_number = self.params.box_number or db.NULL,
                description = self.params.description or db.NULL,
                is_tax_deductible = self.params.is_tax_deductible ~= false,
                is_active = true,
            })

            return { status = 201, json = { data = category, message = "HMRC category created" } }
        end)
    )

    -- PUT /api/v2/admin/hmrc-categories/:uuid
    app:put("/api/v2/admin/hmrc-categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local existing = TaxCategoryQueries.getHmrcByUuid(self.params.uuid)
            if not existing then
                return { status = 404, json = { error = "HMRC category not found" } }
            end

            local updates = {}
            if self.params.key then updates.key = self.params.key end
            if self.params.label then updates.label = self.params.label end
            if self.params.box_number then updates.box_number = self.params.box_number end
            if self.params.description then updates.description = self.params.description end
            if self.params.is_tax_deductible ~= nil then updates.is_tax_deductible = self.params.is_tax_deductible end
            if self.params.is_active ~= nil then updates.is_active = self.params.is_active end

            local updated = TaxCategoryQueries.updateHmrc(self.params.uuid, updates)
            return { status = 200, json = { data = updated, message = "HMRC category updated" } }
        end)
    )

    -- DELETE /api/v2/admin/hmrc-categories/:uuid
    app:delete("/api/v2/admin/hmrc-categories/:uuid",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local existing = TaxCategoryQueries.getHmrcByUuid(self.params.uuid)
            if not existing then
                return { status = 404, json = { error = "HMRC category not found" } }
            end

            TaxCategoryQueries.deleteHmrc(self.params.uuid)
            return { status = 200, json = { message = "HMRC category deactivated" } }
        end)
    )
end
